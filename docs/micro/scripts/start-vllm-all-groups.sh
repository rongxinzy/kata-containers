#!/bin/bash
# Sequential vLLM launcher for all Kata VFIO groups.
# Starts vLLM one group at a time, waiting for model loading to complete
# before proceeding to the next group. This avoids concurrent memory pressure
# that causes Guest OOM during model weight loading.
#
# Usage (via environment variables):
#   KATA_GROUPS="1 6 7 8" KATA_MODEL="/models/Qwen3-14B" bash start-vllm-all-groups.sh
#
# Environment variables:
#   KATA_GROUPS      - space-separated group numbers (default: "1 6 7 8")
#   KATA_MODEL       - path to model (default: /models/Qwen3-14B)
#   KATA_SERVED_NAME - served model name (default: Qwen3-14B)
#
# Note: "GROUPS" is a bash reserved variable — cannot use that name.

set -euo pipefail

# Use TARGET_GROUPS to avoid conflict with bash reserved variable "GROUPS"
TARGET_GROUPS="${KATA_GROUPS:-1 6 7 8}"
MODEL_PATH="${KATA_MODEL:-/models/Qwen3-14B}"
SERVED_MODEL_NAME="${KATA_SERVED_NAME:-Qwen3-14B}"
BASE_PORT=8010
MAX_WAIT=360  # max wait seconds per group (6 minutes for model loading)

# Container naming: kata-vfio-groupN, port mapping: 8010+(N-1)
# G1 → 8010, G6 → 8015, G7 → 8016, G8 → 8017

echo "========================================="
echo " Sequential vLLM Launcher"
echo " Model:  ${MODEL_PATH}"
echo " Groups: ${TARGET_GROUPS}"
echo " Time:   $(date)"
echo "========================================="
echo

for gid in ${TARGET_GROUPS}; do
    NAME="kata-vfio-group${gid}"
    PORT=$((BASE_PORT + gid - 1))

    echo "===== [${NAME}] Starting vLLM on port ${PORT} ====="

    # Verify container is running
    if ! nerdctl ps --format '{{.Names}}' | grep -q "^${NAME}$"; then
        echo "ERROR: Container ${NAME} is not running. Skip."
        continue
    fi

    # Cleanup any leftover vLLM processes inside the container
    echo "  [${NAME}] Cleaning up old vLLM processes..."
    nerdctl exec "${NAME}" bash -c '
        pkill -9 -f "vllm serve" 2>/dev/null || true
        dx-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | xargs -r kill -9 2>/dev/null || true
    ' 2>/dev/null || true
    sleep 3

    # Get container IP for direct health check (bypasses stale CNI NAT rules)
    CTR_IP=$(nerdctl inspect "${NAME}" --format '{{.NetworkSettings.IPAddress}}' 2>/dev/null)
    if [ -z "${CTR_IP}" ]; then
        echo "ERROR: Cannot get IP for ${NAME}. Skip."
        continue
    fi
    echo "  [${NAME}] Container IP: ${CTR_IP}"

    # Cleanup old vLLM
    echo "  [${NAME}] Cleaning up old vLLM processes..."
    nerdctl exec "${NAME}" bash -c "
        pkill -9 -f \"vllm serve\" 2>/dev/null || true
        dx-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | xargs -r kill -9 2>/dev/null || true
    " 2>/dev/null || true
    sleep 3

    # Start vLLM
    echo "  [${NAME}] Launching vLLM serve..."
    nerdctl exec "${NAME}" bash -c "
        export NCCL_P2P_LEVEL=SYS
        nohup vllm serve ${MODEL_PATH} \
            --served-model-name ${SERVED_MODEL_NAME} \
            --tensor-parallel-size 4 \
            --pipeline-parallel-size 2 \
            --port 8000 \
            --dtype float16 \
            --max-model-len 2048 \
            --gpu-memory-utilization 0.80 \
            --max-num-seqs 128 \
            > /root/vllm.log 2>&1 &
        echo \$! > /tmp/vllm.pid
    " 2>&1 | head -3

    # Wait for health check via container IP (bypasses stale CNI NAT rules)
    echo "  [${NAME}] Waiting for model to load..."
    HEALTHY=false
    for i in $(seq 1 ${MAX_WAIT}); do
        if curl -s -o /dev/null "http://${CTR_IP}:8000/health" 2>/dev/null; then
            echo "  [${NAME}] vLLM ready after $((i * 5))s"
            HEALTHY=true
            break
        fi
        # Show progress every 12 checks (1 minute)
        if [ $((i % 12)) -eq 0 ]; then
            echo "  [${NAME}] Still waiting... ($((i * 5))s elapsed)"
        fi
        sleep 5
    done

    if [ "${HEALTHY}" != "true" ]; then
        echo "  [${NAME}] vLLM failed to become healthy within $((MAX_WAIT * 5))s"
        echo "  [${NAME}] Last 20 lines of vllm.log:"
        nerdctl exec "${NAME}" tail -20 /root/vllm.log 2>/dev/null || true
        # Continue with other groups instead of aborting
    fi

    echo
done

echo "========================================="
echo " Summary"
echo "========================================="
for gid in ${TARGET_GROUPS}; do
    NAME="kata-vfio-group${gid}"
    PORT=$((BASE_PORT + gid - 1))
    if curl -s -o /dev/null "http://localhost:${PORT}/health" 2>/dev/null; then
        echo "  [${NAME}] port ${PORT}: healthy"
    else
        echo "  [${NAME}] port ${PORT}: NOT healthy"
    fi
done
echo
echo "To run benchmarks:"
echo "  for gid in ${TARGET_GROUPS}; do"
echo "    nerdctl exec kata-vfio-group\${gid} bash /models/vllm_benchmark.sh &"
echo "  done"
echo "  wait"
