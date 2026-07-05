# Kata Containers VFIO Fixed-BAR GPA=HPA GPU Passthrough

This document describes the changes made to Kata Containers 3.29 to support VFIO fixed-BAR passthrough, enabling GPU devices inside a Kata Pod to use the same guest physical addresses (GPA) as their host physical addresses (HPA). This is required for GPU P2P communication (e.g., NCCL) across multiple passthrough GPUs.

## Background

By default, QEMU/OVMF reassigns PCI BAR addresses during guest boot. For passthrough GPUs, the 64-bit prefetchable BAR (BAR1) holds the GPU frame-buffer aperture. If the guest BAR1 differs from the host BAR1, GPU P2P and NVLink/NCCL may fail or fall back to slower sysmem copies.

The fixed-BAR feature preserves host BAR addresses in the guest:

- QEMU property `x-fixed-bars=on`: preset host BAR addresses into PCI config space and reject firmware overrides.
- QEMU property `x-fixed-bars-allow-32bit-fallback=on`: allow 32-bit non-prefetchable BARs to fall back to dynamic allocation when they overlap guest RAM (32-bit BARs cannot be placed above 4GB).

OVMF must also cooperate: its `ProgramBar()` function must not overwrite a BAR that is already preset. A patch in `MdeModulePkg/Bus/Pci/PciBusDxe/PciResourceSupport.c` achieves this.

## Changes to Kata Source

All changes are in the Kata Containers source tree at `/home/bingo/kata-containers`.

### 1. QEMU patch

File:
- `tools/packaging/qemu/patches/tag_patches/v10.2.1/0001-vfio-pci-fixed-BAR-support-for-QEMU-10.2.1.patch`

This patch adds the fixed-BAR logic to upstream QEMU 10.2.1:
- Adds `preserve_bars_on_reset` to `PCIDevice` so BARs survive system reset.
- Adds `x-fixed-bars` and `x-fixed-bars-allow-32bit-fallback` properties to `vfio-pci`.
- Presets host BAR addresses, validates RAM overlap, and allows 32-bit BAR fallback.
- Rejects firmware writes that would relocate a fixed BAR.

### 2. OVMF patch

File:
- `tools/packaging/static-build/ovmf/patches/0001-MdeModulePkg-PciBusDxe-Preserve-preset-BAR-address-edk2-stable202508.patch`

This patch modifies OVMF's `ProgramBar()` and `ProgramVfBar()` to use an already-preset BAR address instead of allocating a new one.

Container build support:
- `tools/packaging/static-build/ovmf/Dockerfile`: installs `patch`.
- `tools/packaging/static-build/ovmf/build-ovmf.sh`: applies patches from `patches/`, uses `GCC` toolchain (GCC5 is deprecated in current EDK2), and supports building from a local EDK2 source directory via `ovmf_local_dir`.
- `tools/packaging/static-build/ovmf/build.sh`: mounts the local EDK2 directory into the build container.

### 3. Kata runtime changes

#### Cold-plug VFIO parameters

File: `src/runtime/pkg/govmm/qemu/qemu.go`

In `VFIODevice.QemuParams()`, for PCI VFIO devices:
```go
deviceParams = append(deviceParams, fmt.Sprintf("%s,host=%s", driver, vfioDev.BDF))
if vfioDev.Transport.isVirtioPCI(config) {
    deviceParams = append(deviceParams, "x-fixed-bars=on")
    deviceParams = append(deviceParams, "x-fixed-bars-allow-32bit-fallback=on")
    ...
}
```

#### QMP hot-plug VFIO parameters

File: `src/runtime/pkg/govmm/qemu/qmp.go`

In `ExecuteVFIODeviceAdd()` and `ExecutePCIVFIODeviceAdd()`:
```go
args["x-fixed-bars"] = "on"
args["x-fixed-bars-allow-32bit-fallback"] = "on"
```

#### Attach VFIO devices directly to root bus

File: `src/runtime/pkg/device/drivers/vfio.go`

