#!/bin/bash
# Final deployment script for 4 Kata VFIO containers
set -euo pipefail

export CONTAINER_IMAGE=vllm/vllm-openai:v0.21.0-x86_64-cu129
export GUEST_RAM_GB=36

# IOMMU groups per container
# G1: 121,122,128,129,130,131,137,138 → buses 5b,5c,5f,60,61,62,65,66
# G6: 44,45,51,52,53,54,58,59        → buses a6,a7,aa,ab,ac,ad,b0,b1
# G7: 71,72,78,79,80,81,87,88        → buses b8,b9,bc,bd,be,bf,c2,c3
# G8: 89,90,96,97,98,99,103,104      → buses c4,c5,c8,c9,ca,cb,ce,cf

declare -A IOMMU_MAP
IOMMU_MAP[1]="121 122 128 129 130 131 137 138"
IOMMU_MAP[6]="44 45 51 52 53 54 58 59"
IOMMU_MAP[7]="71 72 78 79 80 81 87 88"
IOMMU_MAP[8]="89 90 96 97 98 99 103 104"

for gid in 1 6 7 8; do
    IOMMU_GROUPS="${IOMMU_MAP[$gid]}"
    PORT=$((8010 + gid - 1))
    NAME="kata-vfio-group${gid}"

    echo "===== Group ${gid} | IOMMUs: ${IOMMU_GROUPS} | Port: ${PORT} ====="

    # Resolve BDFs and build device args
    BDFS=""
    DEVICE_ARGS=""
    for grp in ${IOMMU_GROUPS}; do
        dev=$(ls /sys/kernel/iommu_groups/${grp}/devices/ 2>/dev/null | grep '\.0$' | head -1)
        if [ -z "${dev}" ]; then
            echo "ERROR: no function-0 device in IOMMU group ${grp}" >&2
            exit 1
        fi
        BDFS="${BDFS} ${dev}"
        DEVICE_ARGS="${DEVICE_ARGS} --device=/dev/vfio/${grp}"
    done
    BDFS=$(echo "${BDFS}" | sed 's/^ *//')
    DEVICE_ARGS=$(echo "${DEVICE_ARGS}" | sed 's/^ *//')

    echo "  BDFs: ${BDFS}"

    # ACS shutdown
    /root/acs_shutdown_vfio_group.sh ${BDFS} 2>&1 | tail -1

    # Cleanup
    nerdctl rm -f "${NAME}" 2>/dev/null || true
    ctr -n default tasks delete "${NAME}" 2>/dev/null || true
    ctr -n default containers delete "${NAME}" 2>/dev/null || true

    # Start container with proper device args
    echo "  Starting container..."
    nerdctl run -d \
        --runtime io.containerd.kata.v2 \
        --name "${NAME}" \
        ${DEVICE_ARGS} \
        -m 36g \
        -p "${PORT}:8000" \
        -v /models:/models \
        --env NVIDIA_VISIBLE_DEVICES=void \
        --env NVIDIA_DRIVER_CAPABILITIES=compute,utility \
        --entrypoint /bin/bash \
        "${CONTAINER_IMAGE}" \
        -c 'sleep infinity'

    # Wait for ready
    READY=false
    for i in $(seq 1 60); do
        if nerdctl exec "${NAME}" bash -c 'dx-smi -L >/dev/null 2>&1' 2>/dev/null; then
            echo "  [G${gid}] Container ready after $((i*5))s"
            READY=true
            break
        fi
        [ $((i % 6)) -eq 0 ] && echo "  [G${gid}] Waiting... (${i}/60)"
        sleep 5
    done

    if [ "${READY}" != "true" ]; then
        echo "ERROR: [G${gid}] container did not become ready" >&2
        exit 1
    fi

    # Verify
    echo -n "  GPUs: "
    nerdctl exec "${NAME}" dx-smi -L 2>&1 | wc -l | xargs echo -n
    echo " detected"

    # Fixed-BAR check
    echo -n "  Guest BAR1: "
    nerdctl exec "${NAME}" bash -c 'cat /sys/bus/pci/devices/0000:00:10.0/resource 2>/dev/null | head -1 || echo "N/A"'

    # Re-disable ACS
    /root/acs_shutdown_vfio_group.sh ${BDFS} 2>&1 | tail -1

    echo "  [G${gid}] Deployed: ${NAME} on port ${PORT}"
    echo
done

echo "===== DONE ====="
nerdctl ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep kata
echo
echo "QEMU memory:"
ps aux | grep qemu-system | grep -v grep | grep -oP '\-m \d+M' | sort | uniq -c
echo
df -h /dev/shm
