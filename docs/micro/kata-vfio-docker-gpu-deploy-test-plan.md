# Kata VFIO GPU 直通 + Docker GPU 推理 部署测试文档

> **目标服务器**: `172.18.5.133`（root / `Admin@9000`）  
> **测试日期**: 2026-06-27  
> **GPU**: 64 × NVIDIA RTX 4060 Laptop GPU (8GB)  
> **实际部署**: 4 组 Kata VFIO 直通 (32 GPU) + 1 个 Docker 容器 (24 GPU) = **56 GPU 同时运行**  
> **模型**: Qwen3.6-35B-A3B-FP8  
> **状态**: ✅ 4 组全部部署成功，G1 vLLM 已通过 benchmark 验证  

---

## 1. 前置条件

- [ ] 目标机已安装 containerd + nerdctl
- [ ] 目标机已安装 Docker CE + nvidia-container-toolkit
- [ ] `/opt/kata` 下已部署带 `x-fixed-bars` 支持的 QEMU、kata-runtime、OVMF
- [ ] `/dev/shm` 已扩容至 300 GB（4 VM × 64 GB = 256 GB + 余量）
- [ ] `/models/Qwen3.6-35B-A3B-FP8` 模型文件已就绪
- [ ] `/opt/kata/share/defaults/kata-containers/configuration-qemu-nvidia-gpu.toml` 配置模板已存在

---

## 2. GPU 分组定义

> 分组定义来源：`/home/rx/bingo/deploy_all_groups.sh`（8 组 × 8 GPU）  
> 各组 BDF 映射到 IOMMU 组号，用于 `--device=/dev/vfio/N` 参数。

| 组名 | function-0 BDF | IOMMU 组号 | vfio-pci | nvidia | CDI | 用途 |
|------|----------------|-----------|----------|--------|-----|------|
| **G1** | 5b:00.0 5c:00.0 5f:00.0 60:00.0 61:00.0 62:00.0 65:00.0 66:00.0 | 121 122 128 129 130 131 137 138 | ✅ | — | ✅ | **Kata VFIO** |
| **G2** | 67:00.0 68:00.0 6b:00.0 6c:00.0 6d:00.0 6e:00.0 71:00.0 72:00.0 | 139 140 146 147 148 149 153 154 | — | ✅ | ❌ | **Docker** |
| **G3** | 79:00.0 7a:00.0 7d:00.0 7e:00.0 7f:00.0 80:00.0 83:00.0 84:00.0 | 166 167 173 174 175 176 182 183 | — | ✅ | ✅ | **Docker** |
| **G4** | 85:00.0 86:00.0 89:00.0 8a:00.0 8b:00.0 8c:00.0 8f:00.0 90:00.0 | 184 185 191 192 193 194 198 199 | — | ✅ | ✅ | **Docker** |
| **G5** | 9a:00.0 9b:00.0 9e:00.0 9f:00.0 a0:00.0 a1:00.0 a4:00.0 a5:00.0 | 26 27 33 34 35 36 42 43 | ❌ | ❌ | ❌ | **不可用** |
| **G6** | a6:00.0 a7:00.0 aa:00.0 ab:00.0 ac:00.0 ad:00.0 b0:00.0 b1:00.0 | 44 45 51 52 53 54 58 59 | ✅ | — | ✅ | **Kata VFIO** |
| **G7** | b8:00.0 b9:00.0 bc:00.0 bd:00.0 be:00.0 bf:00.0 c2:00.0 c3:00.0 | 71 72 78 79 80 81 87 88 | ✅ | — | ✅ | **Kata VFIO** |
| **G8** | c4:00.0 c5:00.0 c8:00.0 c9:00.0 ca:00.0 cb:00.0 ce:00.0 cf:00.0 | 89 90 96 97 98 99 103 104 | ✅ | — | ✅ | **Kata VFIO** |

### G5 问题说明

G5 是唯一完全不可用的组：
- **Kata VFIO**: CDI timeout（与 G2 相同症状）
- **Docker/nvidia**: `RmInitAdapter failed! (0x22:0x40:894)` — NVIDIA 消费级驱动 ~32 GPU 软限制，额外 GPU 无法初始化
- **结论**: 跳过高 bus 号区间的 GPU（9a-a5 段）可能存在电气/固件问题

### 实际分配

| 实例 | 使用 GPU 组 | GPU 数 | 驱动 | 容器端口 |
|------|------------|--------|------|----------|
| Kata G1 | G1 | 8 | vfio-pci | 8010 |
| Kata G6 | G6 | 8 | vfio-pci | 8015 |
| Kata G7 | G7 | 8 | vfio-pci | 8016 |
| Kata G8 | G8 | 8 | vfio-pci | 8017 |
| Docker | G2+G3+G4 | **24** | nvidia | 8000 |

---

## 3. 环境准备

### 3.1 扩容 /dev/shm

```bash
mount -o remount,size=300G /dev/shm
df -h /dev/shm
# 预期: 300G
# 实测: 4 个 VM × 48GB = 192GB /dev/shm 占用 (64%)
```

### 3.2 配置 Kata

> **实际使用配置**（2026-06-27 验证通过）：

```bash
cp /opt/kata/share/defaults/kata-containers/configuration-qemu-nvidia-gpu.toml \
   /etc/kata-containers/configuration.toml

# 关键参数
sed -i 's|^default_vcpus = .*|default_vcpus = 16|' /etc/kata-containers/configuration.toml
sed -i 's|^default_memory = .*|default_memory = 16384|' /etc/kata-containers/configuration.toml
sed -i 's|^memory_slots = .*|memory_slots = 1|' /etc/kata-containers/configuration.toml  # 改: 2→1
sed -i 's|^enable_hugepages = .*|enable_hugepages = false|' /etc/kata-containers/configuration.toml
sed -i 's|^pcie_root_port = .*|pcie_root_port = 8|' /etc/kata-containers/configuration.toml
sed -i 's|^cold_plug_vfio = .*|cold_plug_vfio = "root-port"|' /etc/kata-containers/configuration.toml
sed -i 's|^disable_selinux = .*|disable_selinux = true|' /etc/kata-containers/configuration.toml
sed -i 's|^pod_resource_api_sock = .*|pod_resource_api_sock = ""|' /etc/kata-containers/configuration.toml
sed -i 's|^kernel_params = .*|kernel_params = "cgroup_no_v1=all pci=realloc pci=nocrs pci=assign-busses"|' /etc/kata-containers/configuration.toml

# ★ 同步到 shim v2 读取路径（必须！）
cp /etc/kata-containers/configuration.toml \
   /opt/kata/share/defaults/kata-containers/configuration-qemu.toml
mkdir -p /opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu
cp /etc/kata-containers/configuration.toml \
   /opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu/configuration-qemu-nvidia-gpu.toml

ln -sf /opt/kata/bin/containerd-shim-kata-v2 /usr/local/bin/containerd-shim-kata-v2
systemctl restart containerd
```

