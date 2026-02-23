#!/usr/bin/env bash
set -euo pipefail

timestamp() {
	date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
	printf '[%s] [jgo-entrypoint] %s\n' "$(timestamp)" "$*" >&2
}

render_argv() {
	printf "["
	local sep=""
	local arg
	for arg in "$@"; do
		printf '%s%q' "${sep}" "${arg}"
		sep=" "
	done
	printf "]"
}

to_abs_path() {
	local p="$1"
	case "${p}" in
	/*) printf '%s' "${p}" ;;
	*) printf '%s/%s' "${PWD}" "${p}" ;;
	esac
}

cache_root="$(to_abs_path ".jgo-cache")"
gocache_path="${GOCACHE:-${cache_root}/go-build}"
gomodcache_path="${GOMODCACHE:-${cache_root}/go-mod}"
home_dir="$(to_abs_path "${HOME:-/home/jgo}")"
legacy_codex_home="${home_dir}/.jgo-cache/codex"
default_codex_home="${home_dir}/.codex"

if [ -z "${CODEX_HOME:-}" ]; then
  if [ -f "${legacy_codex_home}/auth.json" ] && [ ! -f "${default_codex_home}/auth.json" ]; then
    codex_home_path="${legacy_codex_home}"
  else
    codex_home_path="${default_codex_home}"
  fi
else
  codex_home_path="${CODEX_HOME}"
fi

export GOCACHE="$(to_abs_path "${gocache_path}")"
export GOMODCACHE="$(to_abs_path "${gomodcache_path}")"
export CODEX_HOME="$(to_abs_path "${codex_home_path}")"
export XDG_CONFIG_HOME="${home_dir}/.config"
main_file="${JGO_MAIN_FILE:-/opt/jgo/main.go}"

mkdir -p "${GOCACHE}" "${GOMODCACHE}" "${CODEX_HOME}"

argv="$(render_argv "$@")"
log "startup argc=$# argv=${argv}"
log "cache_dir=${cache_root} codex_home=${CODEX_HOME}"

if [ ! -f "${main_file}" ] && [ -f "./main.go" ]; then
	main_file="./main.go"
fi
if [ ! -f "${main_file}" ]; then
	log "error_code=E_MAIN_FILE_MISSING detail='main file not found: ${main_file}'"
	log "hint='set JGO_MAIN_FILE to a valid Go entrypoint file path'"
	exit 1
fi

if [ "$#" -eq 0 ]; then
	log "no args provided; starting resident API server mode"
	set -- serve
	argv="$(render_argv "$@")"
fi

set +e
go run "${main_file}" "$@"
status=$?
set -e

if [ "${status}" -ne 0 ]; then
	log "error_code=E_JGO_EXEC_FAILED exit_status=${status} argv=${argv}"
fi

exit "${status}"
