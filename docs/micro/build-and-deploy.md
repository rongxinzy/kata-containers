# Kata 二进制手动编译与部署指南

**目标读者**: 开发/运维人员  
**用途**: 在本地编译 Kata Runtime、QEMU 并部署到目标服务器  

---

## 1. 源码位置

| 组件 | 本地路径 | 语言 |
|------|---------|------|
| Kata Runtime (Go) | `/home/bingo/kata-containers/src/runtime` | Go |
| QEMU (BAR 修复版) | `/home/bingo/10.2.1/qemu` | C |
| OVMF (UEFI 固件) | `/home/bingo/kata-ovmf/edk2` | C/ASM |
| 部署脚本 | `/home/bingo/kata-containers/docs/micro/scripts/` | Bash |

---

## 2. 编译 Kata Runtime

### 2.1 关键提交

当前分支 `vfio-fixed-bar-gpa-hpa-multifunction` 上的有效提交（供参考）：

```bash
cd /home/bingo/kata-containers

# 当前使用的版本（不含 CDI 修复，CDI 修复有 bug）
git log --oneline -1 8ae7b7d
# 8ae7b7d runtime: Enable NVIDIA GPUDirect P2P for VFIO fixed-BAR GPU passthrough
```

> **注意**: CDI 修复提交 `e629822`（`skip_cdi_annotations`）会导致容器无法启动，**不要使用**。

### 2.2 编译命令

```bash
cd /home/bingo/kata-containers/src/runtime
export PATH="/usr/local/go/bin:$PATH"
make

# 产物:
#   src/runtime/kata-runtime
#   src/runtime/containerd-shim-kata-v2
#   src/runtime/kata-monitor
```

### 2.3 仅编译 shim（更快）

```bash
cd /home/bingo/kata-containers/src/runtime
export PATH="/usr/local/go/bin:$PATH"
make containerd-shim-v2
```

---

## 3. 编译 QEMU

### 3.1 BAR 修复说明

我们修改了 QEMU 的 `hw/vfio/pci.c`，将 `x-fixed-bars-allow-32bit-fallback` 的触发条件从"仅 RAM 重叠"扩展到"所有 32-bit BAR"，解决了 GPU BAR0 与空 PCIe root port bridge 窗口冲突的问题。

**QEMU 关键提交**（`/home/bingo/10.2.1/qemu`）：

| commit | 说明 |
|--------|------|
| `50ab8c5` | 原始 `x-fixed-bars` 和 `x-fixed-bars-allow-32bit-fallback` 支持 |
| `fe45aa3` | **扩展 fallback 到所有 32-bit BAR**（核心修复） |

### 3.2 编译命令（Docker 容器内编译，glibc 2.35 兼容）

QEMU 动态链接 glibc，本地（Ubuntu 24.04, glibc 2.38）编译的二进制无法在目标服务器（Ubuntu 22.04, glibc 2.35）运行。使用 Ubuntu 22.04 Docker 容器编译可确保 glibc 兼容：

```bash
# 一次性编译
docker run --rm \
    -v /home/bingo/10.2.1/qemu:/src \
    -v /tmp/qemu-out:/out \
    ubuntu:22.04 bash -c '
        apt update -qq && apt install -y -qq \
            build-essential ninja-build pkg-config \
            libglib2.0-dev libpixman-1-dev libslirp-dev libfdt-dev \
            python3-venv python3-tomli && \
        cd /src && rm -rf build && mkdir build && cd build && \
        ../configure --target-list=x86_64-softmmu --enable-slirp --disable-werror && \
        make -j$(nproc) && \
        cp qemu-system-x86_64 /out/
    '

# 产物: /tmp/qemu-out/qemu-system-x86_64
```

编译完成后，复制到 Kata 标准路径并生成 tarball：

```bash
DEST=tools/packaging/kata-deploy/local-build/build/qemu/destdir/opt/kata/bin
mkdir -p ${DEST}
cp /tmp/qemu-out/qemu-system-x86_64 ${DEST}/

# 生成 tarball（部署用）
cd tools/packaging/kata-deploy/local-build/build/qemu/destdir
tar -czf ../../../../static-build/qemu/kata-static-qemu.tar.gz opt/
```

### 3.3 验证编译成功

```bash
# 确认版本包含修复
strings /home/bingo/10.2.1/qemu/build/qemu-system-x86_64 | grep -c "fixed_bar_fallback"
# 预期输出: > 0
```

---

## 4. 编译 OVMF

### 4.1 为什么需要部署 OVMF