**验证配置**:
```bash
grep -E "default_vcpus|default_memory|enable_hugepages|pcie_root_port|cold_plug_vfio|memory_slots" \
  /etc/kata-containers/configuration.toml
```
预期:
```
default_vcpus = 16
default_memory = 16384
enable_hugepages = false
pcie_root_port = 8
cold_plug_vfio = "root-port"
memory_slots = 1
```

---

## 4. GPU 驱动绑定

### 4.1 绑定 G1/G3/G4 的 GPU（含 audio 设备）到 vfio-pci

```bash
# 绑定 function-0 (VGA) 和 function-1 (Audio)
for bdf in 5b:00.0 5c:00.0 5f:00.0 60:00.0 61:00.0 62:00.0 65:00.0 66:00.0 \
           79:00.0 7a:00.0 7d:00.0 7e:00.0 7f:00.0 80:00.0 83:00.0 84:00.0 \
           85:00.0 86:00.0 89:00.0 8a:00.0 8b:00.0 8c:00.0 8f:00.0 90:00.0; do
    full_bdf="0000:${bdf}"
    echo "vfio-pci" > /sys/bus/pci/devices/${full_bdf}/driver_override
    [ -f "/sys/bus/pci/devices/${full_bdf}/driver/unbind" ] && \
      echo "${full_bdf}" > /sys/bus/pci/devices/${full_bdf}/driver/unbind
    echo "${full_bdf}" > /sys/bus/pci/drivers_probe
    # audio
    audio_bdf="${full_bdf%.0}.1"
    if [ -d "/sys/bus/pci/devices/${audio_bdf}" ]; then
        echo "vfio-pci" > /sys/bus/pci/devices/${audio_bdf}/driver_override
        [ -f "/sys/bus/pci/devices/${audio_bdf}/driver/unbind" ] && \
          echo "${audio_bdf}" > /sys/bus/pci/devices/${audio_bdf}/driver/unbind
        echo "${audio_bdf}" > /sys/bus/pci/drivers_probe 2>/dev/null || true
    fi
done
```

**验证**:

```bash
# 检查驱动绑定（以 5b:00.0 和 5b:00.1 为例）
basename $(readlink /sys/bus/pci/devices/0000:5b:00.0/driver)   # 预期: vfio-pci
basename $(readlink /sys/bus/pci/devices/0000:5b:00.1/driver)   # 预期: vfio-pci

# 检查 /dev/vfio 设备节点
ls /dev/vfio/ | grep -wE "121|122|166|167|184|185" 
# 预期: 这些 IOMMU 组号都应存在
```

### 4.2 绑定 G5-G8 的 GPU 到 nvidia 驱动

```bash
for bdf in 9a:00.0 9b:00.0 9e:00.0 9f:00.0 a0:00.0 a1:00.0 a4:00.0 a5:00.0 \
           a6:00.0 a7:00.0 aa:00.0 ab:00.0 ac:00.0 ad:00.0 b0:00.0 b1:00.0 \
           b8:00.0 b9:00.0 bc:00.0 bd:00.0 be:00.0 bf:00.0 c2:00.0 c3:00.0 \
           c4:00.0 c5:00.0 c8:00.0 c9:00.0 ca:00.0 cb:00.0 ce:00.0 cf:00.0; do
    full_bdf="0000:${bdf}"
    if [ -f "/sys/bus/pci/devices/${full_bdf}/driver/unbind" ]; then
        echo "${full_bdf}" > /sys/bus/pci/devices/${full_bdf}/driver/unbind
    fi
    echo "nvidia" > /sys/bus/pci/devices/${full_bdf}/driver_override
    echo "${full_bdf}" > /sys/bus/pci/drivers_probe
done

# 重新加载 nvidia 驱动（确保正确初始化）
modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia 2>/dev/null || true
sleep 2
modprobe nvidia nvidia_modeset nvidia_drm nvidia_uvm
sleep 5
```

**验证**:

```bash
nvidia-smi -L | wc -l   # 预期: 32
nvidia-smi -L | head -3  # 预期: 显示 RTX 4060 Laptop GPU
```

---

## 5. 部署 Kata VFIO 容器（3 组 × 8 GPU = 24 GPU）

### 5.1 部署 G1（IOMMU 组: 121 122 128 129 130 131 137 138）

> **重要**: 使用 `--entrypoint sleep` 让容器启动一个保活进程，等 VM 完全启动后再通过 `nerdctl exec` 启动 vLLM。
> 需要 `--net=host` 避免端口转发不可用的问题（Kata CNI 端口转发不可靠）。

```bash
nerdctl rm -f kata-vfio-group1 2>/dev/null || true

nerdctl run -d \
  --runtime io.containerd.kata.v2 \
  --net=host \
  --name kata-vfio-group1 \
  --device=/dev/vfio/121 --device=/dev/vfio/122 \
  --device=/dev/vfio/128 --device=/dev/vfio/129 \
  --device=/dev/vfio/130 --device=/dev/vfio/131 \
  --device=/dev/vfio/137 --device=/dev/vfio/138 \
  -m 32g \
  -v /models:/models \
  --env NVIDIA_VISIBLE_DEVICES=all \
  --entrypoint sleep \
  vllm/vllm-openai:v0.21.0-x86_64-cu129 \
  infinity
```

