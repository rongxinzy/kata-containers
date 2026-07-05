#!/bin/bash
# deploy-containers.sh — Deploy VFIO containers and/or Docker container
#
# Usage:
#   bash deploy-containers.sh           # deploy both (default)
#   bash deploy-containers.sh --k       # deploy only VFIO containers
#   bash deploy-containers.sh --d       # deploy only Docker container
#   bash deploy-containers.sh --all     # deploy both (explicit)
#
# Prerequisites: bind-gpu.sh must be run first (produces /tmp/kata-iommu-groups.txt)
set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Argument parsing
# ---------------------------------------------------------------------------
PHASE="${1:-all}"
RUN_VFIO=false
RUN_DOCKER=false
case "$PHASE" in
    --k|--vfio)       RUN_VFIO=true; RUN_DOCKER=false ;;
    --d|--docker)     RUN_VFIO=false; RUN_DOCKER=true ;;
    --all|all|"")     RUN_VFIO=true; RUN_DOCKER=true ;;
    -h|--help)
        echo "Usage: $0 [--k|--d|--all]"
        echo
        echo "  --k     Deploy only VFIO containers (g1..g4)"
        echo "  --d     Deploy only Docker container (vllm-docker)"
        echo "  --all   Deploy both (default)"
        echo
        echo "Prerequisites: bash bind-gpu.sh must be run first."
        exit 0
        ;;
    *)
        echo "ERROR: unknown argument '$PHASE'. Use --k, --d, or --all." >&2
        exit 1
        ;;
esac

IMG="${2:-vllm/vllm-openai:v0.21.0-x86_64-cu129}"
VFIO_MEM="${3:-32g}"
VFIO_CPUS="${4:-16}"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
phase() { echo; echo "============================================================"; echo " $*"; echo "============================================================"; }

# ---------------------------------------------------------------------------
# 2. Common: read IOMMU groups
# ---------------------------------------------------------------------------
IOMMU_FILE="/tmp/kata-iommu-groups.txt"

