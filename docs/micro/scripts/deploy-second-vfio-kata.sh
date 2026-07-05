#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
#
# deploy-second-vfio-kata.sh
#
# Deploy a second Kata VFIO GPU container on the secondary PCIe switch.
# Uses the same vLLM image as the first container, different GPU set, port 8007.
#

set -o errexit
set -o nounset
set -o pipefail

: "${TARGET_HOST:?must be set, e.g. 172.18.5.243}"
: "${TARGET_USER:?must be set, e.g. root}"
: "${TARGET_PASS:=}"
: "${TARGET_KEY:=}"
: "${VLLM_MODEL_DIR:=/models/Qwen3.6-35B-A3B-FP8}"
: "${VLLM_PORT:=8007}"
: "${HOST_PORT:=8007}"
: "${VLLM_TP_SIZE:=4}"
: "${VLLM_PP_SIZE:=2}"
: "${VLLM_MAX_MODEL_LEN:=4096}"
: "${VLLM_MAX_NUM_SEQS:=256}"
: "${CONTAINER_IMAGE:=vllm/vllm-openai:v0.21.0-x86_64-cu129}"
# Secondary switch GPU VFIO groups
: "${GPU_VFIO_GROUPS_SECOND:=75 76 82 88 89 90 91 97}"
: "${TEST_GPUS:=8}"
: "${NCCL_MODELS_DIR:=/models/DeepSeek-R1-Distill-Qwen-1.5B}"
: "${SKIP_ACS_SHUTDOWN:=false}"
: "${START_VLLM_IN_CONTAINER:=true}"
: "${SKIP_CLEANUP:=true}"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
CONTAINER_NAME="kata-vfio-second-$(date +%s)"

