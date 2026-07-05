# 单 Kata 容器 16 GPU 支持研究与测试记录

**日期**: 2026-07-04 ~ 2026-07-05
**目标**: 突破单 Kata 容器 10 GPU 上限，实现 16 GPU 直通
**目标服务器**: `172.18.1.250`, 64×RTX 4060
**最终状态**: ✅ **16 GPU 成功！**

---

## 最终状态

单 Kata 容器（`cold_plug_vfio=root-port`）**成功支持 16 GPU**。

| GPU 数 | 结果 | 说明 |
|--------|------|------|
| 8 | ✅ | 5s 就绪，GPA=HPA |
| 10 | ✅ | 5s 就绪 |
| 12 | ✅ | 5s 就绪 |
| **16** | ✅ | **5s 就绪，GPA=HPA，0 错误** |

---

## 瓶颈分析与修复

### 瓶颈 1: PCIe slot 碰撞（已修复）

**根因**: Q35 机器 ICH9-LPC 固定在 slot 31（0x1f），GPU 从 slot 16 开始分配时，第 16 个 GPU 撞上 slot 31。

**修复**: `vfioRootSlotBase: 16 → 15`，GPU 使用 slot 15-30（避开 slot 31）。

**文件**: `src/runtime/virtcontainers/qemu_arch_base.go`

### 瓶颈 2: Root port IO 膨胀（已修复）

**根因**: 冷插拔 GPU 直接挂载在 `pcie.0` 上（不经过 root port），但代码仍为每个 GPU 数创建空 root port。16 个 root port × 4KB IO = 64KB > 40KB Q35 IO 窗口。

**修复**: `createPCIeTopology()` 中，当 `ColdPlugVFIO=RootPort` 时不将 VFIO 设备计入 root port 数量。root port 数 = `pcie_root_port` 配置值。

**文件**: `src/runtime/virtcontainers/qemu.go`

### 瓶颈 3: 内核 VFIO bus reset 卡死（已修复）

**根因**: QEMU 打开 VFIO 设备时，内核 vfio-pci 驱动执行 `vfio_pci_dev_set_hot_reset` → `pci_reset_bus` → `pci_bridge_wait_for_secondary_bus` → `pcie_wait_for_link_delay`，链路恢复超时，QEMU 卡死在 ioctl。

内核栈:
```
msleep → pcie_wait_for_link_delay → pci_bridge_wait_for_secondary_bus
→ __pci_reset_bus → vfio_pci_dev_set_hot_reset → vfio_pci_core_ioctl
```

**修复**: 强制 GPU 使用 FLR（Function Level Reset）替代 bus reset：
```bash
echo flr > /sys/bus/pci/devices/0000:XX:00.0/reset_method
```

FLR 只复位单个 GPU 功能，不影响其他 GPU，速度极快。

### 瓶颈 4: OVMF 64-bit MMIO aperture（已排除）

**排查结论**: OVMF **不是瓶颈**。通过直接 QEMU（绕过 kata）测试：
- 16 GPU + initrd: kernel 0.9s 启动
- 16 GPU + 完整 guest image: kernel 0.65s 启动
- 16 GPU + kata dm-verity cmdline: kernel 0.52s 启动

### 瓶颈 5: vhost 内存区域溢出（已修复）

**根因**: 内核 vhost 模块的 `VHOST_MEMORY_MAX_NREGIONS` 默认 64。每个 GPU 的 MMIO BAR 映射为一个内存区域：
- 16 GPU × ~5 MMIO BAR = 80 区域
- Audio 函数 × ~1 BAR = 16 区域
- Guest RAM = 2 区域
- 总计 ~98 区域 > 64 上限

vhost-vsock 的 `vhost_set_mem_table` 调用失败（E2BIG, error 7），导致 kata-agent 无法通过 vsock 连接，容器创建超时 20 分钟。

**日志特征**:
```
qemu-system-x86_64: vhost_set_mem_table failed: Argument list too long (7)
qemu-system-x86_64: Error starting vhost: 7
```

**修复**:
```bash
modprobe -r vhost_vsock vhost_net vhost
modprobe vhost max_mem_regions=256
modprobe vhost_vsock
modprobe vhost_net
```

验证: `cat /sys/module/vhost/parameters/max_mem_regions` → `256`

---

## Kata Runtime 代码改动