### 5.2 部署 G3（IOMMU 组: 166 167 173 174 175 176 182 183）

```bash
nerdctl rm -f kata-vfio-group3 2>/dev/null || true

nerdctl run -d \
  --runtime io.containerd.kata.v2 \
  --net=host \
  --name kata-vfio-group3 \
  --device=/dev/vfio/166 --device=/dev/vfio/167 \
  --device=/dev/vfio/173 --device=/dev/vfio/174 \
  --device=/dev/vfio/175 --device=/dev/vfio/176 \
  --device=/dev/vfio/182 --device=/dev/vfio/183 \
  -m 32g \
  -v /models:/models \
  --env NVIDIA_VISIBLE_DEVICES=all \
  --entrypoint sleep \
  vllm/vllm-openai:v0.21.0-x86_64-cu129 \
  infinity
```

### 5.3 部署 G4（IOMMU 组: 184 185 191 192 193 194 198 199）

```bash
nerdctl rm -f kata-vfio-group4 2>/dev/null || true

nerdctl run -d \
  --runtime io.containerd.kata.v2 \
  --net=host \
  --name kata-vfio-group4 \
  --device=/dev/vfio/184 --device=/dev/vfio/185 \
  --device=/dev/vfio/191 --device=/dev/vfio/192 \
  --device=/dev/vfio/193 --device=/dev/vfio/194 \
  --device=/dev/vfio/198 --device=/dev/vfio/199 \
  -m 32g \
  -v /models:/models \
  --env NVIDIA_VISIBLE_DEVICES=all \
  --entrypoint sleep \
  vllm/vllm-openai:v0.21.0-x86_64-cu129 \
  infinity
```

### 5.4 部署 G6（IOMMU 组: 44 45 51 52 53 54 58 59 — 替代 G2/G5）

```bash
nerdctl rm -f kata-vfio-group6 2>/dev/null || true

nerdctl run -d \
  --runtime io.containerd.kata.v2 \
  --net=host \
  --name kata-vfio-group6 \
  --device=/dev/vfio/44 --device=/dev/vfio/45 \
  --device=/dev/vfio/51 --device=/dev/vfio/52 \
  --device=/dev/vfio/53 --device=/dev/vfio/54 \
  --device=/dev/vfio/58 --device=/dev/vfio/59 \
  -m 32g \
  -v /models:/models \
  --env NVIDIA_VISIBLE_DEVICES=all \
  --entrypoint sleep \
  vllm/vllm-openai:v0.21.0-x86_64-cu129 \
  infinity
```

### 5.5 启动 vLLM 推理服务（TP=4, PP=2, float16, enforce_eager）

> **注意**: 必须等待容器变为 `Up` 状态后才能执行 `nerdctl exec` 启动 vLLM。
> 每个容器约需 60 秒启动。为避免 VM 间资源竞争，建议逐个启动 vLLM，每个间隔 30 秒。
> 
> 参数说明：
> - `TP=4, PP=2`: 8 GPU 拆成 2 个 pipeline stage，每 stage 4 GPU 做 TP。关键：PP=2 使模型权重跨 stage 分摊，降低每卡显存需求
> - `float16`: 比 auto（bfloat16）省显存
> - `enforce_eager`: 禁用 CUDA graph，节省显存
> - `max-model-len 2048`: 限制 KV cache 长度
> - `gpu-memory-utilization 0.90`: 8GB 卡留 10% 余量
> - `NCCL_P2P_LEVEL=SYS`: 确保 NCCL P2P 走 PCIe switch

```bash
MODEL="/models/Qwen3.6-35B-A3B-FP8"
VLLM_ARGS="--served-model-name Qwen3.6-35B-A3B-FP8 --tensor-parallel-size 4 --pipeline-parallel-size 2 --dtype float16 --max-model-len 2048 --gpu-memory-utilization 0.90 --enforce-eager --max-num-seqs 128"

# G1 (port 8006)
nerdctl exec kata-vfio-group1 bash -c "
  export NCCL_P2P_LEVEL=SYS
  nohup vllm serve ${MODEL} ${VLLM_ARGS} --port 8006 > /root/vllm.log 2>&1 &
  echo PID=\$!
"
sleep 30

# G3 (port 8008)
nerdctl exec kata-vfio-group3 bash -c "
  export NCCL_P2P_LEVEL=SYS
  nohup vllm serve ${MODEL} ${VLLM_ARGS} --port 8008 > /root/vllm.log 2>&1 &
  echo PID=\$!
"
sleep 30

# G4 (port 8009)
nerdctl exec kata-vfio-group4 bash -c "
  export NCCL_P2P_LEVEL=SYS
  nohup vllm serve ${MODEL} ${VLLM_ARGS} --port 8009 > /root/vllm.log 2>&1 &
  echo PID=\$!
"
sleep 30

# G6 (port 8010)
nerdctl exec kata-vfio-group6 bash -c "
  export NCCL_P2P_LEVEL=SYS
  nohup vllm serve ${MODEL} ${VLLM_ARGS} --port 8010 > /root/vllm.log 2>&1 &
  echo PID=\$!
"
```

> **注意**: 实际测试中 4 个 Kata VM 同时运行 vLLM 会导致 VM 间互相 kill（内存竞争）。建议从 2 组开始逐步增加，观察 /dev/shm 使用量。

### 5.6 验证 vLLM 服务就绪

每个容器模型加载约需 30-60 秒。加载期间 API Server 不绑定端口。

```bash
# 验证 GPU 可见
nerdctl exec kata-vfio-group1 nvidia-smi -L 2>/dev/null | wc -l   # 预期: 8

# 验证 vLLM 端口
for port in 8006 8008 8009 8010; do
    echo "Port ${port}: $(curl -m3 -s http://localhost:${port}/health)"
done
```

**预期结果**: 每个端口返回空（health check 返回 200 OK，body 为空是正常行为）。

```bash
# 推理测试
curl -s http://localhost:8006/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen3.6-35B-A3B-FP8","messages":[{"role":"user","content":"Hello"}],"max_tokens":20}'
```

---