run_remote() {
    if [[ -n "${TARGET_KEY}" ]]; then
        ssh ${SSH_OPTS} -i "${TARGET_KEY}" "${TARGET_USER}@${TARGET_HOST}" "$@"
    else
        sshpass -p "${TARGET_PASS}" ssh ${SSH_OPTS} "${TARGET_USER}@${TARGET_HOST}" "$@"
    fi
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "Stage: ensure secondary GPUs are bound to vfio-pci"
run_remote "
    for g in ${GPU_VFIO_GROUPS_SECOND}; do
        if [[ ! -e /dev/vfio/\${g} ]]; then
            echo \"/dev/vfio/\${g} missing; bind GPU to vfio-pci first\" >&2
            exit 1
        fi
        echo \"/dev/vfio/\${g} OK\"
    done
"

if [[ "${SKIP_ACS_SHUTDOWN}" != "true" ]]; then
    log "Stage: disable ACS on secondary switch upstream bridges"
    cat > /tmp/acs_shutdown_vfio_second.sh <<'EOF'
#!/usr/bin/env bash
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
        printf 'Disabling ACS on %s was %s for %s\n' "${upstream_bdf}" "${acs_val}" "${bdf}"
        setpci -s "${upstream_bdf}" ECAP_ACS+0x6.w=0x0000
    done
done
echo "ACS shutdown complete."
EOF
    sshpass -p "${TARGET_PASS}" scp ${SSH_OPTS} /tmp/acs_shutdown_vfio_second.sh "${TARGET_USER}@${TARGET_HOST}:/root/acs_shutdown_vfio_second.sh" >&2 || true
    run_remote "
        chmod +x /root/acs_shutdown_vfio_second.sh
        bash -n /root/acs_shutdown_vfio_second.sh
        /root/acs_shutdown_vfio_second.sh
    "
fi

log "Stage: start second GPU container"
DEVICE_ARGS=""
for g in ${GPU_VFIO_GROUPS_SECOND}; do
    DEVICE_ARGS="${DEVICE_ARGS} --device /dev/vfio/${g}"
done

run_remote "
    nerdctl rm -f ${CONTAINER_NAME} 2>/dev/null || true
    ctr -n default tasks delete ${CONTAINER_NAME} 2>/dev/null || true
    ctr -n default containers delete ${CONTAINER_NAME} 2>/dev/null || true
    nerdctl run -d \\
        --runtime io.containerd.kata.v2 \\
        --name ${CONTAINER_NAME} \\
        ${DEVICE_ARGS} \\
        -m 64g \\
        -p ${HOST_PORT}:${VLLM_PORT} \\
        -v ${NCCL_MODELS_DIR}:${NCCL_MODELS_DIR} \\
        -v ${VLLM_MODEL_DIR}:${VLLM_MODEL_DIR} \\
        --entrypoint /bin/bash \\
        ${CONTAINER_IMAGE} \\
        -c 'sleep infinity'
"

log "Waiting for container to be ready"
sleep 5
run_remote "nerdctl exec ${CONTAINER_NAME} nvidia-smi -L"

log "Stage: verify fixed-BAR GPA=HPA"
run_remote "
    echo '=== Guest GPU BAR1 (first GPU) ==='
    nerdctl exec ${CONTAINER_NAME} bash -c 'cat /sys/bus/pci/devices/0000:00:10.0/resource | head -1'
    echo
    echo '=== Host GPU BAR1 (first device in first group) ==='
    first_dev=\$(ls /sys/kernel/iommu_groups/$(echo ${GPU_VFIO_GROUPS_SECOND} | awk '{print $1}')/devices/ | grep '00\.0$' | head -1)
    cat /sys/bus/pci/devices/\${first_dev}/resource | head -1
"

log "Stage: P2P connectivity test"
run_remote "
    nerdctl exec ${CONTAINER_NAME} \\
        ${NCCL_MODELS_DIR}/p2pBandwidthLatencyTest \\
        --numElems=4000000 2>&1 | tail -30
"

log "Stage: NCCL all-reduce test (default P2P level, timeout 120s)"
run_remote "
    nerdctl exec ${CONTAINER_NAME} bash -c '
        cd ${NCCL_MODELS_DIR}/nccl-tests/build
        timeout 120 ./all_reduce_perf -b 8M -e 256M -f 2 -g ${TEST_GPUS} -t 1 -n 20 -w 5
    ' 2>&1 | tail -30
"

if [[ "${SKIP_ACS_SHUTDOWN}" != "true" ]]; then
    log "Stage: re-disable ACS after container start"
    run_remote "/root/acs_shutdown_vfio_second.sh"
fi

log "Stage: NCCL all-reduce test with NCCL_P2P_LEVEL=SYS"
run_remote "
    nerdctl exec ${CONTAINER_NAME} bash -c '
        cd ${NCCL_MODELS_DIR}/nccl-tests/build
        export NCCL_P2P_LEVEL=SYS
        timeout 120 ./all_reduce_perf -b 8M -e 256M -f 2 -g ${TEST_GPUS} -t 1 -n 20 -w 5
    ' 2>&1 | tail -30
"

if [[ "${START_VLLM_IN_CONTAINER}" == "true" ]]; then
    log "Stage: vLLM 35B start command for manual launch"
    echo
    echo "=== Run this inside the second container ==="
    echo "  VLLM_ENABLE_V1_MULTIPROCESSING=0 nohup python3 -m vllm.entrypoints.openai.api_server --model ${VLLM_MODEL_DIR} --trust-remote-code --host 0.0.0.0 --port ${VLLM_PORT} --tensor-parallel-size ${VLLM_TP_SIZE} --pipeline-parallel-size ${VLLM_PP_SIZE} --max-model-len ${VLLM_MAX_MODEL_LEN} --max-num-seqs ${VLLM_MAX_NUM_SEQS} --enable-prefix-caching --dtype auto --gpu-memory-utilization 0.92 > /tmp/vllm-35b.log 2>&1 &"
    echo
    echo "=== Test from host ==="
    echo "  curl -s http://${TARGET_HOST}:${HOST_PORT}/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\": \"${VLLM_MODEL_DIR}\", \"messages\": [{\"role\": \"user\", \"content\": \"1+1=?\"}], \"max_tokens\": 20}'"
    echo
fi

log "Verification complete. Container name: ${CONTAINER_NAME}"
if [[ "${SKIP_CLEANUP}" == "true" ]]; then
    log "SKIP_CLEANUP=true: leaving container ${CONTAINER_NAME} running"
    log "To enter: ssh ${TARGET_USER}@${TARGET_HOST} 'nerdctl exec -it ${CONTAINER_NAME} bash'"
else
    log "Removing container ${CONTAINER_NAME}"
    run_remote "
        nerdctl rm -f ${CONTAINER_NAME} 2>/dev/null || true
        ctr -n default tasks delete ${CONTAINER_NAME} 2>/dev/null || true
        ctr -n default containers delete ${CONTAINER_NAME} 2>/dev/null || true
    "
fi