当前分支 `vfio-fixed-bar-gpa-hpa-multifunction`，已编译并部署的二进制包含以下改动：

### 改动 1: 冷插拔 VFIO 不计入 root port 数

**文件**: `src/runtime/virtcontainers/qemu.go`，函数 `createPCIeTopology()`

```go
// 当 ColdPlugVFIO=RootPort 时，冷插拔 GPU 直接挂载在 pcie.0 上
// 不经过 root port，因此不计入 root port 数量
if q.state.ColdPlugVFIO != config.RootPort {
    for _, dev := range hypervisorConfig.VFIODevices {
        // ... ConfidentialGuest check ...
    }
    numOfPluggablePorts += uint32(len(hypervisorConfig.VFIODevices))
}
```

### 改动 2: vfioRootSlotBase

**文件**: `src/runtime/virtcontainers/qemu_arch_base.go`

```go
// ICH9-LPC 固定在 slot 31 (0x1f)，16 个 GPU 需避开
const vfioRootSlotBase = 15  // 原来为 16
```

---

## 部署配置

### Kata 配置

```toml
# /etc/kata-containers/configuration.toml
cold_plug_vfio = "root-port"
pcie_root_port = 4            # 不需要随 GPU 数量变化
default_memory = 98304         # 96GB（16 GPU 建议 >= 64GB）
agent.launch_process_timeout = 120  # 增大超时（默认 15s 不够）
```

### 宿主机 GPU FLR 设置 + vhost 内存区域

```bash
# 1. 设置 GPU FLR（Function Level Reset）
for iommu in $(cat /tmp/kata-iommu-groups.txt); do
    for dev in $(ls /sys/kernel/iommu_groups/$iommu/devices/ | grep '\.0$'); do
        echo flr > /sys/bus/pci/devices/$dev/reset_method
    done
done

# 2. 增大 vhost 内存区域上限（支持 16 GPU 需要的 ~100 个内存区域）
modprobe -r vhost_vsock vhost_net vhost
modprobe vhost max_mem_regions=256
modprobe vhost_vsock
modprobe vhost_net
# 验证: cat /sys/module/vhost/parameters/max_mem_regions → 256
```

### 关键二进制版本

| 组件 | 版本/Commit | 说明 |
|------|-----------|------|
| kata-runtime | vfio-fixed-bar-gpa-hpa-multifunction + 改动 1, 2 | 本次修改 |
| containerd-shim-kata-v2 | 同上 | 本次修改 |
| QEMU | 10.2.1 + x-fixed-bars 补丁 | `tools/packaging/qemu/patches/` |
| OVMF | edk2-stable202508 + ProgramBar 补丁 | `tools/packaging/static-build/ovmf/patches/` |
| guest kernel | 6.18.15-nvidia-gpu | 自定义 NVIDIA 驱动 |

---

## 测试部署命令

### 16 GPU 容器

```bash
nerdctl run -d --pull never --runtime io.containerd.kata.v2 --name g16 \
    --device=/dev/vfio/260 --device=/dev/vfio/261 \
    --device=/dev/vfio/267 --device=/dev/vfio/268 \
    --device=/dev/vfio/269 --device=/dev/vfio/270 \
    --device=/dev/vfio/276 --device=/dev/vfio/277 \
    --device=/dev/vfio/278 --device=/dev/vfio/279 \
    --device=/dev/vfio/285 --device=/dev/vfio/286 \
    --device=/dev/vfio/287 --device=/dev/vfio/288 \
    --device=/dev/vfio/292 --device=/dev/vfio/293 \
    -m 96g \
    --env NVIDIA_VISIBLE_DEVICES=void \
    --env NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    --entrypoint /bin/bash \
    vllm/vllm-openai:v0.21.0-x86_64-cu129 -c "sleep infinity"
```

### 12 GPU 容器
    --device=/dev/vfio/260 --device=/dev/vfio/261 \
    --device=/dev/vfio/267 --device=/dev/vfio/268 \
    --device=/dev/vfio/269 --device=/dev/vfio/270 \
    --device=/dev/vfio/276 --device=/dev/vfio/277 \
    --device=/dev/vfio/278 --device=/dev/vfio/279 \
    --device=/dev/vfio/285 --device=/dev/vfio/286 \
    -m 64g \
    --env NVIDIA_VISIBLE_DEVICES=void \
    --env NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    --entrypoint /bin/bash \
    vllm/vllm-openai:v0.21.0-x86_64-cu129 -c "sleep infinity"
