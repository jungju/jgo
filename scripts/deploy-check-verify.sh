#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

log() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/deploy-check-verify.sh [--check-only] [--help]

Options:
  --check-only   Run pre/post verification without executing deploy.sh.
  --help         Show this help message.
EOF
}

load_env_file() {
  local env_file=${1:-.env}
  if [[ ! -f "$env_file" ]]; then
    return 0
  fi

  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
  log "환경설정 파일 로드: $env_file"
}

require_command() {
  local cmd=$1
  command -v "$cmd" >/dev/null 2>&1 || fail "필수 명령어 '$cmd'를 찾을 수 없습니다."
}

require_var() {
  local name=$1
  local value=${!name:-}
  [[ -n "$value" ]] || fail "필수 환경 변수 '$name'가 설정되지 않았습니다."
}

CHECK_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only)
      CHECK_ONLY=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "알 수 없는 옵션: $1 (도움말: --help)"
      ;;
  esac
done

load_env_file "${ENV_FILE:-.env}"

KUBE_NAMESPACE=${KUBE_NAMESPACE:-}
KUBE_DEPLOYMENT_NAME=${KUBE_DEPLOYMENT_NAME:-}
KUBE_CONTAINER_NAME=${KUBE_CONTAINER_NAME:-container-0}
KUBE_CONFIG_FILENAME=${KUBE_CONFIG_FILENAME:-${KUBECONFIG:-}}
ROLLOUT_TIMEOUT=${ROLLOUT_TIMEOUT:-180s}
DEPLOY_SCRIPT=${DEPLOY_SCRIPT:-"${repo_root}/deploy.sh"}

require_command kubectl
require_command git
require_command bash
require_var KUBE_DEPLOYMENT_NAME
require_var KUBE_CONTAINER_NAME

kubectl_cmd=(kubectl)
if [[ -n "${KUBE_NAMESPACE}" ]]; then
  kubectl_cmd+=( -n "${KUBE_NAMESPACE}" )
fi
if [[ -n "${KUBE_CONFIG_FILENAME}" ]]; then
  kubectl_cmd+=( --kubeconfig "${KUBE_CONFIG_FILENAME}" )
fi

log "사전 체크 시작"
"${kubectl_cmd[@]}" config current-context >/dev/null
if [[ -n "${KUBE_NAMESPACE}" ]]; then
  "${kubectl_cmd[@]}" get namespace "${KUBE_NAMESPACE}" >/dev/null
fi
"${kubectl_cmd[@]}" get deployment "${KUBE_DEPLOYMENT_NAME}" >/dev/null

container_names="$("${kubectl_cmd[@]}" get deployment "${KUBE_DEPLOYMENT_NAME}" -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{" "}{end}')"
if ! grep -Eq "(^| )${KUBE_CONTAINER_NAME}( |$)" <<<"${container_names}"; then
  fail "deployment/${KUBE_DEPLOYMENT_NAME} 에 컨테이너 '${KUBE_CONTAINER_NAME}'가 없습니다. (현재: ${container_names:-없음})"
fi

log "사전 체크 완료"

if [[ "${CHECK_ONLY}" != "true" ]]; then
  [[ -x "${DEPLOY_SCRIPT}" ]] || fail "deploy 스크립트를 실행할 수 없습니다: ${DEPLOY_SCRIPT}"
  log "배포 실행: ${DEPLOY_SCRIPT}"
  "${DEPLOY_SCRIPT}"
fi

log "사후 검증 시작"
"${kubectl_cmd[@]}" rollout status "deployment/${KUBE_DEPLOYMENT_NAME}" --timeout="${ROLLOUT_TIMEOUT}"

selector="$("${kubectl_cmd[@]}" get deployment "${KUBE_DEPLOYMENT_NAME}" -o jsonpath='{range $k,$v := .spec.selector.matchLabels}{$k}={$v}{","}{end}')"
selector="${selector%,}"
if [[ -z "${selector}" ]]; then
  fail "deployment/${KUBE_DEPLOYMENT_NAME} selector를 찾지 못했습니다."
fi

pod_health="$("${kubectl_cmd[@]}" get pods -l "${selector}" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{range .status.containerStatuses[*]}{.state.waiting.reason}{" "}{.lastState.terminated.reason}{" "}{end}{"\n"}{end}')"
if grep -Eiq 'CrashLoopBackOff|ImagePullBackOff|ErrImagePull|RunContainerError|CreateContainerConfigError|CreateContainerError' <<<"${pod_health}"; then
  echo "${pod_health}" >&2
  fail "배포 후 파드 상태에 오류 패턴이 감지되었습니다."
fi

"${kubectl_cmd[@]}" get deployment "${KUBE_DEPLOYMENT_NAME}" -o wide
"${kubectl_cmd[@]}" get pods -l "${selector}" -o wide

if ! "${kubectl_cmd[@]}" get events --sort-by=.metadata.creationTimestamp --field-selector type=Warning | tail -n 20; then
  warn "Warning 이벤트 조회에 실패했습니다. 권한 설정을 확인하세요."
fi

log "사후 검증 완료"
echo "[SUMMARY] deploy check/verify passed"
