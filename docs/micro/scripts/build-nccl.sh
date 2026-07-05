#!/bin/bash
# build-nccl.sh — Rebuild NCCL tests inside the vllm container image
# NCCL compilation only needs CUDA toolchain, no GPU passthrough required.
#
# Usage:
#   bash build-nccl.sh
#   bash build-nccl.sh vllm/vllm-openai:v0.21.0-x86_64-cu129
set -euo pipefail

IMG="${1:-vllm/vllm-openai:v0.21.0-x86_64-cu129}"
NAME="nccl-builder-$$"

echo "=== Building NCCL in temporary container ==="

# Use Docker (plain runc) — compilation only needs CUDA headers/libs, no GPU
docker rm -f "${NAME}" 2>/dev/null || true

docker run -d --runtime runc --name "${NAME}" \
    -v /models:/models \
    --entrypoint sleep "${IMG}" infinity

echo "Waiting for container..."
for i in $(seq 1 15); do
    sleep 2
    if docker exec "${NAME}" true >/dev/null 2>&1; then
        echo "Container ready ($((i*2))s)"
        break
    fi
done

# Build script
cat > /tmp/build_nccl.sh << 'BUILD'
#!/bin/bash
set -e
cd /models/nccl-tests-2.18.3
export PATH=/usr/local/cuda-12.9/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-12.9/lib64:$LD_LIBRARY_PATH
make clean 2>/dev/null || true
make -j$(nproc) MPI=0 NCCL_HOME=/usr CUDA_HOME=/usr/local/cuda-12.9
echo "BUILD_OK"
BUILD

cp /tmp/build_nccl.sh /models/
docker exec "${NAME}" bash /models/build_nccl.sh

# Verify
echo
echo "=== Verify NCCL binary ==="
docker exec "${NAME}" bash -c "
    export LD_LIBRARY_PATH=/usr/local/cuda-12.9/lib64:\$LD_LIBRARY_PATH
    missing=\$(ldd /models/nccl-tests-2.18.3/build/all_reduce_perf 2>&1 | grep -c 'not found' || true)
    echo \"Missing libs: \${missing}\"
    [ \"\${missing}\" -eq 0 ] && echo 'NCCL binary OK' || echo 'WARNING: some libs missing'
"

docker rm -f "${NAME}" 2>/dev/null || true
echo "=== NCCL build done ==="
