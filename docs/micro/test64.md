# Kata VFIO fixed-BAR GPU 多实例部署文档（3 组 × 8 GPU）

> 目标服务器：`172.18.5.133`（root / Admin@9000）  
> 本地源码目录：`/home/bingo/kata-containers`  
> 每组 8 张 GPU，共 3 组；同一组 GPU 挂在同一 root port 级联的二级 PCIe Switch 下。  
> 单容器内存：32 GB（8 张 RTX 4060 固定 BAR 映射需要足够 guest RAM）。

---

## 1. 前置条件

- 本地已编译好带 `x-fixed-bars` 支持的 QEMU 与 Kata runtime 二进制。
- 目标机已安装 containerd/nerdctl，且 `/opt/kata` 路径可用。
- 目标机 `/dev/shm` 已扩容至 300 GB（不使用 hugepages）。
- 目标机 `/models/nccl-tests-2.18.3/build/all_reduce_perf` 已存在。
- 目标机所有 NVIDIA GPU 已绑定到 `vfio-pci`。
- 目标机已关闭相关 PCIe 桥的 ACS（见第 7 步脚本）。

---

## 2. 本地二进制文件

```text
/home/bingo/kata-containers/src/runtime/kata-runtime
/home/bingo/kata-containers/src/runtime/containerd-shim-kata-v2
/home/bingo/kata-containers/tools/packaging/static-build/qemu/kata-static-qemu.tar.gz
/home/bingo/kata-containers/tools/packaging/kata-deploy/local-build/build/ovmf/destdir/opt/kata/share/ovmf/OVMF.fd
```

---

## 3. GPU 拓扑与分组

目标机共有 4 个 root port domain，每个 domain 下理论上 16 张 GPU（8 个 function-0 + 8 个 function-1 音频设备）。

实际可成功部署的 domain 与分组如下：

- Domain 1 — root port `03:01.0`（可用）
- Domain 2 — root port `26:00.0`（可用，Group 2）
- Domain 3 — root port `a5:00.0`（可用）
- Domain 4 — root port `82:01.0`（可用，Group 4）

Domain 2 不再同时承载 Group 2 和 Group 4；Group 4 已迁移到独立的 Domain 4。

### Domain 1 — root port `03:01.0`（可用）

| 组 | VFIO groups | 宿主机 function-0 BDF |
|---:|---|---|
| 1 | 27 28 34 35 36 37 43 44 | 0c:00.0 0d:00.0 10:00.0 11:00.0 12:00.0 13:00.0 16:00.0 17:00.0 |

对应二级 PCIe Switch：`0a:00.0` / `0e:00.0` / `14:00.0` 级联。

### Domain 2 — root port `26:00.0`（可用，已拆分为 Group 2 和 Group 4）

| 组 | VFIO groups | 宿主机 function-0 BDF |
|---:|---|---|
| 2 | 72 73 79 80 81 82 88 89 | 2a:00.0 2b:00.0 2e:00.0 2f:00.0 30:00.0 31:00.0 34:00.0 35:00.0 |

对应二级 PCIe Switch：`28:00.0` / `2c:00.0` / `32:00.0` 级联。

### Domain 4 — root port `82:01.0`（可用）

| 组 | VFIO groups | 宿主机 function-0 BDF |
|---:|---|---|
| 4 | 148 149 155 156 157 158 162 163 | 9a:00.0 9b:00.0 9e:00.0 9f:00.0 a0:00.0 a1:00.0 a4:00.0 a5:00.0 |

对应二级 PCIe Switch：`84:04.0` / `8b:04.0` / `8b:08.0` / `8b:0c.0` / `8b:10.0` 级联（Broadcom PEX890xx）。

### Domain 3 — root port `a5:00.0`（可用）

| 组 | VFIO groups | 宿主机 function-0 BDF |
|---:|---|---|
| 3 | 173 174 180 181 182 183 189 190 | a9:00.0 aa:00.0 ad:00.0 ae:00.0 af:00.0 b0:00.0 b3:00.0 b4:00.0 |

对应二级 PCIe Switch：`a7:00.0` / `ab:00.0` / `b1:00.0` 级联。

### Domain 4 — root port `87:00.0`（不可用）

当前系统仅识别到 3 张 GPU，且单卡也无法启动 Kata 容器，判断为硬件/BIOS 层面的问题：

| BDF | VFIO group |
|---|---|
| 8b:00.0 / 8b:00.1 | 128 |
| 8c:00.0 / 8c:00.1 | 129 |
| 8f:00.0 / 8f:00.1 | 135 |

> 注意：原始文档中的 8 组方案基于错误的拓扑划分（把同一二级 switch 下的 GPU 拆到了不同组），实际必须保证 8 张 GPU 在同一 root port 级联下。

---

## 4. 环境变量

在目标机 root 会话里统一设置：

```bash
export TARGET_HOST=172.18.5.133
export TARGET_USER=root
export TARGET_PASS=Admin@9000
export KATA_SRC=/home/bingo/kata-containers
export NCCL_MODELS_DIR=/models/nccl-tests-2.18.3
export VLLM_MODEL_DIR=/models/Qwen3.6-35B-A3B-FP8
export CONTAINER_IMAGE=docker.io/vllm/vllm-openai:latest
export GUEST_RAM_GB=32
export GUEST_VCPUS=16
export BASE_PORT=8006
```

---

## 5. 复制本地补丁二进制到目标机

**注意**：如果已有 Kata 容器在运行，`containerd-shim-kata-v2` 会被占用导致 `scp` 失败。这种情况下先停止所有 Kata 容器，或者跳过二进制复制。

```bash
# 在本地执行
BACKUP_DIR="/root/kata-backup-$(date +%Y%m%d-%H%M%S)"

sshpass -p "${TARGET_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${TARGET_USER}@${TARGET_HOST}" "mkdir -p ${BACKUP_DIR}/{bin,share/ovmf}"

# 备份旧二进制
sshpass -p "${TARGET_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${TARGET_USER}@${TARGET_HOST}" "
    cp /opt/kata/bin/qemu-system-x86_64 ${BACKUP_DIR}/bin/ 2>/dev/null || true
    cp /opt/kata/share/ovmf/OVMF.fd ${BACKUP_DIR}/share/ovmf/ 2>/dev/null || true
    cp /opt/kata/bin/kata-runtime ${BACKUP_DIR}/bin/ 2>/dev/null || true
    cp /opt/kata/bin/containerd-shim-kata-v2 ${BACKUP_DIR}/bin/ 2>/dev/null || true
"

# 复制并解压 QEMU
sshpass -p "${TARGET_PASS}" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "${KATA_SRC}/tools/packaging/static-build/qemu/kata-static-qemu.tar.gz" \
    "${TARGET_USER}@${TARGET_HOST}:/tmp/kata-static-qemu.tar.gz"

sshpass -p "${TARGET_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${TARGET_USER}@${TARGET_HOST}" "cd / && tar -xzf /tmp/kata-static-qemu.tar.gz"

# 复制 runtime 二进制
sshpass -p "${TARGET_PASS}" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "${KATA_SRC}/src/runtime/kata-runtime" \
    "${TARGET_USER}@${TARGET_HOST}:/opt/kata/bin/kata-runtime"

sshpass -p "${TARGET_PASS}" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "${KATA_SRC}/src/runtime/containerd-shim-kata-v2" \
    "${TARGET_USER}@${TARGET_HOST}:/opt/kata/bin/containerd-shim-kata-v2"

sshpass -p "${TARGET_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${TARGET_USER}@${TARGET_HOST}" \
    "chmod +x /opt/kata/bin/kata-runtime /opt/kata/bin/containerd-shim-kata-v2"

# 复制 OVMF
sshpass -p "${TARGET_PASS}" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "${KATA_SRC}/tools/packaging/kata-deploy/local-build/build/ovmf/destdir/opt/kata/share/ovmf/OVMF.fd" \
    "${TARGET_USER}@${TARGET_HOST}:/opt/kata/share/ovmf/OVMF.fd"

sshpass -p "${TARGET_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${TARGET_USER}@${TARGET_HOST}" \
    "chmod 644 /opt/kata/share/ovmf/OVMF.fd"

# 校验
sshpass -p "${TARGET_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${TARGET_USER}@${TARGET_HOST}" \
    "md5sum /opt/kata/bin/qemu-system-x86_64 /opt/kata/share/ovmf/OVMF.fd /opt/kata/bin/kata-runtime /opt/kata/bin/containerd-shim-kata-v2"
```

---

## 6. 配置 Kata

```bash
sshpass -p "${TARGET_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${TARGET_USER}@${TARGET_HOST}" "
    cp /opt/kata/share/defaults/kata-containers/configuration-qemu-nvidia-gpu.toml /etc/kata-containers/configuration.toml
    sed -i 's|^pod_resource_api_sock = .*|pod_resource_api_sock = \"\"|' /etc/kata-containers/configuration.toml
    sed -i 's|^default_vcpus = .*|default_vcpus = ${GUEST_VCPUS}|' /etc/kata-containers/configuration.toml
    sed -i 's|^default_memory = .*|default_memory = 16384|' /etc/kata-containers/configuration.toml
    sed -i 's|^memory_slots = .*|memory_slots = 2|' /etc/kata-containers/configuration.toml
    sed -i 's|^pcie_root_port = .*|pcie_root_port = 8|' /etc/kata-containers/configuration.toml
    sed -i 's|^cold_plug_vfio = .*|cold_plug_vfio = \"root-port\"|' /etc/kata-containers/configuration.toml
    sed -i 's|^disable_selinux = .*|disable_selinux = true|' /etc/kata-containers/configuration.toml
    sed -i 's|^kernel_params = .*|kernel_params = \"cgroup_no_v1=all pci=realloc pci=nocrs pci=assign-busses\"|' /etc/kata-containers/configuration.toml
    sed -i 's|^enable_hugepages = .*|enable_hugepages = false|' /etc/kata-containers/configuration.toml
    # ★ 关键：同步配置到 Kata shim v2 默认路径（否则 cold_plug_vfio 不会生效）
    mkdir -p /opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu
    cp /etc/kata-containers/configuration.toml /opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu/configuration-qemu-nvidia-gpu.toml
    cp /etc/kata-containers/configuration.toml /opt/kata/share/defaults/kata-containers/configuration-qemu.toml
    # 确保 shim 在 PATH
    ln -sf /opt/kata/bin/containerd-shim-kata-v2 /usr/local/bin/containerd-shim-kata-v2
"

sshpass -p "${TARGET_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${TARGET_USER}@${TARGET_HOST}" \
    "systemctl restart containerd"
```

---

## 7. 绑定所有 NVIDIA GPU 到 vfio-pci

**警告**：如果已有 Kata 容器在运行，其 QEMU 会持有 `/dev/vfio/N`，此时运行下面脚本会在 `vfio_unregister_group_dev` 处进入不可中断睡眠（D 状态）。**务必先停止所有 Kata 容器，或确认所有 GPU 已绑定后再跳过此步。**

```bash
# 复制脚本到目标机
sshpass -p "${TARGET_PASS}" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "${KATA_SRC}/docs/micro/scripts/vfio_nvidia_bind.sh" \
    "${TARGET_USER}@${TARGET_HOST}:/root/vfio_nvidia_bind.sh"

sshpass -p "${TARGET_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${TARGET_USER}@${TARGET_HOST}" \
    "chmod +x /root/vfio_nvidia_bind.sh && /root/vfio_nvidia_bind.sh bind"
```

---

## 8. 安装 ACS 关闭脚本

```bash
cat > /tmp/acs_shutdown_vfio_group.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

declare -A SEC SUB
declare -a BRIDGES=()
for d in /sys/bus/pci/devices/0000:*; do
    bdf=$(basename "${d}")
    if [[ -f "${d}/secondary_bus_number" ]]; then
        SEC["${bdf}"]=$(cat "${d}/secondary_bus_number" | tr -d ' ')
        SUB["${bdf}"]=$(cat "${d}/subordinate_bus_number" | tr -d ' ')
        BRIDGES+=("${bdf}")
    fi
done

bus_of() {
    printf '%d' "0x$(echo "$1" | cut -d: -f2)"
}

upstream_bridge() {
    local bdf="$1"
    local bus=$(bus_of "${bdf}")
    local best=""
    local best_range=999999
    for b in "${BRIDGES[@]}"; do
        [[ "$b" == "${bdf}" ]] && continue
        if [[ ${SEC[$b]} -le ${bus} && ${bus} -le ${SUB[$b]} ]]; then
            local range=$(( ${SUB[$b]} - ${SEC[$b]} ))
            if [[ ${range} -lt ${best_range} ]]; then
                best_range=${range}
                best=${b}
            fi
        fi
    done
    echo "${best}"
}

declare -A SEEN
ancestor_bridges=()
for gpu in "$@"; do
    cur="${gpu}"
    while true; do
        up=$(upstream_bridge "${cur}")
        [[ -z "${up}" ]] && break
        if [[ -z "${SEEN[${up}]+x}" ]]; then
            SEEN[${up}]=1
            ancestor_bridges+=("${up}")
        fi
        [[ "${up}" == "${cur}" ]] && break
        cur="${up}"
    done
done

for bdf in "${ancestor_bridges[@]}"; do
    acs_val=$(setpci -s "${bdf}" ECAP_ACS+0x6.w 2>/dev/null || true)
    [[ -z "${acs_val}" ]] && continue
    printf 'Disabling ACS on %s was %s\n' "${bdf}" "${acs_val}"
    setpci -s "${bdf}" ECAP_ACS+0x6.w=0x0000
    new_val=$(setpci -s "${bdf}" ECAP_ACS+0x6.w 2>/dev/null || true)
    printf '  -> now %s\n' "${new_val}"
done

echo "ACS shutdown complete."
EOF

sshpass -p "${TARGET_PASS}" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    /tmp/acs_shutdown_vfio_group.sh \
    "${TARGET_USER}@${TARGET_HOST}:/root/acs_shutdown_vfio_group.sh"

sshpass -p "${TARGET_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${TARGET_USER}@${TARGET_HOST}" \
    "chmod +x /root/acs_shutdown_vfio_group.sh && bash -n /root/acs_shutdown_vfio_group.sh"
```

---

## 9. 逐组部署

### 9.1 部署脚本

把以下内容保存到 `/home/rx/bingo/deploy_one_group.sh`（目标机路径）：