## 6. 部署 Docker vLLM 推理实例（4 组 × 8 GPU = 32 GPU）

### 6.1 注意事项

> **nvidia-smi 驱动限制**: 宿主机 nvidia-smi 最多识别 32 块 GPU（所有 64 块都在 nvidia 驱动上，但 smi 只显示 32 块）。
> 如果需要启动 4 个 Docker 实例（每实例 8 GPU），需确认 nvidia-smi 确实能看到 32 块 GPU。
> 如果只能看到 8 块，说明 G7/G8 的 GPU 需要重新绑定到 nvidia 驱动。
> 
> 简化方案：使用 `NVIDIA_VISIBLE_DEVICES=all` 让 Docker 自动获取所有可见 GPU。

### 6.2 启动 4 个 Docker vLLM 实例

```bash
MODEL="/models/Qwen3.6-35B-A3B-FP8"
ALL_UUIDS=$(nvidia-smi --query-gpu=uuid --format=csv,noheader)
echo "Total GPUs visible: $(echo "$ALL_UUIDS" | wc -l)"

for idx in 1 2 3 4; do
    name="vllm-docker-${idx}"
    port=$(( 8011 + idx - 1 ))
    start=$(( (idx - 1) * 8 ))
    end=$(( start + 7 ))
    gpus=$(echo "$ALL_UUIDS" | sed -n "$((start+1)),$((end+1))p" | tr '\n' ',' | sed 's/,$//')
    
    echo "[${name}] port=${port}"
    docker rm -f "${name}" 2>/dev/null || true
    
    docker run -d --name "${name}" \
      --runtime nvidia \
      -e NVIDIA_VISIBLE_DEVICES="${gpus}" \
      -e NCCL_P2P_LEVEL=SYS \
      -p ${port}:8000 \
      -v ${MODEL}:${MODEL} \
      --entrypoint vllm \
      vllm/vllm-openai:v0.21.0-x86_64-cu129 \
      serve ${MODEL} \
        --served-model-name Qwen3.6-35B-A3B-FP8 \
        --tensor-parallel-size 4 \
        --pipeline-parallel-size 2 \
        --port 8000 \
        --dtype float16 \
        --max-model-len 2048 \
        --gpu-memory-utilization 0.90 \
        --enforce-eager \
        --max-num-seqs 128
    
    echo "  等待 90s..."
    sleep 90
done
```

### 6.3 验证 Docker 容器

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep vllm-docker
```

**预期结果**: 4 个容器均为 `Up` 状态。

### 6.4 验证 vLLM 服务就绪

```bash
for port in 8011 8012 8013 8014; do
    echo "Port ${port}:"
    curl -s http://localhost:${port}/v1/models | head -3 || echo "Not ready"
done
```

**预期结果**: 每个端口返回模型信息。

---

## 7. NCCL 测试

### 7.1 Kata 容器内 NCCL all-reduce

```bash
for name in kata-vfio-group1 kata-vfio-group3 kata-vfio-group4; do
    echo "=== $name ==="
    # 默认 P2P
    nerdctl exec $name bash -c \
      "cd /models/nccl-tests-2.18.3/build && timeout 120 ./all_reduce_perf -b 8M -e 256M -f 2 -g 8 -t 1 -n 20 -w 5" \
      2>&1 | tail -5 || true
    # NCCL_P2P_LEVEL=SYS
    nerdctl exec $name bash -c \
      "export NCCL_P2P_LEVEL=SYS && cd /models/nccl-tests-2.18.3/build && timeout 120 ./all_reduce_perf -b 8M -e 256M -f 2 -g 8 -t 1 -n 20 -w 5" \
      2>&1 | tail -5 || true
    echo
done
```

**预期结果**:
- 默认 P2P: ~2 GB/s（走 sysmem）
- NCCL_P2P_LEVEL=SYS: **~12.8 GB/s**

---

## 8. vLLM 推理测试

### 8.1 Kata 容器内启动 vLLM

```bash
for name in kata-vfio-group1 kata-vfio-group3 kata-vfio-group4; do
    echo "Starting vLLM in $name..."
    nerdctl exec -d $name bash -c '
        export NCCL_P2P_LEVEL=SYS
        pkill -9 -f "vllm serve" 2>/dev/null || true
        sleep 2
        nohup vllm serve /models/Qwen3.6-35B-A3B-FP8 \
            --served-model-name Qwen3.6-35B-A3B-FP8 \
            --tensor-parallel-size 4 \
            --pipeline-parallel-size 2 \
            --port 8000 \
            --dtype float16 \
            --max-model-len 2048 \
            --gpu-memory-utilization 0.90 \
            --enforce-eager \
            --max-num-seqs 128 \
            > /root/vllm.log 2>&1 &
    '
    sleep 30
done

# 等待 vLLM 就绪（约 5 分钟）
sleep 300
```

### 8.2 测试推理（Kata 端口 8006/8008/8009）

```bash
for port in 8006 8008 8009; do
    echo "=== Kata Port ${port} ==="
    curl -s http://localhost:${port}/v1/completions \
      -H "Content-Type: application/json" \
      -d '{"model":"Qwen3.6-35B-A3B-FP8","prompt":"Hello","max_tokens":50}' | head -3
    echo
done
```

### 8.3 测试推理（Docker 端口 8011/8012/8013/8014）

```bash
for port in 8011 8012 8013 8014; do
    echo "=== Docker Port ${port} ==="
    curl -s http://localhost:${port}/v1/chat/completions \
      -H "Content-Type: application/json" \
      -d '{"model":"Qwen3.6-35B-A3B-FP8","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}' | head -3
    echo
