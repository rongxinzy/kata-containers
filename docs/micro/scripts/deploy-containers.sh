#!/bin/bash
# deploy-containers.sh — Deploy VFIO containers and/or Docker container
#
# Usage:
#   bash deploy-containers.sh                        # deploy both, 4 groups (default)
#   bash deploy-containers.sh --groups=2             # deploy both, 2 groups (16 GPU each)
#   bash deploy-containers.sh --groups=4             # deploy both, 4 groups (8 GPU each)
#   bash deploy-containers.sh --k                    # deploy only VFIO containers
#   bash deploy-containers.sh --d                    # deploy only Docker container
#   bash deploy-containers.sh --k --groups=2         # VFIO only, 2 groups
#
# Prerequisites: bind-gpu.sh must be run first (produces /tmp/kata-iommu-groups.txt)
set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Argument parsing
# ---------------------------------------------------------------------------
PHASE="all"
RUN_VFIO=false
RUN_DOCKER=false
NUM_GROUPS=4

for arg in "$@"; do
    case "$arg" in
        --k|--vfio)       RUN_VFIO=true ;;
        --d|--docker)     RUN_DOCKER=true ;;
        --groups=*)       NUM_GROUPS="${arg#*=}" ;;
        --all|all)        RUN_VFIO=true; RUN_DOCKER=true ;;
        -h|--help)
            echo "Usage: $0 [--k|--d|--all] [--groups=N]"
            echo
            echo "  --k         Deploy only VFIO containers"
            echo "  --d         Deploy only Docker container"
            echo "  --all       Deploy both (default)"
            echo "  --groups=N  Number of VFIO container groups: 2 (16 GPU each) or 4 (8 GPU each, default)"
            echo
            echo "Prerequisites: bash bind-gpu.sh must be run first."
            echo "Examples:"
            echo "  $0                          # 4 groups × 8 GPU (default)"
            echo "  $0 --groups=2               # 2 groups × 16 GPU"
            echo "  $0 --k --groups=2           # VFIO only, 2 groups × 16 GPU"
            exit 0
            ;;
        *)  ;;
    esac
done

# Default: if no phase specified, run both
if ! $RUN_VFIO && ! $RUN_DOCKER; then
    case "$PHASE" in
        all|"") RUN_VFIO=true; RUN_DOCKER=true ;;
    esac
fi

# Validate groups
if [ "$NUM_GROUPS" != "2" ] && [ "$NUM_GROUPS" != "4" ]; then
    echo "ERROR: --groups must be 2 or 4" >&2
    exit 1
fi

# Defaults (parsed args override later)
IMG="vllm/vllm-openai:v0.21.0-x86_64-cu129"
VFIO_MEM="32g"
VFIO_CPUS="16"

# Override from command line (positional params after flags)
for arg in "$@"; do
    case "$arg" in
        -m=*)   VFIO_MEM="${arg#*=}" ;;
        --mem=*) VFIO_MEM="${arg#*=}" ;;
        --cpus=*) VFIO_CPUS="${arg#*=}" ;;
        --img=*) IMG="${arg#*=}" ;;
    esac
done

# Override memory for 16 GPU mode
if [ "$NUM_GROUPS" = "2" ] && [ "$VFIO_MEM" = "32g" ]; then
    VFIO_MEM="96g"
    VFIO_CPUS="32"
fi

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
    MIN_NEEDED=$((NUM_GROUPS * 8))
    if [ "$TOTAL" -lt "$MIN_NEEDED" ]; then
        echo "ERROR: Only $TOTAL IOMMU groups found, need at least $MIN_NEEDED" >&2
        exit 1
    fi

    GROUP_SIZE=$((TOTAL/NUM_GROUPS))
    BASE_PORT=8014
    GPU_PER_CONTAINER=$((TOTAL/NUM_GROUPS))

    # Set NCCL P2P level based on GPU count per container
    if [ "$GPU_PER_CONTAINER" -ge 16 ]; then
        NCCL_P2P_LEVEL=5
    else
        NCCL_P2P_LEVEL=SYS
    fi

    # Container names
    VFIO_NAMES=()
    for i in $(seq 1 $NUM_GROUPS); do
        VFIO_NAMES+=("g${i}")
    done

    log "Mode: ${NUM_GROUPS} groups × ${GPU_PER_CONTAINER} GPU, NCCL_P2P_LEVEL=${NCCL_P2P_LEVEL}, MEM=${VFIO_MEM}"
fi