```bash
#!/usr/bin/env bash
set -euo pipefail

GROUP="$1"
shift
VFIO_GROUPS=("$@")
PORT=$(( 8006 + GROUP - 1 ))
NAME="kata-vfio-group${GROUP}"
MEM="${GUEST_RAM_GB:-32}g"
NCCL_MODELS_DIR="${NCCL_MODELS_DIR:-/models/nccl-tests-2.18.3}"
VLLM_MODEL_DIR="${VLLM_MODEL_DIR:-/models/Qwen3.6-35B-A3B-FP8}"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-docker.io/vllm/vllm-openai:latest}"

# 解析 function-0 BDF
BDFS=()
DEVICE_ARGS=()
for g in "${VFIO_GROUPS[@]}"; do
    dev=$(ls /sys/kernel/iommu_groups/${g}/devices/ 2>/dev/null | grep '\.0$' | head -1)
    if [[ -z "${dev}" ]]; then
        echo "ERROR: no function-0 device in IOMMU group ${g}" >&2
        exit 1
    fi
    BDFS+=("${dev}")
    DEVICE_ARGS+=("--device=/dev/vfio/${g}")
done

echo "[group${GROUP}] BDFs: ${BDFS[*]}"

# 关闭 ACS
/root/acs_shutdown_vfio_group.sh "${BDFS[@]}"

# 清理旧容器
nerdctl rm -f "${NAME}" 2>/dev/null || true
ctr -n default tasks delete "${NAME}" 2>/dev/null || true
ctr -n default containers delete "${NAME}" 2>/dev/null || true

# 启动容器
nerdctl run -d \
    --runtime io.containerd.kata.v2 \
    --name "${NAME}" \
    "${DEVICE_ARGS[@]}" \
    -m "${MEM}" \
    -p "${PORT}:8000" \
    -v "${NCCL_MODELS_DIR}:${NCCL_MODELS_DIR}" \
    -v "${VLLM_MODEL_DIR}:${VLLM_MODEL_DIR}" \
    --env NVIDIA_VISIBLE_DEVICES=void \
    --env NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    --entrypoint /bin/bash \
    "${CONTAINER_IMAGE}" \
    -c 'sleep infinity'

# 等待就绪
for i in $(seq 1 60); do
    if nerdctl exec "${NAME}" bash -c 'dx-smi -L >/dev/null 2>&1' 2>/dev/null; then
        echo "[group${GROUP}] container ready"
        break
    fi
    sleep 5
done

# 显示 GPU
nerdctl exec "${NAME}" dx-smi -L

# 验证 fixed-BAR GPA=HPA（第一块 GPU）
echo "[group${GROUP}] Guest BAR1:"
nerdctl exec "${NAME}" bash -c 'cat /sys/bus/pci/devices/0000:00:10.0/resource | head -1'
echo "[group${GROUP}] Host BAR1 (${BDFS[0]}):"
cat /sys/bus/pci/devices/${BDFS[0]}/resource | head -1

# NCCL all-reduce 默认
echo "[group${GROUP}] NCCL all-reduce (default P2P level)"
nerdctl exec "${NAME}" bash -c "cd ${NCCL_MODELS_DIR}/build && timeout 120 ./all_reduce_perf -b 8M -e 256M -f 2 -g 8 -t 1 -n 20 -w 5" 2>&1 | tail -30 || true

# 再次关闭 ACS（容器启动后部分桥可能恢复）
/root/acs_shutdown_vfio_group.sh "${BDFS[@]}"

# NCCL all-reduce SYS
echo "[group${GROUP}] NCCL all-reduce (NCCL_P2P_LEVEL=SYS)"
nerdctl exec "${NAME}" bash -c "cd ${NCCL_MODELS_DIR}/build && export NCCL_P2P_LEVEL=SYS && timeout 120 ./all_reduce_perf -b 8M -e 256M -f 2 -g 8 -t 1 -n 20 -w 5" 2>&1 | tail -30 || true

echo "[group${GROUP}] ${NAME} running on host port ${PORT}"
```

关键修复点：

1. `DEVICE_ARGS+=("--device=/dev/vfio/${g}")` 必须用 `=` 连接，nerdctl 不接受 `--device /dev/vfio/N`。
2. 添加 `--env NVIDIA_VISIBLE_DEVICES=void` 禁止宿主机 nvidia container toolkit 把 host GPU 作为 CDI device 注入，否则 8 GPU 同时部署会出现 `failed to inject devices after CDI timeout of 100 seconds`。
3. **必须保留** `--env NVIDIA_DRIVER_CAPABILITIES=compute,utility`，让 toolkit 继续把宿主机的 NVIDIA 驱动库注入到 guest 容器里。如果设为空字符串，容器内会缺失 NVIDIA 驱动，NCCL 会报 `CUDA driver version is insufficient for CUDA runtime version`。
4. `GUEST_RAM_GB` 默认 32 GB；16 GB 在 8 GPU fixed-BAR 场景下会触发 `create container timeout`。

### 9.2 依次部署 3 组

```bash
sshpass -p "${TARGET_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${TARGET_USER}@${TARGET_HOST}" \
    "export NCCL_MODELS_DIR=${NCCL_MODELS_DIR}; export VLLM_MODEL_DIR=${VLLM_MODEL_DIR}; export CONTAINER_IMAGE=${CONTAINER_IMAGE}; export GUEST_RAM_GB=${GUEST_RAM_GB}; /home/rx/bingo/deploy_one_group.sh 1 27 28 34 35 36 37 43 44"

sshpass -p "${TARGET_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${TARGET_USER}@${TARGET_HOST}" \
    "export NCCL_MODELS_DIR=${NCCL_MODELS_DIR}; export VLLM_MODEL_DIR=${VLLM_MODEL_DIR}; export CONTAINER_IMAGE=${CONTAINER_IMAGE}; export GUEST_RAM_GB=${GUEST_RAM_GB}; /home/rx/bingo/deploy_one_group.sh 2 72 73 79 80 81 82 88 89"

sshpass -p "${TARGET_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${TARGET_USER}@${TARGET_HOST}" \
    "export NCCL_MODELS_DIR=${NCCL_MODELS_DIR}; export VLLM_MODEL_DIR=${VLLM_MODEL_DIR}; export CONTAINER_IMAGE=${CONTAINER_IMAGE}; export GUEST_RAM_GB=${GUEST_RAM_GB}; /home/rx/bingo/deploy_one_group.sh 3 173 174 180 181 182 183 189 190"
```

---

## 10. 部署后验证

```bash
sshpass -p "${TARGET_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${TARGET_USER}@${TARGET_HOST}" "
    echo '=== containers ==='
    nerdctl ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep kata-vfio-group || true
    echo
    echo '=== hugepages ==='
    grep Huge /proc/meminfo
    echo
    echo '=== QEMU processes ==='
    ps aux | grep qemu-system-x86_64 | grep -v grep | wc -l
    echo
    echo '=== dx-smi in each container ==='
    for i in 1 2 3; do
        echo '--- kata-vfio-group'\${i}
        nerdctl exec kata-vfio-group\${i} dx-smi -L || true
    done
"
```

---

## 11. NCCL 测试结果

使用 `all_reduce_perf -b 8M -e 256M -f 2 -g 8 -t 1 -n 20 -w 5` 测试。

### Group 1（VFIO groups: 27 28 34 35 36 37 43 44）

- 默认 P2P 级别：**~2.07 GB/s**（走 sysmem）
- 设置 `NCCL_P2P_LEVEL=SYS` 后：**~12.86 GB/s**

Group 1 的 8 张 GPU 在同一 root port `03:01.0` 级联下，关闭 ACS 后 P2P 可正常工作。

### Group 2（VFIO groups: 72 73 79 80 81 82 88 89）

- 默认 P2P 级别：**~2.05 GB/s**（走 sysmem）
- 设置 `NCCL_P2P_LEVEL=SYS` 后：**~12.86 GB/s**

Group 2 的 8 张 GPU 在同一 root port `26:00.0` 级联下。

> 注意：Group 2 的第一块 GPU BAR1 在 guest 内为 `0x87000000`，宿主机为 `0x7d000000`，两者不一致；但 NCCL P2P 测试仍然正常。

### Group 3（VFIO groups: 173 174 180 181 182 183 189 190）

- 默认 P2P 级别：**~2.13 GB/s**（走 sysmem）
- 设置 `NCCL_P2P_LEVEL=SYS` 后：**~12.85 GB/s**

Group 3 的 8 张 GPU 在同一 root port `a5:00.0` 级联下。

### Group 4（VFIO groups: 148 149 155 156 157 158 162 163）

- 默认 P2P 级别：**~2.83 GB/s**（走 sysmem）
- 设置 `NCCL_P2P_LEVEL=SYS` 后：**~12.86 GB/s**

Group 4 使用 Domain 4 的 8 张 GPU（root port `82:01.0`），来自 switch `84:04.0` / `8b:04.0` / `8b:08.0` / `8b:0c.0` / `8b:10.0` 级联。

> 四组设置 `NCCL_P2P_LEVEL=SYS` 后带宽均达到 ~12.8 GB/s 左右。

---

## 12. vLLM 推理服务并发部署

### 12.1 启动脚本

在目标机创建 `/home/rx/bingo/start_vllm_all_groups.sh`：

```bash
#!/usr/bin/env bash
set -uo pipefail

MODEL_PATH="/models/Qwen3.6-35B-A3B-FP8"
SERVED_MODEL_NAME="Qwen3.6-35B-A3B-FP8"
TP=4
PP=2

start_group() {
    local group="$1"
    local name="kata-vfio-group${group}"
    local log="/root/vllm-group.log"

    echo "[group${group}] starting vLLM..."
    nerdctl exec "${name}" bash -c "
        export NCCL_P2P_LEVEL=SYS
        pkill -9 -f \"vllm serve\" 2>/dev/null || true
        sleep 2
        dx-smi --query-compute-apps=pid --format=csv,noheader | xargs -r kill -9 2>/dev/null || true
        rm -f ${log}
        nohup vllm serve ${MODEL_PATH} \\
            --served-model-name ${SERVED_MODEL_NAME} \\
            --tensor-parallel-size ${TP} \\
            --pipeline-parallel-size ${PP} \\
            --port 8000 \\
            --dtype float16 \\
            --max-model-len 2048 \\
            --gpu-memory-utilization 0.90 \\
            --enforce-eager \\
            --max-num-seqs 128 \\
            > ${log} 2>&1 &
echo \$! > /tmp/vllm-group.pid
    "
}

for g in 1 2 3 4; do
    start_group "${g}"
    sleep 60
done
```

关键参数说明：

| 参数 | 取值 | 原因 |
|---|---|---|
| `--tensor-parallel-size` | 4 | 每组 8 GPU 分成 2 个 pipeline stage，每个 stage 4 张卡做 TP |
| `--pipeline-parallel-size` | 2 | 8 张卡拆成 2 个 pipeline stage |
| `--dtype float16` | float16 | 避免 auto 选择 bfloat16 占用更多显存 |
| `--max-model-len` | 2048 | 限制 KV cache 长度 |
| `--gpu-memory-utilization` | 0.90 | 8 GB 显存紧张，0.95 在并发启动时容易失败 |
| `--enforce-eager` | - | 禁用 CUDA graph，节省显存 |
| `--max-num-seqs` | 128 | 限制并发序列数 |
| `NCCL_P2P_LEVEL=SYS` | - | 确保 P2P 走 PCIe switch，带宽 ~12.8 GB/s |

### 12.2 启动命令

```bash
/home/rx/bingo/start_vllm_all_groups.sh
```

服务监听映射：

| 组 | 容器内端口 | Host 端口 |
|---|---|---|
| 1 | 8000 | 8006 |
| 2 | 8000 | 8007 |
| 3 | 8000 | 8008 |
| 4 | 8000 | 8009 |

### 12.3 并发 benchmark

在目标机创建 `/home/rx/bingo/run_all_benchmarks.sh`：

```bash
#!/usr/bin/env bash
set -uo pipefail

for g in 1 2 3 4; do
    echo "[group${g}] starting benchmark"
    nerdctl exec kata-vfio-group${g} /root/vllm_benchmark_group.sh &
done

wait
echo "All benchmarks completed"
```

每个容器内的 `/root/vllm_benchmark_group.sh` 与原始 `/home/rx/bingo/vllm_benchmark.sh` 相同，但 `PORT=8000`。

### 12.4 性能结果

4 组容器内同时运行 `vllm bench serve`，测试配置：

- input_len: 256 / 512 / 1024
- output_len: 256 / 512 / 1024
- num_prompts: 1 / 10 / 50 / 100
- 模型：`/models/Qwen3.6-35B-A3B-FP8`
- 并行：`tensor_parallel_size=4`, `pipeline_parallel_size=2`

结果按指标分成三个表格（每组一列，便于横向对比）。

#### Output token throughput (tok/s)

| input_len | output_len | num_prompts | Group 1 | Group 2 | Group 3 | Group 4 |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 256 | 1 | 5.6 | 5.9 | 5.6 | 5.6 |
| 256 | 256 | 10 | 52.0 | 53.7 | 51.5 | 51.9 |
| 256 | 256 | 50 | 377.6 | 402.7 | 356.8 | 381.9 |
| 256 | 256 | 100 | 408.4 | 400.4 | 363.1 | 427.0 |
| 256 | 512 | 1 | 10.2 | 10.0 | 9.8 | 9.6 |
| 256 | 512 | 10 | 85.3 | 90.0 | 98.7 | 94.6 |
| 256 | 512 | 50 | 420.6 | 432.1 | 421.4 | 442.9 |
| 256 | 512 | 100 | 478.1 | 437.6 | 395.5 | 455.2 |
| 256 | 1024 | 1 | 10.1 | 10.4 | 10.4 | 10.5 |
| 256 | 1024 | 10 | 99.5 | 101.2 | 98.6 | 93.7 |
| 256 | 1024 | 50 | 447.7 | 461.1 | 423.2 | 446.1 |
| 256 | 1024 | 100 | 444.4 | 455.2 | 409.6 | 450.6 |
| 512 | 256 | 1 | 9.3 | 9.9 | 10.9 | 9.0 |
| 512 | 256 | 10 | 89.7 | 81.5 | 92.7 | 92.2 |
| 512 | 256 | 50 | 379.8 | 379.3 | 347.5 | 401.1 |
| 512 | 256 | 100 | 469.6 | 392.8 | 348.9 | 399.6 |
| 512 | 512 | 1 | 10.2 | 10.1 | 10.0 | 10.0 |
| 512 | 512 | 10 | 88.6 | 86.4 | 89.6 | 97.7 |
| 512 | 512 | 50 | 425.6 | 418.5 | 396.4 | 411.7 |
| 512 | 512 | 100 | 467.5 | 433.3 | 362.5 | 421.7 |
| 512 | 1024 | 1 | 10.0 | 11.2 | 10.7 | 10.6 |
| 512 | 1024 | 10 | 95.9 | 95.2 | 96.5 | 91.8 |
| 512 | 1024 | 50 | 450.8 | 445.9 | 410.1 | 443.9 |
| 512 | 1024 | 100 | 455.8 | 438.1 | 386.0 | 478.1 |
| 1024 | 256 | 1 | 9.7 | 10.4 | 9.8 | 9.7 |
| 1024 | 256 | 10 | 95.5 | 85.2 | 80.4 | 95.5 |
| 1024 | 256 | 50 | 393.6 | 363.0 | 282.5 | 355.8 |
| 1024 | 256 | 100 | 367.6 | 388.5 | 277.3 | 346.5 |
| 1024 | 512 | 1 | 10.5 | 10.6 | 9.8 | 10.2 |
| 1024 | 512 | 10 | 97.3 | 100.0 | 93.8 | 94.6 |
| 1024 | 512 | 50 | 412.1 | 420.4 | 341.9 | 388.5 |
| 1024 | 512 | 100 | 426.1 | 423.0 | 334.9 | 418.0 |
| 1024 | 1024 | 1 | 10.8 | 10.7 | 9.9 | 11.0 |
| 1024 | 1024 | 10 | 94.6 | 92.5 | 88.9 | 94.0 |
| 1024 | 1024 | 50 | 312.8 | 328.6 | 288.3 | 306.8 |
| 1024 | 1024 | 100 | 429.9 | 428.4 | 379.7 | 453.4 |