if $RUN_VFIO; then
    if [ ! -f "$IOMMU_FILE" ]; then
        echo "ERROR: $IOMMU_FILE not found. Run bind-gpu.sh first." >&2
        exit 1
    fi

    IOMMU_GROUPS=()
    while IFS= read -r line; do
        [ -n "$line" ] && IOMMU_GROUPS+=("$line")
    done < "$IOMMU_FILE"

    TOTAL=${#IOMMU_GROUPS[@]}
    if [ "$TOTAL" -lt 8 ]; then
        echo "ERROR: Only $TOTAL IOMMU groups found, need at least 8" >&2
        exit 1
    fi

    GROUP_SIZE=$((TOTAL/4))
    BASE_PORT=8014

    log "IOMMU groups=$TOTAL, per group=$GROUP_SIZE, 4 groups total"
fi

# =========================================================================
# Phase: VFIO (Kata) Containers
# =========================================================================
deploy_vfio() {
    phase "Phase: VFIO containers (g1..g4)"

    # --- Configuration ---
    log "Configuring runtime..."
    cp /opt/kata/share/defaults/kata-containers/configuration-qemu-nvidia-gpu.toml \
       /etc/kata-containers/configuration.toml
    sed -i 's|^pod_resource_api_sock = .*|pod_resource_api_sock = ""|' /etc/kata-containers/configuration.toml
    sed -i "s|^default_vcpus = .*|default_vcpus = ${VFIO_CPUS}|" /etc/kata-containers/configuration.toml
    sed -i 's|^default_memory = .*|default_memory = 16384|' /etc/kata-containers/configuration.toml
    sed -i 's|^memory_slots = .*|memory_slots = 1|' /etc/kata-containers/configuration.toml
    sed -i 's|^pcie_root_port = .*|pcie_root_port = 8|' /etc/kata-containers/configuration.toml
    sed -i 's|^cold_plug_vfio = .*|cold_plug_vfio = "root-port"|' /etc/kata-containers/configuration.toml
    sed -i 's|^disable_selinux = .*|disable_selinux = true|' /etc/kata-containers/configuration.toml
    sed -i 's|^kernel_params = .*|kernel_params = "nvidia_uvm.uvm_ats_mode=0 nvidia.NVreg_DmaRemapPeerMmio=0 nvidia.NVreg_EnableResizableBar=0 pci=nocrs pci=assign-busses cgroup_no_v1=all"|' /etc/kata-containers/configuration.toml
    sed -i 's|^enable_hugepages = .*|enable_hugepages = false|' /etc/kata-containers/configuration.toml

    cp /etc/kata-containers/configuration.toml /opt/kata/share/defaults/kata-containers/configuration-qemu.toml
    mkdir -p /opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu
    cp /etc/kata-containers/configuration.toml /opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu/configuration-qemu-nvidia-gpu.toml
    ln -sf /opt/kata/bin/containerd-shim-kata-v2 /usr/local/bin/containerd-shim-kata-v2

    # --- Memlock ---
    log "Setting memlock=infinity..."
    mkdir -p /etc/systemd/system/containerd.service.d/
    cat > /etc/systemd/system/containerd.service.d/memlock.conf << 'MEMLOCK'
[Service]
LimitMEMLOCK=infinity
MEMLOCK
    systemctl daemon-reload

    # --- Clean stale containers & restart containerd ---
    log "Cleaning stale containers and restarting containerd..."

    # Remove known VFIO containers gracefully
    for NAME in g1 g2 g3 g4; do
        nerdctl rm -f "${NAME}" 2>/dev/null || true
        ctr -n default tasks delete "${NAME}" 2>/dev/null || true
        ctr -n default containers delete "${NAME}" 2>/dev/null || true
    done

    # Kill any lingering QEMU/shims from previous runs
    pkill -9 qemu-system 2>/dev/null || true
    pkill -9 containerd-shim 2>/dev/null || true
    sleep 2

    # Clean runtime scratch dirs (not containerd data)
    rm -rf /run/vc /run/containerd
    systemctl restart containerd
    sleep 3

    # --- Expand /dev/shm ---
    log "Expanding /dev/shm to 300G..."
    mount -o remount,size=300G /dev/shm

    # --- Ensure image exists in containerd ---
    log "Checking container image in containerd..."
    if ! ctr -n default images ls 2>/dev/null | grep -q "vllm/vllm-openai"; then
        log "Image not found in containerd, importing from Docker..."
        if docker image inspect "${IMG}" >/dev/null 2>&1; then
            docker save "${IMG}" | nerdctl load
            log "Image imported from Docker successfully."
        else
            log "Docker image not available, pulling from registry..."
            ctr -n default images pull --hosts-dir /etc/containerd/certs.d "${IMG}"
            log "Image pulled from registry."
        fi
    else
        log "Image already present in containerd."
    fi

    # --- Deploy 4 containers ---
    for gid in 0 1 2 3; do
        start=$((gid * GROUP_SIZE))
        end=$((start + GROUP_SIZE - 1))

        local_groups=""
        local_bfds=""
        for i in $(seq $start $end); do
            grp="${IOMMU_GROUPS[$i]}"
            local_groups="$local_groups $grp"
            bdf=$(ls /sys/kernel/iommu_groups/${grp}/devices/ 2>/dev/null | grep '\.0$' | head -1)
            [ -n "$bdf" ] && local_bfds="$local_bfds $bdf"
        done

        PORT=$((BASE_PORT + gid))
        NAME="g$((gid+1))"

        log ">>> ${NAME} (port ${PORT}, groups: ${local_groups})"

        /root/acs_shutdown_vfio_group.sh ${local_bfds} 2>/dev/null || true

        DEVICE_ARGS=""
        for grp in $local_groups; do
            DEVICE_ARGS="$DEVICE_ARGS --device=/dev/vfio/${grp}"
        done

        nerdctl rm -f "${NAME}" 2>/dev/null || true
        nerdctl run -d --pull never --runtime io.containerd.kata.v2 --name "${NAME}" \
            ${DEVICE_ARGS} -m "${VFIO_MEM}" -p "${PORT}:8000" -v /models:/models \
            --env NVIDIA_VISIBLE_DEVICES=void --env NVIDIA_DRIVER_CAPABILITIES=compute,utility \
            --entrypoint /bin/bash "${IMG}" -c "sleep infinity"

        log "  Waiting for GPU..."
        for i in $(seq 1 30); do
            sleep 5
            if nerdctl exec "${NAME}" nvidia-smi -L >/dev/null 2>&1; then
                log "  [${NAME}] ready ($((i*5))s)"
                break
            fi
            [ $((i % 6)) -eq 0 ] && log "  [${NAME}] ...($((i*5))s)"
        done

        nerdctl exec "${NAME}" nvidia-smi -L | wc -l | xargs echo "  GPU count:"
    done

    log "VFIO deployment done."
}

# =========================================================================
# Phase: Docker Container
# =========================================================================
deploy_docker() {
    phase "Phase: Docker container (vllm-docker)"

    # Ensure image is available for Docker
    if ! docker image inspect "${IMG}" >/dev/null 2>&1; then
        log "Pulling image ${IMG}..."
        docker pull "${IMG}"
    fi

    log "Starting Docker container (all nvidia GPUs)..."
    docker rm -f vllm-docker 2>/dev/null || true
    docker run -d --name vllm-docker --runtime nvidia --gpus all --net=host \
        -v /models:/models -e NCCL_P2P_LEVEL=SYS \
        --entrypoint sleep "${IMG}" infinity
    sleep 10

    DOCKER_GPU=$(docker exec vllm-docker nvidia-smi -L 2>/dev/null | wc -l)
    log "Docker GPU count: ${DOCKER_GPU}"
}

# =========================================================================
# Execute
# =========================================================================

if $RUN_VFIO; then
    deploy_vfio
fi

if $RUN_DOCKER; then
    deploy_docker
fi

# =========================================================================
# Summary
# =========================================================================
phase "Summary"

if $RUN_VFIO; then
    echo "--- VFIO containers ---"
    nerdctl ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E '^g[1-4]' || echo "  (none)"
    echo "QEMU processes: $(ps aux | grep qemu-system | grep -v grep | wc -l)"
fi

if $RUN_DOCKER; then
    echo "--- Docker container ---"
    docker ps --format "table {{.Names}}\t{{.Status}}" | grep vllm || echo "  (none)"
fi

df -h /dev/shm
log "Done."
