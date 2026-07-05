#!/bin/bash
set -euo pipefail

# 必须root执行
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: 必须以 root 用户运行此脚本" >&2
    exit 1
fi

# 抓取所有NVIDIA设备完整BDF（0000:xx:xx.x格式）
get_nvidia_bdfs() {
    lspci -nn -D | grep -i nvidia | awk '{print $1}'
}

# 绑定单个BDF到vfio-pci
bind_vfio_single() {
    local BDF="$1"
    local DEV="/sys/bus/pci/devices/${BDF}"

    if [ ! -d "${DEV}" ]; then
        echo "WARN: ${BDF} 不存在，跳过"
        return 0
    fi

    echo "========================================"
    echo "处理设备: ${BDF}"

    # 查看当前IOMMU组
    if [ -L "${DEV}/iommu_group" ]; then
        IOMMU_GROUP=$(readlink -e "${DEV}/iommu_group")
        echo "IOMMU组路径: ${IOMMU_GROUP}"
        echo "IOMMU组编号: $(basename "${IOMMU_GROUP}")"
    else
        echo "IOMMU未启用或无分组"
    fi

    # 设置driver_override为vfio-pci
    echo "vfio-pci" > "${DEV}/driver_override"
    echo "已写入driver_override=vfio-pci"

    # 解绑原驱动
    if [ -f "${DEV}/driver/unbind" ]; then
        echo "${BDF}" > "${DEV}/driver/unbind"
        echo "已解绑原有驱动"
    fi

    # 重新probe触发vfio绑定
    echo "${BDF}" > /sys/bus/pci/drivers_probe
    echo "重新probe完成"
    echo "${BDF} 已成功绑定至vfio-pci"
}

# 解绑恢复NVIDIA原生驱动
unbind_vfio_single() {
    local BDF="$1"
    local DEV="/sys/bus/pci/devices/${BDF}"

    if [ ! -d "${DEV}" ]; then
        echo "WARN: ${BDF} 不存在，跳过"
        return 0
    fi

    echo "========================================"
    echo "恢复设备原生驱动: ${BDF}"

    # 清空首选驱动与override
    echo "" > "${DEV}/preferred_driver"
    echo "" > "${DEV}/driver_override"

    # 解绑当前vfio
    if [ -f "${DEV}/driver/unbind" ]; then
        echo "${BDF}" > "${DEV}/driver/unbind"
    fi

    # 重新probe加载原生nvidia驱动
    echo "${BDF}" > /sys/bus/pci/drivers_probe
    echo "${BDF} 已恢复NVIDIA原生驱动"
}

# 批量绑定所有NVIDIA卡
bind_all_nvidia() {
    BDF_LIST=$(get_nvidia_bdfs)
    if [ -z "${BDF_LIST}" ]; then
        echo "未检测到任何NVIDIA PCI设备"
        exit 0
    fi

    echo "检测到NVIDIA设备列表："
    echo "${BDF_LIST}"
    echo

    while read -r BDF; do
        bind_vfio_single "${BDF}"
    done <<< "${BDF_LIST}"

    echo
    echo "全部NVIDIA设备vfio绑定完成，查看/dev/vfio:"
    ls -l /dev/vfio
}

# 批量恢复所有NVIDIA卡
unbind_all_nvidia() {
    BDF_LIST=$(get_nvidia_bdfs)
    if [ -z "${BDF_LIST}" ]; then
        echo "未检测到任何NVIDIA PCI设备"
        exit 0
    fi

    while read -r BDF; do
        unbind_vfio_single "${BDF}"
    done <<< "${BDF_LIST}"

    echo "全部设备恢复原生驱动完成"
}

# 脚本入口参数判断
case "${1:-bind}" in
    bind|"")
        bind_all_nvidia
        ;;
    unbind)
        unbind_all_nvidia
        ;;
    *)
        echo "用法:"
        echo "  $0          # 自动绑定所有NVIDIA到vfio-pci"
        echo "  $0 unbind   # 恢复所有NVIDIA原生驱动"
        exit 1
        ;;
esac