Removed the assignment of `vfio.Bus` to `rpN`. PCIe VFIO devices are now attached directly to `pcie.0`. This prevents a `pcie-root-port` bridge window from reassigning the 64-bit BAR away from the host address.

#### Guest kernel PCI parameters

File: `src/runtime/virtcontainers/qemu_amd64.go`

Added to the base kernel parameters:
```go
{"pci", "realloc=off"},
{"pci", "nocrs"},
```

These tell the Linux guest not to reallocate PCI resources and to ignore the host CRS, keeping the preset BAR addresses.

## Build Instructions

### Build patched QEMU

```bash
cd /home/bingo/kata-containers/tools/packaging/static-build/qemu
export PATH="/root/go/bin:$PATH"
./build-static-qemu.sh
```

Output: `kata-static-qemu.tar.gz` in the current directory.

### Build patched OVMF

The Kata OVMF build uses the upstream `tianocore/edk2` version specified in `versions.yaml` (`edk2-stable202508`). The build applies the ProgramBar patch from `tools/packaging/static-build/ovmf/patches/` automatically.

1. Ensure the official EDK2 source is cloned and its submodules are initialized:

   ```bash
   cd /home/bingo/kata-ovmf/edk2
   git submodule update --init
   ```

2. Build OVMF from the local source directory:

   ```bash
   cd /home/bingo/kata-containers/tools/packaging/static-build/ovmf
   export PATH="/root/go/bin:$PATH"
   OVMF_LOCAL_DIR="/home/bingo/kata-ovmf/edk2" ./build.sh
   ```

   `OVMF_LOCAL_DIR` defaults to `/home/bingo/kata-ovmf/edk2` and can be overridden.

Output: `edk2-x86_64.tar.gz` in the current directory.

> **Note:** The previous approach of reusing the QEMU 8.2.2 submodule (`/home/bingo/qemu/roms/edk2`) is no longer used. OVMF is now built from the official `tianocore/edk2` source to align with Kata's version requirements.

### Build patched Kata runtime

```bash
cd /home/bingo/kata-containers/src/runtime
export PATH="/usr/local/go/bin:$PATH"
make build
```

Output: `kata-runtime`, `containerd-shim-kata-v2`, `kata-monitor`.

## Deployment on Target Host

This section reflects the deployment used to validate the build on `172.18.5.243` (and previously `172.18.1.111`). The same steps apply to other hosts running the Kata 3.29 static tarball layout under `/opt/kata`.

Back up existing binaries:
```bash
BACKUP_DIR=/root/kata-backup-$(date +%Y%m%d-%H%M%S)
mkdir -p "$BACKUP_DIR"/{bin,share/ovmf}
cp /opt/kata/bin/qemu-system-x86_64 "$BACKUP_DIR/bin/"
cp /opt/kata/share/ovmf/OVMF.fd "$BACKUP_DIR/share/ovmf/"
cp /opt/kata/bin/kata-runtime "$BACKUP_DIR/bin/"
cp /opt/kata/bin/containerd-shim-kata-v2 "$BACKUP_DIR/bin/"
```

Deploy new binaries:
```bash
cd /
tar -xzvf /path/to/kata-static-qemu.tar.gz
tar -xzvf /path/to/edk2-x86_64.tar.gz
cp /path/to/kata-runtime /opt/kata/bin/kata-runtime
cp /path/to/containerd-shim-kata-v2 /opt/kata/bin/containerd-shim-kata-v2
chmod +x /opt/kata/bin/kata-runtime /opt/kata/bin/containerd-shim-kata-v2
```

> **Important:** Make sure the OVMF that ends up in `/opt/kata/share/ovmf/OVMF.fd` actually
> contains the fixed-BAR `ProgramBar`/`ProgramVfBar` patch. If an older/unpatched `OVMF.fd`
> is already present on the target host, the static tarball extraction may leave it in place
> or overwrite it with an unpatched version. Verify by comparing the checksum with the
> patched build output, and copy it explicitly if necessary:
> ```bash
> md5sum /opt/kata/share/ovmf/OVMF.fd
> # should match the patched OVMF built locally, e.g.
> # /home/bingo/kata-containers/tools/packaging/kata-deploy/local-build/build/ovmf/destdir/opt/kata/share/ovmf/OVMF.fd
> cp /path/to/patched/OVMF.fd /opt/kata/share/ovmf/OVMF.fd
> chmod 644 /opt/kata/share/ovmf/OVMF.fd
> ```
> If an unpatched OVMF is deployed, the guest will hang at UEFI initialization when a GPU
> with a high 64-bit BAR address is passed through with `x-fixed-bars=on`.

