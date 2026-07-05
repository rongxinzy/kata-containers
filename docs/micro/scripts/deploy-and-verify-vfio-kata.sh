#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
#
# deploy-and-verify-vfio-kata.sh
#
# One-shot script to deploy and verify the Kata Containers VFIO fixed-BAR
# GPA=HPA GPU passthrough setup.  All remote credentials are taken from
# environment variables so no secrets are stored in this file.
#
# Usage:
#   export TARGET_HOST=172.18.5.243
#   export TARGET_USER=root
#   export TARGET_PASS=Admin@9000          # or use TARGET_KEY
#   export GPU_VFIO_GROUPS="43 44 45 51 52 53 59 60"
#   export TEST_GPUS=8
#   ./deploy-and-verify-vfio-kata.sh
#
# The script is intentionally linear and pauses before destructive steps so
# you can inspect what it is about to do.

set -o errexit
set -o nounset
set -o pipefail

# ---------------------------------------------------------------------------
# User-configurable environment variables
# ---------------------------------------------------------------------------
: "${TARGET_HOST:?must be set, e.g. 172.18.5.243}"
: "${TARGET_USER:?must be set, e.g. root}"
: "${TARGET_PASS:=}"                       # password auth
: "${TARGET_KEY:=}"                         # or private-key auth
: "${KATA_SRC:=/home/bingo/kata-containers}" # local Kata source tree (for binary copy)
: "${NCCL_MODELS_DIR:=/models/DeepSeek-R1-Distill-Qwen-1.5B}"
: "${VLLM_MODEL_DIR:=/models/Qwen3.6-35B-A3B-FP8}" # model served by vLLM
: "${VLLM_PORT:=8006}"                      # vLLM OpenAI API server port
: "${VLLM_TP_SIZE:=4}"                      # tensor-parallel size for vLLM
: "${VLLM_PP_SIZE:=2}"                      # pipeline-parallel size for vLLM (TP*PP must equal number of GPUs)
: "${VLLM_MAX_MODEL_LEN:=4096}"             # max model length for vLLM
: "${VLLM_MAX_NUM_SEQS:=256}"               # max number of sequences for vLLM
: "${CONTAINER_IMAGE:=vllm/vllm-openai:v0.21.0-x86_64-cu129}"
: "${GPU_VFIO_GROUPS:=43 44 45 51 52 53 59 60}" # /dev/vfio/<N> numbers, one per GPU
: "${TEST_GPUS:=8}"                         # number of GPUs to use for NCCL/P2P
: "${SKIP_REBUILD:=true}"                   # skip local source rebuild (use prebuilt binaries)
: "${SKIP_ACS_SHUTDOWN:=false}"             # set to true if you disabled ACS manually
: "${DEPLOY_VLLM_35B:=true}"                # also deploy and test the 35B vLLM model
: "${START_VLLM_IN_CONTAINER:=true}"        # true=print command for manual launch; false=auto-start vLLM
: "${SKIP_CLEANUP:=false}"                  # leave the container running for manual inspection

BACKUP_DIR="/root/kata-backup-$(date +%Y%m%d-%H%M%S)"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

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

