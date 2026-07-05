# Kata VFIO GPU 直通文档集

本目录包含 Kata VFIO GPU 直通方案的所有文档、配置和脚本，用于在 64×RTX 4060 服务器上部署多实例并发推理。

## 目录结构

```
docs/micro/
├── README.md                              ← 本文档
│
├── simple-test-plan.md                    ← ★ 测试人员首先阅读
├── build-and-deploy.md                    ← ★ 开发人员首先阅读
│
├── test64.md                              ← 完整部署记录（含所有调试过程）
├── sw-qiao-test.md                        ← G2/G5 GPU 问题排查记录
├── kata-vfio-docker-gpu-deploy-test-plan.md ← 正式测试方案
├── vfio-fixed-bar-gpa-hpa-kata.md         ← VFIO BAR 修复技术文档
├── test-single-16.md                      ← ★ 单容器 16 GPU 研究记录
│
├── config/
│   └── gpu-groups.conf                    ← GPU 分组配置（每台机器编辑）
│
└── scripts/                               ← 自动化脚本
    ├── run-all.sh                         ← 一键全流程
    ├── bind-gpu.sh                        ← GPU 绑定到 vfio-pci
    ├── deploy-containers.sh               ← 部署 4 Kata + 1 Docker
    ├── start-vllm-services.sh             ← 启动所有 vLLM
    ├── verify-deployment.sh               ← 自动验证报告
    ├── build-nccl.sh                      ← 编译 NCCL (CUDA 13)
    └── ...
```

## 按角色阅读

### 测试人员

只需关注两个文件：

1. 编辑 **`config/gpu-groups.conf`** — 填入本机 GPU 的 BDF 分组
2. 阅读 **`simple-test-plan.md`** — 按步骤执行，使用 `scripts/` 下的脚本

```bash
# 一键完成全部部署 + 验证
bash scripts/run-all.sh
```

### 开发人员

1. **`build-and-deploy.md`** — 如何编译 Kata Runtime + QEMU，并部署到服务器
2. **`vfio-fixed-bar-gpa-hpa-kata.md`** — QEMU BAR 修复的技术细节
3. **`test64.md`** — 完整的调试验证记录（含配置参数、故障排查）

### 运维人员

1. **`simple-test-plan.md`** — 日常部署步骤
2. **`test64.md` §23.7** — 服务器重启后的操作清单
3. **`kata-vfio-docker-gpu-deploy-test-plan.md` §15** — 关键注意事项

## 快速命令参考

```bash
# 绑定 GPU（读取 config/gpu-groups.conf）
bash scripts/bind-gpu.sh

# 部署容器
bash scripts/deploy-containers.sh

# 启动 vLLM
bash scripts/start-vllm-services.sh

# 验证
bash scripts/verify-deployment.sh

# 一键全部
bash scripts/run-all.sh
```

## 关键技术点

| 项目 | 说明 |
|------|------|
| QEMU BAR 修复 | `x-fixed-bars-allow-32bit-fallback` 扩展到所有 32-bit BAR（commit `fe45aa3`） |
| CDI 修复 | 有 bug（`e629822`），不要使用 |
| GPU 分组 | nvidia-smi 不可见的 32 GPU → vfio-pci（Kata），可见的 32 GPU → nvidia（Docker） |
| Kata 配置 | 16 vCPU, 32 GB RAM, cold_plug_vfio=root-port, /dev/shm=300G |
| 模型 | Qwen3-14B, TP=4/PP=2 (Kata), TP=8/PP=4 (Docker) |
| **单容器 16 GPU** | ✅ 已实现，需宿主机 FLR + vhost max_mem_regions=256 + NCCL P2P_LEVEL=5 |
| Kata runtime 改动 | `vfioRootSlotBase=15` + cold-plug 不计入 root port 数 |
