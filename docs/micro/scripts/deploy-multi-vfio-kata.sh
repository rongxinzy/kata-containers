#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
#
# deploy-multi-vfio-kata.sh
#
# Deploy 8 Kata Containers VFIO fixed-BAR GPA=HPA GPU passthrough instances on
# 172.18.5.133.  Each instance gets 8 GPUs that all hang under the same
# first-level PCIe switch fabric (the largest common switch domain on this
# platform).  The script copies locally patched runtime binaries and QEMU,
# disables ACS on every bridge in each GPU path, starts the containers,
# verifies fixed-BAR mapping, P2P and NCCL all-reduce.
#
# Usage:
#   ./deploy-multi-vfio-kata.sh
#
# The script leaves all 8 containers running so the user can start vLLM
# manually in each one.  Guest RAM is kept small (12 GiB) so that 8 VMs fit
# inside the available 1 GiB hugepages.

set -o errexit
set -o nounset
set -o pipefail

# ---------------------------------------------------------------------------
# Connection and local source
# ---------------------------------------------------------------------------
: "${TARGET_HOST:=172.18.5.133}"
: "${TARGET_USER:=root}"
: "${TARGET_PASS:=Admin@9000}"
: "${TARGET_KEY:=}"
: "${KATA_SRC:=/home/bingo/kata-containers}"
# Space-separated list of group numbers to deploy, default all 8 groups.
: "${DEPLOY_GROUPS:=1 2 3 4 5 6 7 8}"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
BACKUP_DIR="/root/kata-backup-$(date +%Y%m%d-%H%M%S)"

# ---------------------------------------------------------------------------
# Per-container settings
# ---------------------------------------------------------------------------
: "${CONTAINER_IMAGE:=vllm/vllm-openai:v0.21.0-x86_64-cu129}"
: "${GUEST_RAM_GB:=12}"
: "${GUEST_VCPUS:=8}"
: "${NCCL_MODELS_DIR:=/models/nccl-tests-2.18.3}"
: "${VLLM_MODEL_DIR:=/models/Qwen3.6-35B-A3B-FP8}"
: "${BASE_PORT:=8006}"

# ---------------------------------------------------------------------------
# GPU groups (VFIO /dev/vfio/<N> numbers of function 0).
# Groups are chosen so that every GPU in a group is under the same first-level
# PCIe switch (08:00.0, 27:00.0, 88:00.0 or a5:00.0).  No single downstream
# switch on this platform has 8 GPUs, so each group spans 2-3 downstream
# switches that share the same first-level switch.
# ---------------------------------------------------------------------------
declare -a GROUP1=(27 28 34 35 36 37 43 44)
declare -a GROUP2=(45 46 52 53 54 55 59 60)
declare -a GROUP3=(72 73 79 80 81 82 88 89)
declare -a GROUP4=(90 91 97 98 99 100 104 105)
declare -a GROUP5=(128 129 135 136 137 138 144 145)
declare -a GROUP6=(146 147 153 154 155 156 160 161)
declare -a GROUP7=(173 174 180 181 182 183 189 190)
declare -a GROUP8=(191 192 198 199 200 201 205 206)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
run_remote() {
    if [[ -n "${TARGET_KEY}" ]]; then
        ssh ${SSH_OPTS} -i "${TARGET_KEY}" "${TARGET_USER}@${TARGET_HOST}" "$@"
    else
        sshpass -p "${TARGET_PASS}" ssh ${SSH_OPTS} "${TARGET_USER}@${TARGET_HOST}" "$@"
    fi
}

