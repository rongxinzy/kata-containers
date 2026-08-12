#!/bin/bash
# verify-deployment.sh — Validate the VFIO + Docker deployment
#
# Usage:
#   bash verify-deployment.sh           # full verification (default)
#   bash verify-deployment.sh --k       # VFIO containers only
#   bash verify-deployment.sh --d       # Docker container only
set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
PHASE="${1:-all}"
RUN_VFIO=false; RUN_DOCKER=false
case "$PHASE" in
    --k|--vfio)     RUN_VFIO=true ;;
    --d|--docker)   RUN_DOCKER=true ;;
    --all|all|"")   RUN_VFIO=true; RUN_DOCKER=true ;;
    *)
        echo "Usage: $0 [--k|--d|--all]"
        exit 1
        ;;
esac

VFIO_PORTS=(8014 8015 8016 8017)
DOCKER_PORT=8000
VFIO_NAMES=(g1 g2 g3 g4)
PASS=0
FAIL=0

get_ip() {
    nerdctl inspect "$1" 2>/dev/null | grep -o '"IPAddress": "[0-9.]*"' | head -1 | grep -o '[0-9.]*'
}

check() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "  ✅ ${label}: ${actual}"
        PASS=$((PASS+1))
    else
        echo "  ❌ ${label}: got=${actual}, expected=${expected}"
        FAIL=$((FAIL+1))
    fi
}

echo "============================================"
echo " Deployment Verification Report"
echo " $(date)"
echo " Scope: $($RUN_VFIO && echo VFIO) $($RUN_DOCKER && echo Docker)"
echo "============================================"

# 1. Container status
echo
echo "=== 1. Container Status ==="
$RUN_VFIO && nerdctl ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | grep -E 'g[1-4]' || echo "  ⏭  Skipped"
$RUN_DOCKER && { docker ps --format "table {{.Names}}\t{{.Status}}" 2>/dev/null | grep vllm-docker || echo "  ⚠  vllm-docker not running"; }

# 2. GPU counts
echo
echo "=== 2. GPU Detection ==="
if $RUN_VFIO; then
    VFIO_TOTAL=0
    for NAME in "${VFIO_NAMES[@]}"; do
        count=$(nerdctl exec "${NAME}" dx-smi -L 2>/dev/null | wc -l || echo 0)
        check "${NAME} GPU" "8" "$count"
        VFIO_TOTAL=$((VFIO_TOTAL + count))
    done
fi
if $RUN_DOCKER; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q vllm-docker; then
        DOCKER_COUNT=$(docker exec vllm-docker nvidia-smi -L 2>/dev/null | wc -l)
        DOCKER_COUNT=$(echo "$DOCKER_COUNT" | head -1 | tr -d '\r\n ')
        check "Docker GPU" "32" "$DOCKER_COUNT"
        if $RUN_VFIO; then
            check "Total GPU" "64" "$((VFIO_TOTAL + DOCKER_COUNT))"
        fi
    else
        echo "  ⏭  Docker container not running, skip GPU check"
    fi
fi

# 3. BAR conflicts
echo
echo "=== 3. BAR Conflicts ==="
if $RUN_VFIO; then
    for NAME in "${VFIO_NAMES[@]}"; do
        conflicts=$(nerdctl exec "${NAME}" bash -c 'dmesg 2>/dev/null | grep -c "can.t claim" || echo 0' 2>/dev/null)
        conflicts=$(echo "$conflicts" | head -1 | tr -d '\r\n ')
        [ -z "$conflicts" ] && conflicts=0
        check "${NAME} BAR conflicts" "0" "$conflicts"
    done
else
    echo "  ⏭  Skipped"
fi

# 4. vLLM health
echo
echo "=== 4. vLLM Health ==="
if $RUN_VFIO; then
    for NAME in "${VFIO_NAMES[@]}"; do
        IP=$(get_ip "${NAME}")
        code=$(curl -s -o /dev/null -w "%{http_code}" -m5 "http://${IP}:8000/health" 2>/dev/null || echo "000")
        check "${NAME} (${IP}:8000) health" "200" "$code"
    done
fi
if $RUN_DOCKER; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q vllm-docker; then
        code=$(curl -s -o /dev/null -w "%{http_code}" -m5 "http://localhost:${DOCKER_PORT}/health" 2>/dev/null || echo "000")
        code=$(echo "$code" | head -1 | tr -d '\r\n ')
        check "Docker health" "200" "$code"
    else
        echo "  ⏭  Docker container not running, skip health check"
    fi
fi

# 5. NCCL P2P (small buffers when vLLM is running)
echo
echo "=== 5. NCCL P2P Bandwidth ==="
if $RUN_VFIO; then
    for NAME in "${VFIO_NAMES[@]}"; do
        # Use small buffers if vLLM is running (GPU memory shared with NCCL)
        if nerdctl exec "${NAME}" ps aux 2>/dev/null | grep -q "[v]llm"; then
            NCCL_OPTS="-b 1M -e 8M -n 5 -w 2"
            MIN_BW=10   # lower threshold for small-buffer NCCL
            NOTE="(small buf, vLLM running)"
        else
            NCCL_OPTS="-b 8M -e 256M -n 20 -w 5"
            MIN_BW=12
            NOTE=""
        fi
        bw=$(nerdctl exec "${NAME}" bash -c "
            export LD_LIBRARY_PATH=/usr/local/cuda-12.9/lib64:\$LD_LIBRARY_PATH
            export NCCL_P2P_LEVEL=SYS
            cd /models/nccl-tests-2.18.3/build
            timeout 60 ./all_reduce_perf ${NCCL_OPTS} -f 2 -g 8 -t 1 2>&1 | grep 'Avg bus bandwidth' | awk '{print \$NF}'
        " 2>/dev/null || echo "")
        [ -z "$bw" ] && bw=0
        bw_num=$(echo "$bw" | awk '{printf "%.0f", $1}' 2>/dev/null || echo 0)
        if [ "$bw_num" -ge "${MIN_BW}" ]; then
            echo "  ✅ ${NAME}: ${bw} GB/s ${NOTE}"
            PASS=$((PASS+1))
        else
            echo "  ❌ ${NAME}: ${bw} GB/s (expected >= ${MIN_BW}) ${NOTE}"
            FAIL=$((FAIL+1))
        fi
    done
else
    echo "  ⏭  Skipped"
fi

# 6. System resources
echo
echo "=== 6. System Resources ==="
echo "--- /dev/shm ---"
df -h /dev/shm
echo "--- Memory ---"
free -h | head -2
echo "--- QEMU processes ---"
ps aux | grep qemu-system | grep -v grep | wc -l | xargs echo "Count:"

# Summary
echo
echo "============================================"
echo " Result: ${PASS} passed, ${FAIL} failed"
echo "============================================"
