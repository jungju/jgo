#!/usr/bin/env bash
set -euo pipefail

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
error() { echo "[ERROR] $*" >&2; }

usage() {
  cat <<'EOF'
Usage: scripts/jgo-codex-auth-test.sh [options]

Options:
  --namespace <name>      Kubernetes namespace (default: ai)
  --service <name>        Kubernetes service/deployment name (default: jgo)
  --service-port <port>   Service port for API (default: 8080)
  --local-port <port>     Local port-forward port (default: 18080)
  --base-url <url>        Use direct API URL (skip kubectl)
  --kubeconfig <path>     KUBECONFIG path for kubectl
  --timeout <seconds>     Curl timeout per request (default: 15)
  --wait-timeout <sec>    Port-forward wait timeout (default: 60)
  --expect-login-required  API는 로그인 필요 메시지를 반환해야 함
  --expect-login-ok        API/CLI 모두 로그인되어 있어야 함
  --skip-codex-exec        codex exec 스모크 테스트 건너뜀
  --codex-prompt <text>    codex exec 확인 프롬프트 (기본 제공문구)
  --help                   Show this help message.
EOF
}

require_command() {
  local cmd=$1
  command -v "$cmd" >/dev/null 2>&1 || {
    error "필수 명령어 '$cmd'가 필요합니다."
    exit 1
  }
}

wait_for_tcp() {
  local port=$1
  local timeout=$2
  local start
  start="$(date +%s)"

  while true; do
    if command -v nc >/dev/null 2>&1; then
      if nc -z -w 1 127.0.0.1 "$port" >/dev/null 2>&1; then
        return 0
      fi
    elif (echo > /dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1; then
      return 0
    fi

    if (( $(date +%s) - start >= timeout )); then
      return 1
    fi
    sleep 1
  done
}

cleanup() {
  if [[ -n "${PF_PID:-}" ]]; then
    kill "$PF_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "${PORTFORWARD_LOG:-}" && -f "${PORTFORWARD_LOG}" ]]; then
    rm -f "$PORTFORWARD_LOG"
  fi
}

setup_base_url() {
  if [[ -n "${BASE_URL:-}" ]]; then
    return 0
  fi

  require_command kubectl
  kubectl_cmd=(kubectl)
  if [[ -n "${KUBECONFIG_PATH:-}" ]]; then
    kubectl_cmd+=(--kubeconfig "$KUBECONFIG_PATH")
  fi

  "${kubectl_cmd[@]}" config current-context >/dev/null
  "${kubectl_cmd[@]}" get namespace "$NAMESPACE" >/dev/null
  "${kubectl_cmd[@]}" get svc "$SERVICE" -n "$NAMESPACE" >/dev/null
  "${kubectl_cmd[@]}" get deploy "$SERVICE" -n "$NAMESPACE" >/dev/null || \
    "${kubectl_cmd[@]}" get deployment "$SERVICE" -n "$NAMESPACE" >/dev/null || \
    warn "deployment를 찾지 못했습니다. service만 확인되면 계속 진행합니다."

  PORTFORWARD_LOG="$(mktemp)"
  "${kubectl_cmd[@]}" -n "$NAMESPACE" port-forward "svc/$SERVICE" "${LOCAL_PORT}:${SERVICE_PORT}" >"$PORTFORWARD_LOG" 2>&1 &
  PF_PID=$!
  if ! wait_for_tcp "$LOCAL_PORT" "$WAIT_TIMEOUT"; then
    error "포트포워드 준비 실패 (${WAIT_TIMEOUT}s)."
    if [[ -f "$PORTFORWARD_LOG" ]]; then
      cat "$PORTFORWARD_LOG" >&2 || true
    fi
    exit 1
  fi
  BASE_URL="http://127.0.0.1:${LOCAL_PORT}"
  log "API URL: ${BASE_URL}"
}

call_api_chat() {
  local payload=$1
  local code
  local out_header out_body
  local body run_id

  out_header="$(mktemp)"
  out_body="$(mktemp)"
  code="$(curl --max-time "$TIMEOUT" -sS -X POST -H 'Content-Type: application/json' -d "$payload" -D "$out_header" -o "$out_body" -w '%{http_code}' "$BASE_URL/v1/chat/completions" || printf '000')"
  body="$(cat "$out_body")"
  run_id="$(awk 'BEGIN{IGNORECASE=1} /^x-jgo-run-id: / {sub(/^x-jgo-run-id:[[:space:]]*/, "", $0); print $0; exit}' "$out_header" | tr -d '\r' || true)"

  if [[ "$code" != "200" ]]; then
    error "POST /v1/chat/completions 응답 코드: ${code}"
    echo "Headers:" >&2
    sed 's/^/[headers] /' "$out_header" >&2 || true
    echo "Body:" >&2
    sed 's/^/[body] /' "$out_body" >&2 || true
    rm -f "$out_header" "$out_body"
    return 1
  fi

  if [[ -z "$run_id" ]]; then
    warn "X-JGO-Run-ID 헤더가 없습니다."
  else
    log "X-JGO-Run-ID: ${run_id}"
  fi
  echo "$body"
  rm -f "$out_header" "$out_body"
  return 0
}

NAMESPACE="${K8S_NAMESPACE:-ai}"
SERVICE="${K8S_WORKLOAD:-jgo}"
SERVICE_PORT="${K8S_SERVICE_PORT:-8080}"
LOCAL_PORT="18080"
BASE_URL="${SMOKE_TEST_BASE_URL:-}"
KUBECONFIG_PATH="${KUBECONFIG:-}"
TIMEOUT="15"
WAIT_TIMEOUT="60"
EXPECT_LOGIN="auto"
SKIP_CODEX_EXEC="false"
CODEX_PROMPT="현재 작업 디렉토리 경로와 현재 시간을 출력하고 codex-codex-auth-test-ok라고 한 줄로 반환해줘."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      NAMESPACE="$2"
      shift 2
      ;;
    --service)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      SERVICE="$2"
      shift 2
      ;;
    --service-port)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      SERVICE_PORT="$2"
      shift 2
      ;;
    --local-port)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      LOCAL_PORT="$2"
      shift 2
      ;;
    --base-url)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      BASE_URL="$2"
      shift 2
      ;;
    --kubeconfig)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      KUBECONFIG_PATH="$2"
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      TIMEOUT="$2"
      shift 2
      ;;
    --wait-timeout)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      WAIT_TIMEOUT="$2"
      shift 2
      ;;
    --expect-login-required)
      EXPECT_LOGIN="required"
      shift
      ;;
    --expect-login-ok)
      EXPECT_LOGIN="ok"
      shift
      ;;
    --skip-codex-exec)
      SKIP_CODEX_EXEC="true"
      shift
      ;;
    --codex-prompt)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      CODEX_PROMPT="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      error "알 수 없는 옵션: $1"
      usage
      exit 1
      ;;
  esac