### QEMU firmware/ROM lookup

QEMU 10.2.1 was built with its default datadir set to `/usr/local/share/qemu`. When Kata starts QEMU, the process cwd is the container bundle directory (`/run/containerd/io.containerd.runtime.v2.task/default/<id>`), so QEMU cannot find `bios-256k.bin`, VGA ROMs, and other firmware files by relative lookup.

The Kata runtime now derives the correct data directory from the configured `path` (the directory `/opt/kata/share/kata-qemu/qemu` next to `/opt/kata/bin/qemu-system-x86_64`) and automatically passes `-L /opt/kata/share/kata-qemu/qemu` to QEMU. No wrapper script is required anymore.

If you are running a non-standard layout, or need to override the lookup directory, you can still manually copy the Kata QEMU datadir to the compiled-in datadir:
```bash
rm -rf /usr/local/share/qemu
cp -a /opt/kata/share/kata-qemu/qemu /usr/local/share/qemu
```

For reference, the previous workaround was to wrap `/opt/kata/bin/qemu-system-x86_64` so that Kata invoked QEMU with `-L /usr/local/share/qemu`. This wrapper has been replaced by the runtime change above.

Kata config to use:
```toml
/etc/kata-containers/configuration.toml:
  cold_plug_vfio = "root-port"
  pcie_root_port = 8
  vfio_mode = "guest-kernel"
  firmware = "/opt/kata/share/ovmf/OVMF.fd"
  enable_hugepages = true
```

### Hugepages for multi-GPU / multi-VM deployments

When running more than one large-memory Kata VFIO GPU VM on the same host,
pre-allocate 1 GiB hugepages and enable them in Kata.  Without hugepages,
Kata falls back to a `memory-backend-file` on `/dev/shm`, which is slow to
allocate for multi-gigabyte guest RAM and can cause `vfio_container_dma_map`
`EFAULT` failures or very long container-create times when a second VM starts.

1. Reserve hugepages at boot by adding to the kernel command line:

   ```bash
   default_hugepagesz=1G hugepagesz=1G hugepages=<N>
   ```

   `<N>` should cover the total guest RAM plus QEMU overhead for all
   concurrently running VMs.  For two 64 GiB GPU VMs, reserve at least
   160 GiB (`hugepages=160`).

2. Verify after reboot:

   ```bash
   cat /proc/meminfo | grep -E "HugePages_Total|Hugepagesize"
   ```

3. Set `enable_hugepages = true` in `/etc/kata-containers/configuration.toml`
   (the deployment script does this automatically).

4. Restart containerd so the runtime picks up the new configuration:

   ```bash
   systemctl restart containerd
   ```

> **Note:** On x86_64 without a confidential-guest technology, Kata passes `firmware` to QEMU
> as `-bios`. The single `OVMF.fd` (code + vars combined) works with `-bios`; split code/vars
> images created for pflash may not work in this mode. Use the patched 4 MiB `OVMF.fd` built
> by the OVMF build above.

The patched `OVMF.fd` is the 4 MiB file produced by the OVMF build. If you previously created
split `OVMF_CODE.fd` / `OVMF_VARS.fd` files for pflash experiments, remove or rename them so
Kata uses the single `OVMF.fd`:
```bash
rm -f /opt/kata/share/ovmf/OVMF_CODE.fd /opt/kata/share/ovmf/OVMF_VARS.fd
```

Then restart containerd:
```bash
systemctl restart containerd
```

### Disabling ACS on GPU upstream switches

