#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

default_source_dir="/opt/jgo/homefiles"
if [ ! -d "${default_source_dir}" ]; then
	default_source_dir="${repo_root}/homefiles"
fi

source_dir="${SOURCE_DIR:-${default_source_dir}}"
target_home="${TARGET_HOME:-/home/jgo}"
target_user="${TARGET_USER:-jgo}"
target_group="${TARGET_GROUP:-${target_user}}"
marker_file="${MARKER_FILE:-${target_home}/.jgo-homefiles-initialized}"

fail_count=0

log() {
	echo "[INFO] $*"
}

ok() {
	echo "[OK] $*"
}

fail() {
	echo "[FAIL] $*"
	fail_count=$((fail_count + 1))
}

ensure_sandbox_workspace_write_config() {
	local config_path="$1"
	local tmp_file

	mkdir -p "$(dirname "${config_path}")"
	touch "${config_path}"
	tmp_file="$(mktemp)"
	awk '
BEGIN {
	in_section = 0
	section_seen = 0
	network_set = 0
}
{
	line = $0

	if (line ~ /^\[[^]]+\][[:space:]]*$/) {
		if (in_section && !network_set) {
			print "network_access = true"
			network_set = 1
		}
		if (line == "[sandbox_workspace_write]") {
			in_section = 1
			section_seen = 1
			network_set = 0
			print line
			next
		}
		in_section = 0
		print line
		next
	}

	if (in_section && line ~ /^[[:space:]]*network_access[[:space:]]*=/) {
		if (!network_set) {
			print "network_access = true"
			network_set = 1
		}
		next
	}

	print line
}
END {
	if (in_section && !network_set) {
		print "network_access = true"
	}
	if (!section_seen) {
		if (NR > 0) {
			print ""
		}
		print "[sandbox_workspace_write]"
		print "network_access = true"
	}
}
' "${config_path}" > "${tmp_file}"
	mv "${tmp_file}" "${config_path}"
}

copy_homefiles_once() {
	if [ -f "${marker_file}" ]; then
		ok "marker file exists (${marker_file}); skip homefiles copy"
		return
	fi

	if [ ! -d "${source_dir}" ]; then
		fail "homefiles source directory not found: ${source_dir}"
		return
	fi

	mkdir -p "${target_home}"
	cp -a "${source_dir}/." "${target_home}/"
	ensure_sandbox_workspace_write_config "${target_home}/.codex/config.toml"
	touch "${marker_file}"

	if [ "$(id -u)" -eq 0 ]; then
		chown -R "${target_user}:${target_group}" "${target_home}"
		ok "copied homefiles to ${target_home} and set owner ${target_user}:${target_group}"
	else
		ok "copied homefiles to ${target_home} (chown skipped: not root user)"
	fi

	ok "created first-run marker: ${marker_file}"
}

check_codex_login() {
	if ! command -v codex >/dev/null 2>&1; then
		fail "codex command not found"
		return
	fi
	if codex login status >/dev/null 2>&1; then
		ok "codex login status: logged in"
	else
		fail "codex login status: not logged in (run: codex login)"
	fi
}

check_gh_login() {
	if ! command -v gh >/dev/null 2>&1; then
		fail "gh command not found"
		return
	fi
	if gh auth status >/dev/null 2>&1; then
		ok "gh auth status: logged in"
	else
		fail "gh auth status: not logged in (run: gh auth login)"
	fi
}

check_kubectl_connectivity() {
	if ! command -v kubectl >/dev/null 2>&1; then
		fail "kubectl command not found"
		return
	fi

	if kubectl config current-context >/dev/null 2>&1; then
		ok "kubectl integration: current context is configured"
	else
		fail "kubectl integration: current context is not configured"
	fi
}

log "first-run checklist start"
copy_homefiles_once
check_codex_login
check_gh_login
check_kubectl_connectivity

if [ "${fail_count}" -gt 0 ]; then
	echo "[SUMMARY] checklist failed (${fail_count} item(s))"
	exit 1
fi

echo "[SUMMARY] checklist passed"