done
```

---

## 9. 全量服务端口映射

| 实例 | 类型 | 宿主机端口 | GPU 数 | 并行配置 |
|------|------|-----------|--------|---------|
| kata-vfio-group1 | Kata VFIO | 8006 | 8 | TP=4, PP=2 |
| kata-vfio-group3 | Kata VFIO | 8008 | 8 | TP=4, PP=2 |
| kata-vfio-group4 | Kata VFIO | 8009 | 8 | TP=4, PP=2 |
| kata-vfio-group6 | Kata VFIO | 8010 | 8 | TP=4, PP=2 |
| vllm-docker-1 | Docker | 8011 | 8 | TP=4, PP=2 |
| vllm-docker-2 | Docker | 8012 | 8 | TP=4, PP=2 |
| vllm-docker-3 | Docker | 8013 | 8 | TP=4, PP=2 |
| vllm-docker-4 | Docker | 8014 | 8 | TP=4, PP=2 |
| **合计** | — | — | **64** | — |

---

## 10. 停止与清理

### 10.1 停止 Kata 容器

```bash
for name in kata-vfio-group1 kata-vfio-group3 kata-vfio-group4 kata-vfio-group6; do
    nerdctl rm -f ${name} 2>/dev/null || true
done
```

### 10.2 停止 Docker 容器

```bash
for idx in 1 2 3 4; do
    docker rm -f vllm-docker-${idx} 2>/dev/null || true
done
```

### 10.3 恢复所有 GPU 到 nvidia 驱动

```bash
for bdf in 5b:00.0 5c:00.0 5f:00.0 60:00.0 61:00.0 62:00.0 65:00.0 66:00.0 \
           79:00.0 7a:00.0 7d:00.0 7e:00.0 7f:00.0 80:00.0 83:00.0 84:00.0 \
           85:00.0 86:00.0 89:00.0 8a:00.0 8b:00.0 8c:00.0 8f:00.0 90:00.0; do
    full_bdf="0000:${bdf}"
    echo "" > /sys/bus/pci/devices/${full_bdf}/driver_override
    echo "nvidia" > /sys/bus/pci/devices/${full_bdf}/driver_override
    if [ -f "/sys/bus/pci/devices/${full_bdf}/driver/unbind" ]; then
        echo "${full_bdf}" > /sys/bus/pci/devices/${full_bdf}/driver/unbind
    fi
    echo "${full_bdf}" > /sys/bus/pci/drivers_probe
    # audio
    audio_bdf="${full_bdf%.0}.1"
    if [ -d "/sys/bus/pci/devices/${audio_bdf}" ]; then
        echo "" > /sys/bus/pci/devices/${audio_bdf}/driver_override
        echo "${audio_bdf}" > /sys/bus/pci/drivers_probe 2>/dev/null || true
    fi
done

modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia 2>/dev/null || true
modprobe nvidia nvidia_modeset nvidia_drm nvidia_uvm
nvidia-smi -L | wc -l   # 预期: 64
```

---

## 11. 已知问题与排障

| 现象 | 原因 | 处理 |
|------|------|------|
| `group XXX is not viable` | IOMMU group 中有设备未绑定 vfio-pci（通常是 audio 设备 .1） | 同时绑定 function-0 和 function-1 到 vfio-pci |
| `CDI timeout of 100 seconds` | G2/G5 组特有的 CDI 注入超时问题 | 跳过 G2/G5，使用 G6 替代。需先解绑 G6 的 nvidia 再绑到 vfio-pci |
| `invalid reference format` | nerdctl 镜像名格式错误 | 使用 `vllm/vllm-openai:v0.21.0-x86_64-cu129`，显式指定 x86 平台和版号 |
| `No devices were found` (nvidia-smi) | nvidia 驱动未正确初始化 | 重新加载驱动：`modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia && modprobe nvidia nvidia_modeset nvidia_drm nvidia_uvm` |
| Docker GPU 显存不足 | `--runtime nvidia --gpus all` 导致所有 GPU 注入 | 使用 `--runtime nvidia -e NVIDIA_VISIBLE_DEVICES=UUID列表` 限制可见 GPU |
| `cannot set both Count and DeviceIDs` | `--runtime nvidia` 与 `--gpus device=N` 冲突 | 使用 `--runtime nvidia` + `NVIDIA_VISIBLE_DEVICES`，不使用 `--gpus` |
| Kata 容器 `Created` 不运行 | nvidia 驱动重载导致 QEMU 进程被杀 | 清理容器后重新 `nerdctl run` |
| 脚本中 `\` 转义问题 | SSH 远程执行 heredoc 脚本时 `\\` 被错误解释 | 直接在目标机上创建脚本文件，或使用单行命令 |
| `cold_plug_vfio = "no-port"` 未生效 | **Kata shim v2 读取 `/opt/kata/share/defaults/kata-containers/configuration-qemu.toml`，而不是 `/etc/kata-containers/configuration.toml`** | 必须同步 copy 配置到该路径 |
| VM 内存 64GB 导致多 VM 无法共存 | `default_memory = 32768` 时 VM 实际内存翻倍为 64GB | 设置 `default_memory = 16384`（VM 内存 = 32GB）+ `memory_slots = 2` |
| nerdctl 端口转发不可用 | Kata VM 的 CNI 端口转发不稳定，`nc` 显示端口关闭 | 使用 `--net=host` 直接暴露端口 |
| `Engine core initialization failed` | TP=8 时 MoE 模型中间层 64 不能被 FP8 block_k=128 整除 | 使用 **TP=4 + PP=2**（不要用 TP=8） |
| vLLM CUDA OOM (7.62 GiB) | RTX 4060 8GB 显存不足以用 TP=4 加载 35B 模型全体权重 | 使用 `--dtype float16 --enforce-eager --max-model-len 2048 --gpu-memory-utilization 0.90` |
| `POST /v1/completions HTTP/1.1 404 Not Found` | vLLM serve 缺少 `--served-model-name`，benchmark 中 `--model` 使用文件路径而非 served name | 启动 vLLM 时加 `--served-model-name <短名>`，benchmark 中 `--model` 和 `--served-model-name` 使用同一个短名 |
| Docker 容器 `--entrypoint vllm` 下 `sleep infinity` 被当成 model 参数 | vllm entrypoint 将 CMD 参数拼接为模型路径 | 使用 `--entrypoint sleep` 而不是 `--entrypoint /bin/bash` |
| `nerdctl exec` 启动 vLLM 后成为僵尸进程 | 前次 vLLM 进程未正确清理，共享内存泄漏 | **彻底重建容器**（`nerdctl rm -f`）而不是在旧容器内重启 vLLM |
| 多 VM 部署时旧 VM 在新 VM 创建过程中被杀 | 内存竞争（/dev/shm 不足或 overcommit） | 扩容 /dev/shm 到 300G，`default_memory=16384`，逐个部署间隔 30s |
| 4 个 Kata vLLM VM 无法同时运行 | 大规模 GPU VM 的内存/IOMMU 资源竞争 | 当前实测：4 个 Alpine VM 可共存；vLLM 模型加载期间建议 ≤2 组 |
| `--entrypoint vllm ... sleep infinity` 失败 | vllm entrypoint 把 `sleep infinity` 当成模型名 | 改为 `--entrypoint sleep`，之后用 `nerdctl exec` 启动 vLLM |
| `/dev/shm` 不足 | 4 个 Kata VM 每个 32GB 需要 128GB /dev/shm | `mount -o remount,size=200G /dev/shm` |

---

## 12. 实际部署结果

> **部署日期**: 2026-06-27  
> **部署脚本**: `docs/micro/scripts/deploy-kata-4groups.sh`  
> **部署时间**: ~20 分钟（含 4 组串行部署和 ACS 操作）

### 12.1 容器状态

```
kata-vfio-group8  Up  0.0.0.0:8017->8000/tcp  (G8: 8 GPUs, GPA=HPA ✅)
kata-vfio-group7  Up  0.0.0.0:8016->8000/tcp  (G7: 8 GPUs, GPA=HPA ✅)
kata-vfio-group6  Up  0.0.0.0:8015->8000/tcp  (G6: 8 GPUs, GPA=HPA ✅)
kata-vfio-group1  Up  0.0.0.0:8010->8000/tcp  (G1: 8 GPUs, GPA=HPA ✅, vLLM HEALTHY)
vllm-docker       Up  0.0.0.0:8000->8000/tcp   (Docker: 24 GPUs, nvidia driver)
```

### 12.2 Fixed-BAR GPA=HPA 验证

| 组 | Guest BAR1 | Host BAR1 | 一致 |
|----|------------|-----------|------|
| G1 | 0x9e000000 | 0x9e000000 | ✅ |
| G6 | 0xcd000000 | 0xcd000000 | ✅ |
| G7 | 0xc0000000 | 0xc0000000 | ✅ |
| G8 | 0xac000000 | 0xac000000 | ✅ |

### 12.3 vLLM 基准测试 (G1, 256/256/10)

| 指标 | 本次实测 | test64.md 参考 |
|------|---------|---------------|
| Output tok/s | **51.54** | 52.0 |
| Mean TTFT (ms) | 21252 | 12641 |
| Mean TPOT (ms) | 110.70 | 142.1 |

### 12.4 资源使用

| 指标 | 值 |
|------|-----|
| /dev/shm | 192 GB / 300 GB (64%) |
| 宿主机空闲内存 | ~110 GB |
| QEMU 进程 | 4 × ~48 GB RSS |
| Docker 容器 | 1 × 24 GPU |

---

## 13. 部署脚本参考

### 13.1 部署脚本 (`deploy-kata-4groups.sh`)

完整脚本保存在仓库根目录。核心逻辑：

```bash
declare -A IOMMU_MAP
IOMMU_MAP[1]="121 122 128 129 130 131 137 138"   # G1
IOMMU_MAP[6]="44 45 51 52 53 54 58 59"           # G6
IOMMU_MAP[7]="71 72 78 79 80 81 87 88"           # G7
IOMMU_MAP[8]="89 90 96 97 98 99 103 104"         # G8

