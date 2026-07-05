# 单 Kata 容器多 GPU 测试记录

**日期**: 2026-07-04  
**目标**: 验证单个 Kata 容器最多支持多少 GPU

---

## 前置条件

- 目标服务器: `172.18.1.250`, 64×RTX 4060
- 已部署自定义二进制（QEMU x-fixed-bars, OVMF ProgramBar, guest kernel）
- GPU 已绑定到 vfio-pci: `bash bind-gpu.sh`
- Kata 配置: `/etc/kata-containers/configuration.toml`

---

## 配置要点

### 1. `pcie_root_port` 必须等于 GPU 数量

```toml
# /etc/kata-containers/configuration.toml
pcie_root_port = 10  # 必须等于 GPU 数，不能多也不能少
```

- 设多了 → IO 端口超限（每个 root port 消耗 4K IO，总 IO 64K）
- 设少了 → Kata runtime 拒绝启动
- **上限 10 GPU**（实测 11 即失败）

### 2. 增大 `default_memory`

```toml
default_memory = 32768  # 32GB，为 10 GPU 提供足够 PCIe MMIO 空间
```

### 3. 保持 `cold_plug_vfio = "root-port"`

```toml
cold_plug_vfio = "root-port"  # 必须，否则 GPA≠HPA，P2P 失效
```

### 4. 完整 kernel_params

```toml
kernel_params = "nvidia_uvm.uvm_ats_mode=0 nvidia.NVreg_DmaRemapPeerMmio=0 nvidia.NVreg_EnableResizableBar=0 pci=nocrs pci=assign-busses cgroup_no_v1=all"
```

### 5. 部署命令

```bash
# 以 10 GPU 为例（G1+G2 前 10 张）
nerdctl run -d --pull never --runtime io.containerd.kata.v2 --name g10 \
    --device=/dev/vfio/260 --device=/dev/vfio/261 --device=/dev/vfio/267 \
    --device=/dev/vfio/268 --device=/dev/vfio/269 --device=/dev/vfio/270 \
    --device=/dev/vfio/276 --device=/dev/vfio/277 --device=/dev/vfio/278 \
    --device=/dev/vfio/279 \
    -m 64g -v /models:/models \
    --env NVIDIA_VISIBLE_DEVICES=void \
    --env NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    --entrypoint /bin/bash \
    vllm/vllm-openai:v0.21.0-x86_64-cu129 -c "sleep infinity"
```

---

## 测试结果

### GPU 数量上限

| GPU 数 | pcie_root_port | 结果 |
|--------|---------------|------|
| 8 | 8 | ✅ 5s 就绪 |
| 10 | 10 | ✅ 5s 就绪 |
| 11 | 11 | ❌ QEMU 崩溃 (exit 1) |
| 12 | 12 | ❌ QEMU 崩溃 |
| 16 | 16 | ❌ QEMU 崩溃 |

### 失败原因

Kata runtime 代码 (`qemu_arch_base.go`):

```go
const vfioRootSlotBase  = 16   // GPU 地址从 16 开始
      maxPCIeRootPort   = 16   // 最大 root port 数（IO 端口限制 64K ÷ 4K）
```

10 GPU 占用地址 16-25（10 个 slot）+ 10 root port（10×4K=40K IO）+ bridge（4K）+ 基础设备（~10K）= ~54K IO，在 64K 限制内。

11 GPU 时需要地址 16-26（11 个 slot）+ 11 root port（11×4K=44K IO）+ bridge + 基础 = ~58K IO，理论上仍够，但 QEMU 实际初始化时仍有冲突。

QEMU 单独命令行测试 10+ GPU 可以通过，限制在 Kata runtime 生成 QEMU 命令时的 slot 分配逻辑。

---

## 相关文档

- `simple-test-plan.md` — 4 容器部署测试计划
- `kata-vra.md` — PCIe 虚拟化参考架构（IO 端口限制说明）
- `deploy-containers.sh` — 自动化部署脚本