#### Mean TTFT (ms)

| input_len | output_len | num_prompts | Group 1 | Group 2 | Group 3 | Group 4 |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 256 | 1 | 6440.0 | 6119.9 | 6629.6 | 6443.7 |
| 256 | 256 | 10 | 12641.1 | 6267.9 | 6357.0 | 6494.8 |
| 256 | 256 | 50 | 1350.9 | 1331.0 | 2392.2 | 1333.6 |
| 256 | 256 | 100 | 7466.8 | 7400.5 | 9906.5 | 7029.2 |
| 256 | 512 | 1 | 294.3 | 252.5 | 256.6 | 242.4 |
| 256 | 512 | 10 | 632.4 | 620.1 | 776.6 | 607.2 |
| 256 | 512 | 50 | 1305.7 | 1358.3 | 2263.2 | 1347.3 |
| 256 | 512 | 100 | 11467.1 | 12259.1 | 15372.6 | 11632.0 |
| 256 | 1024 | 1 | 268.9 | 247.1 | 273.0 | 255.1 |
| 256 | 1024 | 10 | 625.8 | 623.5 | 615.2 | 684.1 |
| 256 | 1024 | 50 | 1302.2 | 1372.6 | 2173.6 | 1359.8 |
| 256 | 1024 | 100 | 22104.9 | 21237.1 | 27243.9 | 21957.5 |
| 512 | 256 | 1 | 269.1 | 258.8 | 260.6 | 305.1 |
| 512 | 256 | 10 | 779.9 | 876.2 | 954.6 | 764.8 |
| 512 | 256 | 50 | 2204.3 | 2159.6 | 4292.2 | 2223.4 |
| 512 | 256 | 100 | 9561.8 | 10123.5 | 13998.2 | 10143.6 |
| 512 | 512 | 1 | 247.1 | 265.2 | 242.8 | 264.1 |
| 512 | 512 | 10 | 774.7 | 691.0 | 925.0 | 781.0 |
| 512 | 512 | 50 | 2222.9 | 2117.3 | 3001.6 | 2143.0 |
| 512 | 512 | 100 | 14760.0 | 15606.0 | 21715.3 | 16272.5 |
| 512 | 1024 | 1 | 313.1 | 256.7 | 257.9 | 257.9 |
| 512 | 1024 | 10 | 775.8 | 776.0 | 1069.0 | 764.8 |
| 512 | 1024 | 50 | 2181.6 | 2233.3 | 3998.4 | 2174.2 |
| 512 | 1024 | 100 | 27825.7 | 27454.5 | 36450.4 | 26325.2 |
| 1024 | 256 | 1 | 274.8 | 289.6 | 252.8 | 253.5 |
| 1024 | 256 | 10 | 1079.5 | 1140.0 | 2268.4 | 1147.8 |
| 1024 | 256 | 50 | 3880.1 | 3897.0 | 7811.3 | 3883.3 |
| 1024 | 256 | 100 | 16266.1 | 15774.5 | 27423.8 | 17267.0 |
| 1024 | 512 | 1 | 237.8 | 247.2 | 252.7 | 265.2 |
| 1024 | 512 | 10 | 1070.5 | 1076.3 | 1979.5 | 1081.5 |
| 1024 | 512 | 50 | 3869.8 | 3908.8 | 8790.9 | 3923.0 |
| 1024 | 512 | 100 | 25539.6 | 25020.0 | 37959.8 | 24028.5 |
| 1024 | 1024 | 1 | 314.7 | 270.3 | 242.7 | 260.3 |
| 1024 | 1024 | 10 | 1098.5 | 1068.7 | 1666.7 | 1102.1 |
| 1024 | 1024 | 50 | 3881.0 | 3884.4 | 8026.5 | 3892.4 |
| 1024 | 1024 | 100 | 46033.2 | 46020.4 | 58261.7 | 44593.8 |

#### Mean TPOT (ms)

| input_len | output_len | num_prompts | Group 1 | Group 2 | Group 3 | Group 4 |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 256 | 1 | 153.9 | 146.6 | 153.3 | 154.7 |
| 256 | 256 | 10 | 142.1 | 156.2 | 163.5 | 161.8 |
| 256 | 256 | 50 | 124.6 | 118.3 | 129.8 | 125.1 |
| 256 | 256 | 100 | 124.5 | 126.6 | 139.7 | 117.3 |
| 256 | 512 | 1 | 97.8 | 99.8 | 102.0 | 104.0 |
| 256 | 512 | 10 | 116.0 | 109.8 | 99.7 | 104.6 |
| 256 | 512 | 50 | 115.7 | 112.3 | 113.6 | 109.7 |
| 256 | 512 | 100 | 113.9 | 125.0 | 139.0 | 118.2 |
| 256 | 1024 | 1 | 99.2 | 95.9 | 95.5 | 95.2 |
| 256 | 1024 | 10 | 99.9 | 98.2 | 100.8 | 106.0 |
| 256 | 1024 | 50 | 110.1 | 106.9 | 115.9 | 110.5 |
| 256 | 1024 | 100 | 129.4 | 125.0 | 143.6 | 128.0 |
| 512 | 256 | 1 | 106.3 | 100.3 | 91.1 | 110.4 |
| 512 | 256 | 10 | 108.2 | 118.9 | 103.8 | 105.5 |
| 512 | 256 | 50 | 120.2 | 122.1 | 125.4 | 114.6 |
| 512 | 256 | 100 | 120.8 | 139.3 | 154.6 | 138.1 |
| 512 | 512 | 1 | 97.3 | 98.7 | 99.6 | 99.6 |
| 512 | 512 | 10 | 111.3 | 114.4 | 109.9 | 100.8 |
| 512 | 512 | 50 | 111.9 | 114.2 | 119.1 | 116.6 |
| 512 | 512 | 100 | 118.5 | 128.0 | 156.2 | 132.3 |
| 512 | 1024 | 1 | 99.7 | 89.0 | 93.6 | 94.0 |
| 512 | 1024 | 10 | 103.4 | 104.3 | 102.6 | 108.1 |
| 512 | 1024 | 50 | 108.1 | 109.5 | 117.7 | 109.8 |
| 512 | 1024 | 100 | 129.4 | 135.1 | 151.1 | 122.5 |
| 1024 | 256 | 1 | 102.2 | 95.6 | 101.7 | 102.0 |
| 1024 | 256 | 10 | 100.1 | 112.3 | 115.2 | 100.0 |
| 1024 | 256 | 50 | 108.3 | 117.0 | 141.3 | 120.5 |
| 1024 | 256 | 100 | 137.1 | 128.3 | 174.2 | 146.0 |
| 1024 | 512 | 1 | 94.8 | 94.4 | 101.6 | 97.9 |
| 1024 | 512 | 10 | 100.4 | 97.5 | 102.7 | 103.4 |
| 1024 | 512 | 50 | 111.2 | 108.9 | 126.3 | 119.1 |
| 1024 | 512 | 100 | 123.8 | 124.1 | 153.3 | 123.6 |
| 1024 | 1024 | 1 | 92.0 | 93.2 | 100.4 | 90.6 |
| 1024 | 1024 | 10 | 104.5 | 107.0 | 110.8 | 105.2 |
| 1024 | 1024 | 50 | 115.9 | 108.2 | 124.1 | 116.2 |
| 1024 | 1024 | 100 | 129.3 | 129.8 | 142.5 | 122.4 |

> 说明：
> - `Group 3` 在高并发（num_prompts=100）和大 input/output（1024）场景下 TTFT/TPOT 明显劣于其他三组，可能与其所在 Domain 3 的 PCIe 路径或负载有关。
> - 单 prompt（n=1）时 TTFT 较高（6–12 s）是因为 vLLM 首次推理需要触发 Triton JIT 编译；后续用例 TTFT 下降到数百 ms 量级。
> - 高并发（n=50/100）下 output token throughput 可达 280–480 tok/s，各组差异约 ±15%。

---

## 13. 常见故障

| 现象 | 原因 | 处理 |
|---|---|---|
| `scp: dest open "/opt/kata/bin/containerd-shim-kata-v2": Failure` | 二进制被运行中的 shim 占用 | 先 `nerdctl rm -f kata-vfio-groupX` 停止所有 Kata 容器，或跳过二进制复制 |
| `vfio_nvidia_bind.sh` 进入 D 状态 | 运行中的 QEMU 持有 `/dev/vfio/N`，脚本尝试 unbind | 停止所有 Kata 容器后再绑定；若已绑定则跳过此步 |
| `failed to create shim task: create container timeout` | 可能是 ACS 未关闭、VFIO 组被占、或 hugepages 不足 | 检查 `dmesg`、确认无 D 状态进程、确认 `HugePages_Free` 足够 |
| `unknown flag: --device /dev/vfio/N` | nerdctl 需要 `--device=/dev/vfio/N` 格式 | 修改脚本使用 `=` 连接 |
| `failed to inject devices after CDI timeout of 100 seconds` | 宿主机 nvidia container toolkit 同时处理多个 CDI device 注入超时 | 添加 `--env NVIDIA_VISIBLE_DEVICES=void`，禁止把 host GPU 作为 CDI device 注入 |
| 容器内 `dx-smi` 找不到，NCCL 报 `CUDA driver version is insufficient for CUDA runtime version` | NVIDIA 驱动库或 DONXIN 命令未注入到 guest 容器 | 保留 `--env NVIDIA_DRIVER_CAPABILITIES=compute,utility`，让 toolkit 注入驱动库；不要设为空字符串 |
| `deploy_all_groups.sh` 部署 group 0 且 VFIO groups 为空 | 环境中存在 `GROUPS=0` 等变量覆盖了脚本内的数组 | 脚本改用 `GPU_GROUPS` 数组；执行前 `unset GROUPS` |
| NCCL 带宽低（约 2 GB/s） | P2P 走 sysmem | 设置 `NCCL_P2P_LEVEL=SYS` 再测，应达 ~12 GB/s |
| Guest BAR1 与 Host BAR1 不一致 | fixed-BAR 未生效 | 确认 QEMU 命令行包含 `x-fixed-bars=on` |
| Domain 4 GPU 无法启动 | 硬件/BIOS 限制，仅识别 3 张 GPU | 不使用 Domain 4 |
| Group 2 单独部署也报 `vfio_container_dma_map ... = -14 (Bad address)` | `/dev/shm` 被前 3 组 `memory-backend-file` 占满（默认 126 GB），剩余空间不足 40 GB；也可能是 `RLIMIT_MEMLOCK` 不足导致 VFIO 无法锁定内存 | 1. 临时扩容：`mount -o remount,size=200G /dev/shm`；2. 给 containerd 加 `LimitMEMLOCK=infinity`（见下方 memlock 说明） |
| vLLM 启动报 `No available memory for the cache blocks` | 8×RTX 4060 仅 8 GB 显存，35B FP8 模型权重占用后 KV cache 不足 | 使用 `--dtype float16 --max-model-len 2048 --gpu-memory-utilization 0.90 --enforce-eager --max-num-seqs 128` |
| 并发启动 vLLM 时部分组 GPU 空闲显存不足 0.95 利用率 | 各组独立 GPU，但前一次失败残留 worker 占用显存 | 启动前用 `dx-smi --query-compute-apps=pid --format=csv,noheader \| xargs -r kill -9` 清理 |
| Group 2/4 外部端口健康检查无响应，容器内部 200 | 旧 CNI NAT 规则残留，端口 DNAT 到已不存在的 IP（如 8007→10.4.0.68、8009→10.4.0.70） | 检查并修正 `iptables -t nat -L CNI-HOSTPORT-DNAT -n` 中的 DNAT 目标为当前容器 IP（8007→10.4.0.72、8009→10.4.0.71），或清理 `/var/lib/cni/results` 后重启 containerd |
| G2/G5 容器 `CDI timeout of 100 seconds` | NVRC 在桥 6a ≥3 GPU 时无法生成 `/var/run/cdi/nvidia.yaml`，agent 空等 100s | **已修复（commit `e629822`）**：配置 `skip_cdi_annotations = ["vfio139", ...]` 跳过 CDI 注解生成。详见 §22 |
| G2 桥 6a GPU 在 guest 内 NVIDIA probe 失败 | Guest PCI MMIO 窗口不足导致 BAR 地址冲突 | 待修复：增大 QEMU PCI MMIO 窗口或使用其他桥上的 GPU |

### memlock（RLIMIT_MEMLOCK）说明

VFIO 直通要求 guest RAM 对应的 host 物理页被**锁定**（pin），防止 swap 后被 IOMMU DMA 访问到错误地址。`RLIMIT_MEMLOCK` 限制了一个进程最多能锁定多少内存：

```bash
# 查看当前 shell 的 memlock 限制
ulimit -l

# 查看某个运行中进程的限制
cat /proc/<pid>/limits | grep locked
```

当使用 `/dev/shm` 普通内存而非 hugepages 时，QEMU 的 `memory-backend-file` 需要通过 `mlock` 锁定，会受 `RLIMIT_MEMLOCK` 限制。如果单 VM 内存接近或超过该限制，VFIO DMA 映射会失败。

设置方法：

1. **登录会话级别**（对新登录的 shell 生效）：

