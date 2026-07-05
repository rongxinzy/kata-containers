# Kata VFIO 多实例并发推理测试——执行手册

**版本**: v3.0  
**日期**: 2026-07-05  
**目标读者**: 测试人员  
**前置阅读**: 无，按步骤执行即可  

---

## 概述

在 64×RTX 4060 服务器上支持两种部署模式：

| 模式 | 容器数 | 每容器 GPU | 总 GPU | 适用场景 |
|------|--------|-----------|--------|---------|
| **4 kata** (默认) | 4 × kata | 各 8 GPU | 32 | 多实例小模型并发 |
| **2 kata** | 2 × kata | 各 16 GPU | 32 | 大模型/少实例高吞吐 |

每容器 vLLM 自动适配启参：

| 模式 | 每容器 GPU | vLLM TP/PP | NCCL_P2P_LEVEL | 容器内存 |
|------|-----------|-----------|----------------|---------|
| 4 kata | 8 | TP=4 PP=2 | SYS | 32g |
| 2 kata | 16 | **TP=4 PP=4** | **5** | 96g |

配合 Docker 容器使用剩余 nvidia-smi 可见的 GPU。

**核心原则**：脚本自动适配——无需手动指定 BDF 或 IOMMU 组号。

---

## 1. 前置条件

### 1.1 环境信息

| 项目 | 值 |
|------|-----|
| 服务器 IP | `172.18.5.133` |
| 登录方式 | `ssh root@172.18.5.133` (密码 `Admin@9000`) |
| GPU | 64× NVIDIA RTX 4060 Laptop (8 GB) |
| 系统内存 | ≥ 300 GB |
| 模型路径 | `/models/Qwen3-14B` |
| NCCL 测试 | `/models/nccl-tests-2.18.3` |

### 1.2 所需文件

| 文件 | 用途 |
|------|------|
| `docs/micro/config/gpu-groups.conf` | **GPU 分组配置**——每台机器单独配置 |
| `docs/micro/scripts/bind-gpu.sh` | 读取配置，绑定 GPU 到 vfio-pci |
| `docs/micro/scripts/deploy-containers.sh` | 部署容器 (支持 `--groups=2\|4`) |
| `docs/micro/scripts/start-vllm-services.sh` | 启动所有 vLLM 服务（自动适配） |
| `docs/micro/scripts/verify-deployment.sh` | 自动验证报告 |
| `docs/micro/scripts/run-all.sh` | 一键全流程 (`--groups=2\|4`)

### 1.3 首次配置（每台机器只需做一次）

**Step A: 确定 GPU 分组**

```bash
# 登录服务器，查看 GPU 拓扑
ssh root@172.18.5.133
lspci | grep -i nvidia | grep 'VGA\|3D' | head -32
nvidia-smi -L | wc -l   # 确认可见 32 张
```

根据 `lspci -tvv` 的输出，把同一 PCIe switch 下的 8 张 GPU 分为一组，
编辑 `docs/micro/config/gpu-groups.conf` 填入正确的 BDF。

> 如何判断同一个 switch：`lspci -tvv` 输出中，同一 `+-XX.0-[YY-ZZ]` 下的设备就是同一 switch。

**Step B: 部署依赖**

```bash
# QEMU 运行时库（目标服务器执行一次）
ssh root@172.18.5.133 "apt-get install -y libpixman-1-0 libslirp0 libfdt1"

# NCCL 重新编译（容器 CUDA 13 兼容）
bash docs/micro/scripts/build-nccl.sh

# 确保 ACS 关闭脚本存在
# （Kata VFIO 必须，如果 /root/acs_shutdown_vfio_group.sh 已存在则跳过）
```

---

## 2. 测试步骤

### Step 1: 绑定 GPU

```bash
bash docs/micro/scripts/bind-gpu.sh
```

脚本自动完成：
- 扫描所有 NVIDIA GPU 的 PCIe 拓扑
- 按二级 switch 分组，选择 2 个 switch（32 GPU）绑定到 vfio-pci
- 其余 32 GPU 留给 Docker
- 输出文件: `/tmp/kata-iommu-groups.txt`

### Step 2: 部署容器

**模式 A: 4 容器 × 8 GPU（默认）**

