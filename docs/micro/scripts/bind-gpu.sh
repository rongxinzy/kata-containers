#!/bin/bash
# bind-gpu.sh — Bind GPUs to vfio-pci for Kata containers
# Usage: bash bind-gpu.sh [config_file]
#
# If config file is provided (or docs/micro/config/gpu-groups.conf exists),
# use the exact BDF groups specified there.
# Otherwise, auto-detect using nvidia-smi visibility.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${1:-${SCRIPT_DIR}/../config/gpu-groups.conf}"
IOMMU_FILE="/tmp/kata-iommu-groups.txt"
GROUP_MAP_FILE="/tmp/kata-group-map.txt"

modprobe vfio-pci 2>/dev/null || true

echo "=== bind-gpu.sh ==="

# ── Helper: bind a single BDF to vfio-pci ──
bind_one() {
    local full="0000:$1"
    local drv
    drv="$(basename "$(readlink -f "/sys/bus/pci/devices/$full/driver" 2>/dev/null)" 2>/dev/null || echo "none")"
    [ "$drv" = "vfio-pci" ] && return 0  # already bound

    echo "  $1 → vfio-pci"
    echo "vfio-pci" > "/sys/bus/pci/devices/$full/driver_override"
    [ -f "/sys/bus/pci/devices/$full/driver/unbind" ] && echo "$full" > "/sys/bus/pci/devices/$full/driver/unbind" 2>/dev/null || true
    echo "$full" > /sys/bus/pci/drivers_probe 2>/dev/null || true

    # Audio function
    local audio="${full%.0}.1"
    if [ -d "/sys/bus/pci/devices/$audio" ]; then
        echo "vfio-pci" > "/sys/bus/pci/devices/$audio/driver_override"
        [ -f "/sys/bus/pci/devices/$audio/driver/unbind" ] && echo "$audio" > "/sys/bus/pci/devices/$audio/driver/unbind" 2>/dev/null || true
        echo "$audio" > /sys/bus/pci/drivers_probe 2>/dev/null || true
    fi
}

# ── Determine which GPUs to bind ──
if [ -f "$CONFIG" ]; then
    echo "使用配置文件: $CONFIG"
    echo

    > "$IOMMU_FILE"
    > "$GROUP_MAP_FILE"

    while IFS='=' read -r group_name bdf_list; do
        # Skip comments and empty lines
        [[ "$group_name" =~ ^[[:space:]]*# ]] && continue
        [ -z "$group_name" ] && continue
        [[ "$group_name" =~ ^\[ ]] && continue

        echo "=== $group_name ==="

        IFS=',' read -ra bdfs <<< "$bdf_list"
        for bdf in "${bdfs[@]}"; do
            bdf=$(echo "$bdf" | xargs)  # trim whitespace
            [ -z "$bdf" ] && continue

            bind_one "$bdf"

            # Record IOMMU group
            full="0000:${bdf}"
            iommu="$(basename "$(readlink -f "/sys/bus/pci/devices/$full/iommu_group")" 2>/dev/null || echo "?")"
            echo "$iommu" >> "$IOMMU_FILE"
            echo "$group_name $bdf $iommu" >> "$GROUP_MAP_FILE"
        done
    done < "$CONFIG"

else
    echo "配置文件不存在 ($CONFIG), 使用自动检测..."
    echo

    # Find all NVIDIA GPUs
    ALL_GPUS=()
    for dev in /sys/bus/pci/devices/0000:*; do
        bdf=$(basename "$dev")
        class=$(cat "$dev/class" 2>/dev/null || echo "")
        vendor=$(cat "$dev/vendor" 2>/dev/null || echo "")
        if [ "$class" = "0x030000" ] && [ "$vendor" = "0x10de" ]; then
            [ "$bdf" = "0000:02:00.0" ] && continue
            ALL_GPUS+=("$bdf")
        fi
    done

    > "$IOMMU_FILE"
    bound=0
    for bdf in "${ALL_GPUS[@]}"; do
        full="0000:${bdf}"
        drv="$(basename "$(readlink -f "/sys/bus/pci/devices/$full/driver" 2>/dev/null)" 2>/dev/null || echo "none")"
        [ "$drv" = "nvidia" ] && continue  # nvidia-smi visible → Docker

        bind_one "$bdf"

        iommu="$(basename "$(readlink -f "/sys/bus/pci/devices/$full/iommu_group")" 2>/dev/null || echo "?")"
        echo "$iommu" >> "$IOMMU_FILE"
        bound=$((bound + 1))
    done
fi

sleep 2

# ── Output ──
sort -n -u "$IOMMU_FILE" -o "$IOMMU_FILE"

echo
echo "=== 结果 ==="
echo "Kata VFIO groups: $(wc -l < "$IOMMU_FILE") groups"
cat "$IOMMU_FILE" | tr '\n' ' '
echo
echo
echo "nvidia-smi 可见: $(nvidia-smi -L 2>/dev/null | wc -l) GPU"
echo "VFIO 设备: $(ls /dev/vfio/ 2>/dev/null | grep -c '^[0-9]' || echo 0)"
echo
echo "IOMMU 组列表: $IOMMU_FILE"

if [ -f "$GROUP_MAP_FILE" ] && [ -s "$GROUP_MAP_FILE" ]; then
    echo "分组映射: $GROUP_MAP_FILE"
    cat "$GROUP_MAP_FILE"
fi