```bash
cat > /etc/security/limits.d/99-vfio.conf <<EOF
*    soft    memlock    unlimited
*    hard    memlock    unlimited
EOF
```

2. **systemd 服务级别**（containerd 等服务不读 `limits.conf`，必须单独设置）：

```bash
mkdir -p /etc/systemd/system/containerd.service.d/
cat > /etc/systemd/system/containerd.service.d/memlock.conf <<EOF
[Service]
LimitMEMLOCK=infinity
EOF

systemctl daemon-reload
systemctl restart containerd
```

3. **临时设置当前进程**（仅对当前 shell 及其子进程生效）：

```bash
ulimit -l unlimited
```

> 注意：本次 Group 2 失败的**直接原因**是 `/dev/shm` 容量不足，不是 memlock。但使用 `/dev/shm` 替代 hugepages 时，建议同时设置 `LimitMEMLOCK=infinity`，避免大内存 VM 因锁定限制启动失败。

---

## 13. deploy_all_groups.sh 说明

`/home/rx/bingo/deploy_all_groups.sh` 用于串行部署 4 组容器并自动运行 NCCL 测试。注意：

- 脚本内部使用 `GPU_GROUPS` 数组，避免与环境中可能存在的 `GROUPS` 变量冲突。
- 执行前建议先 `unset GROUPS`，防止环境变量覆盖数组。
- 它会调用同目录下的 `deploy_one_group.sh`。

```bash
unset GROUPS
cd /home/rx/bingo
./deploy_all_groups.sh
```

当前 `deploy_all_groups.sh` 中的 4 组配置：

```bash
GPU_GROUPS=(
    "1:27 28 34 35 36 37 43 44"
    "2:72 73 79 80 81 82 88 89"
    "3:173 174 180 181 182 183 189 190"
    "4:148 149 155 156 157 158 162 163"
)
```

---

## 14. 宿主机 Docker 单实例 vLLM 对比测试

在释放所有 Kata 容器后，把**未用于 Kata 4 组**的 GPU 重新绑定到 `nvidia` 驱动，用 Docker CE + nvidia-container-runtime 启动单个 vLLM 实例作为对比。

### 14.1 环境

- 镜像：`vllm/vllm-openai:v0.21.0-x86_64-cu129`（本地已有，避免 Docker Hub 拉取超时）
- 容器启动命令（TP=4, PP=2，与 Kata 组内一致）：

```bash
docker run -d --name vllm-host --runtime nvidia --gpus all \
    --entrypoint vllm \
    -p 8000:8000 \
    -v /models/Qwen3.6-35B-A3B-FP8:/models/Qwen3.6-35B-A3B-FP8 \
    -e NVIDIA_VISIBLE_DEVICES=all \
    vllm/vllm-openai:v0.21.0-x86_64-cu129 \
    serve /models/Qwen3.6-35B-A3B-FP8 \
      --served-model-name Qwen3.6-35B-A3B-FP8 \
      --tensor-parallel-size 4 \
      --pipeline-parallel-size 2 \
      --port 8000 \
      --dtype float16 \
      --max-model-len 2048 \
      --gpu-memory-utilization 0.90 \
      --enforce-eager \
      --max-num-seqs 128
```

> 注意：Qwen3.6-35B-A3B-FP8 的 attention heads 为 16，因此 `tensor_parallel_size` 必须是 16 的约数；宿主机直接运行也受同样限制。

### 14.2 单实例 benchmark 结果

| input_len | output_len | num_prompts | Output tok/s | Mean TTFT (ms) | Mean TPOT (ms) |
|---:|---:|---:|---:|---:|---:|
| 256 | 256 | 1 | 9.65 | 4102.60 | 87.90 |
| 256 | 256 | 10 | 91.37 | 2785.83 | 93.32 |
| 256 | 256 | 50 | 624.33 | 1898.83 | 72.22 |
| 256 | 256 | 100 | 672.97 | 6486.59 | 79.51 |
| 256 | 512 | 50 | 779.59 | 1891.28 | 60.25 |
| 256 | 512 | 100 | 762.26 | 9778.04 | 75.66 |
| 256 | 1024 | 100 | 791.79 | 15980.31 | 75.94 |
| 512 | 512 | 100 | 727.68 | 13487.88 | 78.21 |
| 512 | 1024 | 100 | 762.69 | 21041.40 | 77.68 |
| 1024 | 1024 | 100 | 680.45 | 34827.79 | 78.70 |

### 14.3 与 Kata 4 组平均性能对比

| input/output/prompts | 宿主机单实例 (tok/s) | Kata 4 组平均 (tok/s) | 宿主机 / Kata 倍数 |
|---:|---:|---:|---:|
| 256/256/1 | 9.65 | ~5.7 | ~1.69× |
| 256/256/10 | 91.37 | ~52.2 | ~1.75× |
| 256/256/50 | 624.33 | ~379.7 | ~1.64× |
| 256/256/100 | 672.97 | ~399.7 | ~1.68× |
| 256/512/50 | 779.59 | ~429.3 | ~1.82× |
| 256/512/100 | 762.26 | ~441.6 | ~1.73× |
| 256/1024/100 | 791.79 | ~439.9 | ~1.80× |
| 512/512/100 | 727.68 | ~421.3 | ~1.73× |
| 512/1024/100 | 762.69 | ~439.5 | ~1.73× |
| 1024/1024/100 | 680.45 | ~422.9 | ~1.61× |

结论：宿主机单实例（8 GPU）吞吐约为 Kata 单组（同 8 GPU）的 **1.6–1.8 倍**，TTFT 和 TPOT 也整体更优。差异主要来自 VFIO 直通、guest VM 内的 PCIe switch P2P 路径、以及 `/dev/shm` memory-backend 的额外开销。

---

## 15. 并发极限测试：Kata 4 组 + 宿主机多 Docker 同时推理

### 15.1 测试目标

验证在同一宿主机上，**Kata VFIO GPU 直通容器**与**宿主机 Docker GPU 容器**同时推理时，最多能同时运行多少张 GPU，以及各自和总体的吞吐表现。

### 15.2 并发配置

| 实例类型 | 数量 | 每实例 GPU | 总 GPU | 端口 | 说明 |
|---|---:|---:|---:|---:|---|
| Kata 组 | 4 | 8 | 32 | 8006/7/8/9 | VFIO 直通，guest VM 内 TP=4, PP=2 |
| Docker 容器 | 2 | 8 | 16 | 8010/8011 | 宿主机 `nvidia-container-runtime`，TP=4, PP=2 |
| **合计** | **6** | — | **48** | — | 同时运行 48 张 RTX 4060 Laptop GPU |

> 结论：本次硬件环境下，最多可同时运行 **48 张 GPU** 进行推理（32 张走 Kata VFIO + 16 张走宿主机 Docker）。若要在宿主机上启动更多 Docker 实例，需要从 Kata 中释放 GPU。

### 15.2.1 Kata 4 组实际分配的 GPU

| 组 | 容器名 | function-0 BDF | VFIO group |
|---|---|---|---|
| 1 | `kata-vfio-group1` | `0c:00.0` `0d:00.0` `10:00.0` `11:00.0` `12:00.0` `13:00.0` `16:00.0` `17:00.0` | 27 28 34 35 36 37 43 44 |
| 2 | `kata-vfio-group2` | `2a:00.0` `2b:00.0` `2e:00.0` `2f:00.0` `30:00.0` `31:00.0` `34:00.0` `35:00.0` | 72 73 79 80 81 82 88 89 |
| 3 | `kata-vfio-group3` | `8e:00.0` `8f:00.0` `92:00.0` `93:00.0` `94:00.0` `95:00.0` `98:00.0` `99:00.0` | 130 131 137 138 139 140 146 147 |
| 4 | `kata-vfio-group4` | `9a:00.0` `9b:00.0` `9e:00.0` `9f:00.0` `a0:00.0` `a1:00.0` `a4:00.0` `a5:00.0` | 148 149 155 156 157 158 162 163 |

> 注意：实际运行的 Group 3/4 与 `deploy_all_groups.sh` 中旧配置（`173...190`、`90...105`）不同。当前容器使用 Domain 3/Domain 4 的 GPU，上表以实际运行的 QEMU 命令行为准。

### 15.2.2 宿主机 Docker 实例实际分配的 GPU

| 实例 | 容器名 | function-0 BDF | 驱动 |
|---|---|---|---|
| Docker-1 | `vllm-host-d1` | `18:00.0` `19:00.0` `1c:00.0` `1d:00.0` `1e:00.0` `1f:00.0` `22:00.0` `23:00.0` | `nvidia` |
| Docker-2 | `vllm-host-d2` | `36:00.0` `37:00.0` `3a:00.0` `3b:00.0` `3c:00.0` `3d:00.0` `40:00.0` `41:00.0` | `nvidia` |

Docker 实例通过 `NVIDIA_VISIBLE_DEVICES` 指定 UUID 限制可见 GPU，`--gpus all` 仅作为容器运行时的入口；实际分配见上表。

### 15.3 启动方式

宿主机 Docker 实例启动脚本：

```bash
/home/rx/bingo/start_host_docker_vllm.sh
```

并发 benchmark 启动脚本：

```bash
/home/rx/bingo/run_all_concurrent_benchmarks.sh
```

### 15.4 平均单实例吞吐

| 实例 | 平均 output tok/s | 最小 | 最大 |
|---|---:|---:|---:|
| Group 1 | 202.3 | 9.6 | 477.6 |
| Group 2 | 207.2 | 9.6 | 457.3 |
| Group 3 | 219.5 | 9.6 | 459.9 |
| Group 4 | 248.4 | 9.7 | 494.8 |
| Docker-1 | 219.8 | 12.6 | 566.8 |
| Docker-2 | 219.4 | 12.6 | 561.6 |

### 15.5 聚合吞吐（48 GPU 同时运行）

| input_len | output_len | num_prompts | Kata 4 组合计 | Docker 2 实例合计 | 48 GPU 总计 |
|---:|---:|---:|---:|---:|---:|
| 256 | 256 | 1 | 38.8 | 27.9 | 66.7 |
| 256 | 256 | 10 | 407.8 | 299.8 | 707.5 |
| 256 | 256 | 50 | 1579.1 | 599.3 | 2178.4 |
| 256 | 256 | 100 | 1684.3 | 1128.4 | 2812.7 |
| 256 | 512 | 50 | 1780.8 | 996.0 | 2776.9 |
| 256 | 512 | 100 | 1768.0 | 802.6 | 2570.6 |
| 256 | 1024 | 50 | 1833.2 | 824.9 | 2658.1 |
| 256 | 1024 | 100 | 1702.5 | 712.4 | 2414.8 |
| 512 | 512 | 100 | 1566.3 | 1080.7 | 2647.0 |
| 512 | 1024 | 100 | 1599.8 | 760.1 | 2359.9 |
| 1024 | 256 | 100 | 1054.0 | 482.5 | 1536.5 |
| 1024 | 512 | 100 | 1391.8 | 799.1 | 2190.9 |
| 1024 | 1024 | 50 | 1210.9 | 390.9 | 1601.8 |
| 1024 | 1024 | 100 | 1747.7 | 967.2 | 2714.9 |

### 15.6 关键发现

1. **可同时运行 GPU 数量**：本机最多 **48 张 GPU** 同时推理（Kata 32 张 + 宿主机 Docker 16 张）。这是由当前 VFIO 分组决定的：4 组 Kata 用掉 32 张 GPU 后，宿主机剩余 16 张可绑定 `nvidia` 驱动。
2. **单实例性能**：并发运行时，Kata 单组平均吞吐 **202–248 tok/s**，宿主机 Docker 单实例平均吞吐 **219 tok/s**，两者接近。
3. **聚合吞吐**：在代表性高并发用例（如 input=256, output=256, num_prompts=100）下，48 GPU 合计可达 **2812.7 tok/s**。
4. **资源竞争**：部分 Docker 实例用例出现 TTFT 异常升高（如 512/256/10 时 TTFT ~42 s），推测是两个 Docker 实例共享宿主机 PCIe/NIC 路径或 CPU 调度导致的间歇性抖动，但 output tok/s 未完全崩溃。
5. **内存压力**：并发运行时宿主机内存使用约 216 GB/251 GB，`/dev/shm` 使用 160 GB/200 GB，仍处于可用边缘，建议保持 `/dev/shm` 200 GB 配置。

### 15.7 完整结果文件

原始 benchmark 日志：

- `/root/benchmark-group{1..4}.log`
- `/root/benchmark-vllm-host-d{1,2}.log`

完整解析表格：

- `/root/concurrent_benchmark_summary.md`

---

## 16. 一键停止所有 Kata VFIO 容器

```bash
sshpass -p "${TARGET_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${TARGET_USER}@${TARGET_HOST}" "
    for i in 1 2 3 4; do
        nerdctl rm -f kata-vfio-group\${i} 2>/dev/null || true
    done
"
```

---

## 17. 2026-06-27 配置更新（基于 8 组 64 GPU 测试）

本节记录 2026-06-27 在 64 × RTX 4060 Laptop GPU（8 组 × 8 GPU）服务器上的部署改进。

### 17.1 关键配置变更

| 参数 | 旧值 | 新值 | 原因 |
|------|------|------|------|
| `default_memory` | 32768 | **16384** | VM 内存翻倍（16GB→32GB），32768 时 VM 实际 64 GB 导致 4 VM 无法共存 |
| `memory_slots` | 10 | **2** | 减少 QEMU maxmem 避免内核 overcommit 拒绝分配 |
| `enable_hugepages` | true | **false** | 使用 /dev/shm 代替 hugepages |
| `/dev/shm` 大小 | 200 GB | **300 GB** | 4 VM × 64 GB = 256 GB 需要余量 |
| `kernel_params` | `"nvidia_uvm..."` | `"cgroup_no_v1=all pci=realloc pci=nocrs pci=assign-busses"` | 简化参数，`pci=realloc` 对 GPU BAR 重映射有用 |

### 17.2 关键发现

1. **Kata shim v2 配置路径**: shim 读取的是 `/opt/kata/share/defaults/kata-containers/configuration-qemu.toml`，**不是** `/etc/kata-containers/configuration.toml`。必须同步复制两个路径，否则 `cold_plug_vfio="root-port"` 和 `pcie_root_port=8` 不会生效。

2. **nerdctl 端口转发不可靠**: Kata VM 的 CNI 端口转发不稳定，建议使用 `--net=host` 直接暴露端口。

3. **command 语法**: nerdctl/docker 的 `-c` 参数会将所有参数作为单个字符串传递给 entrypoint。正确做法是参数直接跟在镜像名后面：`nerdctl run --entrypoint vllm image serve /model --tp 4`。