Direct GPU P2P across PCIe root ports requires the upstream PCIe switches of
the VFIO-bound GPUs to have ACS (Access Control Services) disabled.  The
runtime's VFIO passthrough does **not** disable ACS automatically; it must be
cleared after binding the GPUs to `vfio-pci` and **before** starting the Kata
container.  Do not verify ACS state with `lspci -vvv` on the vfio-bound host
GPUs; use `setpci` instead.

A helper script finds the upstream bridge for each `/dev/vfio/N` group and
clears the ACS source-valid/request-redirect/completion-redirect bits:

```bash
cat > /root/acs_shutdown_vfio.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for vfio_dev in /dev/vfio/*; do
    [[ -c "${vfio_dev}" ]] || continue
    group_num=$(basename "${vfio_dev}")
    [[ "${group_num}" =~ ^[0-9]+$ ]] || continue
    group_dir="/sys/kernel/iommu_groups/${group_num}/devices"
    [[ -d "${group_dir}" ]] || continue
    for dev in "${group_dir}"/*; do
        bdf=$(basename "${dev}")
        [[ "${bdf}" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$ ]] || continue
        bus_num_hex=$(echo "${bdf}" | cut -d: -f2)
        bus_num_dec=$(printf '%d' "0x${bus_num_hex}")
        upstream_bdf=""
        for bridge in /sys/bus/pci/devices/*; do
            if [[ -f ${bridge}/secondary_bus_number ]]; then
                sec=$(cat "${bridge}/secondary_bus_number" 2>/dev/null | tr -d ' ')
                if [[ "${sec}" == "${bus_num_dec}" ]]; then
                    upstream_bdf=$(basename "${bridge}")
                    break
                fi
            fi
        done
        [[ -n ${upstream_bdf} ]] || continue
        acs_val=$(setpci -s "${upstream_bdf}" ECAP_ACS+0x6.w 2>/dev/null || true)
        [[ -n ${acs_val} ]] || continue
        printf 'Disabling ACS on %s was %s for %s\n' "${upstream_bdf}" "${acs_val}" "${bdf}"
        setpci -s "${upstream_bdf}" ECAP_ACS+0x6.w=0x0000
    done
done
echo "ACS shutdown complete."
EOF
chmod +x /root/acs_shutdown_vfio.sh
/root/acs_shutdown_vfio.sh
```

Verify with `setpci`:

```bash
setpci -s <upstream_bdf> ECAP_ACS+0x6.w
# Expected: 0000
```

The container startup re-initializes the upstream switches and re-enables ACS,
so re-run the script after starting the container if you need `NCCL_P2P_LEVEL=SYS`.

> **Hardware ACS lock-down:** On some platforms the upstream PCIe switches for
> secondary GPU slots have ACS redirect bits that are read-only in software.
> `setpci` may report `was 001d` and `lspci -vv` will still show
> `ReqRedir+` and `CmpltRedir+` after the script runs:
> ```
> ACSCtl: SrcValid- TransBlk- ReqRedir+ CmpltRedir+ UpstreamFwd- EgressCtrl- DirectTrans-
> ```
> When this happens, **more than one GPU from that switch cannot be passthrough
> into the same Kata VM**; the guest will hang during PCI resource assignment and
> the Kata agent will time out connecting over VSOCK.  Single-GPU containers on
> those slots still work.  To use multiple GPUs, disable ACS in the platform BIOS
> (look for an "ACS disable" or "Peer-to-Peer" option) or use slots whose
> upstream switches allow software ACS control.

## Verification
n
Start a Kata container with two VFIO GPUs:
```bash
nerdctl run -d \
  --runtime io.containerd.kata.v2 \
  --name vllm-bingo3 \
  --device /dev/vfio/43 \
  --device /dev/vfio/49 \
  -m 16g \
  -p 8006:8006 \
  -v /models/DeepSeek-R1-Distill-Qwen-1.5B:/models/DeepSeek-R1-Distill-Qwen-1.5B \
  --entrypoint /bin/bash \
  docker.io/vllm/vllm-openai:latest \
  -c "sleep infinity"
```

Inside the container, verify GPU BAR addresses:
```bash
lspci -vv -nn -s 00:0e.0 | grep "Region 1"
lspci -vv -nn -s 00:0f.0 | grep "Region 1"
```