copy_to_remote() {
    local src="$1"
    local dst="$2"
    if [[ -n "${TARGET_KEY}" ]]; then
        scp ${SSH_OPTS} -i "${TARGET_KEY}" -r "${src}" "${TARGET_USER}@${TARGET_HOST}:${dst}"
    else
        sshpass -p "${TARGET_PASS}" scp ${SSH_OPTS} -r "${src}" "${TARGET_USER}@${TARGET_HOST}:${dst}"
    fi
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Return the GPU function-0 BDF for a VFIO group number.
vfio_group_to_bdf() {
    local grp="$1"
    run_remote "
        dev=\$(ls /sys/kernel/iommu_groups/${grp}/devices/ 2>/dev/null | grep '\.0$' | head -1)
        if [[ -z \${dev} ]]; then
            echo "ERROR: no function-0 device in IOMMU group ${grp}" >&2
            exit 1
        fi
        echo \${dev}
    "
}

# ---------------------------------------------------------------------------
# 0. Validate local assets
# ---------------------------------------------------------------------------
log "Validating local Kata assets in ${KATA_SRC}"

KATA_RUNTIME="${KATA_SRC}/src/runtime/kata-runtime"
KATA_SHIM="${KATA_SRC}/src/runtime/containerd-shim-kata-v2"
QEMU_BIN="${KATA_SRC}/tools/packaging/static-build/qemu/kata-static-qemu.tar.gz"
OVMF_FD="${KATA_SRC}/tools/packaging/kata-deploy/local-build/build/ovmf/destdir/opt/kata/share/ovmf/OVMF.fd"

for f in "${KATA_RUNTIME}" "${KATA_SHIM}" "${QEMU_BIN}"; do
    if [[ ! -f "${f}" ]]; then
        echo "ERROR: missing ${f}" >&2
        exit 1
    fi
done

if [[ ! -f "${OVMF_FD}" ]]; then
    echo "WARNING: local OVMF.fd not found at ${OVMF_FD}; using target OVMF" >&2
fi

# ---------------------------------------------------------------------------
# 1. Deploy patched binaries to target (skip if a previous group is running
#    and the shim binary is locked; set SKIP_BINARY_COPY=true)
# ---------------------------------------------------------------------------
: "${SKIP_BINARY_COPY:=false}"

log "Deploying patched binaries to ${TARGET_HOST}"
run_remote "mkdir -p ${BACKUP_DIR}/{bin,share/ovmf}"

if [[ "${SKIP_BINARY_COPY}" == "true" ]]; then
    log "SKIP_BINARY_COPY=true: skipping binary copy (using already-deployed patched binaries)"
    run_remote "
        cp /opt/kata/bin/qemu-system-x86_64 ${BACKUP_DIR}/bin/ 2>/dev/null || true
        cp /opt/kata/share/ovmf/OVMF.fd ${BACKUP_DIR}/share/ovmf/ 2>/dev/null || true
        cp /opt/kata/bin/kata-runtime ${BACKUP_DIR}/bin/ 2>/dev/null || true
        cp /opt/kata/bin/containerd-shim-kata-v2 ${BACKUP_DIR}/bin/ 2>/dev/null || true
    "
else
    run_remote "
        cp /opt/kata/bin/qemu-system-x86_64 ${BACKUP_DIR}/bin/ 2>/dev/null || true
        cp /opt/kata/share/ovmf/OVMF.fd ${BACKUP_DIR}/share/ovmf/ 2>/dev/null || true
        cp /opt/kata/bin/kata-runtime ${BACKUP_DIR}/bin/ 2>/dev/null || true
        cp /opt/kata/bin/containerd-shim-kata-v2 ${BACKUP_DIR}/bin/ 2>/dev/null || true
    "

    log "Extracting patched QEMU on target"
    copy_to_remote "${QEMU_BIN}" "/tmp/kata-static-qemu.tar.gz"
    run_remote "cd / && tar -xzf /tmp/kata-static-qemu.tar.gz"

    log "Copying runtime binaries"
    copy_to_remote "${KATA_RUNTIME}" "/opt/kata/bin/kata-runtime"
    copy_to_remote "${KATA_SHIM}" "/opt/kata/bin/containerd-shim-kata-v2"
    run_remote "chmod +x /opt/kata/bin/kata-runtime /opt/kata/bin/containerd-shim-kata-v2"

    if [[ -f "${OVMF_FD}" ]]; then
        log "Copying patched OVMF.fd"
        copy_to_remote "${OVMF_FD}" "/opt/kata/share/ovmf/OVMF.fd"
        run_remote "chmod 644 /opt/kata/share/ovmf/OVMF.fd"
    fi
fi

run_remote "md5sum /opt/kata/bin/qemu-system-x86_64 /opt/kata/share/ovmf/OVMF.fd /opt/kata/bin/kata-runtime /opt/kata/bin/containerd-shim-kata-v2"

# ---------------------------------------------------------------------------
# 2. Apply Kata configuration
# ---------------------------------------------------------------------------
log "Applying Kata configuration"
run_remote "
    cp /opt/kata/share/defaults/kata-containers/configuration-qemu-nvidia-gpu.toml /etc/kata-containers/configuration.toml
    sed -i 's|^pod_resource_api_sock = .*|pod_resource_api_sock = \"\"|' /etc/kata-containers/configuration.toml
    sed -i 's|^default_vcpus = .*|default_vcpus = ${GUEST_VCPUS}|' /etc/kata-containers/configuration.toml
    sed -i 's|^pcie_root_port = .*|pcie_root_port = 8|' /etc/kata-containers/configuration.toml
    sed -i 's|^cold_plug_vfio = .*|cold_plug_vfio = \"root-port\"|' /etc/kata-containers/configuration.toml
    sed -i 's|^disable_selinux = .*|disable_selinux = true|' /etc/kata-containers/configuration.toml
    sed -i 's|^kernel_params = .*|kernel_params = \"nvidia_uvm.uvm_ats_mode=0 pci=nocrs pci=assign-busses cgroup_no_v1=all\"|' /etc/kata-containers/configuration.toml
    sed -i 's|^enable_hugepages = .*|enable_hugepages = true|' /etc/kata-containers/configuration.toml
"

log "Restarting containerd"
run_remote "systemctl restart containerd"
sleep 3

# ---------------------------------------------------------------------------
# 3. Bind GPUs to vfio-pci (idempotent)
#    Set SKIP_GPU_BIND=true when a previous container is already running and
#    its QEMU holds /dev/vfio devices, which would make vfio_nvidia_bind.sh
#    hang in vfio_unregister_group_dev().
# ---------------------------------------------------------------------------
: "${SKIP_GPU_BIND:=false}"

if [[ "${SKIP_GPU_BIND}" == "true" ]]; then
    log "SKIP_GPU_BIND=true: skipping vfio-pci bind step (assuming GPUs are already bound)"
else
    log "Binding all NVIDIA GPUs to vfio-pci"
    if [[ -f "${KATA_SRC}/vfio_nvidia_bind.sh" ]]; then
        copy_to_remote "${KATA_SRC}/vfio_nvidia_bind.sh" "/root/vfio_nvidia_bind.sh"
        run_remote "chmod +x /root/vfio_nvidia_bind.sh && /root/vfio_nvidia_bind.sh bind"
    else
        echo "WARNING: vfio_nvidia_bind.sh not found; assuming GPUs are already bound" >&2
    fi
fi

# ---------------------------------------------------------------------------
# 4. Install enhanced ACS shutdown helper on target
# ---------------------------------------------------------------------------
log "Installing enhanced ACS shutdown helper"
cat > /tmp/acs_shutdown_vfio_group.sh <<'EOF'
#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

# Read all bridges into arrays
declare -A SEC SUB
declare -a BRIDGES=()
for d in /sys/bus/pci/devices/0000:*; do
    bdf=$(basename "${d}")
    if [[ -f "${d}/secondary_bus_number" ]]; then
        SEC["${bdf}"]=$(cat "${d}/secondary_bus_number" | tr -d ' ')
        SUB["${bdf}"]=$(cat "${d}/subordinate_bus_number" | tr -d ' ')
        BRIDGES+=("${bdf}")
    fi
done

bus_of() {
    printf '%d' "0x$(echo "$1" | cut -d: -f2)"
}

# Find the upstream bridge of a given BDF (tightest range)
upstream_bridge() {
    local bdf="$1"
    local bus=$(bus_of "${bdf}")
    local best=""
    local best_range=999999
    for b in "${BRIDGES[@]}"; do
        [[ "$b" == "${bdf}" ]] && continue
        if [[ ${SEC[$b]} -le ${bus} && ${bus} -le ${SUB[$b]} ]]; then
            local range=$(( ${SUB[$b]} - ${SEC[$b]} ))
            if [[ ${range} -lt ${best_range} ]]; then
                best_range=${range}
                best=${b}
            fi
        fi
    done
    echo "${best}"
}

# Collect ancestor bridges for the given GPU BDFs
declare -A SEEN
ancestor_bridges=()
for gpu in "$@"; do
    cur="${gpu}"
    while true; do
        up=$(upstream_bridge "${cur}")
        [[ -z "${up}" ]] && break
        if [[ -z "${SEEN[${up}]+x}" ]]; then
            SEEN[${up}]=1
            ancestor_bridges+=("${up}")
        fi
        [[ "${up}" == "${cur}" ]] && break
        cur="${up}"
    done
done

# Disable ACS on every collected bridge that exposes the ACS control register
for bdf in "${ancestor_bridges[@]}"; do
    acs_val=$(setpci -s "${bdf}" ECAP_ACS+0x6.w 2>/dev/null || true)
    [[ -z "${acs_val}" ]] && continue
    printf 'Disabling ACS on %s was %s\n' "${bdf}" "${acs_val}"
    setpci -s "${bdf}" ECAP_ACS+0x6.w=0x0000
    new_val=$(setpci -s "${bdf}" ECAP_ACS+0x6.w 2>/dev/null || true)
    printf '  -> now %s\n' "${new_val}"
done

echo "ACS shutdown complete."
EOF
copy_to_remote /tmp/acs_shutdown_vfio_group.sh /root/acs_shutdown_vfio_group.sh
run_remote "chmod +x /root/acs_shutdown_vfio_group.sh && bash -n /root/acs_shutdown_vfio_group.sh"

# ---------------------------------------------------------------------------
# 5. Deploy one Kata VFIO container per group
# ---------------------------------------------------------------------------
deploy_group() {
    local idx="$1"
    local -n group="$2"
    local port=$(( BASE_PORT + idx - 1 ))
    local name="kata-vfio-group${idx}"
    local mem="${GUEST_RAM_GB}g"

    log "[group${idx}] Resolving VFIO groups: ${group[*]}"
    local bdfs=""
    local device_args=""
    for g in "${group[@]}"; do
        local bdf
        bdf=$(vfio_group_to_bdf "${g}")
        bdfs="${bdfs} ${bdf}"
        device_args="${device_args} --device /dev/vfio/${g}"
    done
    bdfs=$(echo "${bdfs}" | sed 's/^ *//')

    log "[group${idx}] Disabling ACS on all ancestor bridges for: ${bdfs}"
    run_remote "/root/acs_shutdown_vfio_group.sh ${bdfs}"

    log "[group${idx}] Starting container ${name} with ${#group[@]} GPUs, ${mem} RAM, host port ${port}"
    run_remote "
        nerdctl rm -f ${name} 2>/dev/null || true
        ctr -n default tasks delete ${name} 2>/dev/null || true
        ctr -n default containers delete ${name} 2>/dev/null || true
        nerdctl run -d \\
            --runtime io.containerd.kata.v2 \\
            --name ${name} \\
            ${device_args} \\
            -m ${mem} \\
            -p ${port}:8000 \\
            -v ${NCCL_MODELS_DIR}:${NCCL_MODELS_DIR} \\
            -v ${VLLM_MODEL_DIR}:${VLLM_MODEL_DIR} \\
            --entrypoint /bin/bash \\
            ${CONTAINER_IMAGE} \\
            -c 'sleep infinity'
    "

    log "[group${idx}] Waiting for container to be ready"
    local ready=false
    for i in $(seq 1 60); do
        if run_remote "nerdctl exec ${name} nvidia-smi -L" >/dev/null 2>&1; then
            ready=true
            break
        fi
        sleep 5
    done
    if [[ "${ready}" != "true" ]]; then
        echo "ERROR: [group${idx}] container did not become ready" >&2
        return 1
    fi

    log "[group${idx}] nvidia-smi GPU list"
    run_remote "nerdctl exec ${name} nvidia-smi -L"

    log "[group${idx}] Verifying fixed-BAR GPA=HPA (first GPU)"
    local first_dev
    first_dev=$(echo "${bdfs}" | awk '{print $1}')
    run_remote "
        echo '=== Guest BAR1 ==='
        nerdctl exec ${name} bash -c 'cat /sys/bus/pci/devices/0000:00:10.0/resource | head -1'
        echo '=== Host BAR1 ==='
        cat /sys/bus/pci/devices/${first_dev}/resource | head -1
    "

    if [[ -n "${RUN_P2P_TEST:-}" && -f "${NCCL_MODELS_DIR}/p2pBandwidthLatencyTest" ]]; then
        log "[group${idx}] P2P connectivity test"
        run_remote "
            nerdctl exec ${name} ${NCCL_MODELS_DIR}/p2pBandwidthLatencyTest --numElems=4000000 2>&1 | tail -30
        " || true
    else
        log "[group${idx}] Skipping P2P test (p2pBandwidthLatencyTest not available)"
    fi

    log "[group${idx}] NCCL all-reduce (default P2P level)"
    run_remote "
        nerdctl exec ${name} bash -c 'cd ${NCCL_MODELS_DIR}/build && timeout 120 ./all_reduce_perf -b 8M -e 256M -f 2 -g 8 -t 1 -n 20 -w 5' 2>&1 | tail -30
    " || true

    log "[group${idx}] Re-disabling ACS after container start"
    run_remote "/root/acs_shutdown_vfio_group.sh ${bdfs}"

    log "[group${idx}] NCCL all-reduce (NCCL_P2P_LEVEL=SYS)"
    run_remote "
        nerdctl exec ${name} bash -c 'cd ${NCCL_MODELS_DIR}/build && export NCCL_P2P_LEVEL=SYS && timeout 120 ./all_reduce_perf -b 8M -e 256M -f 2 -g 8 -t 1 -n 20 -w 5' 2>&1 | tail -30
    " || true

    log "[group${idx}] Container ${name} is running on host port ${port}"
    echo
}

for i in ${DEPLOY_GROUPS}; do
    case ${i} in
        1) deploy_group 1 GROUP1 ;;
        2) deploy_group 2 GROUP2 ;;
        3) deploy_group 3 GROUP3 ;;
        4) deploy_group 4 GROUP4 ;;
        5) deploy_group 5 GROUP5 ;;
        6) deploy_group 6 GROUP6 ;;
        7) deploy_group 7 GROUP7 ;;
        8) deploy_group 8 GROUP8 ;;
    esac
done

# ---------------------------------------------------------------------------
# 6. Final summary
# ---------------------------------------------------------------------------
log "All groups deployed. Summary:"
run_remote "
    echo '=== containers ==='
    nerdctl ps -a --format 'table {{.Names}}\\t{{.Status}}\\t{{.Ports}}' | grep kata-vfio-group || true
    echo
    echo '=== hugepages ==='
    grep Huge /proc/meminfo
    echo
    echo '=== QEMU processes ==='
    ps aux | grep qemu-system-x86_64 | grep -v grep | wc -l
"

log "Done. Previous binaries backed up to ${TARGET_HOST}:${BACKUP_DIR}"
log "To start vLLM manually in a container:"
log "  ssh ${TARGET_USER}@${TARGET_HOST} 'nerdctl exec -it kata-vfio-group1 bash'"