4. **TP=8 + FP8 block size 冲突**: Qwen3.6-35B-A3B 模型的 MoE 中间层 512 在 TP=8 时分到每卡 64，不能被 FP8 block_k=128 整除。**必须使用 TP=4 + PP=2**。

5. **PP=2 降低显存需求**: 8 GPU 拆成 2 pipeline stages × 4 TP，每卡只需 4.52 GiB 权重 + 1.13 GiB KV cache ≈ 5.65 GiB，在 8GB RTX 4060 上刚好够。

6. **4 VM 限制**: ~~不带 vLLM 的 Alpine VM 可以 4 组同时运行（32GB/VM）。加载 vLLM 模型时，当前实测仅 2 组可同时存活。~~ **2026-06-27 更新：4 组 Kata VFIO（G1+G6+G7+G8）同时运行 sleep infinity 稳定存活，G1 加载 vLLM 后其余 3 组仍保持 Up。4 组全部加载 vLLM 的内存压力待进一步验证。**

### 17.3 GPU 组 CDI 兼容性（全 8 组）

| 组 | BDF（function-0） | IOMMU 组 | CDI 状态 | 备注 |
|----|-------------------|----------|---------|------|
| G1 | 5b 5c 5f 60 61 62 65 66 | 121 122 128 129 130 131 137 138 | ✅ | |
| G2 | 67 68 6b 6c 6d 6e 71 72 | 139 140 146 147 148 149 153 154 | ❌ CDI timeout | |
| G3 | 79 7a 7d 7e 7f 80 83 84 | 166 167 173 174 175 176 182 183 | ✅ | |
| G4 | 85 86 89 8a 8b 8c 8f 90 | 184 185 191 192 193 194 198 199 | ✅ | |
| G5 | 9a 9b 9e 9f a0 a1 a4 a5 | 26 27 33 34 35 36 42 43 | ❌ CDI timeout | 同时 nvidia RmInitAdapter 失败 |
| G6 | a6 a7 aa ab ac ad b0 b1 | 44 45 51 52 53 54 58 59 | ✅ | 从 nvidia 重绑到 vfio-pci 可用 |
| G7 | b8 b9 bc bd be bf c2 c3 | 71 72 78 79 80 81 87 88 | ✅ | 本次实测可用 |
| G8 | c4 c5 c8 c9 ca cb ce cf | 89 90 96 97 98 99 103 104 | ✅ | 本次实测可用 |

### 17.4 推荐 vLLM 启动命令

```bash
# 1. 创建容器（VM 引导，sleep 保活）
nerdctl run -d --runtime=io.containerd.kata.v2 --net=host --name kata-g1 \
  --device=/dev/vfio/121 --device=/dev/vfio/122 --device=/dev/vfio/128 --device=/dev/vfio/129 \
  --device=/dev/vfio/130 --device=/dev/vfio/131 --device=/dev/vfio/137 --device=/dev/vfio/138 \
  -m 32g -v /models:/models --env NVIDIA_VISIBLE_DEVICES=all \
  --entrypoint sleep vllm/vllm-openai:v0.21.0-x86_64-cu129 infinity

# 2. 等 VM Up 后启动 vLLM（通过 exec）
nerdctl exec kata-g1 bash -c "
  export NCCL_P2P_LEVEL=SYS
  nohup vllm serve /models/Qwen3.6-35B-A3B-FP8 \
    --served-model-name Qwen3.6-35B-A3B-FP8 \
    --tensor-parallel-size 4 --pipeline-parallel-size 2 \
    --port 8006 --dtype float16 --max-model-len 2048 \
    --gpu-memory-utilization 0.90 --enforce-eager --max-num-seqs 128 \
    > /root/vllm.log 2>&1 &
"

# 3. 验证
sleep 30 && curl http://localhost:8006/health
```

### 17.5 与旧版差异总结

| 项目 | test64.md 原版 | 本次更新 |
|------|---------------|---------|
| 内存管理 | 123 GB hugepages | /dev/shm 300 GB, no hugepages |
| VM 内存 | 32 GB (default_memory=32768→64GB VM) | 32 GB (实际 QEMU -m 49152M=48GB，公式 `default_memory×(1+memory_slots)`) |
| 并行 | 3 组 Kata | 目标 4 组，实测 4 组 sleep 稳定，vLLM 待全量验证 |
| 端口暴露 | `-p 8006:8000`（不可靠） | `--net=host` |
| vLLM dtype | auto (bfloat16) | **float16**（省显存） |
| CUDA graph | 默认启用 | **enforce-eager**（省显存） |
| entrypoint | `/bin/bash -c "sleep infinity"` | **`--entrypoint sleep`** (实测 `/bin/bash -c 'sleep infinity'` 更稳定，因 vllm 镜像无 sleep 二进制) |
| runtime | `io.containerd.kata.v2` | 同上（已确认可用） |

### 17.6 VM 内存计算公式（已修正）

Kata runtime 的 QEMU 内存分两阶段确定：

1. **初始启动**（`qemu.go:2655` `genericMemoryTopology()`）：QEMU `-m` = `default_memory`
2. **容器创建**（`sandbox.go:2378-2380` `updateResources()`）：热插拔容器 memory limit

```
最终 QEMU -m = default_memory + 容器 memory limit (nerdctl -m)
```

实测验证：
- `default_memory=16384` + `nerdctl -m 32g` → QEMU `-m 49152M`（48 GB）
- `default_memory=16384` + `nerdctl -m 36g` → QEMU `-m 53248M`（52 GB）

**注意**：`memory_slots` **不影响** `-m` 值，只控制最多可热插拔的 DIMM 槽位数。旧版文档中 `default_memory × (1 + memory_slots)` 的公式是巧合近似（32g ≈ 16g × 2，slots=2 时 16384 × 3 = 49152 碰巧匹配），实际代码逻辑见 §19.2.1。

4 VM × 48GB = 192GB /dev/shm 占用，刚好在 300GB 限制内（64%）。

---

## 18. 2026-06-27 — 4 Kata VFIO + 1 Docker 并发部署

> 目标：在 64 × RTX 4060 Laptop GPU 服务器上同时运行 4 组 Kata VFIO（各 8 GPU）+ 1 个 Docker 容器（24 GPU），总计 56 GPU 同时推理。

### 18.1 GPU 分配方案

| 实例 | 使用 GPU 组 | GPU 数 | 驱动 | 端口 | vLLM |
|------|------------|--------|------|------|------|
| Kata G1 | G1 (5b-66) | 8 | vfio-pci | 8010 | ✅ |
| Kata G6 | G6 (a6-b1) | 8 | vfio-pci | 8015 | 待启动 |
| Kata G7 | G7 (b8-c3) | 8 | vfio-pci | 8016 | 待启动 |
| Kata G8 | G8 (c4-cf) | 8 | vfio-pci | 8017 | 待启动 |
| Docker | G2+G3+G4 (67-90) | 24 | nvidia | 8000 | 待启动 |

**实际 Docker 为 24 GPU 而非计划 32 GPU**，原因：
- G5（9a-a5）绑定 nvidia 驱动后 `RmInitAdapter failed! (0x22:0x40:894)`，无法初始化
- NVIDIA 消费级驱动有 ~32 GPU 软限制
- G2+G3+G4 = 24 GPU 是目前可用的最大 nvidia 驱动 GPU 数量

### 18.2 部署脚本

最终工作脚本保存在：
- **部署脚本**：`/root/deploy_kata_final.sh`（本地副本：`deploy-kata-4groups.sh`）
- **benchmark 脚本**：`/models/vllm_benchmark.sh`（容器间共享卷）
- **源模板**：`/home/rx/bingo/vllm_benchmark_concurrent.sh`

#### deploy_kata_final.sh 核心逻辑

```bash
#!/bin/bash
# 4 Kata VFIO 容器部署脚本
# 关键点：
# 1. IOMMU 组通过关联数组映射，确保 --device=/dev/vfio/N 正确传入
# 2. 每个容器部署前先执行 ACS shutdown
# 3. 容器启动后重新关闭 ACS（VM 启动会恢复部分桥的 ACS）
# 4. 使用 shared volume /models 在容器间共享脚本，避免 nerdctl exec -i 管道问题

declare -A IOMMU_MAP
IOMMU_MAP[1]="121 122 128 129 130 131 137 138"
IOMMU_MAP[6]="44 45 51 52 53 54 58 59"
IOMMU_MAP[7]="71 72 78 79 80 81 87 88"
IOMMU_MAP[8]="89 90 96 97 98 99 103 104"

for gid in 1 6 7 8; do
    IOMMU_GROUPS="${IOMMU_MAP[$gid]}"
    # → 构建 BDFS 列表 + DEVICE_ARGS
    # → /root/acs_shutdown_vfio_group.sh
    # → nerdctl run --device=/dev/vfio/N -m 32g -p PORT:8000
done
```

#### vllm_benchmark.sh

```bash
#!/bin/bash
# 基于 /home/rx/bingo/vllm_benchmark_concurrent.sh 修改
# 部署到 /models/vllm_benchmark.sh（共享卷，所有容器可访问）
# 测试矩阵：input_len×output_len×num_prompts = 3×3×4 = 36 cases
MODEL_PATH="/models/Qwen3.6-35B-A3B-FP8"
PORT=8000
input_lens=(256 512 1024)
output_lens=(256 512 1024)
num_prompts_list=(1 10 50 100)
# → vllm bench serve --port $PORT --ignore_eos ...
```

### 18.3 关键踩坑与修复

| 问题 | 原因 | 修复 |
|------|------|------|
| G5 容器 `create container timeout` | CDI timeout（已知问题，17.3） | 跳过 G5，改用 G1 |
| G5 nvidia `RmInitAdapter failed` | nvidia 驱动 ~32 GPU 限制 | G5 既不能 Kata 也不能 Docker，放弃 |
| `nerdctl exec -i` 管道挂起 | Kata VM 的 stdio 管道不可靠 | 改用 `/models` 共享卷分发脚本 |
| `nerdctl exec -d`（detached）不工作 | Kata shim 的 detach 模式兼容性 | 使用 `nohup ... &` + `exec` 无 `-d` |
| 部署脚本中 IOMMU 组为空 | bash 关联数组在远程 ssh 中未正确展开 | 使用 `declare -A` + `${IOMMU_MAP[$gid]}` 显式展开 |
| VM 内存 48GB 而非 32GB | `default_memory × (1 + memory_slots)` 公式 | 已改 `memory_slots=1`，待重启 containerd 后生效 |
| G1 容器 `nerdctl exec` 超时 | 之前的不完全清理导致 shim 状态不一致 | `pkill -9 qemu-system` + `ctr tasks delete` 彻底清理 |

### 18.4 vLLM 验证结果

#### G1 基准结果（256/256/10）

| 指标 | 值 | test64.md 参考 (Group 1) |
|------|-----|--------------------------|
| Output tok/s | **51.54** | 52.0 |
| Mean TTFT (ms) | 21252 | 12641 |
| Mean TPOT (ms) | 110.70 | 142.1 |

> G1 TTFT 差异可能是因为 Triton JIT 编译缓存未预热（首次运行）。

#### 部署后状态

```
kata-vfio-group8  Up  0.0.0.0:8017->8000/tcp  (G8: 8 GPUs, GPA=HPA ✅)
kata-vfio-group7  Up  0.0.0.0:8016->8000/tcp  (G7: 8 GPUs, GPA=HPA ✅)
kata-vfio-group6  Up  0.0.0.0:8015->8000/tcp  (G6: 8 GPUs, GPA=HPA ✅)
kata-vfio-group1  Up  0.0.0.0:8010->8000/tcp  (G1: 8 GPUs, GPA=HPA ✅, vLLM HEALTHY)
vllm-docker       Up  0.0.0.0:8000->8000/tcp   (Docker: 24 GPUs, nvidia driver)
```

- /dev/shm: 192GB/300GB (64%)
- QEMU 进程: 4 × 49152M
- 宿主机空闲内存: ~110GB

### 18.5 快速操作命令

```bash
# === 一键部署 4 组 Kata ===
ssh root@172.18.5.133 'bash /root/deploy_kata_final.sh'

# === 启动 vLLM（在容器内） ===
ssh root@172.18.5.133 "nerdctl exec kata-vfio-group1 bash -c '
  export NCCL_P2P_LEVEL=SYS
  nohup vllm serve /models/Qwen3.6-35B-A3B-FP8 \
    --served-model-name Qwen3.6-35B-A3B-FP8 \
    --tensor-parallel-size 4 --pipeline-parallel-size 2 \
    --port 8000 --dtype float16 --max-model-len 2048 \
    --gpu-memory-utilization 0.90 --enforce-eager --max-num-seqs 128 \
    > /root/vllm.log 2>&1 &
'"

# === 运行 benchmark ===
ssh root@172.18.5.133 'nerdctl exec kata-vfio-group1 bash /models/vllm_benchmark.sh'

# === 多组并发 benchmark ===
for gid in 1 6 7 8; do
  ssh root@172.18.5.133 \
    "nerdctl exec kata-vfio-group${gid} bash /models/vllm_benchmark.sh" &
done
wait

# === Docker 对比测试 ===
ssh root@172.18.5.133 'docker exec vllm-docker bash /models/vllm_benchmark.sh'

# === 一键停止 ===
ssh root@172.18.5.133 '
  for gid in 1 6 7 8; do nerdctl rm -f kata-vfio-group${gid} 2>/dev/null; done
  docker rm -f vllm-docker 2>/dev/null
'
```

### 18.6 脚本文件清单

| 路径 | 用途 | 来源 |
|------|------|------|
| `/root/deploy-kata-4groups.sh` | 部署 4 组 Kata VFIO 容器 | 本次编写（仓库：`deploy-kata-4groups.sh`） |
| `/root/start-vllm-in-kata.sh` | 在 Kata 容器内启动 vLLM | 仓库：`start-vllm-in-kata.sh` |
| `/models/vllm_benchmark.sh` | vLLM 性能基准测试（36 cases） | 基于 `/home/rx/bingo/vllm_benchmark_concurrent.sh` |
| `/root/acs_shutdown_vfio_group.sh` | 关闭 GPU 上游桥 ACS | test64.md §8 |
| `/root/start-vllm-all-groups.sh` | **新增**：顺序启动所有组 vLLM，带健康检查 | 仓库：`start-vllm-all-groups.sh` |
| `/home/rx/bingo/deploy_all_groups.sh` | 全 8 组 VFIO 绑定+部署（旧版） | 之前编写 |
| `/home/rx/bingo/deploy_one_group.sh` | 单组 VFIO 部署（被 deploy_all_groups 调用） | 之前编写 |
| `/home/rx/bingo/vfio_nvidia_bind.sh` | NVIDIA GPU 批量绑定到 vfio-pci | 之前编写 |