```

---

## 验证命令

```bash
# 确认 GPU 在 pcie.0 上（不是 rp0）
ps aux | grep qemu-system | grep "vfio-pci" | grep -o "bus=pcie.0"

# 确认 slot 范围 (0xf-0x1a for 12 GPU)
ps aux | grep qemu-system | grep -o "bus=pcie.0,addr=[0-9a-f]*" | sort -u

# 确认 GPA=HPA (BAR1 地址匹配)
nerdctl exec g12 cat /sys/bus/pci/devices/0000:00:0f.0/resource | sed -n 2p
cat /sys/bus/pci/devices/0000:b8:00.0/resource | sed -n 2p

# 确认 root port 数量为 0（不再膨胀）
ps aux | grep qemu-system | grep -c "pcie-root-port"

# GPU 检测
nerdctl exec g12 nvidia-smi -L | wc -l  # 预期: 12
```

---

## OVMF 排查记录

### 直接 QEMU 测试（绕过 kata）

| 测试配置 | 结果 | Kernel 启动时间 |
|---------|------|---------------|
| 16 GPU + initrd (alpine) | ✅ | 0.9s |
| 16 GPU + guest image (raw rootfs) | ✅ | 0.65s |
| 16 GPU + kata dm-verity kernel cmdline | ✅ | 0.52s |

结论：**OVMF 不是瓶颈**，16 GPU 下 kernel 启动只需 < 1 秒。

### VFIO bus reset 卡死定位

通过 `/proc/PID/stack` 捕获到 QEMU 卡在内核 `pcie_wait_for_link_delay`，strace 显示 94% 时间在 ioctl（VFIO 设备初始化）。FLR 修复后消失。

---

## 14+ GPU 后续排查方向（已解决）

✅ 根因是 vhost 内存区域限制，不是 PCI slot 问题。增大 `max_mem_regions` 后 16 GPU 正常。

---

## NCCL P2P 带宽验证

### 问题

默认 `NCCL_P2P_LEVEL=SYS` 时，NCCL 读取 guest 虚拟 PCIe 拓扑，所有 GPU 对显示为 "PHB"（经 PCIe Host Bridge），拒绝直连 P2P，带宽仅 2.09 GB/s。

### 根因

16 GPU 在 guest 内均位于虚拟 `pcie.0` 总线上，`nvidia-smi topo -m` 显示全部为 PHB。但物理上这些 GPU 同属一个 PCIe switch（`b3:10.0`，上游 `af:01.0`），支持直连 P2P。`x-nv-gpudirect-clique=0` 已启用，`nvidia-smi topo -p2p r` 显示全"OK"。

### 修复

```bash
# 容器环境变量或在 vLLM 启动脚本中设置
export NCCL_P2P_LEVEL=5   # 强制本地 P2P，忽略虚拟拓扑
```

### 测试结果（P2P_LEVEL=5）

| 测试 | GPU 数 | 峰值 bus BW | 错误 |
|------|--------|-----------|------|
| all_reduce | 16 | **12.97 GB/s** | 0 |
| all_reduce | 2 | 12.32 GB/s | 0 |
| sendrecv (P2P 直连) | 2 | **12.97 GB/s** | 0 |

带宽达到 PCIe Gen4 x8 理论上限（~13 GB/s），与宿主机直连 GPU 一致。

### 完整 NCCL 测试命令

```bash
# 16 GPU all_reduce 完整测试
nerdctl exec g16 bash -c 'NCCL_P2P_LEVEL=5 \
    /models/nccl-tests-2.18.3/build/all_reduce_perf \
    -b 8 -e 1G -f 2 -g 16'

# 2 GPU 直连带宽测试
nerdctl exec g16 bash -c 'NCCL_P2P_LEVEL=5 \
    /models/nccl-tests-2.18.3/build/sendrecv_perf \
    -b 1M -e 1G -f 2 -g 2'
```

---

## 相关文档

- `simple-test-plan.md` — 4 容器部署测试计划
- `vfio-fixed-bar-gpa-hpa-kata.md` — VFIO fixed-BAR 部署指南
- `build-and-deploy.md` — 编译和部署指南
