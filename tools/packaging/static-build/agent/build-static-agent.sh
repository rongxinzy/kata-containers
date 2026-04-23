#!/usr/bin/env bash
#
# Copyright (c) 2023 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0

set -o errexit
set -o nounset
set -o pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${script_dir}/../../scripts/lib.sh"

configure_github_access() {
	local github_proxy="${GITHUB_PROXY:-}"

	[ -n "${github_proxy}" ] || return 0

	export HOME="/tmp"
	export GIT_CONFIG_GLOBAL="${GIT_CONFIG_GLOBAL:-${HOME}/.gitconfig}"
	export CARGO_NET_GIT_FETCH_WITH_CLI="${CARGO_NET_GIT_FETCH_WITH_CLI:-true}"
	mkdir -p "${HOME}"
	git config --global http.https://github.com.proxy "${github_proxy}"
}

build_agent_from_source() {
	echo "build agent from source"

	/usr/bin/install_libseccomp.sh /opt /opt

	configure_github_access

	cd src/agent
	DESTDIR=${DESTDIR} AGENT_POLICY=${AGENT_POLICY} INIT_DATA=${INIT_DATA} make
	DESTDIR=${DESTDIR} AGENT_POLICY=${AGENT_POLICY} INIT_DATA=${INIT_DATA} make install
}

build_agent_from_source "$@"