### 18.7 Qwen3-14B 模型测试（2026-06-27 下午）

在 4 组 Kata + 1 Docker 部署的基础上，切换模型为 Qwen3-14B（BF16, 29.5GB）：

| 模型 | 格式 | 参数量 | 每GPU权重 | 8GB卡可行 | Benchmark (256/256/10) |
|------|------|--------|----------|----------|----------------------|
| Qwen3.6-35B-A3B | FP8 MoE | 35B | ~4.5 GB | ✅ | 51.5 tok/s |
| Qwen3.5-27B | BF16 Dense | 27B | ~6.75 GB | ❌ OOM | — |
| **Qwen3-14B** | **BF16 Dense** | **14B** | **~3.7 GB** | ✅ | ~372 tok/s (G1) |

#### 14B 部署关键发现

1. **`--served-model-name` 必须设置**: vLLM serve 必须带 `--served-model-name` 参数，否则模型名默认为路径（如 `/models/Qwen3-14B`）。benchmark 脚本中的 `--model` 参数必须与 `--served-model-name` 一致（使用简短名如 `Qwen3-14B`），不能使用文件系统路径。**不匹配会导致 `POST /v1/completions HTTP/1.1 404 Not Found`**。

2. **正确启动命令**:
   ```bash
   nerdctl exec kata-vfio-group1 bash -c "
     export NCCL_P2P_LEVEL=SYS
     nohup vllm serve /models/Qwen3-14B \
       --served-model-name Qwen3-14B \
       --tensor-parallel-size 4 --pipeline-parallel-size 2 \
       --port 8000 --dtype float16 --max-model-len 4096 \
       --gpu-memory-utilization 0.92 --enforce-eager --max-num-seqs 128 \
       > /tmp/vllm.log 2>&1 &
   "
   ```

3. **正确 benchmark 命令**:
   ```bash
   # 错误: --model /models/Qwen3-14B（路径，会 404）
   # 正确: --model Qwen3-14B（与 --served-model-name 一致）
   vllm bench serve --port 8000 --model Qwen3-14B --served-model-name Qwen3-14B \
     --ignore_eos --random-input-len 256 --random-output-len 256 --num-prompts 10
   ```

4. **内存充足**: 14B 模型每 GPU 仅 ~3.7 GB，8GB 显卡留 4+ GB 给 KV cache，`max-model-len 4096` 轻松。

5. **Docker 模型挂载**: Docker 容器必须挂载 `-v /models:/models`（不要只挂载单个模型目录），否则切换模型时需重建容器。

#### 并发 benchmark 结果（G1 + G6 + Docker，256/256/100）

| 实例 | Output tok/s | Mean TTFT (ms) | Mean TPOT (ms) |
|------|-------------|----------------|----------------|
| Docker (24 GPU, TP4/PP2) | ~822 | ~3037 | ~109 |
| Kata 待重跑 | — | — | — |

> Docker 单实例 benchmark 完成（36/36 cases），G1/G6 因 `--model` 路径问题需重跑。Docker 结果附在 `/root/bench-docker.log`。

---

## 19. 4 组 Kata VFIO 同时跑 vLLM 的 OOM 根因与修复

### 19.1 问题描述

G1/G6/G7/G8 四个 Kata VFIO 容器空跑 `sleep infinity` 稳定存活。但 4 组**同时**启动 vLLM 时部分组失败（OOM kill）。单独启动 G1 或 G6 则成功。

### 19.2 根因分析

#### 19.2.1 QEMU 实际内存计算公式

通过代码追踪（`qemu.go:2655`, `sandbox.go:2378-2380`），实际公式为：

```
QEMU -m = default_memory + 容器 memory limit
        = 16384 MB (16 GB VM 系统) + nerdctl -m 32g (32 GB 容器)
        = 49152 MB = 48 GB
```

**注意**：文档 §17.6 中的 `default_memory × (1 + memory_slots)` 公式是近似值，实际是 `default_memory + 容器 OCI memory limit` 的热插拔叠加。`memory_slots` 只控制最多可热插拔的 DIMM 槽位数，不影响 `-m` 值。

#### 19.2.2 宿主机资源消耗

| 资源 | 单 VM | 4 VM 合计 |
|------|-------|----------|
| QEMU `-m` (/dev/shm) | 48 GB | **192 GB** |
| QEMU 进程开销（VFIO DMA 等） | ~3 GB | **~12 GB** |
| 宿主机 RAM 总占用 | ~51 GB | **~204 GB** |

宿主机总 RAM 251 GB，剩余 ~47 GB 供 OS、containerd 和 Docker 容器使用。这个层面是安全的（/dev/shm 300 GB 容量够用）。

#### 19.2.3 vLLM 模型加载内存（核心瓶颈）★

Qwen3-14B（BF16，~28.6 GB 权重）TP=4/PP=2 分布：

```
单 GPU 权重 shard:  28.6 ÷ 2(pipeline) ÷ 4(tensor) = 3.6 GB
8 个 rank 同时加载:   8 × 3.6 GB = 28.8 GB
CUDA/NCCL 初始化:     ~2-3 GB        ← torch.distributed, ncclCommInitRank
─────────────────────────
Guest 内 CPU 峰值:    ~31-34 GB
容器内存限制:         32 GB           ← 刚好不够！
```

**这就是根因**。vLLM 加载模型时所有 8 个 GPU rank **同时**从磁盘读取各自的 weight shard 到 CPU 内存再搬到 GPU，瞬时峰值 ~31-34 GB，突破 `nerdctl -m 32g` 的 32 GB 上限。

#### 19.2.4 并发启动为何加剧问题

4 个 VM 同时启动 vLLM 时，叠加了三层竞争：

1. **Guest 内存**: 每个 VM 内 vLLM 加载峰值接近容器限制，任何一个 VM 超过 32 GB → Guest OOM killer
2. **virtio-fs IO**: 4 个 VM 同时从共享卷读取 4 × 28.6 GB = 114 GB 权重数据，文件系统吞吐成为瓶颈
3. **宿主机 CPU**: 4 × 8 = 32 个 Python 进程并发做 tensor 初始化 + NCCL 握手

相反，**单独启动 G1** 成功的原因是：只有 1 个 VM 在做内存密集加载，宿主机 IO 和 CPU 空闲，加载速度快，峰值内存停留时间短。

#### 19.2.5 稳态推理为什么没问题

模型加载完成后进入推理阶段：
- 权重已在 GPU 显存，CPU 内存释放
- 每个 rank CPU 内存降至 ~1-2 GB（KV cache 元数据）
- 8 rank × 2 GB = 16 GB，远低于 32 GB 限制
- 推理是 GPU-bound，CPU 压力极小

**结论：4 组可以同时推理，但不能同时加载模型。**

### 19.3 修复方案

#### 方案 A：顺序启动 vLLM（推荐）

脚本：**`start-vllm-all-groups.sh`**

```bash
# 逐组启动 vLLM，每组等 /health 返回 200 后再启动下一组
bash /root/start-vllm-all-groups.sh "1 6 7 8" /models/Qwen3-14B
```

成本：4 × ~3min = ~12 分钟串行加载。稳态后 4 组同时推理不受影响。

#### 方案 B：增加容器内存上限

`deploy-kata-4groups.sh` 中：

```diff
-export GUEST_RAM_GB=32
+export GUEST_RAM_GB=36
...
-nerdctl run ... -m 32g ...
+nerdctl run ... -m 36g ...
```

新配置：
- 单 VM QEMU = 16 + 36 = 52 GB
- 4 VM = 208 GB /dev/shm（300 GB 的 69%，安全）
- 容器内有 36 GB，vLLM 加载峰值 34 GB 轻松容纳
- 同时加载变为可行

#### 方案 C：A + B 组合（最稳妥）

顺序启动 + 36 GB 内存上限。加载不 OOM，推理更快。

### 19.4 脚本变更清单

| 脚本 | 变更 | 说明 |
|------|------|------|
| `docs/micro/scripts/deploy-kata-4groups.sh` | `-m 32g` → `-m 36g` | 容器内存上限提升 |
| `docs/micro/scripts/start-vllm-in-kata.sh` | 重写，参数化 + 自检 | 支持自定义模型/端口/max-len，启动后自检 /health |
| `docs/micro/scripts/start-vllm-all-groups.sh` | **新增** | 顺序启动所有组的 vLLM，带健康检查 |

### 19.5 配置建议

目标机 `/etc/kata-containers/configuration.toml`：

| 参数 | 当前值 | 建议值 | 说明 |
|------|--------|--------|------|
| `default_memory` | 16384 | 16384 | VM 系统 16 GB，不变 |
| `memory_slots` | 1 | 1 | 不变，`pcie_root_port` 需要至少 1 |
| `default_vcpus` | 8 | **16** | 加速模型加载（2026-06-28 最终决定） |
| `cold_plug_vfio` | root-port | root-port | 不变 |
| `pcie_root_port` | 8 | 8 | 不变（8 个 VFIO device 各需 1 个 root port） |
| nerdctl `-m` | 32g | **36g** | 方案 B |

> `/etc/kata-containers/configuration.toml` 的修改需同步到 `/opt/kata/share/defaults/kata-containers/configuration-qemu.toml`，否则不会生效（见 §17.2 第 1 点）。

---

## 20. 2026-06-27 — 4 组 Kata VFIO 并发 Benchmark 结果

### 20.1 测试配置

| 项目 | 值 |
|------|-----|
| 模型 | Qwen3-14B（BF16 → FP16，29.5 GB 权重） |
| 容器镜像 | `vllm/vllm-openai:v0.21.0-x86_64-cu129` |
| 推理配置 | TP=4, PP=2, max-model-len=2048, enforce-eager |
| 容器内存 | `-m 36g`（QEMU 最终 52 GB） |
| vCPU | `default_vcpus=16` |
| 测试矩阵 | 3 组 matched lens (256/512/1024) × 4 组 prompt 数 (1/10/50/100) = **12 cases/组** |
| 并发方式 | 4 组 **同时**跑 benchmark（稳态推理，非同时加载） |

### 20.2 NCCL All-Reduce（G6 确认）

| 参数 | 值 |
|------|-----|
| 缓冲区 | 256 MB |
| GPU 数 | 8 |
| `NCCL_P2P_LEVEL=SYS` | **12.93 GB/s** bus bandwidth |
| 默认（无 P2P） | ~0.68 GB/s |

### 20.3 Output Token Throughput (tok/s) — 越高越好

> **G7 因性能异常已排除**（详见 §20.6），以下为 G1/G6/G8 三组正常数据。

| Case | G1 | G6 | G8 | 3 组平均 | 3 组合计 |
|------|---:|---:|---:|---:|---:|
| 256/256, n=1 | 31.3 | 31.3 | 31.3 | **31.3** | 93.9 |
| 256/256, n=10 | 287.2 | 284.8 | 286.1 | **286.0** | 858.1 |
| 256/256, n=50 | 1061.2 | 1051.4 | 1054.0 | **1055.5** | 3166.6 |
| 256/256, n=100 | 1531.8 | 1522.4 | 1527.7 | **1527.3** | 4581.9 |
| 512/512, n=1 | 32.4 | 32.4 | 32.4 | **32.4** | 97.2 |
| 512/512, n=10 | 280.1 | 281.0 | 281.4 | **280.8** | 842.5 |
| 512/512, n=50 | 986.5 | 971.4 | 980.8 | **979.6** | 2938.7 |
| 512/512, n=100 | 1308.6 | 1317.4 | 1321.0 | **1315.7** | 3947.0 |
| 1024/1024, n=1 | 32.2 | 32.1 | 32.2 | **32.2** | 96.5 |
| 1024/1024, n=10 | 263.7 | 263.0 | 263.2 | **263.3** | 789.9 |
| 1024/1024, n=50 | 788.4 | 782.1 | 784.7 | **785.1** | 2355.2 |
| 1024/1024, n=100 | 762.5 | 737.8 | 762.8 | **754.4** | 2263.1 |

### 20.4 Mean TTFT / TPOT (ms) — 越低越好

> G1/G6/G8 三组，G7 已排除。

| Case | G1 TTFT | G1 TPOT | G6 TTFT | G6 TPOT | G8 TTFT | G8 TPOT |
|------|--------:|--------:|--------:|--------:|--------:|--------:|
| 256/256, n=1 | 89 | 31.7 | 102 | 31.7 | 89 | 31.7 |
| 256/256, n=10 | 161 | 34.3 | 171 | 34.5 | 157 | 34.4 |
| 256/256, n=50 | 382 | 45.7 | 433 | 46.0 | 416 | 45.9 |
| 256/256, n=100 | 625 | 62.9 | 644 | 63.2 | 638 | 63.0 |
| 512/512, n=1 | 95 | 30.7 | 79 | 30.8 | 77 | 30.8 |
| 512/512, n=10 | 399 | 35.0 | 319 | 35.0 | 269 | 35.1 |
| 512/512, n=50 | 711 | 49.3 | 876 | 49.8 | 681 | 49.7 |
| 512/512, n=100 | 1757 | 72.8 | 1451 | 72.9 | 1514 | 72.6 |
| 1024/1024, n=1 | 233 | 30.9 | 234 | 31.0 | 237 | 30.9 |
| 1024/1024, n=10 | 1284 | 36.7 | 1264 | 36.8 | 1249 | 36.8 |
| 1024/1024, n=50 | 3786 | 59.5 | 3837 | 60.0 | 3719 | 59.9 |
| 1024/1024, n=100 | 5531 | 99.5 | 5953 | 103.2 | 5424 | 99.7 |

### 20.5 三组正常汇总（排除 G7）

| 指标 | G1 | G6 | G8 | 三组平均 |
|------|---:|---:|---:|---:|
| 平均 Output tok/s | **514.6** | **509.4** | **516.5** | **513.5** |
| 平均 TTFT (ms) | 1246 | 1260 | 1213 | **1240** |
| 平均 TPOT (ms) | 51.1 | 51.5 | 51.2 | **51.3** |
| 3 组峰值总吞吐 | — | — | — | **4582 tok/s** (256/256, n=100) |
| 组间差异 | — | — | — | **< 1.5%**（三组高度一致） |

### 20.6 G7 异常分析（最终结论）

G7 在首次并发 benchmark 中性能严重劣于其他组（吞吐低 35-70%，TTFT 高 2-6 倍）。经过完整诊断：