done

trap cleanup EXIT

require_command codex
require_command curl

if ! codex login status >/tmp/jgo_codex_auth_status.log 2>&1; then
  LOGIN_STATUS="required"
  codex_login_output="$(cat /tmp/jgo_codex_auth_status.log)"
else
  LOGIN_STATUS="ok"
  codex_login_output=""
fi
rm -f /tmp/jgo_codex_auth_status.log

log "codex login status: ${LOGIN_STATUS}"
if [[ -n "$codex_login_output" ]]; then
  log "login status output: ${codex_login_output}"
fi

case "$EXPECT_LOGIN" in
  required)
    if [[ "$LOGIN_STATUS" != "required" ]]; then
      error "예상: 로그인 필요, 실제: 로그인됨"
      exit 1
    fi
    ;;
  ok)
    if [[ "$LOGIN_STATUS" != "ok" ]]; then
      error "예상: 로그인 완료, 실제: 로그인 미완료"
      exit 1
    fi
    ;;
esac

if [[ "$SKIP_CODEX_EXEC" != "true" ]]; then
  if [[ "$LOGIN_STATUS" == "required" ]]; then
    warn "codex 로그인 미완료 상태: codex exec smoke는 건너뜁니다."
  else
    if ! codex exec --full-auto --skip-git-repo-check "$CODEX_PROMPT" >/tmp/jgo_codex_exec.log 2>&1; then
      error "codex exec 테스트 실패"
      cat /tmp/jgo_codex_exec.log >&2 || true
      exit 1
    fi
    if ! grep -Fq "codex-codex-auth-test-ok" /tmp/jgo_codex_exec.log; then
      warn "codex exec 응답에서 확인 토큰을 찾지 못했습니다."
    else
      log "codex exec 테스트 통과"
    fi
    rm -f /tmp/jgo_codex_exec.log
  fi
else
  warn "codex exec smoke test skipped"
fi

setup_base_url
payload='{"model":"jgo","messages":[{"role":"user","content":"ping"}],"stream":false}'
chat_body="$(call_api_chat "$payload")" || exit 1

case "$EXPECT_LOGIN" in
  required)
    if ! grep -Fq 'codex가 로그인되어 있지 않습니다' <<< "$chat_body"; then
      error "API는 로그인 필요 메시지를 반환하지 않았습니다."
      exit 1
    fi
    log "API 로그인 필요 케이스 통과"
    ;;
  ok)
    if ! grep -Fq '"object":"chat.completion"' <<< "$chat_body"; then
      error "API 로그인 완료 응답에서 chat.completion 형식이 없습니다."
      exit 1
    fi
    log "API 로그인 완료 케이스 통과"
    ;;
  auto)
    if [[ "$LOGIN_STATUS" == "required" ]]; then
      if ! grep -Fq 'codex가 로그인되어 있지 않습니다' <<< "$chat_body"; then
        error "로그인 미완료 상태에서 API 안내 메시지가 없습니다."
        exit 1
      fi
      log "API 로그인 미완료 동작 일치"
    else
      if ! grep -Fq '"object":"chat.completion"' <<< "$chat_body"; then
        error "로그인 완료 상태에서 API 응답 형식이 chat.completion이 아닙니다."
        exit 1
      fi
      log "API 로그인 완료 동작 일치"
    fi
    ;;
esac

log "Codex 로그인/실행 검증 테스트 통과"