Expected result (matches host BAR1):
- GPU1: `Region 1: Memory at 21f800000000 (64-bit, prefetchable) [size=16G]`
- GPU2: `Region 1: Memory at 21e800000000 (64-bit, prefetchable) [size=16G]`

The exact addresses depend on the host GPU BAR layout; the important check is that the guest
BAR1 value equals the host BAR1 value for each device.

Start vLLM with tensor parallelism:
```bash
python3 -m vllm.entrypoints.openai.api_server \
  --model /models/DeepSeek-R1-Distill-Qwen-1.5B \
  --trust-remote-code \
  --host 0.0.0.0 --port 8006 \
  --tensor-parallel-size 2 \
  --max-model-len 4096 \
  --max-num-seqs 512 \
  --enable-prefix-caching
```

Test inference:
```bash
curl http://localhost:8006/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "/models/DeepSeek-R1-Distill-Qwen-1.5B",
       "prompt": "1+1=?",
       "max_tokens": 20}'
```

### Installing extra packages inside the vLLM container

The `vllm/vllm-openai` image is minimal and `apt-get update` may fail with
`At least one invalid signature was encountered` because the inline GPG verification in
`apt-get` does not work correctly in this container environment. The workaround is to
populate `/var/lib/apt/lists/` manually and install with `--allow-unauthenticated`:

```bash
nerdctl exec vllm-bingo3 bash -c '
  rm -rf /var/lib/apt/lists/*
  mkdir -p /var/lib/apt/lists/partial
  cd /var/lib/apt/lists/partial
  curl -s -O http://mirrors.aliyun.com/ubuntu/dists/jammy/InRelease
  curl -s -O http://mirrors.aliyun.com/ubuntu/dists/jammy/main/binary-amd64/Packages.gz
  curl -s -O http://mirrors.aliyun.com/ubuntu/dists/jammy/restricted/binary-amd64/Packages.gz
  curl -s -O http://mirrors.aliyun.com/ubuntu/dists/jammy/universe/binary-amd64/Packages.gz
  curl -s -O http://mirrors.aliyun.com/ubuntu/dists/jammy/multiverse/binary-amd64/Packages.gz
  mv /var/lib/apt/lists/partial/* /var/lib/apt/lists/
  apt-get install -y --no-install-recommends --allow-unauthenticated cmake
'
```

If installation fails with "You don't have enough free space in `/var/cache/apt/archives/`",
the host root filesystem is full. Free space by removing large backups/tarballs, e.g.:

```bash
rm -rf /opt/kata.bak
rm -f /root/vllm-openai_v0.21.0-x86_64-cu129.tar
rm -f /root/NVIDIA-Linux-x86_64-595.58.03.run.1
rm -f /root/kata-backup-*
```

### Cleaning up stale CNI port-mapping rules

Repeated failed container starts can leave stale CNI `CNI-HOSTPORT-DNAT` rules that shadow
the current container's port mapping. Symptoms: `curl http://127.0.0.1:8006` returns
`000` even though the service is running inside the container. Fix by flushing CNI state
and recreating the container:

```bash
systemctl stop containerd
rm -rf /var/lib/cni/networks/bridge /var/lib/cni/results/*
iptables -t nat -F CNI-HOSTPORT-DNAT
iptables -t nat -F CNI-HOSTPORT-MASQ
iptables -t nat -F CNI-HOSTPORT-SETMARK
# remove old per-container DNAT chains (list with: iptables -t nat -L -n | grep CNI-DN-)
systemctl start containerd
nerdctl run -d ...  # recreate the container
```

### Running host-compiled CUDA samples inside the container

CUDA samples (or other C++/CUDA binaries) compiled on the host cannot always run inside the
Kata container because the host and the `vllm/vllm-openai` image may have different glibc and
libstdc++ versions. For example, the host may be Ubuntu 25.10 with glibc 2.42 / libstdc++
`GLIBCXX_3.4.34`, while the container is Ubuntu 22.04 with glibc 2.35 / libstdc++
`GLIBCXX_3.4.30`.