for gid in 1 6 7 8; do
    IOMMU_GROUPS="${IOMMU_MAP[$gid]}"
    PORT=$((8010 + gid - 1))
    NAME="kata-vfio-group${gid}"
    
    # 构建 BDFS 和 --device 参数
    for grp in ${IOMMU_GROUPS}; do
        dev=$(ls /sys/kernel/iommu_groups/${grp}/devices/ | grep '\.0$' | head -1)
        DEVICE_ARGS="${DEVICE_ARGS} --device=/dev/vfio/${grp}"
    done
    
    # ACS shutdown → deploy → wait ready → verify GPA=HPA → re-ACS
    /root/acs_shutdown_vfio_group.sh ${BDFS}
    nerdctl run -d --runtime io.containerd.kata.v2 --name "${NAME}" \
        ${DEVICE_ARGS} -m 32g -p "${PORT}:8000" -v /models:/models \
        --env NVIDIA_VISIBLE_DEVICES=void \
        --env NVIDIA_DRIVER_CAPABILITIES=compute,utility \
        --entrypoint /bin/bash "${CONTAINER_IMAGE}" -c 'sleep infinity'
done
```

### 13.2 vLLM 启动脚本 (`start-vllm-in-kata.sh`)

```bash
nerdctl exec kata-vfio-group1 bash -c '
  export NCCL_P2P_LEVEL=SYS
  nohup vllm serve /models/Qwen3.6-35B-A3B-FP8 \
    --served-model-name Qwen3.6-35B-A3B-FP8 \
    --tensor-parallel-size 4 --pipeline-parallel-size 2 \
    --port 8000 --dtype float16 --max-model-len 2048 \
    --gpu-memory-utilization 0.90 --enforce-eager --max-num-seqs 128 \
    > /root/vllm.log 2>&1 &
'
sleep 180 && curl http://localhost:8010/health
```

### 13.3 Benchmark 脚本 (`/models/vllm_benchmark.sh`)

基于 `/home/rx/bingo/vllm_benchmark_concurrent.sh`，部署到共享卷 `/models/`：

```bash
input_lens=(256 512 1024)
output_lens=(256 512 1024)
num_prompts_list=(1 10 50 100)
# 36 cases: 3×3×4
for input_len ...; for output_len ...; for num_prompts ...
    vllm bench serve --port 8000 --ignore_eos \
        --random-input-len ${input_len} \
        --random-output-len ${output_len} \
        --num-prompts ${num_prompts}
