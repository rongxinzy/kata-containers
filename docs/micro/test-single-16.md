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

### 瓶颈 6: pcie.0 slot 耗尽 → vhost-user-fs-pci 无处可放（已修复）

**根因**: Q35 的 pcie.0 只有 32 个 slot。当 `pcie_root_port = 8` 时：
- 8 个 root port 占用 slots 0-7
- 1 个 pci-bridge（`default_bridges=1`）占用 1 个 slot
- 16 个 GPU（multifunction=on）占用 slots 15-30
- ICH9-LPC 固定 slot 31
- **合计占用/预留 27 个 slot，仅剩 5 个空闲**

virtio 设备（virtio-serial-pci, virtio-blk-pci, vhost-vsock-pci, vhost-user-fs-pci）无法分配到 slot，QEMU 直接报错退出：

```
qemu-system-x86_64: -device vhost-user-fs-pci,...: PCI: no slot/function
available for vhost-user-fs-pci, all in use or reserved
```

**为何 15 GPU 能启动**: 15 GPU 占用 slots 15-29（而非 30），多出 1 个空闲 slot，恰好够 vhost-user-fs-pci 使用。

**修复**: `pcie_root_port` 从 8 降为 **4**。冷插拔 GPU 直连 pcie.0 不经 root port，root port 只用于热插拔预留，4 个足够。

```toml
# /etc/kata-containers/configuration.toml
pcie_root_port = 4   # 16 GPU 时必须 ≤4，否则 pcie.0 slot 耗尽
```

**注意**: 仅减小 `pcie_root_port` 还不够，**必须同时部署包含 `vfioRootSlotBase=15` 修复的二进制**（瓶颈 1），否则 16 个 GPU 仍会因 slot 31 碰撞而失败。

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

## 排查调试工具与方法

### 1. 定位内核 VFIO bus reset 卡死

**现象**: QEMU 进程存在但 CPU 13%，kata-agent 始终未连接，持续 15+ 分钟。

**工具**: `/proc/PID/stack`

```bash
PID=$(pgrep -f qemu-system | head -1)
cat /proc/$PID/stack
```

**关键输出**:
```
[<0>] msleep+0x2d/0x40
[<0>] pcie_wait_for_link_delay+0x5f/0xf0
[<0>] pci_bridge_wait_for_secondary_bus.part.0+0x16a/0x1d0
[<0>] __pci_reset_bus+0xe8/0x140
[<0>] pci_reset_bus+0x3b/0x50
[<0>] vfio_pci_dev_set_hot_reset+0x1b9/0x1d0
```

**分析**: 内核 `vfio_pci_dev_set_hot_reset` → `pci_reset_bus` → `pci_bridge_wait_for_secondary_bus` → `pcie_wait_for_link_delay`，PCIe 链路恢复超时。

**工具**: `strace -c -p PID`

```bash
timeout 10 strace -c -p $PID 2>&1 | tail -30
```

**关键输出**: 94% 时间在 `ioctl`（VFIO 设备初始化），799 次调用 35 错误。

**修复**: 通过 sysfs 强制 FLR 替代 bus reset:

```bash
# 查看可用复位方式
cat /sys/bus/pci/devices/0000:b8:00.0/reset_method   # → "flr bus"

# 强制函数级复位
echo flr > /sys/bus/pci/devices/0000:b8:00.0/reset_method
```

### 2. 定位 vhost 内存区域溢出

**现象**: 14+ GPU 时容器创建超时，QEMU 正常运行但 agent 未连接。

**工具**: `journalctl` 过滤 QEMU 错误

```bash
journalctl -u containerd --since "2 min ago" --no-pager \
  | grep -i "qemu-system.*error"
```

**关键输出**:
```
vhost_set_mem_table failed: Argument list too long (7)
Error starting vhost: 7
```

**分析**: errno 7 = E2BIG，`VHOST_MEMORY_MAX_NREGIONS` 默认 64，16 GPU 需 ~100 区域。

**修复**:
```bash
cat /sys/module/vhost/parameters/max_mem_regions   # → 64
modprobe -r vhost_vsock vhost_net vhost
modprobe vhost max_mem_regions=256
modprobe vhost_vsock vhost_net
```

### 3. 排查 OVMF 是否卡死（直接 QEMU 测试绕过 kata）

**目的**: 区分 OVMF firmware 问题还是 kata agent/用户空间问题。

**方法**: 构造等效 QEMU 命令行，绕过 kata runtime 直接启动 VM：

```bash
/opt/kata/bin/qemu-system-x86_64 \
    -machine q35,accel=kvm -cpu host,pmu=off \
    -m 64G -bios /opt/kata/share/ovmf/OVMF.fd \
    -kernel /opt/kata/share/kata-containers/vmlinuz-*-nvidia-gpu \
    -initrd /opt/kata/share/kata-containers/kata-alpine-*.initrd \
    -append "console=ttyS0 tsc=reliable reboot=k pci=realloc=off pci=nocrs panic=60" \
    -nographic -vga none -no-user-config -nodefaults \
    -device vfio-pci,host=0000:b8:00.0,x-fixed-bars=on,bus=pcie.0,addr=f,multifunction=on \
    ... (共 16 GPU 设备) \
    -serial stdio
```

