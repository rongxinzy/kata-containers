#!/bin/bash
# start-vllm-services.sh — Start vLLM in VFIO containers and/or Docker
#
# Usage:
#   bash start-vllm-services.sh [model] [name] [vfio_tp] [vfio_pp] [docker_tp] [docker_pp]
#   bash start-vllm-services.sh --k   [args...]   # VFIO containers only
#   bash start-vllm-services.sh --d   [args...]   # Docker container only
#   bash start-vllm-services.sh --all [args...]   # both (default)
#
# Note: Health checks use container IP (not host port mapping) because
#       Kata's port forwarding via iptables/CNI is unreliable.
set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
PHASE="--all"
FIRST_POS=1
case "${1:-}" in
    --k|--vfio)   PHASE="--k";   FIRST_POS=2 ;;
    --d|--docker) PHASE="--d";   FIRST_POS=2 ;;
    --all)        PHASE="--all"; FIRST_POS=2 ;;
esac

MODEL="${!FIRST_POS:-/models/Qwen3-14B}"
NEXT=$((FIRST_POS + 1))
SERVED_NAME="${!NEXT:-Qwen3-14B}"
NEXT=$((FIRST_POS + 2))
VFIO_TP="${!NEXT:-4}"
NEXT=$((FIRST_POS + 3))
VFIO_PP="${!NEXT:-2}"
NEXT=$((FIRST_POS + 4))
DOCKER_TP="${!NEXT:-8}"
NEXT=$((FIRST_POS + 5))
DOCKER_PP="${!NEXT:-4}"

RUN_VFIO=false; RUN_DOCKER=false
case "$PHASE" in
    --k)   RUN_VFIO=true ;;
    --d)   RUN_DOCKER=true ;;
    --all) RUN_VFIO=true; RUN_DOCKER=true ;;
esac

VFIO_NAMES=(g1 g2 g3 g4)
DOCKER_PORT=8000

VFIO_ARGS="--served-model-name ${SERVED_NAME} \
    --tensor-parallel-size ${VFIO_TP} --pipeline-parallel-size ${VFIO_PP} \
    --port 8000 --dtype float16 --max-model-len 2048 \
    --gpu-memory-utilization 0.80 --max-num-seqs 128"

START_VFIO_CMD="export NCCL_P2P_LEVEL=SYS; nohup vllm serve ${MODEL} ${VFIO_ARGS} > /root/vllm.log 2>&1 &"
START_DOCKER_CMD="export NCCL_P2P_LEVEL=SYS; nohup vllm serve ${MODEL} --served-model-name ${SERVED_NAME} --tensor-parallel-size ${DOCKER_TP} --pipeline-parallel-size ${DOCKER_PP} --port 8000 --dtype float16 --max-model-len 2048 --gpu-memory-utilization 0.70 --max-num-seqs 128 > /root/vllm.log 2>&1 &"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Get container IP (Kata port forwarding via iptables is unreliable)
get_ip() {
    nerdctl inspect "$1" 2>/dev/null | grep -o '"IPAddress": "[0-9.]*"' | head -1 | grep -o '[0-9.]*'
}

# =========================================================================
# Phase: VFIO containers
# =========================================================================
if $RUN_VFIO; then
    echo "=== Starting vLLM on VFIO containers ==="
    for NAME in "${VFIO_NAMES[@]}"; do
        IP=$(get_ip "${NAME}")
        if [ -z "$IP" ]; then
            log "[${NAME}] ERROR: cannot get container IP"
            continue
        fi

        log "[${NAME}:${IP}:8000] Starting..."
        nerdctl exec "${NAME}" bash -c "${START_VFIO_CMD}" 2>/dev/null

        log "  Waiting for model (max 5 min)..."
        for i in $(seq 1 60); do
            sleep 5
            if curl -sf -m3 "http://${IP}:8000/health" >/dev/null 2>&1; then
                log "  [${NAME}] vLLM ready ($((i*5))s)"
                break
            fi
            [ $((i % 12)) -eq 0 ] && log "  [${NAME}] ...$((i*5))s"
        done
    done
fi

# =========================================================================
# Phase: Docker
# =========================================================================
if $RUN_DOCKER; then
    echo
    echo "=== Starting vLLM on Docker (TP=${DOCKER_TP} PP=${DOCKER_PP}) ==="
    docker exec vllm-docker bash -c "${START_DOCKER_CMD}" 2>/dev/null

    log "  Waiting for model (max 10 min)..."
    for i in $(seq 1 120); do
        sleep 5
        if curl -sf -m3 "http://localhost:${DOCKER_PORT}/health" >/dev/null 2>&1; then
            log "  [Docker] vLLM ready ($((i*5))s)"
            break
        fi
        [ $((i % 24)) -eq 0 ] && log "  [Docker] ...$((i*5))s"
    done
fi

# =========================================================================
# Health summary
# =========================================================================
echo
echo "=== Health Check ==="
$RUN_VFIO && for NAME in "${VFIO_NAMES[@]}"; do
    IP=$(get_ip "${NAME}")
    echo -n "${NAME} (${IP}:8000): "
    curl -s -o /dev/null -w "%{http_code}\n" -m3 "http://${IP}:8000/health" 2>/dev/null || echo "FAIL"
done
$RUN_DOCKER && echo -n "Docker ${DOCKER_PORT}: " && curl -s -o /dev/null -w "%{http_code}\n" -m3 "http://localhost:${DOCKER_PORT}/health" 2>/dev/null || echo "FAIL"
echo "=== Done ==="