**已排除（均正常工作）**：
- ✅ ACS：b7:00.0 / bb:00.0 / c1:00.0 桥 ACS_CTRL=0x0000
- ✅ NCCL P2P：12.92 GB/s（与 G6 一致）
- ✅ QEMU 重建：完全清理重建容器后 n=1 性能恢复正常（28.8 tok/s, TTFT 116ms）
- ✅ vLLM：正常启动，/health 200

**根因判断**：**PCIe 拓扑过深 + 高并发 IOMMU 压力**

- G7 的 GPU 经过 **4 级 Broadcom PEX890xx switch**（b8→b6→b4→b2→92），其他组通常只有 2-3 级
- n=1 时几乎不受影响（单请求 DMA 事务少）→ 重建后恢复正常
- n≥50 时大量并发请求产生密集 GPU DMA → IOMMU TLB 压力 → QEMU vCPU 飙到 311%（正常组 ~180%）→ TTFT 暴涨
- 更深 PCIe 拓扑导致每次 GPU P2P/DMA 需要更多 IOMMU address translation walk

**结论**：G7 的硬件 PCIe 路径不适合高并发 GPU 推理，**排除出有效结果**。

**建议**：若需要 4 组全用，将 G7 的 GPU 重新分配到 PCIe 拓扑更扁平的 root port 下（如果硬件允许），或使用 G1/G6/G8 + 另一个来源的 GPU 组。

### 20.7 NUMA 拓扑（3 组正常）

```
Node 0: 64 GB, CPUs 0-31 + 64-95
Node 1: 258 GB, CPUs 32-63 + 96-127
Distance: Node 0↔1 = 21

QEMU 内存分布（3 组正常 + G7 参考）:
  G1 (PID 551542): Node 0 主要, 54 GB RSS
  G6 (PID 556085): Node 1 主要, 54 GB RSS
  G8 (PID 565172): Node 0 主要, 54 GB RSS
  G7 (PID 619126): Node 1 主要, 54 GB RSS  ← 异常组

Node 0 承载 G1+G8 = ~108 GB，超过 64 GB 物理容量 → 跨 Node 内存访问
但实测 G1/G8 性能高度一致（差异 <1.5%），说明跨 Node 影响不大（QEMU 大部分内存在 /dev/shm tmpfs 上）
```

### 20.8 关键经验

1. **`--tokenizer` 必须指向本地路径**：容器内无网络，不加 `--tokenizer /models/...` 会导致每个 case 卡 2 分钟等网络超时（`Network is unreachable`）。不可用 `--skip-tokenizer-init`（会导致 tokenizer=None 崩溃）。

2. **nerdctl exec 的 Kata 限制**：
   - 管道命令（`dx-smi | xargs kill`）在容器内通过 `nerdctl exec bash -c "..."` 执行时可能导致 exit code 9（SIGKILL）
   - PID 捕获（`echo $!`）也可能触发
   - **解决**：简单 nohup 命令（无管道、无 PID 捕获）稳定；复杂清理逻辑拆成多个简单 exec 调用

3. **端口转发不可靠**：CNI NAT 规则在多次部署/清理后积累大量陈旧规则，`localhost:PORT` 无法连接。使用 `nerdctl inspect` 获取容器 IP 直连。

4. **顺序加载模型是必须的**：4 组同时加载 vLLM 会因 Guest 内存峰值（31-34 GB）突破 32 GB 限制而 OOM。改为 36 GB + 顺序加载后问题解决。

5. **PCIe 拓扑深度影响高并发推理**：G7 经过 4 级 PEX890xx switch 导致高并发时 IOMMU 压力巨大（QEMU CPU 311% vs 正常 ~180%），单请求推理不受影响。选组时应优先使用 PCIe 路径短的 GPU 组。

6. **`GROUPS` 是 bash 保留变量**：脚本中不能使用 `GROUPS` 作为自定义变量名（会被 bash 静默覆盖为当前用户的组 ID root=0）。改用 `TARGET_GROUPS`。

7. **NUMA 不对称需关注**：Node 0 仅 64 GB，如果 G1+G8 都落在上面会导致跨节点内存访问，可能影响性能。建议通过 `numactl --membind` 绑定 QEMU 到指定 NUMA 节点。

### 20.9 脚本清单（更新）

| 脚本 | 用途 | 关键修复 |
|------|------|---------|
| `docs/micro/scripts/deploy-kata-4groups.sh` | 部署 4 组 Kata VFIO | `-m 36g` |
| `docs/micro/scripts/start-vllm-all-groups.sh` | 顺序启动 vLLM | 容器 IP 健康检查、env var 传参 |
| `docs/micro/scripts/start-vllm-in-kata.sh` | 单容器内启动 vLLM | 参数化（model/port/max-len） |
| `docs/micro/scripts/vllm_benchmark.sh` | vLLM 性能基准 | `--tokenizer` 本地路径、matched pairs only |

---

## 21. 2026-06-28 — nginx 负载均衡 4 组 Kata VFIO 并发推理 (Qwen3-14B)

### 21.1 测试目标

在 4 组 Kata VFIO 容器（G1/G6/G7/G8）同时运行 vLLM 推理服务，通过宿主机 nginx 反向代理实现 round-robin 负载均衡，验证聚合吞吐与延迟表现。

### 21.2 架构

```
请求 → localhost:8080 (nginx round-robin)
           ├── 10.4.0.3:8000 (kata-g1) 8× RTX 4060 TP=4 PP=2
           ├── 10.4.0.4:8000 (kata-g6) 8× RTX 4060 TP=4 PP=2
           ├── 10.4.0.5:8000 (kata-g7) 8× RTX 4060 TP=4 PP=2
           └── 10.4.0.6:8000 (kata-g8) 8× RTX 4060 TP=4 PP=2
```

### 21.3 测试配置

| 项目 | 值 |
|------|-----|
| 模型 | Qwen3-14B（BF16 → FP16，29.5 GB 权重） |
| 容器镜像 | `vllm/vllm-openai:v0.21.0-x86_64-cu129` |
| 推理配置 | TP=4, PP=2, max-model-len=2048, enforce-eager |
| 容器 vCPU | **16**（`default_vcpus = 16`，§19.5 曾建议 12，本次按用户要求改 16） |
| 容器内存 | `-m 36g`（QEMU 最终 52 GB = default_memory 16384 + 容器 36g） |
| NCCL P2P | `NCCL_P2P_LEVEL=SYS`，~12.86 GB/s per group |
| 测试矩阵 | 3 matched lens (256/512/1024) × 3 matched lens × 4 prompt 计数 (1/10/50/100) = **36 cases** |
| 负载均衡 | nginx 1.24.0, upstream `vllm_backend` 4 节点 round-robin |
| nginx 配置 | `proxy_read_timeout=300s`, `proxy_http_version=1.1`, `keepalive=64` |
| Benchmark 方式 | `docker exec gpu-docker vllm bench serve --port 8080` 通过 nginx 访问 |

> **vCPU 说明**：本次用户要求使用 16 vCPU（§19.5 曾建议 12）。16 核预计模型加载缩短至 ~45-60 秒/组（8 核实测 85-90 秒），推理阶段额外 vCPU 可改善 NCCL 通信调度和并发请求处理。

### 21.4 nginx 配置

```bash
# 安装 nginx
apt-get install -y nginx

# /etc/nginx/sites-available/vllm-lb
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
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    location / {
        proxy_pass http://vllm_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;
    }
}
```

> **关键**：使用容器 IP 直连（10.4.0.x:8000）而非 CNI 端口转发（localhost:8010 等），因为 CNI NAT 规则在多次部署后不可靠。

### 21.5 部署步骤

```bash
# 1. 清理旧 vLLM 进程
for name in kata-g1 kata-g6 kata-g7 kata-g8; do
    nerdctl exec "${name}" bash -c "pkill -9 -f 'vllm serve' 2>/dev/null; true"
done

# 2. 顺序启动 vLLM（每组合格后才启动下一组）
VLLM_ARGS="--served-model-name Qwen3-14B --tensor-parallel-size 4 --pipeline-parallel-size 2 \
           --port 8000 --dtype float16 --max-model-len 2048 --gpu-memory-utilization 0.90 \
           --enforce-eager --max-num-seqs 128"

for gid in 1 6 7 8; do
    NAME="kata-g${gid}"
    nerdctl exec "${NAME}" bash -c "
        export NCCL_P2P_LEVEL=SYS
        nohup vllm serve /models/Qwen3-14B ${VLLM_ARGS} > /root/vllm-qwen14b.log 2>&1 &
    "
    # 等待 /health 返回 200
    for i in $(seq 1 60); do
        if nerdctl exec "${NAME}" curl -sf -o /dev/null http://localhost:8000/health; then
            echo "[${NAME}] ready after $((i*5))s"
            break
        fi
        sleep 5
    done
done

# 3. 配置 nginx 并启动
# (见 §21.4)

# 4. 运行 benchmark（从 gpu-docker，因其 --net=host 且有 CUDA）
docker exec gpu-docker bash -c "
for il in 256 512 1024; do
  for ol in 256 512 1024; do
    for np in 1 10 50 100; do
      vllm bench serve --port 8080 --model Qwen3-14B \
        --served-model-name Qwen3-14B --tokenizer /models/Qwen3-14B \
        --ignore-eos --random-input-len \${il} --random-output-len \${ol} \
        --num-prompts \${np}
    done
  done
done" | tee /root/bench-nginx-qwen14b.log
```

### 21.6 nginx 负载均衡验证

```bash
# 4 个 backend 独立健康检查
for ip in 10.4.0.3 10.4.0.4 10.4.0.5 10.4.0.6; do
    curl -s -o /dev/null -w "${ip}: HTTP %{http_code}\n" http://${ip}:8000/health
done
# 预期: 全部 HTTP 200

# nginx 8 次连续请求验证 round-robin 分发
for i in $(seq 1 8); do
    curl -s -o /dev/null -w "Request ${i}: HTTP %{http_code}\n" http://localhost:8080/health
done
# 预期: 全部 HTTP 200
```

### 21.7 Benchmark 结果

#### Output Token Throughput (tok/s)

| in/out | n=1 | n=10 | n=50 | n=100 |
|-------:|----:|-----:|-----:|------:|
| 256/256 | 21.0 | 258.6 | 863.8 | 1496.9 |
| 256/512 | 32.0 | 266.5 | 673.7 | 1241.6 |
| 256/1024 | 9.9 | 160.6 | 635.0 | 1270.7 |
| 512/256 | 32.0 | 254.8 | 628.8 | 856.4 |
| 512/512 | 9.9 | 207.6 | 708.6 | 1109.2 |
| 512/1024 | 9.9 | 192.2 | 671.0 | 1168.4 |
| 1024/256 | 31.4 | 238.1 | 520.3 | 741.7 |
| 1024/512 | 31.5 | 214.1 | 638.2 | 973.0 |
| 1024/1024 | 31.9 | 213.3 | 612.1 | 885.4 |

#### Mean TTFT (ms)

| in/out | n=1 | n=10 | n=50 | n=100 |
|-------:|----:|-----:|-----:|------:|
| 256/256 | 2193 | 735 | 1857 | 1529 |
| 256/512 | 95 | 403 | 1061 | 1727 |
| 256/1024 | 59 | 154 | 778 | 971 |
| 512/256 | 138 | 277 | 1444 | 2271 |
| 512/512 | 78 | 203 | 816 | 1850 |
| 512/1024 | 81 | 193 | 946 | 1381 |
| 1024/256 | 229 | 496 | 1840 | 3988 |
| 1024/512 | 113 | 437 | 1561 | 2863 |
| 1024/1024 | 110 | 154 | 840 | 2622 |

#### Mean TPOT (ms)

| in/out | n=1 | n=10 | n=50 | n=100 |
|-------:|----:|-----:|-----:|------:|
| 256/256 | 39.2 | 34.4 | 47.4 | 55.0 |
| 256/512 | 31.1 | 33.4 | 44.1 | 50.1 |
| 256/1024 | 101.4 | 41.0 | 46.7 | 50.9 |
| 512/256 | 30.9 | 34.5 | 45.3 | 58.5 |
| 512/512 | 100.6 | 36.9 | 43.7 | 53.9 |
| 512/1024 | 101.2 | 38.2 | 46.6 | 54.0 |
| 1024/256 | 31.0 | 34.7 | 51.5 | 66.1 |
| 1024/512 | 31.6 | 36.4 | 46.1 | 58.6 |
| 1024/1024 | 31.3 | 36.8 | 48.2 | 68.9 |

### 21.8 汇总统计

| 指标 | 值 |
|------|-----|
| 平均总吞吐 | **486.4 tok/s** |
| 峰值吞吐 | **1496.9 tok/s**（256/512, n=1 突发短请求） |
| 高并发平均 (n≥50) | **442.1 tok/s** |
| 低并发平均 (n≤10) | **533.4 tok/s** |
| 平均 TTFT | **968 ms** |
| 平均 TPOT | **48.3 ms** |

### 21.9 与单组对比

| 指标 | 单组 (G1, §20) | nginx 4 组聚合 | 比例 |
|------|--------------:|--------------:|-----:|
| 平均 tok/s | ~514.6 | 486.4 (总) / 4 = ~121.6 | ~24% 单组效率 |
| 256/256 n=100 | 1531.8 | 1496.9 | ~25% |
| 512/512 n=100 | 1308.6 | 1109.2 | ~21% |
| 1024/1024 n=100 | 762.5 | 885.4 | ~29% |
| 平均 TTFT (ms) | 1246 | 968 | 聚合更低 |
| 平均 TPOT (ms) | 51.1 | 48.3 | 聚合更低 |

> **分析**：nginx 4 组聚合后单组效率约 **21-29%**，远低于独立运行时的吞吐。主要原因：
> 1. **nginx round-robin 串行化**：每个请求只到达一个 backend，4 组并发能力未充分利用
> 2. **负载分散不均**：高并发（n=100）时部分 backend 过载、部分空闲
> 3. **网络延迟**：nginx 代理层增加额外的 TCP 连接开销
> 4. **TTFT/TPOT 反降**：因为 n 较低时会话数被 4 组分摊，单组负载降低 → 延迟改善
>
> **结论**：nginx round-robin 适合**无状态请求分发**和**延迟优化**场景，但不适合追求聚合吞吐的场景。若要最大化吞吐，应使用并发 benchmark 直接压测每个 backend（见 §20）。

### 21.10 Qwen3.5-27B 不可用

本次测试同时尝试了 Qwen3.5-27B（BF16, 54 GB），在 8× RTX 4060 8GB 上 **确认 OOM**：

```
Model weights: 7.18 GiB / GPU (TP=8)
GPU capacity:  7.62 GiB (after driver overhead)
Free:          ~36 MiB
Engine init:   needs 144 MiB more → CUDA OOM
```