**结果**: kernel 0.5-0.9s 启动，**OVMF 不是瓶颈**。

### 4. PCIe 设备布局分析

**工具**: Python 脚本解析 `/proc/PID/cmdline`

```python
# /tmp/parse-qemu.py
import glob, re
pids = [p for p in glob.glob("/proc/*/cmdline")
        if "qemu-system" in open(p).read()]
pid = pids[0].split("/")[2]
with open(f"/proc/{pid}/cmdline", "rb") as f:
    data = f.read().split(b"\x00")
devices = []
in_device = False
for p in data:
    s = p.decode("utf-8", errors="replace")
    if s == "-device":
        in_device = True; devices.append("")
    elif in_device:
        devices[-1] = s; in_device = False
for d in devices:
    parts = d.strip().split(",")
    bus = next((x.split("=")[1] for x in parts if x.startswith("bus=")), "auto")
    addr = next((x.split("=")[1] for x in parts if x.startswith("addr=")), "auto")
    print(f"bus={bus:8s} addr={addr:6s}  {parts[0]}")
```

**12 GPU 设备布局示例**:
```
bus=pcie.0   addr=2       pci-bridge (io-reserve=4k)
bus=auto     addr=auto    virtio-serial-pci
bus=auto     addr=auto    virtio-blk-pci
bus=pcie.0   addr=f..1a   vfio-pci × 12 (GPU + audio)
bus=auto     addr=auto    vhost-vsock-pci
bus=auto     addr=auto    vhost-user-fs-pci
```

### 5. PCIe 物理拓扑追踪

**工具**: `readlink -f` 追踪 sysfs 拓扑

```bash
# GPU 物理拓扑（经过几层 PCIe bridge）
readlink -f /sys/bus/pci/devices/0000:b8:00.0 | tr "/" "\n" | grep "0000:"

# 输出: pci0000:af → af:01.0 → b0:00.0 → b1:00.0 → ... → b8:00.0 (10 层)
```

**ACS 状态检查**:
```bash
for bdf in af:01.0 b1:00.0 b3:10.0 b5:00.0 b7:00.0; do
    setpci -s $bdf ECAP_ACS+0x06.w
done
# ACS_CTRL=0000 → 已禁用
```

### 6. GPU P2P 拓扑分析

**工具**: guest 内 NVIDIA 工具

```bash
# 检查 P2P 能力
nvidia-smi topo -p2p r -i 0,1   # nvidia-smi topo 简写
# 全部 "OK" → P2P 已启用 (x-nv-gpudirect-clique=0)

# 检查物理拓扑
nvidia-smi topo -m   # 全部 "PHB" → guest 虚拟 pcie.0 限制
```

**NCCL 传输路径诊断**:
```bash
NCCL_DEBUG=INFO NCCL_P2P_LEVEL=5 all_reduce_perf -b 256M -e 256M -f 2 -g 2 2>&1 \
  | grep -E "P2P Type|directMode|Channel.*via"
```
```
isAllDirectP2p 0 → P2P_LEVEL=SYS (默认，虚拟拓扑限制)
isAllDirectP2p 1 → P2P_LEVEL=5 (强制本地 P2P)
Channel 00 : 0[0] → 1[1] via P2P/direct pointer
```

### 7. QEMU 启动错误快速定位

```bash
# 查看 containerd 中 kata 的 QEMU 错误
journalctl -u containerd --since "2 min ago" --no-pager \
  | grep -E "qemu-system.*error|slot.*not available|vfio.*Could not"

# 查看 QEMU 进程状态
cat /proc/$(pgrep qemu-system)/status | grep -E "State|VmRSS|Threads"

# 进程运行时间
ps -o etime= -p $(pgrep qemu-system)
```

### 8. 排查流程总结

```
16 GPU 容器创建超时
  │
  ├─ QEMU 进程存在? ─── NO ──→ journalctl 查 QEMU 启动错误
  │                             (slot 冲突 / VFIO busy / IO 耗尽)
  │
  └─ QEMU 进程存在? ─── YES ──→ cat /proc/PID/stack
        │
        ├─ pcie_wait_for_link ──→ VFIO bus reset 卡死
        │                         → echo flr > reset_method
        │
        ├─ do_poll/ppoll ──→ QEMU 正常运行，guest 已启动
        │     │
        │     ├─ agent 超时未连接 ──→ journalctl 查 vhost/vsock 错误
        │     │                       → vhost_set_mem_table failed?
        │     │                       → max_mem_regions 不够
        │     │
        │     └─ agent 已连接 ──→ OK
        │
        └─ do_wait ──→ QEMU 初始化阶段卡住
                       → VFIO 设备打开失败 / 内存分配问题

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
