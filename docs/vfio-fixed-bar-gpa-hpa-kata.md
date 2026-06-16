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

This section reflects the deployment used to validate the build on `172.18.1.111`. The same steps apply to other hosts running the Kata 3.29 static tarball layout under `/opt/kata`.

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
  firmware = "/opt/kata/share/ovmf/OVMF_CODE.fd"
  firmware_volume = "/opt/kata/share/ovmf/OVMF_VARS.fd"
```

The split OVMF files can be produced from the single `OVMF.fd` if needed:
```bash
cp /opt/kata/share/ovmf/OVMF.fd /opt/kata/share/ovmf/OVMF_VARS.fd
cp /opt/kata/share/kata-qemu/qemu/edk2-x86_64-code.fd /opt/kata/share/ovmf/OVMF_CODE.fd
chmod 644 /opt/kata/share/ovmf/OVMF_VARS.fd
```

Then restart containerd:
```bash
systemctl restart containerd
```

## Verification

Start a Kata container with two VFIO GPUs:
```bash
nerdctl run -d \
  --runtime io.containerd.kata.v2 \
  --name vllm-bingo3 \
  --device /dev/vfio/43 \
  --device /dev/vfio/44 \
  -m 16g \
  -p 8006:8006 \
  -v /models/DeepSeek-R1-Distill-Qwen-1.5B:/models/DeepSeek-R1-Distill-Qwen-1.5B \
  --entrypoint /bin/bash \
  docker.io/vllm/vllm-openai:latest
```

Inside the container, verify GPU BAR addresses:
```bash
lspci -vv -nn -s 00:0e.0 | grep "Region 1"
lspci -vv -nn -s 00:0f.0 | grep "Region 1"
```

Expected result (matches host BAR1):
- GPU1: `Region 1: Memory at 21d800000000 (64-bit, prefetchable) [size=16G]`
- GPU2: `Region 1: Memory at 21d000000000 (64-bit, prefetchable) [size=16G]`

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

## Related Commits

- `/home/bingo/qemu`: `8cc8584 vfio/pci: Allow 32-bit BAR fallback for fixed-BAR mode`
- `/home/bingo/qemu`: `2f55227 docs: Document x-fixed-bars-allow-32bit-fallback`
- `/home/bingo/kata-containers`: `1ed044d kata: Enable VFIO fixed-BAR GPA=HPA passthrough for GPU inference`
