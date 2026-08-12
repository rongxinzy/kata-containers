#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_dir="$(cd "${script_dir}/.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/donxin-tools-test.XXXXXX")"
trap 'rm -rf "${work_dir}"' EXIT

cc -std=c11 -O2 -Wall -Wextra -Werror \
	-o "${work_dir}/fake-backend" "${script_dir}/fake-backend.c"
cc -std=c11 -O2 -Wall -Wextra -Werror \
	-DDONXIN_GPU_QUERY_PATH='"'"${work_dir}/fake-backend"'"' \
	-DDONXIN_SYSBOX_PATH='"'"${work_dir}/fake-backend"'"' \
	-o "${work_dir}/dx-smi" "${source_dir}/dx-command-proxy.c"
cc -std=c11 -O2 -Wall -Wextra -Werror \
	-o "${work_dir}/cdi-transform" "${source_dir}/dx-cdi-transform.c"

ln -s dx-smi "${work_dir}/lspci"
ln -s dx-smi "${work_dir}/lsmod"
ln -s dx-smi "${work_dir}/nvidia-smi"

run_proxy_test() {
	local command_name=$1
	local expected_stdout=$2
	local expected_stderr=$3
	local stdout_file="${work_dir}/${command_name}.stdout"
	local stderr_file="${work_dir}/${command_name}.stderr"
	local status=0

	"${work_dir}/${command_name}" -L >"${stdout_file}" 2>"${stderr_file}" || status=$?
	[[ ${status} -eq 7 ]]
	rg -q "${expected_stdout}" "${stdout_file}"
	rg -q "${expected_stderr}" "${stderr_file}"
	rg -q 'arg\[1\]=-L' "${stdout_file}"
}

run_proxy_test dx-smi 'DX-SMI DONXIN-8120S DONXIN-8120 DONXIN-8140 donxin' 'DONXIN Corporation donxin_uvm'
run_proxy_test lspci 'DONXIN-8120S DONXIN-8120 DONXIN-8140 donxin DONXIN:2805' 'DONXIN Corporation donxin_uvm'
run_proxy_test lsmod 'donxin' 'DONXIN Corporation donxin_uvm'

# The guest-only compatibility name must not filter NVRC's backend output.
status=0
"${work_dir}/nvidia-smi" >"${work_dir}/compat.stdout" 2>"${work_dir}/compat.stderr" || status=$?
[[ ${status} -eq 7 ]]
rg -q 'NVIDIA-SMI' "${work_dir}/compat.stdout"

cp "${script_dir}/nvidia-cdi.yaml" "${work_dir}/nvidia-cdi.yaml"
"${work_dir}/cdi-transform" "${work_dir}/nvidia-cdi.yaml"

rg -q 'containerPath: /usr/bin/dx-smi' "${work_dir}/nvidia-cdi.yaml"
rg -q 'containerPath: /usr/bin/lspci' "${work_dir}/nvidia-cdi.yaml"
rg -q 'containerPath: /usr/bin/lsmod' "${work_dir}/nvidia-cdi.yaml"
rg -q 'containerPath: /usr/sbin/lsmod' "${work_dir}/nvidia-cdi.yaml"
rg -q 'containerPath: /usr/libexec/donxin/gpu-query' "${work_dir}/nvidia-cdi.yaml"
rg -q 'containerPath: /usr/libexec/donxin/sysbox' "${work_dir}/nvidia-cdi.yaml"
! rg -q 'containerPath: .*/nvidia-smi' "${work_dir}/nvidia-cdi.yaml"
! rg -q 'nvidia-smi' "${work_dir}/nvidia-cdi.yaml"
rg -q 'containerPath: /bin/nvidia-persistenced' "${work_dir}/nvidia-cdi.yaml"

# A second pass has no compatibility mount to replace and must fail closed
# without modifying the already branded specification.
cp "${work_dir}/nvidia-cdi.yaml" "${work_dir}/branded-before-retry.yaml"
if "${work_dir}/cdi-transform" "${work_dir}/nvidia-cdi.yaml" 2>/dev/null; then
	echo "CDI transform unexpectedly accepted a spec without nvidia-smi" >&2
	exit 1
fi
cmp "${work_dir}/branded-before-retry.yaml" "${work_dir}/nvidia-cdi.yaml"

echo "DONXIN command integration tests: PASS"
