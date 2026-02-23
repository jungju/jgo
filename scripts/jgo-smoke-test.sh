#!/usr/bin/env bash
set -euo pipefail

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
error() { echo "[ERROR] $*" >&2; }

usage() {
  cat <<'EOF'
Usage: scripts/jgo-smoke-test.sh [options]

Options:
  --namespace <name>      Kubernetes namespace (default: ai)
  --service <name>        Kubernetes service/deployment name (default: jgo)
  --service-port <port>   Service port for API (default: 8080)
  --local-port <port>     Local port-forward port (default: 18080)
  --base-url <url>        Use direct URL, skip kubectl setup
  --kubeconfig <path>     KUBECONFIG path for kubectl
  --timeout <seconds>     Curl timeout per request (default: 15)
  --wait-timeout <sec>    Port-forward wait timeout (default: 60)
  --expect-auth-only      Expect API to return login-required message
  --check-stream          Validate SSE style stream response
  --help                  Show this help message.
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

call_api() {
  local method=$1
  local path=$2
  local body=${3:-}
  local expect_substring=${4:-}

  local out_header out_body
  out_header="$(mktemp)"
  out_body="$(mktemp)"

  local code
  if [[ "$method" == "GET" ]]; then
    code="$(curl --max-time "$TIMEOUT" -sS -D "$out_header" -o "$out_body" -w '%{http_code}' "$BASE_URL$path" || printf '000')"
  else
    code="$(curl --max-time "$TIMEOUT" -sS -X POST -H 'Content-Type: application/json' -d "$body" -D "$out_header" -o "$out_body" -w '%{http_code}' "$BASE_URL$path" || printf '000')"
  fi

  local body_content=""
  body_content="$(cat "$out_body")"
  local run_id
  run_id="$(awk 'BEGIN{IGNORECASE=1} /^x-jgo-run-id: / {sub(/^x-jgo-run-id:[[:space:]]*/, "", $0); print $0; exit}' "$out_header" | tr -d '\r' || true)"

  if [[ "$code" != "200" ]]; then
    error "${method} ${path} -> HTTP ${code}"
    echo "Headers:" >&2
    sed 's/^/[headers] /' "$out_header" >&2 || true
    echo "Body:" >&2
    sed 's/^/[body] /' "$out_body" >&2 || true
    rm -f "$out_body" "$out_header"
    return 1
  fi

  if [[ -n "$expect_substring" ]] && ! grep -Fq "$expect_substring" "$out_body"; then
    error "${method} ${path}: expected substring not found -> ${expect_substring}"
    echo "Body: ${body_content}" >&2
    rm -f "$out_body" "$out_header"
    return 1
  fi

  if [[ -z "$run_id" ]]; then
    warn "${method} ${path}: X-JGO-Run-ID 헤더가 없습니다."
  else
    log "${method} ${path} OK (run_id=${run_id})"
  fi

  echo "$body_content"
  rm -f "$out_body" "$out_header"
  return 0
}

cleanup() {
  if [[ -n "${PF_PID:-}" ]]; then
    kill "$PF_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "${PORTFORWARD_LOG:-}" && -f "${PORTFORWARD_LOG}" ]]; then
    rm -f "$PORTFORWARD_LOG"
  fi
}

NAMESPACE="${K8S_NAMESPACE:-ai}"
SERVICE="${K8S_WORKLOAD:-jgo}"
SERVICE_PORT="${K8S_SERVICE_PORT:-8080}"
LOCAL_PORT="18080"
BASE_URL="${SMOKE_TEST_BASE_URL:-}"
KUBECONFIG_PATH="${KUBECONFIG:-}"
TIMEOUT="15"
WAIT_TIMEOUT="60"
EXPECT_AUTH_ONLY="false"
CHECK_STREAM="false"

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
    --expect-auth-only)
      EXPECT_AUTH_ONLY="true"
      shift
      ;;
    --check-stream)
      CHECK_STREAM="true"
      shift
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

