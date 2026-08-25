#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 DONXIN

set -eu

real_ctk=/usr/libexec/donxin/nvidia-ctk
transform=/usr/libexec/donxin/cdi-transform

is_cdi=no
is_generate=no
output=
expect_output=no

for argument in "$@"; do
	if [ "${expect_output}" = yes ]; then
		output=${argument}
		expect_output=no
		continue
	fi
	case "${argument}" in
	cdi) is_cdi=yes ;;
	generate) is_generate=yes ;;
	--output=*) output=${argument#*=} ;;
	--output | -o) expect_output=yes ;;
	-o=*) output=${argument#*=} ;;
	esac
done

if [ "${is_cdi}" != yes ] || [ "${is_generate}" != yes ]; then
	exec "${real_ctk}" "$@"
fi

if [ -z "${output}" ] || [ "${output}" = "-" ] || [ "${output}" = "/dev/stdout" ]; then
	temporary=/run/donxin-cdi.$$.yaml
	trap 'rm -f "${temporary}"' EXIT HUP INT TERM
	"${real_ctk}" "$@" --output="${temporary}"
	"${transform}" "${temporary}"
	cat "${temporary}"
	exit 0
fi

"${real_ctk}" "$@"
"${transform}" "${output}"