```bash
bash docs/micro/scripts/deploy-containers.sh
# 等价于: bash docs/micro/scripts/deploy-containers.sh --groups=4
```

**模式 B: 2 容器 × 16 GPU**

```bash
bash docs/micro/scripts/deploy-containers.sh --groups=2
```

脚本自动完成：
- 配置 Kata（自动适配 vCPU/RAM/agent timeout）
- 16 GPU 模式自动设置 `NCCL_P2P_LEVEL=5`（绕过虚拟拓扑）
- 清除 containerd 旧状态 + 扩容 /dev/shm
- 依据 `/tmp/kata-iommu-groups.txt` 部署 N 个 Kata 容器
- 部署 1 个 Docker 容器（使用剩余 GPU）

| 模式 | 容器 | 每容器 GPU | 内存 | 端口 |
|------|------|-----------|------|------|
| 4 groups | g1~g4 | 8 | 32g | 8014~8017 |
| 2 groups | g1, g2 | 16 | 64g | 8014, 8015 |

### Step 3: 启动 vLLM

```bash
bash docs/micro/scripts/start-vllm-services.sh
```

脚本自动检测容器和 GPU 数量，适配 TP/PP 参数：
- **4 kata 模式**: 每容器 TP=4, PP=2，NCCL_P2P_LEVEL=SYS
- **2 kata 模式**: 每容器 TP=8, PP=2，NCCL_P2P_LEVEL=5
- Docker: TP=8, PP=4

### Step 4: 验证

```bash
bash docs/micro/scripts/verify-deployment.sh
```

脚本自动检查：
- 容器状态（N Kata + 1 Docker Up）
- GPU 数量
- BAR 冲突（全部 0）
- vLLM 健康（全部 200）
- NCCL P2P 带宽
- 系统资源（/dev/shm、内存、QEMU 进程）

---

## 3. 服务端口

| 实例 | 端口 |
|------|------|
| kata-g1 | 8014 |
| kata-g2 | 8015 |
| kata-g3 | 8016 |
| kata-g4 | 8017 |
| vllm-docker | 8000 |

---

## 4. 故障排查

| 现象 | 处理 |
|------|------|
| `bind-gpu.sh` 报 VFIO 组不足 | `modprobe vfio-pci` 后重试 |
| 容器 `Created` 不启动 | Step 2 已自动清理，重新执行即可 |
| vLLM 加载超时 | 正常需 3-5 分钟；检查 `/root/vllm.log` |
| NCCL 报 `libcudart.so.12` | 执行 `build-nccl.sh` 重新编译 |
| 端口无响应 | 模型仍在加载中，等待 5 分钟 |

---

## 5. 性能基准（Qwen3-14B, len=256）

| 模式 | GPU | TP/PP | 50并发 tok/s | 100并发 tok/s | vLLM 启动 |
|------|-----|-------|-------------|-------------|----------|
| 2 kata | 16 | TP=4 PP=4 | 1628 | 2387 | 140s |
| 单 kata | 8 | TP=4 PP=2 | 1667 | **2439** | 120s |

> 8 GPU TP=4 PP=2 在 Qwen3-14B 上吞吐更高——PP=4 的 pipeline bubble 开销大于收益。  
> 16 GPU TP=4 PP=4 适合更大模型（如 Qwen3-70B）或需要更大 batch size 的场景。

---

## 6. 停止与清理

```bash
# 停止所有容器
for NAME in kata-g1 kata-g2 kata-g3 kata-g4; do
    nerdctl rm -f ${NAME} 2>/dev/null || true
done
docker rm -f vllm-docker 2>/dev/null || true

# 恢复 GPU（建议重启）
reboot
```

---

## 附录：手动推理测试

```bash
# 快速测试单个端口
curl -s http://localhost:8014/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen3-14B","prompt":"Hello, my name is","max_tokens":20}'
```

---

## 附录：单容器多 GPU 模式

除了本手册的 4 容器方案，也支持单 Kata 容器直通最多 **16 GPU**，适合不需要多实例并发的场景。详细配置见 `test-single-16.md`。

要点：
- `NCCL_P2P_LEVEL=5` 强制 P2P（绕过虚拟拓扑）
- 宿主机需设置 GPU FLR + `vhost max_mem_regions=256`
- Kata runtime 需应用 `vfioRootSlotBase=15` 和 cold-plug root port 优化
