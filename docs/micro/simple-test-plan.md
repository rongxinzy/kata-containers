# Kata VFIO 多实例并发推理测试——执行手册

**版本**: v2.0  
**日期**: 2026-07-01  
**目标读者**: 测试人员  
**前置阅读**: 无，按步骤执行即可  

---

## 概述

在一台 64×RTX 4060 服务器上同时运行 5 个 Qwen3-14B vLLM 推理实例：

| 实例 | 类型 | GPU | 配置 |
|------|------|-----|------|
| kata-g1 ~ kata-g4 | Kata VFIO 直通 | 各 8 GPU (共 32) | TP=4, PP=2 |
| vllm-docker | Docker (宿主机) | 32 GPU | TP=8, PP=4 |

**核心原则**：脚本自动适配不同机器的 GPU 拓扑——无需手动指定 BDF 或 IOMMU 组号。

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
| `docs/micro/scripts/deploy-containers.sh` | 部署 4 Kata + 1 Docker |
| `docs/micro/scripts/start-vllm-services.sh` | 启动所有 vLLM 服务 |
| `docs/micro/scripts/verify-deployment.sh` | 自动验证报告 |
| `docs/micro/scripts/run-all.sh` | 一键全流程 |

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

```bash
bash docs/micro/scripts/deploy-containers.sh
```

脚本自动完成：
- 配置 Kata（16 vCPU, 32G RAM, cold_plug_vfio=root-port）
- 清除 containerd 旧状态
- 扩容 /dev/shm 到 300G
- 依据 `/tmp/kata-iommu-groups.txt` 部署 4 个 Kata 容器
- 部署 1 个 Docker 容器（使用剩余 GPU）

预期输出：
```
kata-g1   Up   0.0.0.0:8014->8000/tcp
kata-g2   Up   0.0.0.0:8015->8000/tcp
kata-g3   Up   0.0.0.0:8016->8000/tcp
kata-g4   Up   0.0.0.0:8017->8000/tcp
vllm-docker   Up   ...
QEMU 进程: 4
```

### Step 3: 启动 vLLM

```bash
bash docs/micro/scripts/start-vllm-services.sh
```

脚本自动完成：
- 逐个启动 Kata 容器内的 vLLM（TP=4, PP=2）
- 启动 Docker 容器内的 vLLM（TP=8, PP=4）
- 等待每个实例健康检查返回 200

预期：5 个端口 (8014, 8015, 8016, 8017, 8000) 全部返回 200。

### Step 4: 验证

```bash
bash docs/micro/scripts/verify-deployment.sh
```

脚本自动检查：
- 容器状态（4 Kata + 1 Docker Up）
- GPU 数量（每个 Kata 8, Docker 32）
- BAR 冲突（全部 0）
- vLLM 健康（全部 200）
- NCCL P2P 带宽（每组 ≥ 12 GB/s）
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

## 5. 停止与清理

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
