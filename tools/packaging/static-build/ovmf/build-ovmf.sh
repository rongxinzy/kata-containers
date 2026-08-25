#!/bin/bash
#
# Copyright (c) 2022 IBM
# Copyright (c) 2022 Intel
#
# SPDX-License-Identifier: Apache-2.0

set -o errexit
set -o nounset
set -o pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/../../scripts/lib.sh"

# disabling set -u because scripts attempt to expand undefined variables
set +u
ovmf_build="${ovmf_build:-x86_64}"
ovmf_repo="${ovmf_repo:-}"
ovmf_version="${ovmf_version:-}"
ovmf_package="${ovmf_package:-}"
package_output_dir="${package_output_dir:-}"
DESTDIR=${DESTDIR:-${PWD}}
PREFIX="${PREFIX:-/opt/kata}"
architecture="${architecture:-X64}"
if [[ "${ovmf_build}" == "arm64" ]] || [[ "${ovmf_build}" == "cca" ]]; then
	architecture="AARCH64"
fi
toolchain="${toolchain:-GCC}"
build_target="${build_target:-RELEASE}"

ovmf_local_dir="${ovmf_local_dir:-}"
SOURCE_REPO_TOKEN="${SOURCE_REPO_TOKEN:-}"

git_source() {
	if [[ -n "${SOURCE_REPO_TOKEN}" ]]; then
		local encoded_token
		encoded_token="$(printf 'x-access-token:%s' "${SOURCE_REPO_TOKEN}" | base64 | tr -d '\n')"
		git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic ${encoded_token}" "$@"
	else
		GIT_TERMINAL_PROMPT=0 git "$@"
	fi
}

[ -n "$ovmf_repo" ] || die "failed to get ovmf repo"
if [[ -z "${ovmf_version}" ]] && [[ -z "${ovmf_branch}" ]]; then
    die "failed to get ovmf version or branch"
fi
[ -n "$ovmf_package" ] || die "failed to get ovmf package or commit"
[ -n "$package_output_dir" ] || die "failed to get ovmf package or commit"

ovmf_dir="${ovmf_repo##*/}"

info "Build ${ovmf_repo} version: ${ovmf_version}"

if [ -n "${ovmf_local_dir}" ] && [ -d "${ovmf_local_dir}" ]; then
	info "Using local OVMF source directory ${ovmf_local_dir}"
	source_root="${ovmf_local_dir}"
	cd "${source_root}"
	# Remove pre-built BaseTools binaries from the host so they are rebuilt
	# inside the container with the container's toolchain/libraries.
	rm -rf BaseTools/Source/C/bin BaseTools/Source/C/libs
	find BaseTools/Source/C -type d -name 'DEBUG' -prune -exec rm -rf {} + 2>/dev/null || true
	find BaseTools/Source/C -type d -name '.deps' -prune -exec rm -rf {} + 2>/dev/null || true
	find BaseTools/Source/C \( -name '*.o' -o -name '*.obj' -o -name '*.d' \) -delete 2>/dev/null || true
	find BaseTools/Source/C -type f -perm /111 -delete 2>/dev/null || true
else
	build_root=$(mktemp -d)
	pushd $build_root
	source_root="${build_root}/${ovmf_dir}"
	mkdir -p "${source_root}"
	git -C "${source_root}" init
	git -C "${source_root}" remote add origin "${ovmf_repo}"
	git_source -C "${source_root}" fetch --depth 1 origin "${ovmf_version}"
	git -C "${source_root}" checkout --detach FETCH_HEAD
	cd "${source_root}"
	git submodule init
	git submodule update
fi

if [ -d "${script_dir}/patches" ] && [ "$(ls -A "${script_dir}/patches"/*.patch 2>/dev/null)" ]; then
	info "Applying OVMF patches"
	for p in "${script_dir}"/patches/*.patch; do
		# EDK2 source files use CRLF line endings.  Normalize the target file to
		# LF before applying a LF-formatted patch so the context matches and we
		# don't depend on the container's patch behaviour regarding CRLF.
		cr=$(printf '\015')
		sed -i "s/${cr}$//" MdeModulePkg/Bus/Pci/PciBusDxe/PciResourceSupport.c
		patch -p1 < "$p"
	done
fi

info "Using BaseTools make target"
make -C BaseTools/

info "Calling edksetup script"
source edksetup.sh

if [ "${ovmf_build}" == "sev" ]; then
	info "Creating dummy grub file"
	#required for building AmdSev package without grub
	touch OvmfPkg/AmdSev/Grub/grub.efi
fi

info "Building ovmf"
build_cmd="build -b ${build_target} -t ${toolchain} -a ${architecture} -p ${ovmf_package}"
eval "${build_cmd}"

info "Done Building"

build_path_target_toolchain="Build/${package_output_dir}/${build_target}_${toolchain}"
build_path_fv="${build_path_target_toolchain}/FV"
build_output_dir="${source_root}/${build_path_fv}"
if [ "${ovmf_build}" == "tdx" ]; then
	build_path_arch="${build_path_target_toolchain}/X64"
	stat "${build_output_dir}/OVMF.fd"
elif [ "${ovmf_build}" == "arm64" ] || [ "${ovmf_build}" == "cca" ]; then
	stat "${build_output_dir}/QEMU_EFI.fd"
	stat "${build_output_dir}/QEMU_VARS.fd"
else
	stat "${build_output_dir}/OVMF.fd"
fi

if [ -z "${ovmf_local_dir}" ]; then
	#need to leave tmp dir
	popd
fi

info "Install fd to destdir"
if [ "${ovmf_build}" == "arm64" ] || [ "${ovmf_build}" == "cca" ]; then
	install_dir="${DESTDIR}/${PREFIX}/share/aavmf"
else
	install_dir="${DESTDIR}/${PREFIX}/share/ovmf"
fi

mkdir -p "${install_dir}"
if [ "${ovmf_build}" == "sev" ]; then
	install "${build_output_dir}/OVMF.fd" "${install_dir}/AMDSEV.fd"
elif [ "${ovmf_build}" == "tdx" ]; then
	install "${build_output_dir}/OVMF.fd" "${install_dir}/OVMF.inteltdx.fd"
elif [ "${ovmf_build}" == "arm64" ] || [ "${ovmf_build}" == "cca" ]; then
	install "${build_output_dir}/QEMU_EFI.fd" "${install_dir}/AAVMF_CODE.fd"
	install "${build_output_dir}/QEMU_VARS.fd" "${install_dir}/AAVMF_VARS.fd"
	# QEMU expects 64MiB CODE and VARS files on ARM/AARCH64 architectures
	# Truncate the firmware files to the expected size
	truncate -s 64M ${install_dir}/AAVMF_CODE.fd
	truncate -s 64M ${install_dir}/AAVMF_VARS.fd
else
	install "${build_output_dir}/OVMF.fd" "${install_dir}"
fi

local_dir=${PWD}
tarball_dir="${ovmf_tarball_dir:-${local_dir}}"
mkdir -p "${tarball_dir}"
pushd $DESTDIR
tar -czvf "${tarball_dir}/${ovmf_dir}-${ovmf_build}.tar.gz" "./$PREFIX"
rm -rf $(dirname ./$PREFIX)
popd