# =========================================================================
# Phase: VFIO (Kata) Containers
# =========================================================================
deploy_vfio() {
    phase "Phase: VFIO containers (${NUM_GROUPS} groups × ${GPU_PER_CONTAINER} GPU each)"

    # --- Configuration ---
    log "Configuring runtime..."
    cp /opt/kata/share/defaults/kata-containers/configuration-qemu-nvidia-gpu.toml \
       /etc/kata-containers/configuration.toml
    sed -i 's|^pod_resource_api_sock = .*|pod_resource_api_sock = ""|' /etc/kata-containers/configuration.toml
    sed -i "s|^default_vcpus = .*|default_vcpus = ${VFIO_CPUS}|" /etc/kata-containers/configuration.toml
    sed -i 's|^default_memory = .*|default_memory = 16384|' /etc/kata-containers/configuration.toml
    sed -i 's|^memory_slots = .*|memory_slots = 1|' /etc/kata-containers/configuration.toml
    if [ "$GPU_PER_CONTAINER" -ge 16 ]; then
        # 16 GPU mode: no root ports needed, save PCI slots for vhost devices
        sed -i 's|^pcie_root_port = .*|pcie_root_port = 0|' /etc/kata-containers/configuration.toml
    else
        sed -i 's|^pcie_root_port = .*|pcie_root_port = 8|' /etc/kata-containers/configuration.toml
    fi
    sed -i 's|^cold_plug_vfio = .*|cold_plug_vfio = "root-port"|' /etc/kata-containers/configuration.toml
    sed -i 's|^disable_selinux = .*|disable_selinux = true|' /etc/kata-containers/configuration.toml
    sed -i 's|^kernel_params = .*|kernel_params = "nvidia_uvm.uvm_ats_mode=0 nvidia.NVreg_DmaRemapPeerMmio=0 nvidia.NVreg_EnableResizableBar=0 pci=nocrs pci=assign-busses cgroup_no_v1=all"|' /etc/kata-containers/configuration.toml
    sed -i 's|^enable_hugepages = .*|enable_hugepages = false|' /etc/kata-containers/configuration.toml
    sed -i 's|agent.launch_process_timeout=[0-9]*|agent.launch_process_timeout=120|' /etc/kata-containers/configuration.toml

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

    for NAME in "${VFIO_NAMES[@]}"; do
        nerdctl rm -f "${NAME}" 2>/dev/null || true
        ctr -n default tasks delete "${NAME}" 2>/dev/null || true
        ctr -n default containers delete "${NAME}" 2>/dev/null || true
    done

    pkill -9 qemu-system 2>/dev/null || true
    pkill -9 containerd-shim 2>/dev/null || true
    sleep 2

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

    # --- Deploy N containers ---
    for gid in $(seq 0 $((NUM_GROUPS - 1))); do
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
        NAME="${VFIO_NAMES[$gid]}"

        log ">>> ${NAME} (port ${PORT}, groups: ${local_groups})"

        /root/acs_shutdown_vfio_group.sh ${local_bfds} 2>/dev/null || true

        DEVICE_ARGS=""
        for grp in $local_groups; do
            DEVICE_ARGS="$DEVICE_ARGS --device=/dev/vfio/${grp}"
        done

        nerdctl rm -f "${NAME}" 2>/dev/null || true
        nerdctl run -d --pull never --runtime io.containerd.kata.v2 --name "${NAME}" \
            ${DEVICE_ARGS} -m "${VFIO_MEM}" -p "${PORT}:8000" -v /models:/models \
            --env NCCL_P2P_LEVEL=${NCCL_P2P_LEVEL} \
            --env NVIDIA_VISIBLE_DEVICES=void --env NVIDIA_DRIVER_CAPABILITIES=compute,utility \
            --entrypoint /bin/bash "${IMG}" -c "sleep infinity"

        log "  Waiting for GPU..."
        for i in $(seq 1 60); do
            sleep 5
            if nerdctl exec "${NAME}" dx-smi -L >/dev/null 2>&1; then
                log "  [${NAME}] ready ($((i*5))s)"
                break
            fi
            [ $((i % 12)) -eq 0 ] && log "  [${NAME}] ...($((i*5))s)"
        done

        nerdctl exec "${NAME}" dx-smi -L | wc -l | xargs echo "  GPU count:"
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
    echo "--- VFIO containers (${NUM_GROUPS} groups) ---"
    nerdctl ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "^g[1-${NUM_GROUPS}]" || echo "  (none)"
    echo "QEMU processes: $(ps aux | grep qemu-system | grep -v grep | wc -l)"
fi

if $RUN_DOCKER; then
    echo "--- Docker container ---"
    docker ps --format "table {{.Names}}\t{{.Status}}" | grep vllm || echo "  (none)"
fi

df -h /dev/shm
log "Done."
