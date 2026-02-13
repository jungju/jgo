#!/usr/bin/env bash
set -euo pipefail

cache_root="${JGO_CACHE_DIR:-/jgo-cache}"
export JGO_CACHE_DIR="${cache_root}"
export GOCACHE="${GOCACHE:-${cache_root}/go-build}"
export GOMODCACHE="${GOMODCACHE:-${cache_root}/go-mod}"
export CODEX_HOME="${CODEX_HOME:-${cache_root}/codex}"
env_file="${JGO_ENV_FILE:-/work/.env}"

mkdir -p "${cache_root}/repos" "${cache_root}/work" "${GOCACHE}" "${GOMODCACHE}" "${CODEX_HOME}"

if [ -f "${env_file}" ]; then
	set -a
	# shellcheck disable=SC1090
	. "${env_file}"
	set +a
fi

exec go run /opt/jgo/main.go "$@"
