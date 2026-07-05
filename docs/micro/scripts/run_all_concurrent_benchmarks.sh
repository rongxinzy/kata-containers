#!/usr/bin/env bash
set -uo pipefail

BENCH_SCRIPT="/home/rx/bingo/vllm_benchmark_concurrent.sh"

# Copy benchmark script into each Kata container
for g in 1 2 3 4; do
    nerdctl cp "${BENCH_SCRIPT}" "kata-vfio-group${g}:/root/vllm_benchmark_concurrent.sh"
    nerdctl exec "kata-vfio-group${g}" chmod +x /root/vllm_benchmark_concurrent.sh
done

# Copy benchmark script into each Docker container
for d in vllm-host-d1 vllm-host-d2; do
    docker cp "${BENCH_SCRIPT}" "${d}:/root/vllm_benchmark_concurrent.sh"
    docker exec "${d}" chmod +x /root/vllm_benchmark_concurrent.sh
done

# Run all benchmarks concurrently in background
for g in 1 2 3 4; do
    echo "[group${g}] starting benchmark"
    nerdctl exec kata-vfio-group${g} bash -lc "/root/vllm_benchmark_concurrent.sh" > /root/benchmark-group${g}.log 2>&1 &
done

for d in vllm-host-d1 vllm-host-d2; do
    echo "[${d}] starting benchmark"
    docker exec "${d}" bash -lc "/root/vllm_benchmark_concurrent.sh" > /root/benchmark-${d}.log 2>&1 &
done

wait
echo "All concurrent benchmarks completed"