OVMF（Open Virtual Machine Firmware）是 QEMU 虚拟机的 UEFI 固件。**必须使用打了 `ProgramBar` 补丁的版本**，否则 `x-fixed-bars=on` 时 guest 会在 UEFI 初始化阶段挂死（QEMU 100% CPU）。

如果 QEMU 命令行中 `-bios /opt/kata/share/ovmf/OVMF.fd` 指向的 OVMF 不是补丁版，会出现：
```
Guest hangs at UEFI splash screen, QEMU 100% CPU, no kernel output
```

### 4.2 源码位置

```
/home/bingo/kata-ovmf/edk2    ← EDK2 源码（edk2-stable202508）
```

补丁由 Kata 构建脚本自动应用：
```
/home/bingo/kata-containers/tools/packaging/static-build/ovmf/build-ovmf.sh
```

### 4.3 编译命令

```bash
cd /home/bingo/kata-containers/tools/packaging/static-build/ovmf
bash build-ovmf.sh
```

### 4.4 产物位置

```
tools/packaging/kata-deploy/local-build/build/ovmf/destdir/opt/kata/share/ovmf/OVMF.fd
```

---

## 5. 部署到目标服务器

### 4.1 环境变量

```bash
export TARGET_HOST=172.18.5.133
export TARGET_USER=root
export TARGET_PASS=Admin@9000
```

### 4.2 部署 Kata Runtime

```bash
# 先停止所有 Kata 容器（否则 shim 文件被占用）
ssh root@${TARGET_HOST} "
    for name in \$(nerdctl ps -a --format '{{.Names}}' | grep kata); do
        nerdctl rm -f \$name 2>/dev/null || true
    done
    pkill -9 containerd-shim qemu-system 2>/dev/null || true
    sleep 2
"

# 备份旧文件
ssh root@${TARGET_HOST} "
    cp /opt/kata/bin/containerd-shim-kata-v2 /opt/kata/bin/containerd-shim-kata-v2.bak
    cp /opt/kata/bin/kata-runtime /opt/kata/bin/kata-runtime.bak
"

# 复制新文件
scp src/runtime/containerd-shim-kata-v2 root@${TARGET_HOST}:/opt/kata/bin/
scp src/runtime/kata-runtime root@${TARGET_HOST}:/opt/kata/bin/

# 设置权限
ssh root@${TARGET_HOST} "chmod +x /opt/kata/bin/containerd-shim-kata-v2 /opt/kata/bin/kata-runtime"
```

### 5.2 部署 QEMU

```bash
# 方式 A: 直接复制二进制
scp tools/packaging/kata-deploy/local-build/build/qemu/destdir/opt/kata/bin/qemu-system-x86_64 \
    root@${TARGET_HOST}:/opt/kata/bin/

# 方式 B: 用 tarball 部署（推荐）
scp tools/packaging/static-build/qemu/kata-static-qemu.tar.gz \
    root@${TARGET_HOST}:/tmp/
ssh root@${TARGET_HOST} "cd / && tar -xzf /tmp/kata-static-qemu.tar.gz"

# 设置权限 + 安装运行时依赖
ssh root@${TARGET_HOST} "
    chmod +x /opt/kata/bin/qemu-system-x86_64
    apt-get install -y libpixman-1-0 libslirp0 libfdt1
"

# 验证无缺失库
ssh root@${TARGET_HOST} "ldd /opt/kata/bin/qemu-system-x86_64 | grep 'not found' || echo 'All libraries OK'"
```

### 5.3 部署 OVMF

```bash
# 备份旧文件
ssh root@${TARGET_HOST} "
    cp /opt/kata/share/ovmf/OVMF.fd /opt/kata/share/ovmf/OVMF.fd.bak 2>/dev/null || true
"

# 复制新文件
scp tools/packaging/kata-deploy/local-build/build/ovmf/destdir/opt/kata/share/ovmf/OVMF.fd \
    root@${TARGET_HOST}:/opt/kata/share/ovmf/OVMF.fd

# 设置权限
ssh root@${TARGET_HOST} "chmod 644 /opt/kata/share/ovmf/OVMF.fd"
```

### 5.4 部署后操作

```bash
# 重启 containerd
ssh root@${TARGET_HOST} "systemctl restart containerd"

# 验证版本
ssh root@${TARGET_HOST} "
    /opt/kata/bin/qemu-system-x86_64 --version | head -1
    /opt/kata/bin/kata-runtime --version
"
```

### 5.5 16 GPU 宿主机配置

16 GPU 单容器部署需要额外配置：