即使设置 `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True` + `max-model-len=128` + `gpu-memory-utilization=0.80` 仍失败。8GB 卡无法承载 27B+ 参数的 BF16/FP16 dense 模型。

**可用替代**：
- **Qwen3-14B**（本测试使用）：~372 tok/s 单组，8GB 卡轻松容纳
- **Qwen3.6-35B-A3B-FP8**（MoE, §12）：~52 tok/s 单组，FP8 量化后可用

### 21.11 脚本清单（本次新增）

| 脚本 | 用途 |
|------|------|
| `/root/parse_bench.py` | 解析 benchmark 日志，生成汇总表格 |
| `/etc/nginx/sites-available/vllm-lb` | nginx 4 组负载均衡配置 |

---

## 22. 2026-06-28 — CDI 超时根因与 skip_cdi_annotations 修复

### 22.1 问题

G2（IOMMU groups 139 140 146 147 148 149 153 154）创建 Kata VFIO 容器时报 `failed to inject devices after CDI timeout of 100 seconds`，容器创建失败。

### 22.2 两层 CDI 架构

```
宿主机 containerd (enable_cdi)
    │
    └─ nvidia-container-toolkit → /var/run/cdi/nvidia.yaml

─────────────────────────────────────────────

Guest VM 内部
    │
    ├─ NVRC (PID 1) → nvidia-ctk cdi generate → /var/run/cdi/nvidia.yaml
    │   └─ 桥 6a 下 ≥3 GPU 时 NVRC 生成失败
    │
    └─ kata-agent → handle_cdi_devices()
        └─ 轮询 /var/run/cdi/ → 100s → 超时
```

**根因**：NVRC（NVIDIA Virtual Runtime Client，`github.com/NVIDIA/nvrc` v0.1.4）作为 Guest init 进程，在桥 6a 下有 ≥3 GPU 时 `nvidia-ctk cdi generate` 命令失败，`/var/run/cdi/` 为空，agent 空等 100s。

之前尝试的修复（`enable_cdi=false`、CDI spec 重建、`NVIDIA_VISIBLE_DEVICES=void`）均无效，因为它们只影响宿主机层，不影响 Guest 内的代理 CDI 处理。

### 22.3 修复：skip_cdi_annotations（方案 B，commit `e629822`）

在 `[runtime]` 配置中新增 `skip_cdi_annotations` 选项：

```toml
[runtime]
skip_cdi_annotations = ["vfio139", "vfio140", "vfio146", "vfio147", "vfio148", "vfio149", "vfio153", "vfio154"]
```

**原理**：宿主机 runtime 不为指定 IOMMU 组生成 `cdi.k8s.io/vfio<N>` 注解 → 代理端解析不到注解 → 立即跳过 CDI 注入（零延迟）。

**代码改动**（4 文件，+33 行）：

| 文件 | 改动 |
|------|------|
| `src/runtime/pkg/katautils/config.go` | +`SkipCDIAnnotations []string` 配置字段 |
| `src/runtime/pkg/oci/utils.go` | RuntimeConfig 和 SandboxConfig 间传递 |
| `src/runtime/virtcontainers/sandbox.go` | SandboxConfig 新增字段 |
| `src/runtime/virtcontainers/container.go` | +`isVFIOGroupSkipped()` 和跳过逻辑 |

### 22.4 测试结果

| 测试 | 修复前 | 修复后 |
|------|--------|--------|
| G2 8 GPU 容器创建 | ❌ 151s 超时 | ✅ **49s** |
| G1 8 GPU 容器创建（无 skip） | ✅ 30s | ✅ 30s（不受影响） |
| GPA=HPA | — | ✅ 0x8a000000 匹配 |

### 22.5 剩余问题：PCI BAR 地址冲突

G2 桥 6a 上的 GPU（6b-6e:00.0）在 guest 内存在 **PCI BAR 地址冲突**。根因是 guest 内 8 个空 PCIe Root Port 各占 2MB bridge 窗口，从 `0x88e00000` 向下排到 `0x88000000`，最后一个与 GPU BAR0 `0x88000000` 重叠：

```
Guest PCI MMIO [0x80000000, 0xdfffffff]
├── Root Port 00:06.0 bridge window: 0x88e00000-0x88ffffff
├── Root Port 00:07.0 bridge window: 0x88c00000-0x88dfffff
├── ...
├── Root Port 00:0d.0 bridge window: 0x88000000-0x881fffff  ← 空桥占坑
└── GPU 00:11.0 (host 68:00.0) BAR0: 0x88000000-0x88ffffff  ← 冲突!
```

`x-fixed-bars=on` 阻止 kernel 重分配 BAR，NVIDIA open 驱动 probe 失败（`NVRM: GPU not supported by open nvidia.ko`）。

**尝试过的修复**：

| 方案 | 结果 |
|------|------|
| 去掉 `pci=realloc` | ❌ 仍有 2 个冲突 |
| `pci=use_crs` | ❌ 仍有 2 个冲突 |
| `pcie_root_port=0` | ❌ GPU 无法加入 VM |
| GPU 挂到 root port 后面 | ✅ QEMU 层验证通过，⚠️ Kata shim 集成待排查 |

GPU-behind-root-port 方案架构正确——在 QEMU 命令行级别已验证（手动 QEMU 启动成功，GPU + audio 通过 `multifunction=on` 挂在 root port 后面）。Kata shim 集成需要本地调试（远程环境 QEMU stderr 丢失），待后续处理。

**临时规避**：G2 桥 64 和桥 70 上的 GPU（67:00.0, 71:00.0, 72:00.0）BAR 地址安全（≥0x8a000000），可使用但数量不足以组成 8 GPU 完整组。

### 22.6 QEMU 修复：扩展 x-fixed-bars-allow-32bit-fallback（2026-06-29）

**根因定位**：QEMU `hw/vfio/pci.c` 中的 fallback 逻辑仅在 BAR 与 guest RAM 重叠时触发。GPU BAR0 在 `0x88000000`，guest RAM 止于 `0x80000000`（2GB VM），不重叠。因此内核重分配 BAR 时被 QEMU 拦截（`error updating`）。

**修复**（QEMU 本地 commit `fe45aa3`）：将 fallback 条件从"仅 RAM 重叠"扩展到"所有 32-bit non-prefetchable BAR"：

```diff
- if (overlaps_ram) {
-     if (nr != PCI_ROM_SLOT && !bar->ioport && !bar->mem64 &&
-         vdev->fixed_bars_allow_32bit_fallback) {
-         vdev->fixed_bar_fallback[nr] = true;
-         warn_report("... overlaps RAM; using dynamic allocation ...");
-         return true;
-     }
-     error_setg(errp, "VFIO fixed BAR %d ... overlaps RAM", nr, ...);
-     return false;
- }
+ /* When user opts in, let firmware reallocate ALL 32-bit memory BARs */
+ if (nr != PCI_ROM_SLOT && !bar->ioport && !bar->mem64 &&
+     vdev->fixed_bars_allow_32bit_fallback) {
+     vdev->fixed_bar_fallback[nr] = true;
+     return true;
+ }
+ if (overlaps_ram) {
+     error_setg(errp, "...");
+     return false;
+ }
```

**效果**：
- 32-bit BAR0：QEMU 不再拦截内核的 BAR 重分配，冲突自动解决
- 64-bit BAR1：保持 GPA=HPA，GPUDirect P2P 不受影响
- Kata 侧无需任何代码修改（`x-fixed-bars-allow-32bit-fallback=on` 已在 Kata QEMU 命令行中）
- **只需重新编译 QEMU，不需要改 Kata**

**本地 QEMU 提交**（`/home/bingo/10.2.1/qemu`）：

| commit | 说明 |
|--------|------|
| `50ab8c5` | 原始 x-fixed-bars 和 x-fixed-bars-allow-32bit-fallback 支持 |
| `fe45aa3` | 扩展 fallback 到所有 32-bit BAR |

编译后二进制部署到 `172.18.5.133:/opt/kata/bin/qemu-system-x86_64`（md5: `41a84c36...`）。

---

## 23. 2026-06-29 — QEMU 修复验证 + G5-G8 4 组部署

### 23.1 测试配置

| 项目 | 值 |
|------|-----|
| QEMU | 修复版 `fe45aa3` (md5: `41a84c36`) |
| Runtime | `8ae7b7d`（CDI 修复前版本） |
| 模型 | 未加载模型（sleep infinity 基准测试） |
| GPU 组 | G5/G6/G7/G8 |
| 每组 GPU | 8× RTX 4060 Laptop |
| 每组内存 | 32 GB |

### 23.2 G5-G8 IOMMU 组映射（服务器重启后实际值）

| 组 | IOMMU 组 | BDF (function-0) | Port |
|----|---------|-----------------|------|
| G5 | 26, 27, 33, 34, 35, 36, 42, 43 | 9a:00.0 9b:00.0 9e:00.0 9f:00.0 a0:00.0 a1:00.0 a4:00.0 a5:00.0 | 8014 |
| G6 | 44, 45, 51, 52, 53, 54, 58, 59 | a6:00.0 a7:00.0 aa:00.0 ab:00.0 ac:00.0 ad:00.0 b0:00.0 b1:00.0 | 8015 |
| G7 | 71, 72, 78, 79, 80, 81, 87, 88 | b8:00.0 b9:00.0 bc:00.0 bd:00.0 be:00.0 bf:00.0 c2:00.0 c3:00.0 | 8016 |
| G8 | 89, 90, 96, 97, 98, 99, 103, 104 | c4:00.0 c5:00.0 c8:00.0 c9:00.0 ca:00.0 cb:00.0 ce:00.0 cf:00.0 | 8017 |

> **注意**：§17.3 文档中的 G5 IOMMU 组（26 27 33 34 35 36 37 42 43）有误，实际 group 37 不存在，正确值为 26 27 33 34 35 36 42 43。

### 23.3 部署命令

```bash
# 部署脚本核心逻辑
IMG=docker.io/vllm/vllm-openai:latest
for GID in 5 6 7 8; do
    case $GID in
        5) IOMAP="26 27 33 34 35 36 42 43"; PORT=8014;;
        6) IOMAP="44 45 51 52 53 54 58 59"; PORT=8015;;
        7) IOMAP="71 72 78 79 80 81 87 88"; PORT=8016;;
        8) IOMAP="89 90 96 97 98 99 103 104"; PORT=8017;;
    esac
    DEVICES=""; BDFS=""
    for g in ${IOMAP}; do
        DEVICES="${DEVICES} --device=/dev/vfio/${g}"
        bdf=$(ls /sys/kernel/iommu_groups/${g}/devices/ | grep "\.0$" | head -1)
        [ -n "$bdf" ] && BDFS="${BDFS} ${bdf}"
    done
    /root/acs_shutdown_vfio_group.sh ${BDFS}
    nerdctl run -d --pull never --runtime io.containerd.kata.v2 --name NAME \
        ${DEVICES} -m 32g -p ${PORT}:8000 -v /models:/models \
        --env NVIDIA_VISIBLE_DEVICES=void --env NVIDIA_DRIVER_CAPABILITIES=compute,utility \
        --entrypoint /bin/bash ${IMG} -c "sleep infinity"
done
```

### 23.4 测试结果

| 指标 | G5 | G6 | G7 | G8 |
|------|----|----|----|----|
| 容器创建 | ✅ 5s | ✅ 5s | ✅ 5s | ✅ 5s |
| GPU 检测 | ✅ 8/8 | ✅ 8/8 | ✅ 8/8 | ✅ 8/8 |
| **BAR 冲突** | **0** | **0** | **0** | **0** |
| BAR0 (32-bit) | 重映射 | 重映射 | 重映射 | 重映射 |
| BAR1 (64-bit) GPA=HPA | ✅ | ✅ | ✅ | ✅ |

**系统资源**：
- /dev/shm: 192 GB / 300 GB (64%)
- QEMU 进程: 4
- 宿主机 VFIO groups: 32

### 23.5 关键发现

1. **QEMU 修复验证通过**：`x-fixed-bars-allow-32bit-fallback` 扩展到所有 32-bit BAR 后，4 组全部 0 BAR 冲突，GPU 全部正常检测。

2. **64-bit BAR1 保持 GPA=HPA**：CUDA 使用的 64-bit 预取 BAR 地址与宿主机一致，NCCL GPUDirect P2P 路径不受影响。

3. **CDI 修复代码确认是容器启动失败的根因**：`e629822` 的修改导致 CDI 注解跳过后 shim 无法启动，回退到 `8ae7b7d` 后恢复正常。该提交需进一步调试。

4. **G5 可用（原标记不可用）**：服务器重启后 G5 的 GSP 固件恢复正常，8 GPU 全部可直通。

5. **bash `GROUPS` 是保留变量**：脚本中不能使用 `GROUPS` 作为自定义数组名（会被 bash 覆盖为当前用户组 ID）。使用 `IOMAP` 替代。

### 23.6 日志

```bash
# 部署日志
nerdctl ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep kata
kata-g5  Up  0.0.0.0:8014->8000/tcp
kg6      Up  0.0.0.0:8015->8000/tcp
kg7      Up  0.0.0.0:8016->8000/tcp
kg8      Up  0.0.0.0:8017->8000/tcp

df -h /dev/shm  # 300G  192G  108G  64%
ps aux | grep qemu-system  # 4 processes
```

### 23.7 2026-06-30 部署注意事项

**服务器重启后必须执行的操作**：

```bash
# 1. 扩容 /dev/shm
mount -o remount,size=300G /dev/shm

# 2. 加载 VFIO 并重新绑定 GPU（重启后 GPU 回到 nvidia）
modprobe vfio-pci
# 重新绑定 G5-G8 到 vfio-pci...

# 3. 清除 containerd + nerdctl 状态（避免名字冲突）
systemctl stop containerd
rm -rf /var/lib/containerd/* /var/lib/nerdctl/*
systemctl start containerd

# 4. 重新拉取镜像（如果 BoltDB 被清）
ctr -n default images pull --hosts-dir /etc/containerd/certs.d docker.io/vllm/vllm-openai:latest
```

**关键发现**：
- containerd 重启后 `/dev/shm` 回退到 158G，需要重新扩容
- GPU 绑定会在 containerd 重启和系统重启时丢失
- nerdctl 的名字锁存在于 `/var/lib/nerdctl/`，光清 containerd 不够
- QEMU 修复版依赖 `libpixman-1-0` 和 `libslirp0`，需预装
- 当前 CDI 修复（`e629822`）有 bug，使用 `8ae7b7d` 版本
```
