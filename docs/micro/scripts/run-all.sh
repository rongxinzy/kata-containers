#!/bin/bash
# run-all.sh — End-to-end deployment + verification
#
# Usage:
#   bash run-all.sh                    # full pipeline, 4 groups (default)
#   bash run-all.sh --groups=2         # full pipeline, 2 groups (16 GPU each)
#   bash run-all.sh --k                # VFIO only
#   bash run-all.sh --d                # Docker only
#   bash run-all.sh --k --groups=2     # VFIO only, 2 groups
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RUN_VFIO=true
RUN_DOCKER=true
NUM_GROUPS=4

for arg in "$@"; do
    case "$arg" in
        --k|--vfio)     RUN_VFIO=true;  RUN_DOCKER=false ;;
        --d|--docker)   RUN_VFIO=false; RUN_DOCKER=true ;;
        --groups=*)     NUM_GROUPS="${arg#*=}" ;;
    esac
done

echo "============================================"
echo " VFIO + Docker Deployment"
echo " Groups: ${NUM_GROUPS}, Scope: $($RUN_VFIO && echo VFIO) $($RUN_DOCKER && echo Docker)"
echo " $(date)"
echo "============================================"

# Step 0: Prerequisites
echo
echo "=== Step 0: Prerequisites ==="

if ldd /opt/kata/bin/qemu-system-x86_64 2>/dev/null | grep -q "not found"; then
    echo "Installing QEMU runtime libs..."
    apt-get install -y -qq libpixman-1-0 libslirp0 2>/dev/null
fi

if ! ctr -n default images ls 2>/dev/null | grep -q vllm; then
    echo "Pulling container image..."
    ctr -n default images pull --hosts-dir /etc/containerd/certs.d vllm/vllm-openai:v0.21.0-x86_64-cu129
fi

# Step 1: Bind GPUs
if $RUN_VFIO; then
    echo
    echo "=== Step 1: Bind GPUs ==="
    bash "${SCRIPT_DIR}/bind-gpu.sh"
fi

# Step 2: Build NCCL
echo
echo "=== Step 2: Build NCCL ==="
bash "${SCRIPT_DIR}/build-nccl.sh"

# Step 3: Deploy (split phases)
if $RUN_VFIO; then
    echo
    echo "=== Step 3a: VFIO containers (${NUM_GROUPS} groups) ==="
    bash "${SCRIPT_DIR}/deploy-containers.sh" --k --groups=${NUM_GROUPS}
fi

if $RUN_DOCKER; then
    echo
    echo "=== Step 3b: Docker container ==="
    bash "${SCRIPT_DIR}/deploy-containers.sh" --d
fi

# Step 4: Start vLLM
echo
echo "=== Step 4: Start vLLM ==="
VLLM_ARGS=""
$RUN_VFIO || VLLM_ARGS="--d"
$RUN_DOCKER || VLLM_ARGS="--k"
bash "${SCRIPT_DIR}/start-vllm-services.sh" ${VLLM_ARGS}

# Step 5: Verify
echo
echo "=== Step 5: Verify ==="
VERIFY_ARGS=""
$RUN_VFIO || VERIFY_ARGS="--d"
$RUN_DOCKER || VERIFY_ARGS="--k"
bash "${SCRIPT_DIR}/verify-deployment.sh" ${VERIFY_ARGS}

echo
echo "============================================"
echo " Pipeline complete"
echo " $(date)"
echo "============================================"