```bash
ssh root@${TARGET_HOST} "
    # 1. 设置 GPU FLR（避免 VFIO bus reset 超时）
    for iommu in \$(cat /tmp/kata-iommu-groups.txt); do
        for dev in \$(ls /sys/kernel/iommu_groups/\$iommu/devices/ | grep '\.0\$'); do
            echo flr > /sys/bus/pci/devices/\$dev/reset_method
        done
    done

    # 2. 增大 vhost 内存区域上限（16 GPU ~100 区域 > 默认 64）
    modprobe -r vhost_vsock vhost_net vhost 2>/dev/null
    modprobe vhost max_mem_regions=256
    modprobe vhost_vsock
    modprobe vhost_net

    # 验证
    cat /sys/module/vhost/parameters/max_mem_regions  # → 256

    # 3. 增加 kata agent 超时
    sed -i 's|agent.launch_process_timeout=[0-9]*|agent.launch_process_timeout=120|' \\
        /etc/kata-containers/configuration.toml
"
```

> 详细排查记录见 `test-single-16.md`。

---

## 6. 验证部署

### 6.1 快速功能测试

```bash
ssh root@${TARGET_HOST} "
    nerdctl run --rm --runtime io.containerd.kata.v2 alpine:latest echo OK
"
# 预期: OK
```

### 6.2 GPU 直通测试

```bash
# 先绑定 GPU，再启动容器
ssh root@${TARGET_HOST} "bash /path/to/bind-gpu.sh"
ssh root@${TARGET_HOST} "
    nerdctl run --rm --pull never --runtime io.containerd.kata.v2 \
        --device=/dev/vfio/139 -m 4g \
        --env NVIDIA_VISIBLE_DEVICES=void \
        --env NVIDIA_DRIVER_CAPABILITIES=compute,utility \
        --entrypoint nvidia-smi \
        docker.io/vllm/vllm-openai:latest -L
"
# 预期: 显示 1 张 RTX 4060
```

### 6.3 BAR 冲突验证

```bash
ssh root@${TARGET_HOST} "
    SANDBOX_ID=\$(nerdctl ps -a --format '{{.ID}}' | head -1)
    nerdctl exec \$SANDBOX_ID dmesg | grep -c 'can.t claim'
"
# 预期: 0
```

---

## 7. 回滚

```bash
# 恢复旧版本
ssh root@${TARGET_HOST} "
    cp /opt/kata/bin/containerd-shim-kata-v2.bak /opt/kata/bin/containerd-shim-kata-v2
    cp /opt/kata/bin/kata-runtime.bak /opt/kata/bin/kata-runtime
    # QEMU 从原始 tarball 恢复:
    cd / && tar -xzf /tmp/kata-static-qemu-original.tar.gz
"
ssh root@${TARGET_HOST} "systemctl restart containerd"
```

---

## 8. 常见问题

| 问题 | 处理 |
|------|------|
| `scp: dest open ... Failure` | shim 文件被占用，先停止所有 Kata 容器 |
| QEMU 缺库（`libpixman`, `libslirp`, `libfdt` not found） | `apt-get install -y libpixman-1-0 libslirp0 libfdt1` |
| 容器 `Created` 不启动 | containerd 状态残留，清空 `/var/lib/containerd/*` |
| 新 QEMU 不生效 | 确认 `chmod +x` 后 `systemctl restart containerd` |
| `GLIBC_2.38 not found` / `SLIRP_4.7 not found` | 见 §8.1 |
| 16 GPU QEMU 启动时卡死在 VFIO reset | `echo flr > /sys/bus/pci/devices/<BDF>/reset_method` |
| 16 GPU 容器超时 (vhost error 7) | `modprobe vhost max_mem_regions=256` |
| NCCL P2P 带宽低（~2 GB/s） | 设置容器环境变量 `NCCL_P2P_LEVEL=5` |

### 8.1 glibc 版本不兼容

如果部署时遇到：

```
/opt/kata/bin/qemu-system-x86_64: version `GLIBC_2.38' not found
/opt/kata/bin/qemu-system-x86_64: version `SLIRP_4.7' not found
```

说明 QEMU 在比目标服务器更新的 glibc 环境中编译。**按 §3.2 的 Docker 方式重新编译即可**——Ubuntu 22.04 容器产出的二进制直接兼容 22.04 目标服务器。

---

## 9. 完整脚本（一键部署）

参考 `docs/micro/scripts/run-all.sh`，它组合了 GPU 绑定、Kata 配置、容器部署、vLLM 启动和验证。