require_command curl
if [[ -z "$BASE_URL" ]]; then
  require_command kubectl
  kubectl_cmd=(kubectl)
  if [[ -n "$KUBECONFIG_PATH" ]]; then
    kubectl_cmd+=(--kubeconfig "$KUBECONFIG_PATH")
  fi

  "${kubectl_cmd[@]}" config current-context >/dev/null
  "${kubectl_cmd[@]}" get namespace "$NAMESPACE" >/dev/null
  "${kubectl_cmd[@]}" get svc "$SERVICE" -n "$NAMESPACE" >/dev/null
  "${kubectl_cmd[@]}" get deploy "$SERVICE" -n "$NAMESPACE" >/dev/null || \
    "${kubectl_cmd[@]}" get deployment "$SERVICE" -n "$NAMESPACE" >/dev/null || \
    warn "deployment를 찾지 못했습니다. service만 확인되면 계속 진행합니다."

  service_ports="$("${kubectl_cmd[@]}" -n "$NAMESPACE" get svc "$SERVICE" -o jsonpath='{range .spec.ports[*]}{.port}{"\n"}{end}')"
  if ! grep -qx "$SERVICE_PORT" <<< "$service_ports"; then
    error "서비스 '$SERVICE' 에 포트 '$SERVICE_PORT' 가 정의되어 있지 않습니다."
    echo "$service_ports" | sed 's/^/[service.ports] /' >&2
    exit 1
  fi

  PORTFORWARD_LOG="$(mktemp)"
  "${kubectl_cmd[@]}" -n "$NAMESPACE" port-forward "svc/$SERVICE" "${LOCAL_PORT}:${SERVICE_PORT}" >"$PORTFORWARD_LOG" 2>&1 &
  PF_PID=$!

  if ! wait_for_tcp "$LOCAL_PORT" "$WAIT_TIMEOUT"; then
    error "포트포워드가 ${WAIT_TIMEOUT}초 내에 준비되지 않았습니다."
    if [[ -f "$PORTFORWARD_LOG" ]]; then
      cat "$PORTFORWARD_LOG" >&2 || true
    fi
    exit 1
  fi

  BASE_URL="http://127.0.0.1:${LOCAL_PORT}"
  log "port-forward established: svc/${SERVICE} -> ${BASE_URL}"
else
  log "직접 URL 사용: ${BASE_URL}"
fi

failures=0

health_body="$(call_api GET "/healthz" "" '"status":"ok"' )" || failures=$((failures + 1))

models_body="$(call_api GET "/v1/models" "" '"object":"list"' )" || failures=$((failures + 1))
if [[ "$failures" -eq 0 ]]; then
  if ! grep -Fq '"id":"jgo"' <<< "$models_body"; then
    warn "/v1/models 응답에 model=jgo 정보가 없을 수 있습니다."
  fi
fi

chat_payload='{"model":"jgo","messages":[{"role":"user","content":"ping"}],"stream":false}'
chat_body="$(call_api POST "/v1/chat/completions" "$chat_payload" '"model":"jgo"' )" || failures=$((failures + 1))
if [[ "$failures" -eq 0 ]]; then
  if [[ "$EXPECT_AUTH_ONLY" == "true" ]]; then
    if ! grep -Fq 'codex가 로그인되어 있지 않습니다' <<< "$chat_body"; then
      error "AUTH 전용 모드에서 기대 응답이 아닙니다 (로그인 안내 메시지 없음)."
      failures=$((failures + 1))
    else
      log "POST /v1/chat/completions OK (login-required response confirmed)"
    fi
  else
    if ! grep -Fq '"object":"chat.completion"' <<< "$chat_body"; then
      error "POST /v1/chat/completions 응답에 chat.completion이 없습니다."
      failures=$((failures + 1))
    fi
  fi
fi

if [[ "$CHECK_STREAM" == "true" ]]; then
  stream_payload='{"model":"jgo","messages":[{"role":"user","content":"ping"}],"stream":true}'
  if ! stream_body="$(curl -sS --max-time "$TIMEOUT" -N -H 'Content-Type: application/json' -d "$stream_payload" "$BASE_URL/v1/chat/completions")"; then
    error "POST /v1/chat/completions stream 테스트 요청 실패"
    failures=$((failures + 1))
  elif [[ -z "$stream_body" ]]; then
    error "POST /v1/chat/completions stream 테스트 응답이 비어 있습니다."
    failures=$((failures + 1))
  elif ! grep -Fq 'data:' <<< "$stream_body"; then
    error "POST /v1/chat/completions stream 응답이 SSE 형식이 아닙니다."
    failures=$((failures + 1))
  else
    log "POST /v1/chat/completions stream OK"
  fi
fi

if [[ "$failures" -ne 0 ]]; then
  error "Smoke test failed: 실패 ${failures}건"
  exit 1
fi

log "Smoke test passed"