```

### 13.4 并发 Benchmark 启动

```bash
# 4 组 Kata 并发
for gid in 1 6 7 8; do
  ssh root@172.18.5.133 \
    "nerdctl exec kata-vfio-group${gid} bash /models/vllm_benchmark.sh" &
done
wait

# Docker 对比
ssh root@172.18.5.133 'docker exec vllm-docker bash /models/vllm_benchmark.sh'
```

---

## 14. 脚本清单

| 脚本 | 位置 | 用途 |
|------|------|------|
| `deploy-kata-4groups.sh` | `docs/micro/scripts/` | 一键部署 4 组 Kata VFIO 容器 |
| `start-vllm-in-kata.sh` | `docs/micro/scripts/` | 在 Kata 容器中启动 vLLM |
| `deploy-multi-vfio-kata.sh` | `docs/micro/scripts/` | 旧版 8 组部署脚本 |
| `vfio_nvidia_bind.sh` | `docs/micro/scripts/` | VFIO/NVIDIA 批量绑定 |
| `vllm_benchmark.sh` | `docs/micro/scripts/` | vLLM bench serve (36 cases) |
| `deploy_all_groups.sh` | 目标机 `/home/rx/bingo/` | 全 8 组 VFIO 部署（含 GPU 分组映射） |
| `deploy_one_group.sh` | 目标机 `/home/rx/bingo/` | 单组 VFIO 部署 |
| `vfio_nvidia_bind.sh` | 目标机 `/home/rx/bingo/` | GPU 驱动批量绑定 |
| `vllm_benchmark_concurrent.sh` | 目标机 `/home/rx/bingo/` | benchmark 模板 |

---

## 16. nginx 负载均衡 4 组 Kata VFIO 并发推理测试

> **测试日期**: 2026-06-28  
> **模型**: Qwen3-14B (BF16, TP=4, PP=2)  
> **状态**: ✅ 4 组全部通过，benchmark 完成  

### 16.1 测试目标

验证通过宿主机 nginx 反向代理 round-robin 负载均衡，将推理请求分发到 4 个 Kata VFIO 容器（G1/G6/G7/G8），测试聚合吞吐与延迟表现。

### 16.2 测试架构

```
                     localhost:8080 (nginx)
                            │
           ┌────────────────┼────────────────┐
           │                │                │
    ┌──────┴──────┐  ┌──────┴──────┐  ┌──────┴──────┐
    │ kata-g1     │  │ kata-g6     │  │ kata-g7     │  │ kata-g8     │
    │ 10.4.0.3:8000│ │ 10.4.0.4:8000│ │ 10.4.0.5:8000│ │ 10.4.0.6:8000│
    │ 8× RTX 4060 │  │ 8× RTX 4060 │  │ 8× RTX 4060 │  │ 8× RTX 4060 │
    │ TP=4 PP=2  │  │ TP=4 PP=2  │  │ TP=4 PP=2  │  │ TP=4 PP=2  │
    └────────────┘  └────────────┘  └────────────┘  └────────────┘
```

### 16.3 前置条件

- [x] 4 组 Kata VFIO 容器已部署（kata-g1/g6/g7/g8），每容器 8 GPU + 16 vCPU 可用
- [x] Qwen3-14B 模型已就绪：`/models/Qwen3-14B`
- [x] nginx 已安装并配置 upstream 指向 4 个容器 IP
- [x] 宿主机 Docker 容器 `gpu-docker` 可用（`--net=host`，用于执行 benchmark）
- [x] NCCL P2P 已验证：4 组全部 ~12.86 GB/s
- [x] GPA=HPA 已验证：4 组全部匹配
- [x] 配置：`default_vcpus=16`, `default_memory=16384`, `memory_slots=1`, `-m 36g`

### 16.4 测试步骤

#### Step 1: 清理并启动 vLLM（顺序启动）

```bash
# 清理旧进程
for name in kata-g1 kata-g6 kata-g7 kata-g8; do
    nerdctl exec "${name}" bash -c "pkill -9 -f 'vllm serve' 2>/dev/null; true"
done

# 顺序启动（每组合格后才启动下一组）
VLLM_ARGS="--served-model-name Qwen3-14B --tensor-parallel-size 4 --pipeline-parallel-size 2 \
           --port 8000 --dtype float16 --max-model-len 2048 --gpu-memory-utilization 0.90 \
           --enforce-eager --max-num-seqs 128"

for gid in 1 6 7 8; do
    NAME="kata-g${gid}"
    nerdctl exec "${NAME}" bash -c "
        export NCCL_P2P_LEVEL=SYS
        nohup vllm serve /models/Qwen3-14B ${VLLM_ARGS} > /root/vllm-qwen14b.log 2>&1 &
    "
    # 等 /health 200
    for i in $(seq 1 60); do
        if nerdctl exec "${NAME}" curl -sf http://localhost:8000/health 2>/dev/null; then
            echo "[${NAME}] ready ($((i*5))s)"
            break
        fi
        sleep 5
    done
done
```

#### Step 2: 配置 nginx

```bash
apt-get install -y nginx

