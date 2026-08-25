# DONXIN GPU command integration

This directory provides the user-facing GPU administration commands for the
DONXIN NVIDIA guest image variants. It intentionally does not run the original
standalone tool's `make install` target.

During rootfs construction:

- the vendor `nvidia-smi` binary is moved to the internal
  `/usr/libexec/donxin/gpu-query` path;
- `dx-smi` becomes the public, output-filtering command;
- a guest-only `nvidia-smi` compatibility alias remains for NVRC v0.1.4;
- `lspci` and `lsmod` are provided by the same filtering proxy over static
  BusyBox applets; and
- `nvidia-ctk` is wrapped so the generated CDI spec exposes `dx-smi`, `lspci`
  and `lsmod`, but does not mount `nvidia-smi` into workload containers.

The real GPU query command remains available only at the internal path so NVRC
can initialize and configure the GPU without changing its pinned interface.