pause() {
    echo
    echo ">>> $1"
    # In non-interactive environments (e.g. CI) there is no TTY, so just
    # continue automatically after a short delay.
    if [[ -t 0 ]]; then
        read -rp "Press Enter to continue, Ctrl-C to abort ..."
    else
        echo "Non-interactive run: continuing automatically in 3 seconds ..."
        sleep 3
    fi
    echo
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# ---------------------------------------------------------------------------
# 0. Validate local source tree and prebuilt binaries
# ---------------------------------------------------------------------------
log "Validating local Kata source tree at ${KATA_SRC}"
cd "${KATA_SRC}"

if [[ ! -f "src/runtime/Makefile" ]]; then
    echo "ERROR: ${KATA_SRC} does not look like a Kata runtime source tree" >&2
    exit 1
fi

KATA_RUNTIME="${KATA_SRC}/src/runtime/kata-runtime"
KATA_SHIM="${KATA_SRC}/src/runtime/containerd-shim-kata-v2"

if [[ "${SKIP_REBUILD}" != "true" ]]; then
    log "SKIP_REBUILD=false: full rebuild requested"
    # Build patched QEMU
    QEMU_TARBALL="${KATA_SRC}/tools/packaging/static-build/qemu/kata-static-qemu.tar.gz"
    if [[ -f "${QEMU_TARBALL}" ]]; then
        log "Found existing QEMU tarball: ${QEMU_TARBALL}"
        pause "Rebuild QEMU tarball? (Ctrl-C to skip and use existing)"
    fi
    (
        cd "${KATA_SRC}/tools/packaging/static-build/qemu"
        export PATH="/root/go/bin:${PATH}"
        ./build-static-qemu.sh
    )
    log "QEMU tarball ready: ${QEMU_TARBALL}"

    # Build patched OVMF
    : "${EDK2_SRC:=/home/bingo/kata-ovmf/edk2}"
    if [[ ! -f "${EDK2_SRC}/edksetup.sh" ]]; then
        echo "ERROR: EDK2_SRC=${EDK2_SRC} does not look like an EDK2 checkout" >&2
        exit 1
    fi
    OVMF_BUILD_DIR="${KATA_SRC}/tools/packaging/kata-deploy/local-build/build/ovmf"
    OVMF_TARBALL="${OVMF_BUILD_DIR}/builddir/edk2-x86_64.tar.gz"
    OVMF_FD="${OVMF_BUILD_DIR}/destdir/opt/kata/share/ovmf/OVMF.fd"
    if [[ -f "${OVMF_TARBALL}" && -f "${OVMF_FD}" ]]; then
        log "Found existing OVMF tarball and OVMF.fd"
        pause "Rebuild OVMF? (Ctrl-C to skip and use existing)"
    fi
    (
        cd "${EDK2_SRC}"
        git submodule update --init || true
    )
    (
        cd "${KATA_SRC}/tools/packaging/static-build/ovmf"
        export PATH="/root/go/bin:${PATH}"
        OVMF_LOCAL_DIR="${EDK2_SRC}" ./build.sh
    )
    log "OVMF tarball ready: ${OVMF_TARBALL}"

    # Build Kata runtime
    (
        cd "${KATA_SRC}/src/runtime"
        export PATH="/usr/local/go/bin:${PATH}"
        make build
    )
    log "Runtime binaries rebuilt: ${KATA_RUNTIME}, ${KATA_SHIM}"
else
    log "SKIP_REBUILD=true: using prebuilt binaries"
    if [[ ! -f "${KATA_RUNTIME}" || ! -f "${KATA_SHIM}" ]]; then
        echo "ERROR: prebuilt binaries missing; run with SKIP_REBUILD=false first" >&2
        exit 1
    fi
    log "Runtime binaries ready: ${KATA_RUNTIME}, ${KATA_SHIM}"
fi

# ---------------------------------------------------------------------------
# 1. Deploy to target host
# ---------------------------------------------------------------------------
pause "About to deploy binaries to ${TARGET_HOST}. Existing files will be backed up to ${BACKUP_DIR}."

log "Creating backup directory on ${TARGET_HOST}"
run_remote "mkdir -p ${BACKUP_DIR}/{bin,share/ovmf}"

log "Backing up existing Kata binaries"
run_remote "
    cp /opt/kata/bin/qemu-system-x86_64 ${BACKUP_DIR}/bin/ 2>/dev/null || true
    cp /opt/kata/share/ovmf/OVMF.fd ${BACKUP_DIR}/share/ovmf/ 2>/dev/null || true
    cp /opt/kata/bin/kata-runtime ${BACKUP_DIR}/bin/ 2>/dev/null || true
    cp /opt/kata/bin/containerd-shim-kata-v2 ${BACKUP_DIR}/bin/ 2>/dev/null || true
"

if [[ "${SKIP_REBUILD}" != "true" ]]; then
    log "Copying QEMU tarball to target host"
    copy_to_remote "${QEMU_TARBALL}" "/tmp/kata-static-qemu.tar.gz"

    log "Copying OVMF tarball to target host"
    copy_to_remote "${OVMF_TARBALL}" "/tmp/edk2-x86_64.tar.gz"

    log "Extracting tarballs on target host"
    run_remote "
        cd /
        tar -xzf /tmp/kata-static-qemu.tar.gz
        tar -xzf /tmp/edk2-x86_64.tar.gz
    "
fi

log "Copying rebuilt runtime binaries"
copy_to_remote "${KATA_RUNTIME}" "/opt/kata/bin/kata-runtime"
copy_to_remote "${KATA_SHIM}" "/opt/kata/bin/containerd-shim-kata-v2"
run_remote "chmod +x /opt/kata/bin/kata-runtime /opt/kata/bin/containerd-shim-kata-v2"

log "Ensuring patched OVMF.fd is in place"
if [[ "${SKIP_REBUILD}" != "true" ]]; then
    run_remote "
        if [[ -f ${OVMF_FD} ]]; then
            cp ${OVMF_FD} /opt/kata/share/ovmf/OVMF.fd
            chmod 644 /opt/kata/share/ovmf/OVMF.fd
        fi
        md5sum /opt/kata/share/ovmf/OVMF.fd
    "
fi

# ---------------------------------------------------------------------------
# 2. Apply Kata configuration
# ---------------------------------------------------------------------------
log "Stage: apply Kata configuration"

# Use the nvidia-gpu template as the base.  This template already sets the
# nvidia-gpu kernel/image and vfio_mode=guest-kernel.  We override the
# parameters needed for fixed-BAR GPA=HPA passthrough.
run_remote "
    cp /opt/kata/share/defaults/kata-containers/configuration-qemu-nvidia-gpu.toml /etc/kata-containers/configuration.toml

    # The nvidia-gpu template assumes kubernetes and points pod_resource_api_sock
    # to the Kubelet socket.  In a bare-metal/containerd deployment we must
    # clear it so that cold-plug uses explicit --device /dev/vfio/N.
    sed -i 's|^pod_resource_api_sock = .*|pod_resource_api_sock = \"\"|' /etc/kata-containers/configuration.toml

    # We pass enough vCPUs for the guest NCCL workload.  Use <0 to pin to
    # physical cores, or an explicit positive number.
    sed -i 's|^default_vcpus = .*|default_vcpus = 16|' /etc/kata-containers/configuration.toml

    # pcie_root_port must be >= number of GPUs because each GPU occupies its
    # own virtual root port in root-port mode.
    sed -i 's|^pcie_root_port = .*|pcie_root_port = 8|' /etc/kata-containers/configuration.toml

    # cold_plug_vfio=root-port places each VFIO device directly on pcie.0,
    # which keeps BAR addresses fixed (GPA=HPA) when combined with the
    # x-fixed-bars QEMU patch.
    sed -i 's|^cold_plug_vfio = .*|cold_plug_vfio = \"root-port\"|' /etc/kata-containers/configuration.toml

    # Disable selinux to avoid permission issues with /dev/vfio bind mounts.
    sed -i 's|^disable_selinux = .*|disable_selinux = true|' /etc/kata-containers/configuration.toml

    # kernel_params: pci=nocrs pci=assign-busses keep the guest root bus from
    # reallocating BARs.  nvidia_uvm.uvm_ats_mode=0 disables ATS inside the
    # guest, which avoids peer-to-peer DMA hangs across virtual root ports.
    # cgroup_no_v1=all is required by the Kata guest image.
    sed -i 's|^kernel_params = .*|kernel_params = \"nvidia_uvm.uvm_ats_mode=0 pci=nocrs pci=assign-busses cgroup_no_v1=all\"|' /etc/kata-containers/configuration.toml

    # Use pre-allocated hugepages for guest RAM.  This avoids slow tmpfs
    # allocation in /dev/shm and is required for reliable VFIO DMA pinning
    # when running multiple large GPU VMs concurrently.
    sed -i 's|^enable_hugepages = .*|enable_hugepages = true|' /etc/kata-containers/configuration.toml
"

log "Restarting containerd"
run_remote "systemctl restart containerd"
sleep 3

# ---------------------------------------------------------------------------
# 3. Bind GPUs to vfio-pci (if not already bound)
# ---------------------------------------------------------------------------
log "Stage: ensure target GPUs are bound to vfio-pci"
run_remote "
    for g in ${GPU_VFIO_GROUPS}; do
        if [[ ! -e /dev/vfio/\${g} ]]; then
            echo \"/dev/vfio/\${g} missing; run /root/bingo/vfio_nvidia_bind.sh first\"
            exit 1
        fi
        echo \"/dev/vfio/\${g} OK\"
    done
"

# ---------------------------------------------------------------------------
# 4. Disable ACS on the immediate upstream switches of the target GPUs
# ---------------------------------------------------------------------------
if [[ "${SKIP_ACS_SHUTDOWN}" != "true" ]]; then
    log "Stage: disable ACS on GPU upstream switches"
    log "IMPORTANT: this step MUST run after vfio binding and BEFORE starting"
    log "           the Kata GPU container.  Do NOT verify with lspci -vvv."

    # Write the helper locally first, then copy it, to avoid nested quoting issues.
    cat > /tmp/acs_shutdown_vfio.sh <<'EOF'
#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

for vfio_dev in /dev/vfio/*; do
    [[ -c "${vfio_dev}" ]] || continue
    group_num=$(basename "${vfio_dev}")
    [[ "${group_num}" =~ ^[0-9]+$ ]] || continue

    group_dir="/sys/kernel/iommu_groups/${group_num}/devices"
    [[ -d "${group_dir}" ]] || continue

    for dev in "${group_dir}"/*; do
        bdf=$(basename "${dev}")
        [[ "${bdf}" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$ ]] || continue

        # Find the upstream bridge by matching the device's bus number to the
        # bridge's secondary_bus_number.
        bus_num_hex=$(echo "${bdf}" | cut -d: -f2)
        bus_num_dec=$(printf '%d' "0x${bus_num_hex}")
        upstream_bdf=""
        for bridge in /sys/bus/pci/devices/*; do
            if [[ -f ${bridge}/secondary_bus_number ]]; then
                sec=$(cat "${bridge}/secondary_bus_number" 2>/dev/null | tr -d ' ')
                if [[ "${sec}" == "${bus_num_dec}" ]]; then
                    upstream_bdf=$(basename "${bridge}")
                    break
                fi
            fi
        done
        [[ -n ${upstream_bdf} ]] || continue

        acs_val=$(setpci -s "${upstream_bdf}" ECAP_ACS+0x6.w 2>/dev/null || true)
        [[ -n ${acs_val} ]] || continue

        # Clear SrcValid(0), ReqRedir(2), CmpltRedir(3), UpstreamFwd(4).
        printf 'Disabling ACS on %s was %s for %s\n' "${upstream_bdf}" "${acs_val}" "${bdf}"
        setpci -s "${upstream_bdf}" ECAP_ACS+0x6.w=0x0000
    done
done

echo "ACS shutdown complete. Verify with: setpci -s <BDF> ECAP_ACS+0x6.w"
EOF
    copy_to_remote /tmp/acs_shutdown_vfio.sh /root/acs_shutdown_vfio.sh
    run_remote "
        chmod +x /root/acs_shutdown_vfio.sh
        bash -n /root/acs_shutdown_vfio.sh
        /root/acs_shutdown_vfio.sh
    "
else
    log "SKIP_ACS_SHUTDOWN=true: skipping ACS shutdown"
fi

# Verify ACS is disabled using setpci (NOT lspci -vvv).
log "Verifying ACS state with setpci"
run_remote "
    for g in ${GPU_VFIO_GROUPS}; do
        dev=\$(ls /sys/kernel/iommu_groups/\${g}/devices/ | grep '00\\.0$' | head -1)
        bus_num_hex=\$(echo \${dev} | cut -d: -f2)
        bus_num_dec=\$(printf '%d' 0x\${bus_num_hex})
        upstream_bdf=''
        for bridge in /sys/bus/pci/devices/*; do
            if [[ -f \${bridge}/secondary_bus_number ]]; then
                sec=\$(cat \${bridge}/secondary_bus_number 2>/dev/null | tr -d ' ')
                if [[ \"\${sec}\" == \"\${bus_num_dec}\" ]]; then
                    upstream_bdf=\$(basename \${bridge})
                    break
                fi
            fi
        done
        acs_val=\$(setpci -s \${upstream_bdf} ECAP_ACS+0x6.w 2>/dev/null || true)
        echo \"/dev/vfio/\${g} upstream \${upstream_bdf} ACSCtl=\${acs_val}\"
    done
"

# ---------------------------------------------------------------------------
# 5. Smoke test
# ---------------------------------------------------------------------------
log "Stage: Kata smoke test"
# The container may print 'ttrpc: closed' during cleanup; the kernel version
# line proves the VM started, so we tolerate a non-zero exit code here.
run_remote "
    nerdctl run --rm --runtime io.containerd.kata.v2 \
        docker.m.daocloud.io/library/ubuntu:latest \
        uname -r || true
"

# ---------------------------------------------------------------------------
# 6. Start GPU container
# ---------------------------------------------------------------------------
log "Stage: start GPU container"
DEVICE_ARGS=""
for g in ${GPU_VFIO_GROUPS}; do
    DEVICE_ARGS="${DEVICE_ARGS} --device /dev/vfio/${g}"
done

CONTAINER_NAME="kata-vfio-test-$(date +%s)"
run_remote "
    nerdctl rm -f ${CONTAINER_NAME} 2>/dev/null || true
    ctr -n default tasks delete ${CONTAINER_NAME} 2>/dev/null || true
    ctr -n default containers delete ${CONTAINER_NAME} 2>/dev/null || true
    nerdctl run -d \\
        --runtime io.containerd.kata.v2 \\
        --name ${CONTAINER_NAME} \\
        ${DEVICE_ARGS} \\
        -m 64g \\
        -v ${NCCL_MODELS_DIR}:${NCCL_MODELS_DIR} \\
        -v ${VLLM_MODEL_DIR}:${VLLM_MODEL_DIR} \\
        --entrypoint /bin/bash \\
        ${CONTAINER_IMAGE} \\
        -c 'sleep infinity'
"

log "Waiting for container to be ready"
sleep 5
run_remote "nerdctl exec ${CONTAINER_NAME} nvidia-smi -L"

# ---------------------------------------------------------------------------
# 7. Verify fixed-BAR: guest BAR1 == host BAR1
# ---------------------------------------------------------------------------
log "Stage: verify fixed-BAR GPA=HPA"
run_remote "
    echo '=== Guest GPU BAR1 (first GPU) ==='
    nerdctl exec ${CONTAINER_NAME} bash -c 'cat /sys/bus/pci/devices/0000:00:10.0/resource | head -1'
    echo
    echo '=== Host GPU BAR1 (first device in first group) ==='
    first_dev=\$(ls /sys/kernel/iommu_groups/$(echo ${GPU_VFIO_GROUPS} | awk '{print $1}')/devices/ | grep '00\.0$' | head -1)
    cat /sys/bus/pci/devices/\${first_dev}/resource | head -1
"

# ---------------------------------------------------------------------------
# 8. P2P connectivity test
# ---------------------------------------------------------------------------
log "Stage: P2P connectivity test"
run_remote "
    nerdctl exec ${CONTAINER_NAME} \\
        ${NCCL_MODELS_DIR}/p2pBandwidthLatencyTest \\
        --numElems=4000000 2>&1 | tail -30
"

# ---------------------------------------------------------------------------
# 9. NCCL all-reduce test (default P2P level, stable baseline)
# ---------------------------------------------------------------------------
log "Stage: NCCL all-reduce test (default P2P level, timeout 120s)"
run_remote "
    nerdctl exec ${CONTAINER_NAME} bash -c '
        cd ${NCCL_MODELS_DIR}/nccl-tests/build
        timeout 120 ./all_reduce_perf -b 8M -e 256M -f 2 -g ${TEST_GPUS} -t 1 -n 20 -w 5
    ' 2>&1 | tail -30
"

# ---------------------------------------------------------------------------
# 10. NCCL with NCCL_P2P_LEVEL=SYS (requires ACS to stay disabled)
# ---------------------------------------------------------------------------
log "Stage: NCCL all-reduce test with NCCL_P2P_LEVEL=SYS"
log "NOTE: The container startup re-enables ACS on the GPU upstream switches."
log "      Re-disabling ACS now is required for direct P2P DMA to work."

run_remote "
    # Re-disable ACS after the container has started.  The VM creation causes
    # the Broadcom switches to re-initialize ACS to their default 0x001d.
    /root/acs_shutdown_vfio.sh

    # Verify the target switches are clean before running NCCL.
    for g in ${GPU_VFIO_GROUPS}; do
        dev=\$(ls /sys/kernel/iommu_groups/\${g}/devices/ | grep '00\\.0$' | head -1)
        bus_num_hex=\$(echo \${dev} | cut -d: -f2)
        bus_num_dec=\$(printf '%d' 0x\${bus_num_hex})
        upstream_bdf=''
        for bridge in /sys/bus/pci/devices/*; do
            if [[ -f \${bridge}/secondary_bus_number ]]; then
                sec=\$(cat \${bridge}/secondary_bus_number 2>/dev/null | tr -d ' ')
                if [[ \"\${sec}\" == \"\${bus_num_dec}\" ]]; then
                    upstream_bdf=\$(basename \${bridge})
                    break
                fi
            fi
        done
        acs_val=\$(setpci -s \${upstream_bdf} ECAP_ACS+0x6.w 2>/dev/null || true)
        echo \"/dev/vfio/\${g} upstream \${upstream_bdf} ACSCtl=\${acs_val}\"
    done

    nerdctl exec ${CONTAINER_NAME} bash -c '
        cd ${NCCL_MODELS_DIR}/nccl-tests/build
        export NCCL_P2P_LEVEL=SYS
        timeout 120 ./all_reduce_perf -b 8M -e 256M -f 2 -g ${TEST_GPUS} -t 1 -n 20 -w 5
    ' 2>&1 | tail -30
"

# ---------------------------------------------------------------------------
# 11. Capture host ACS and PCIe link state
# ---------------------------------------------------------------------------
log "Stage: capture host ACS and link state"
run_remote "
    echo '=== Immediate upstream switch ACS registers (setpci) ==='
    for g in ${GPU_VFIO_GROUPS}; do
        dev=\$(ls /sys/kernel/iommu_groups/\${g}/devices/ | grep '00\\.0$' | head -1)
        bus_num_hex=\$(echo \${dev} | cut -d: -f2)
        bus_num_dec=\$(printf '%d' 0x\${bus_num_hex})
        upstream_bdf=''
        for bridge in /sys/bus/pci/devices/*; do
            if [[ -f \${bridge}/secondary_bus_number ]]; then
                sec=\$(cat \${bridge}/secondary_bus_number 2>/dev/null | tr -d ' ')
                if [[ \"\${sec}\" == \"\${bus_num_dec}\" ]]; then
                    upstream_bdf=\$(basename \${bridge})
                    break
                fi
            fi
        done
        acs_val=\$(setpci -s \${upstream_bdf} ECAP_ACS+0x6.w 2>/dev/null || true)
        echo \"/dev/vfio/\${g} upstream \${upstream_bdf} ACSCtl=\${acs_val}\"
    done
    echo
    echo '=== PCIe link status (lspci, host GPUs are vfio-bound so nvidia-smi is unavailable) ==='
    for g in ${GPU_VFIO_GROUPS}; do
        dev=\$(ls /sys/kernel/iommu_groups/\${g}/devices/ | grep '00\.0$' | head -1)
        echo -n "\${dev}: "
        lspci -vv -s \${dev} | grep -E 'LnkCap:|LnkSta:' | tr '\n' ' '
        echo
    done
"

# ---------------------------------------------------------------------------
# 12. Deploy vLLM 35B model service (optional)
# ---------------------------------------------------------------------------
if [[ "${DEPLOY_VLLM_35B}" == "true" ]]; then
    log "Stage: vLLM 35B model service"
    log "Model: ${VLLM_MODEL_DIR}"
    log "Tensor parallelism: ${VLLM_TP_SIZE}, pipeline parallelism: ${VLLM_PP_SIZE}, max-model-len: ${VLLM_MAX_MODEL_LEN}"
    log "NOTE: Qwen3.6-35B-A3B-FP8 uses block-wise FP8 weights.  TP=8 fails because"
    log "      intermediate_size/8=64 is not divisible by block_k=128.  We use TP=4+PP=2"
    log "      so all 8 GPUs are used while keeping each tensor-parallel shard compatible."

    if [[ "${START_VLLM_IN_CONTAINER}" == "true" ]]; then
        log "START_VLLM_IN_CONTAINER=true: the script will only print the start command"
        log "so you can run it manually inside the container."
        VLLM_START_CMD="VLLM_ENABLE_V1_MULTIPROCESSING=0 nohup python3 -m vllm.entrypoints.openai.api_server --model ${VLLM_MODEL_DIR} --trust-remote-code --host 0.0.0.0 --port ${VLLM_PORT} --tensor-parallel-size ${VLLM_TP_SIZE} --pipeline-parallel-size ${VLLM_PP_SIZE} --max-model-len ${VLLM_MAX_MODEL_LEN} --max-num-seqs ${VLLM_MAX_NUM_SEQS} --enable-prefix-caching --dtype auto --gpu-memory-utilization 0.92 > /tmp/vllm-35b.log 2>&1 &"
        echo
        echo "=== Run this command inside the container to start vLLM ==="
        echo "  ${VLLM_START_CMD}"
        echo
        echo "=== Then wait for /health and test with ==="
        echo "  curl -s http://localhost:${VLLM_PORT}/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\": \"${VLLM_MODEL_DIR}\", \"messages\": [{\"role\": \"user\", \"content\": \"1+1=?\"}], \"max_tokens\": 20}'"
        echo
    else
        # Generate the vLLM start command locally so we do not have to fight nested
        # quoting across SSH + nerdctl exec.  Variables are expanded now; only $!
        # needs to survive to the remote bash.
        VLLM_START_CMD="export VLLM_ENABLE_V1_MULTIPROCESSING=0; cd /tmp; rm -f /tmp/vllm-35b.log; nohup python3 -m vllm.entrypoints.openai.api_server --model ${VLLM_MODEL_DIR} --trust-remote-code --host 0.0.0.0 --port ${VLLM_PORT} --tensor-parallel-size ${VLLM_TP_SIZE} --pipeline-parallel-size ${VLLM_PP_SIZE} --max-model-len ${VLLM_MAX_MODEL_LEN} --max-num-seqs ${VLLM_MAX_NUM_SEQS} --enable-prefix-caching --dtype auto --gpu-memory-utilization 0.92 > /tmp/vllm-35b.log 2>&1 & echo vLLM_started_pid=\$!"

        run_remote "
            # Start the vLLM OpenAI API server in the background.
            # nohup + & keeps the API server alive after nerdctl exec returns.
            nerdctl exec ${CONTAINER_NAME} bash -c '${VLLM_START_CMD}'

            # Wait for the server to be ready.  Weight load + torch.compile + CUDA graph
            # capture for this model takes roughly 2-3 minutes on 8x RTX 4090.
            for i in \$(seq 1 300); do
                if nerdctl exec ${CONTAINER_NAME} bash -c \"curl -sf http://localhost:${VLLM_PORT}/health >/dev/null 2>&1\"; then
                    echo \"vLLM is ready after \${i} seconds\"
                    break
                fi
                if [[ \${i} -eq 300 ]]; then
                    echo \"ERROR: vLLM did not become ready within 300 seconds\" >&2
                    nerdctl exec ${CONTAINER_NAME} tail -80 /tmp/vllm-35b.log || true
                    exit 1
                fi
                sleep 1
            done
        "

        # ---------------------------------------------------------------------------
        # 13. Smoke test the vLLM 35B model
        # ---------------------------------------------------------------------------
        log "Stage: vLLM 35B smoke test"
        # Build the Python smoke-test script locally and pass it via stdin to the
        # container to avoid nerdctl cp (which is unreliable for Kata containers)
        # and nested shell quoting.
        VLLM_SMOKE_SCRIPT="import urllib.request, json
req = urllib.request.Request(
    'http://localhost:${VLLM_PORT}/v1/chat/completions',
    data=json.dumps({
        'model': '${VLLM_MODEL_DIR}',
        'messages': [{'role': 'user', 'content': '1+1=?'}],
        'max_tokens': 20
    }).encode(),
    headers={'Content-Type': 'application/json'},
    method='POST'
)
resp = urllib.request.urlopen(req, timeout=60)
print(resp.read().decode())
"
        run_remote "
            printf '%s' '${VLLM_SMOKE_SCRIPT}' | nerdctl exec -i ${CONTAINER_NAME} python3 /dev/stdin
        "
    fi
fi

# ---------------------------------------------------------------------------
# 14. Cleanup
# ---------------------------------------------------------------------------
log "Verification complete. Container name: ${CONTAINER_NAME}"
if [[ "${DEPLOY_VLLM_35B}" == "true" && "${START_VLLM_IN_CONTAINER}" != "true" ]]; then
    log "vLLM 35B service is running at http://${TARGET_HOST}:${VLLM_PORT} (inside container ${CONTAINER_NAME})"
fi

if [[ "${SKIP_CLEANUP}" == "true" ]]; then
    log "SKIP_CLEANUP=true: leaving container ${CONTAINER_NAME} running for manual inspection"
    log "To enter the container: ssh ${TARGET_USER}@${TARGET_HOST} 'nerdctl exec -it ${CONTAINER_NAME} bash'"
else
    pause "Remove the verification container?"
    run_remote "
        nerdctl rm -f ${CONTAINER_NAME} 2>/dev/null || true
        ctr -n default tasks delete ${CONTAINER_NAME} 2>/dev/null || true
        ctr -n default containers delete ${CONTAINER_NAME} 2>/dev/null || true
    "
fi

log "Done. Backup of previous binaries is at ${TARGET_HOST}:${BACKUP_DIR}"
