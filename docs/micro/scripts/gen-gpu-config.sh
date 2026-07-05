#!/bin/bash
# gen-gpu-config.sh — Scan GPUs and generate gpu-groups.conf
# Usage: bash gen-gpu-config.sh [output_file]
set -euo pipefail

OUTPUT="${1:-/tmp/gpu-groups.conf}"
HOSTNAME=$(hostname)
GPU_COUNT=0

echo "=== 扫描 GPU 拓扑 ==="

# Collect all non-nvidia GPUs (for Kata VFIO)
KATA_BDFS=()
for dev in /sys/bus/pci/devices/0000:*/class; do
    class=$(cat "$dev" 2>/dev/null || echo "")
    d=$(dirname "$dev")
    vendor=$(cat "$d/vendor" 2>/dev/null || echo "")
    [ "$class" != "0x030000" ] && continue
    [ "$vendor" != "0x10de" ] && continue

    bdf=$(basename "$d")
    GPU_COUNT=$((GPU_COUNT + 1))

    drv=$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null || echo "none")
    [ "$drv" = "nvidia" ] && continue  # Docker GPUs

    KATA_BDFS+=("${bdf#0000:}")
done

KATA_COUNT=${#KATA_BDFS[@]}
echo "总 GPU: $GPU_COUNT | Kata (vfio): $KATA_COUNT | Docker (nvidia): $((GPU_COUNT - KATA_COUNT))"

if [ $KATA_COUNT -lt 8 ]; then
    echo "ERROR: 仅 $KATA_COUNT 个非 nvidia GPU, 至少需要 8 个"
    exit 1
fi

# Group by bus segment (first 2 chars of BDF)
# GPUs under same root port share same bus prefix
declare -A SEGMENTS
for bdf in "${KATA_BDFS[@]}"; do
    seg="${bdf:0:2}"  # e.g., "b8" -> "b8", "c4" -> "c4"
    SEGMENTS["$seg"]="${SEGMENTS[$seg]:-} $bdf"
done

# Sort by bus prefix and split into groups of 8
SORTED_BDFS=()
for seg in $(echo "${!SEGMENTS[@]}" | tr " " "\n" | sort); do
    for bdf in ${SEGMENTS[$seg]}; do
        SORTED_BDFS+=("$bdf")
    done
done

echo "排序后 Kata GPU: ${#SORTED_BDFS[@]}"

# Write config
cat > "$OUTPUT" << EOF
# GPU 分组配置文件 — ${HOSTNAME} ($(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "GPU"))
#
# 生成日期: $(date +%Y-%m-%d)
# 自动生成脚本: docs/micro/scripts/gen-gpu-config.sh
# Kata GPU: ${KATA_COUNT} | Docker GPU: $((GPU_COUNT - KATA_COUNT))
#
# 分组按 bus 号排序，每 8 个连续 GPU 为一组

[groups]
EOF

GROUP=1
for ((start=0; start<${#SORTED_BDFS[@]}; start+=8)); do
    group_bdfs=""
    for ((i=0; i<8 && (start+i)<${#SORTED_BDFS[@]}; i++)); do
        [ $i -gt 0 ] && group_bdfs="$group_bdfs,"
        group_bdfs="$group_bdfs${SORTED_BDFS[$((start+i))]}"
    done
    echo "G${GROUP}=$group_bdfs" >> "$OUTPUT"
    GROUP=$((GROUP + 1))
done

echo
echo "=== 已生成: $OUTPUT ==="
cat "$OUTPUT"
echo
echo "Groups: $((GROUP-1))"
