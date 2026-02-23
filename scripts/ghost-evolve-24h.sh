#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ghost-evolve-24h.sh [--owner OWNER] [--repo REPO] [--duration-hours N] [--interval-minutes N] [--log-file PATH]

Description:
  Runs a non-interactive codex evolution loop for a repository.
  Each iteration asks codex to make one minimal meaningful improvement,
  verify, commit, and push.
USAGE
}

OWNER="${GH_OWNER:-jungju}"
REPO="${GH_REPO:-jgo}"
DURATION_HOURS="24"
INTERVAL_MINUTES="30"
LOG_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner) OWNER="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --duration-hours) DURATION_HOURS="${2:-}"; shift 2 ;;
    --interval-minutes) INTERVAL_MINUTES="${2:-}"; shift 2 ;;
    --log-file) LOG_FILE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if ! [[ "$DURATION_HOURS" =~ ^[0-9]+$ ]] || ! [[ "$INTERVAL_MINUTES" =~ ^[0-9]+$ ]]; then
  echo "duration-hours and interval-minutes must be integers" >&2
  exit 1
fi
if [[ "$DURATION_HOURS" -le 0 || "$INTERVAL_MINUTES" -le 0 ]]; then
  echo "duration-hours and interval-minutes must be > 0" >&2
  exit 1
fi

DEST="${HOME}/repos/github.com/${OWNER}/${REPO}"
if [[ ! -d "${DEST}/.git" ]]; then
  echo "repository not found at ${DEST}" >&2
  exit 1
fi
if ! command -v codex >/dev/null 2>&1; then
  echo "codex command not found" >&2
  exit 1
fi

mkdir -p "${HOME}/runs"
if [[ -z "$LOG_FILE" ]]; then
  LOG_FILE="${HOME}/runs/$(date +%Y%m%d-%H%M%S)-${REPO}-evolve.log"
fi

END_EPOCH=$(( $(date +%s) + DURATION_HOURS * 3600 ))
ITER=1

{
  echo "start: $(date -Iseconds)"
  echo "owner=${OWNER} repo=${REPO} duration_hours=${DURATION_HOURS} interval_minutes=${INTERVAL_MINUTES}"
  echo "repo_path=${DEST}"
} | tee -a "$LOG_FILE"

cd "$DEST"
git fetch --all --prune || true

echo "status_before:" | tee -a "$LOG_FILE"
git status -sb | tee -a "$LOG_FILE"

while [[ $(date +%s) -lt $END_EPOCH ]]; do
  NOW="$(date -Iseconds)"
  REMAIN_SEC=$(( END_EPOCH - $(date +%s) ))
  echo "[$NOW] iteration=${ITER} remain_sec=${REMAIN_SEC}" | tee -a "$LOG_FILE"

  PROMPT="https://github.com/${OWNER}/${REPO} 이 프로젝트를 스스로 진화해. 이번 반복에서는 최소 변경 1건만 수행하고 테스트/검증 가능한 명령을 실행한 뒤 커밋/푸시해. 비파괴적으로 진행하고 기존 변경은 되돌리지 마. 마지막에 변경 파일/검증 결과/남은 리스크를 짧게 보고해."

  if codex exec --full-auto --skip-git-repo-check "$PROMPT" >>"$LOG_FILE" 2>&1; then
    echo "[$(date -Iseconds)] iteration=${ITER} result=success" | tee -a "$LOG_FILE"
  else
    echo "[$(date -Iseconds)] iteration=${ITER} result=failed" | tee -a "$LOG_FILE"
  fi

  ITER=$((ITER + 1))
  if [[ $(date +%s) -ge $END_EPOCH ]]; then
    break
  fi

  SLEEP_SEC=$(( INTERVAL_MINUTES * 60 ))
  echo "sleep=${SLEEP_SEC}s" | tee -a "$LOG_FILE"
  sleep "$SLEEP_SEC"
done

echo "end: $(date -Iseconds) iterations=$((ITER - 1))" | tee -a "$LOG_FILE"
echo "log_file=${LOG_FILE}" | tee -a "$LOG_FILE"