Symptom:
```
./p2pBandwidthLatencyTest: /lib/x86_64-linux-gnu/libstdc++.so.6: version `GLIBCXX_3.4.32' not found
```

Do **not** copy only `libstdc++.so.6` from the host into the container: the newer
`libstdc++` also requires a newer glibc (`GLIBC_2.36`, `GLIBC_2.38`), and upgrading glibc
inside the container is risky.

Recommended fix: rebuild the sample inside the container. The `vllm/vllm-openai` image
includes `nvcc` and `g++`:

```bash
nerdctl exec vllm-bingo3 bash -c '
  ln -sf /models/DeepSeek-R1-Distill-Qwen-1.5B/cuda-samples-13.2 /root/cuda-samples-13.2
  cd /models/DeepSeek-R1-Distill-Qwen-1.5B/cuda-samples-13.2/Samples/5_Domain_Specific/p2pBandwidthLatencyTest
  make clean
  make -j$(nproc)
'
```

### Avoiding OOM when running CUDA P2P tests alongside vLLM

If vLLM is already running and holding GPU memory, the default `p2pBandwidthLatencyTest`
buffer size (`numElems = 40000000`, ~160 MiB per buffer) can exhaust the remaining VRAM on
a 16 GiB GPU and fail with:

```
Cuda failure p2pBandwidthLatencyTest.cu:250: 'out of memory'
```

Reduce the test buffer size with `--numElems`:

```bash
nerdctl exec vllm-bingo3 \
  /models/DeepSeek-R1-Distill-Qwen-1.5B/cuda-samples-13.2/build/Samples/5_Domain_Specific/p2pBandwidthLatencyTest/p2pBandwidthLatencyTest \
  --numElems=4000000
```

A successful run shows the P2P connectivity matrix as all `1`s, and the cross-GPU
bandwidth increases when P2P is enabled.

### Running NCCL tests inside the container

`nccl-tests` compiled on the host will fail inside the container with a glibc version
error, just like the CUDA samples above. Rebuild it inside the container before running
multi-GPU collectives:

```bash
nerdctl exec vllm-bingo3 bash -c '
  cd /models/DeepSeek-R1-Distill-Qwen-1.5B/nccl-tests
  make clean
  make -j$(nproc) BUILD=1 CUDA_HOME=$(dirname $(dirname $(which nvcc)))
'
```

Run the `all_reduce` benchmark on the two passthrough GPUs. Without any environment
variables NCCL may avoid cross-Host-Bridge P2P and fall back to sysmem copies:

```bash
nerdctl exec vllm-bingo3 \
  /models/DeepSeek-R1-Distill-Qwen-1.5B/nccl-tests/build/all_reduce_perf \
  -b 8M -e 256M -f 2 -g 2 -t 1 -n 20 -w 5
```

On the test hardware (dual NVIDIA GeForce RTX 4090 Laptop GPU, PCIe Gen4 x8, no NVLink)
this produced an average bus bandwidth of only ~6.7 GB/s because NCCL did not use direct
P2P across the PCIe Host Bridge.

Force P2P over PCIe with `NCCL_P2P_LEVEL=SYS`:

```bash
nerdctl exec vllm-bingo3 bash -c '
  cd /models/DeepSeek-R1-Distill-Qwen-1.5B/nccl-tests/build &&
  NCCL_P2P_LEVEL=SYS ./all_reduce_perf -b 8M -e 256M -f 2 -g 2 -t 1 -n 20 -w 5
'
```

With this setting the same hardware reached ~12.3 GB/s, which is close to the practical
limit for PCIe Gen4 x8 (~15.75 GB/s raw, ~12-13 GB/s achievable). `NCCL_DEBUG=INFO`
output confirms the transport is `P2P/direct pointer`.

> **Recommendation:** For vLLM tensor-parallel or other multi-GPU workloads in this
> configuration, export `NCCL_P2P_LEVEL=SYS` before starting the workload:
> ```bash
> export NCCL_P2P_LEVEL=SYS
> ```

The absolute bandwidth is limited by the hardware (no NVLink, Gen4 x8), not by the Kata
VFIO fixed-BAR passthrough path. The fixed-BAR feature still matters because it preserves
the host BAR1 addresses in the guest, which is what allows NCCL P2P to work at all.

### Basic Kata container smoke test

Before running GPU workloads, confirm that a simple Kata container can start with the new QEMU/OVMF:

```bash
ctr run --runtime "io.containerd.kata.v2" --rm \
  "docker.m.daocloud.io/library/ubuntu:latest" test-kata uname -r