cat > /etc/nginx/sites-available/vllm-lb <<'NGINX'
upstream vllm_backend {
    server 10.4.0.3:8000 max_fails=2 fail_timeout=30s;
    server 10.4.0.4:8000 max_fails=2 fail_timeout=30s;
    server 10.4.0.5:8000 max_fails=2 fail_timeout=30s;
    server 10.4.0.6:8000 max_fails=2 fail_timeout=30s;
    keepalive 64;
}
server {
    listen 8080;
    proxy_read_timeout 300s;
    proxy_connect_timeout 30s;
    proxy_send_timeout 300s;
    location / {
        proxy_pass http://vllm_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/vllm-lb /etc/nginx/sites-enabled/vllm-lb
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx
```

#### Step 3: 验证后端健康

```bash
# 各 backend 独立检查
for ip in 10.4.0.3 10.4.0.4 10.4.0.5 10.4.0.6; do
    curl -s -o /dev/null -w "${ip}: %{http_code}\n" http://${ip}:8000/health
done
# 预期: 全部 200

# nginx 负载均衡验证
for i in $(seq 1 8); do
    curl -s -o /dev/null -w "req ${i}: %{http_code}\n" http://localhost:8080/health
done
# 预期: 全部 200
```

#### Step 4: 运行 Benchmark（36 cases）

```bash
# 从 gpu-docker 执行（有 CUDA + --net=host）
docker exec gpu-docker bash -c "
for il in 256 512 1024; do
  for ol in 256 512 1024; do
    for np in 1 10 50 100; do
      echo \"--- Case: input=\${il} output=\${ol} n=\${np} ---\"
      vllm bench serve --port 8080 --model Qwen3-14B \
        --served-model-name Qwen3-14B --tokenizer /models/Qwen3-14B \
        --ignore-eos --random-input-len \${il} --random-output-len \${ol} \
        --num-prompts \${np}
    done
  done
done" | tee /root/bench-nginx-qwen14b.log
```

### 16.5 预期结果

| 指标 | 预期范围 |
|------|---------|
| 低并发 (n≤10) 平均吞吐 | 250-600 tok/s |
| 高并发 (n≥50) 平均吞吐 | 400-900 tok/s |
| 峰值吞吐 | 1000-1500 tok/s |
| TTFT (n=1) | 50-2200 ms（首次推理有 JIT 编译开销） |
| TPOT | 30-60 ms |

### 16.6 实际结果

见 `test64.md §21`。

### 16.7 已知问题

| 现象 | 原因 | 处理 |
|------|------|------|
| Qwen3.5-27B OOM | 8GB 卡无法容纳 27B BF16 权重 (7.18 GiB + 引擎初始化内存) | 使用 Qwen3-14B 或 Qwen3.6-35B-A3B-FP8 |
| nginx 聚合吞吐低于线性扩展 | round-robin 串行化，请求只到达单个 backend | 无状态分发场景可用；追求吞吐应直接压测每个 backend |
| `vllm bench serve` 在 Docker run --rm 时报 `No CUDA runtime` | 临时容器无 GPU | 从已有 GPU 容器（gpu-docker）执行 benchmark |

---

## 15. 关键注意事项

1. **绑定顺序**: 必须先停止所有 Kata 容器，再绑定/解绑 GPU 驱动，否则 QEMU 持有 VFIO 设备会导致 D 状态死锁。
2. **Audio 设备**: 每张 GPU f0/f1 在同一 IOMMU group，**必须同时绑定到 vfio-pci**。
3. **NVIDIA_VISIBLE_DEVICES=void**: 禁止 nvidia container toolkit CDI 注入，避免 CDI timeout。
4. **DERIVER_CAPABILITIES**: 必须保留 `compute,utility`，否则容器内缺 NVIDIA 驱动库。
5. **配置同步**: Kata shim v2 读 `/opt/kata/share/defaults/.../configuration-qemu.toml`，须与 `/etc/kata-containers/` 同步。
6. **共享卷传脚本**: `nerdctl exec -i` 管道在 Kata 中不可靠，用 `/models` 共享卷。
7. **容器 entrypoint**: 用 `/bin/bash -c 'sleep infinity'`（非 `--entrypoint sleep`，vllm 镜像中 sleep 可能是 alias）。
8. **G5 不可用**: CDI timeout (Kata) + RmInitAdapter failed (nvidia)。**2026-06-29 更新**：服务器冷重启后 G5 恢复可用，IOMMU groups 正确值为 26 27 33 34 35 36 42 43（非原文档中的含 37 版本）。
9. **NVIDIA 32 GPU 限制**: 消费级驱动仅支持 ~32 GPU，Docker 可用 GPU 数取决于哪些组在 nvidia 上。

---

## 16. QEMU BAR 冲突修复（2026-06-29 验证通过）

### 16.1 问题

宿主机 GPU BAR0（32-bit）与 guest 中空 pcie-root-port bridge 窗口在 QEMU 固定 BAR 映射（`x-fixed-bars=on`）下发生冲突，导致 NVIDIA 驱动 probe 失败。

### 16.2 修复

修改 QEMU `hw/vfio/pci.c`，将 `x-fixed-bars-allow-32bit-fallback` 的触发条件从"仅 RAM 重叠"扩展到"所有 32-bit BAR"。提交 `fe45aa3`，本地路径 `/home/bingo/10.2.1/qemu`。

```diff
- if (overlaps_ram) {
-     if (nr != PCI_ROM_SLOT && !bar->ioport && !bar->mem64 &&
-         vdev->fixed_bars_allow_32bit_fallback) {
-         vdev->fixed_bar_fallback[nr] = true;
-         return true;
-     }
+ if (nr != PCI_ROM_SLOT && !bar->ioport && !bar->mem64 &&
+     vdev->fixed_bars_allow_32bit_fallback) {
+     vdev->fixed_bar_fallback[nr] = true;
+     return true;
+ }
```

### 16.3 效果

- 32-bit BAR0：guest 内核可重新分配，解决 bridge 窗口冲突
- 64-bit BAR1：保持 GPA=HPA，NCCL P2P 不受影响
- Kata 无需修改代码

### 16.4 部署

```bash
# 编译
cd /home/bingo/10.2.1/qemu/build && make -j$(nproc)
# 部署
scp qemu-system-x86_64 root@172.18.5.133:/opt/kata/bin/
```

### 16.5 验证结果（2026-06-29）

4 组 Kata VFIO（G5/G6/G7/G8）同时部署，全部 0 BAR 冲突，GPU 正常检测。

**G5-G8 IOMMU 组（服务器重启后实际值）**：

| 组 | IOMMU 组 | BDF | Port |
|----|---------|-----|------|
| G5 | 26 27 33 34 35 36 42 43 | 9a-9b 9e-9f a0-a1 a4-a5 | 8014 |
| G6 | 44 45 51 52 53 54 58 59 | a6-a7 aa-ab ac-ad b0-b1 | 8015 |
| G7 | 71 72 78 79 80 81 87 88 | b8-b9 bc-bd be-bf c2-c3 | 8016 |
| G8 | 89 90 96 97 98 99 103 104 | c4-c5 c8-c9 ca-cb ce-cf | 8017 |
