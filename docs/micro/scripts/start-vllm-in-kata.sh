#!/bin/bash
# Start vLLM inside a single Kata VFIO container.
# Designed to be run via: nerdctl exec <container> bash /models/start-vllm-in-kata.sh
#
# Usage (inside container):
#   bash start-vllm-in-kata.sh [model_path] [port] [max_model_len]
#
# Defaults:
#   model_path:    /models/Qwen3-14B
#   port:          8000
#   max_model_len: 2048

set -euo pipefail

MODEL_PATH="${1:-/models/Qwen3-14B}"
PORT="${2:-8000}"
MAX_MODEL_LEN="${3:-2048}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.90}"
TP="${TP:-4}"
PP="${PP:-2}"

# Derive served model name from model directory name
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-$(basename ${MODEL_PATH})}"

echo "=== vLLM Startup ==="
echo "Model:       ${MODEL_PATH}"
echo "Served name: ${SERVED_MODEL_NAME}"
echo "Port:        ${PORT}"
echo "TP/PP:       ${TP}/${PP}"
echo "Max len:     ${MAX_MODEL_LEN}"
echo "GPU mem util: ${GPU_MEM_UTIL}"
echo "===================="

# Cleanup old processes
echo "Cleaning up old vLLM processes..."
pkill -9 -f "vllm serve" 2>/dev/null || true
sleep 2
nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | xargs -r kill -9 2>/dev/null || true
sleep 2

# Clear old log
rm -f /root/vllm.log

# Launch vLLM
echo "Launching vLLM serve..."
export NCCL_P2P_LEVEL=SYS
nohup vllm serve "${MODEL_PATH}" \
    --served-model-name "${SERVED_MODEL_NAME}" \
    --tensor-parallel-size "${TP}" \
    --pipeline-parallel-size "${PP}" \
    --port "${PORT}" \
    --dtype float16 \
    --max-model-len "${MAX_MODEL_LEN}" \
    --gpu-memory-utilization "${GPU_MEM_UTIL}" \
    --max-num-seqs 128 \
    > /root/vllm.log 2>&1 &

VLLM_PID=$!
echo "${VLLM_PID}" > /tmp/vllm.pid
echo "vLLM launched with PID ${VLLM_PID}"

# Self health check (up to 6 minutes)
echo "Waiting for vLLM to become healthy..."
for i in $(seq 1 72); do
    if curl -s -o /dev/null "http://localhost:${PORT}/health" 2>/dev/null; then
        echo "✅ vLLM healthy after $((i * 5))s"
        exit 0
    fi
    sleep 5
done

echo "❌ vLLM failed to become healthy within 360s"
echo "Last 40 lines of /root/vllm.log:"
tail -40 /root/vllm.log
exit 1