```

Expected output: the guest kernel version, e.g. `6.18.15`.

## Notes and Caveats

- OVMF is built from the official `tianocore/edk2` source (`edk2-stable202508`) checked out at `/home/bingo/kata-ovmf/edk2`. The ProgramBar patch is applied by `tools/packaging/static-build/ovmf/build-ovmf.sh` during the build. Make sure EDK2 submodules are initialized (`git submodule update --init`) before building.
- 32-bit non-prefetchable BAR0 is expected to fall back to dynamic allocation because it overlaps guest RAM. This is unavoidable for 32-bit BARs; the important BAR for GPU compute/P2P is the 64-bit BAR1.
- The `containerd-shim-kata-v2` binary is dynamically linked to the host glibc in this build. For a fully static runtime matching Kata's official release, use `tools/packaging/static-build/shim-v2/build.sh`.
- If the guest hangs at UEFI initialization with `x-fixed-bars=on` and QEMU consumes 100% CPU, first verify that the patched `OVMF.fd` is deployed and that `/etc/kata-containers/configuration.toml` uses the single `OVMF.fd` as `-bios`.

## QEMU BAR Fix (2026-06-29)

### Problem

The original `x-fixed-bars-allow-32bit-fallback` only triggered when a 32-bit BAR overlapped with guest RAM. However, GPU BAR0 could also conflict with empty pcie-root-port bridge windows in the guest (e.g., 8 root ports each consuming 2MB of 32-bit MMIO space from 0x88e00000 downward). This conflict is NOT a RAM overlap, so the fallback never activated, causing NVIDIA driver probe failures.

### Fix (Commit: `fe45aa3`)

Extend the fallback condition from "only RAM overlap" to "all 32-bit non-prefetchable memory BARs":

```diff
- if (overlaps_ram) {
-     if (nr != PCI_ROM_SLOT && !bar->ioport && !bar->mem64 &&
-         vdev->fixed_bars_allow_32bit_fallback) {
-         vdev->fixed_bar_fallback[nr] = true;
-         warn_report("... overlaps RAM; using dynamic allocation ...");
-         return true;
-     }
-     error_setg(errp, "VFIO fixed BAR %d ... overlaps RAM", ...);
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

### Verification（2026-06-29）

Tested on `172.18.5.133` with 4 concurrent Kata VFIO containers (G5/G6/G7/G8, 32 GPUs total):
- All groups: **0 BAR conflicts**
- 64-bit BAR1: **GPA=HPA preserved** for all GPUs
- 32-bit BAR0: dynamically reallocated by guest kernel (expected)

### Deployment

```bash
cd /home/bingo/10.2.1/qemu/build && make -j$(nproc)
scp qemu-system-x86_64 root@172.18.5.133:/opt/kata/bin/
# Server dependencies: apt-get install libpixman-1-0 libslirp0
```

## Related Commits

- `/home/bingo/qemu`: `8cc8584 vfio/pci: Allow 32-bit BAR fallback for fixed-BAR mode`
- `/home/bingo/qemu`: `2f55227 docs: Document x-fixed-bars-allow-32bit-fallback`
- `/home/bingo/qemu`: `50ab8c5 vfio: Add x-fixed-bars and x-fixed-bars-allow-32bit-fallback support`
- `/home/bingo/qemu`: `fe45aa3 vfio: Extend x-fixed-bars-allow-32bit-fallback to all 32-bit BARs`
- `/home/bingo/kata-containers`: `1ed044d kata: Enable VFIO fixed-BAR GPA=HPA passthrough for GPU inference`
