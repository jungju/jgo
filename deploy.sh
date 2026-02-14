#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

load_env_file() {
  local env_file=${1:-.env}
  if [[ ! -f "$env_file" ]]; then
    return 0
  fi

  set -a
  # shellcheck disable=SC1090
  # shell에서 공용으로 쓰는 .env 형식(export 포함/미포함, 주석/공백)을 그대로 반영
  source "$env_file"
  set +a
  echo "환경설정 파일 로드: $env_file"
}

load_env_file "${ENV_FILE:-.env}"

require_command() {
  local cmd=$1
  command -v "$cmd" >/dev/null 2>&1 || fail "필수 명령어 '$cmd'를 찾을 수 없습니다."
}

require_var() {
  local name=$1
  local value=${!name:-}
  [[ -n "$value" ]] || fail "필수 환경 변수 '$name'가 설정되지 않았습니다."
}

json_escape() {
  local value=$1
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

deploy_k8s() {
  local tag=$1
  local image="${DOCKER_IMAGE}:${tag}"
  local -a kubectl_cmd=(kubectl)

  if [[ -n "${KUBE_NAMESPACE}" ]]; then
    kubectl_cmd+=( -n "$KUBE_NAMESPACE" )
  fi
  if [[ -n "${KUBE_CONFIG_FILENAME}" ]]; then
    kubectl_cmd+=( --kubeconfig "$KUBE_CONFIG_FILENAME" )
  fi
  kubectl_cmd+=( set image "deployment/$KUBE_DEPLOYMENT_NAME" "${KUBE_CONTAINER_NAME}=${image}" )

  echo "Kubernetes 배포 시작: deployment/$KUBE_DEPLOYMENT_NAME -> image=$image"
  "${kubectl_cmd[@]}"
  echo "Kubernetes 배포 완료."
}

get_latest_tag() {
  git tag --sort=-v:refname --list 'v[0-9]*.[0-9]*.[0-9]*' | head -n 1
}

next_tag() {
  local target=$1
  local last=${2:-}
  local major=0 minor=0 patch=0

  if [[ -n "$last" ]]; then
    local version=${last#v}
    IFS='.' read -r major minor patch <<< "$version"
    if ! [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ && "$patch" =~ ^[0-9]+$ ]]; then
      fail "지원하지 않는 태그 형식입니다: $last"
    fi
  fi

  case "$target" in
    patch)
      patch=$((patch + 1))
      ;;
    minor)
      minor=$((minor + 1))
      patch=0
      ;;
    major)
      major=$((major + 1))
      minor=0
      patch=0
      ;;
    *)
      fail "VERSION_TARGET 값이 올바르지 않습니다. (patch | minor | major)"
      ;;
  esac

  echo "v${major}.${minor}.${patch}"
}

create_release_if_needed() {
  local tag=$1
  local message=$2

  [[ -n "${GITHUB_TOKEN:-}" ]] || return 0

  local remote_url
  local repo_path
  local repo_owner
  local repo_name
  local payload

  remote_url=$(git remote get-url origin)
  case "$remote_url" in
    git@github.com:*) repo_path="${remote_url#git@github.com:}" ;;
    https://github.com/*) repo_path="${remote_url#https://github.com/}" ;;
    *) echo "[WARN] GitHub URL이 아니어서 Release 생성을 건너뜁니다: $remote_url" >&2; return 0 ;;
  esac

  repo_path="${repo_path%.git}"
  repo_owner="${repo_path%%/*}"
  repo_name="${repo_path#*/}"
  if [[ -z "$repo_owner" || "$repo_owner" == "$repo_path" || -z "$repo_name" ]]; then
    echo "[WARN] GitHub 저장소 정보를 파싱하지 못해 Release 생성을 건너뜁니다." >&2
    return 0
  fi

  payload=$(cat <<EOF
{
  "tag_name": "$(json_escape "$tag")",
  "name": "$(json_escape "$tag")",
  "body": "$(json_escape "$message")",
  "draft": false,
  "prerelease": false
}
EOF
)

  echo "GitHub Release 생성 시도: ${repo_owner}/${repo_name}#$tag"
  curl --fail -sS -XPOST \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "https://api.github.com/repos/$repo_owner/$repo_name/releases" >/dev/null
}

GIT_MAIN_BRANCH=${GIT_MAIN_BRANCH:-main}
VERSION_TARGET=${VERSION_TARGET:-patch}
VERSION_TARGET=${VERSION_TARGET,,}
KUBE_CONTAINER_NAME=${KUBE_CONTAINER_NAME:-container-0}
FORCE_DEPLOY=${FORCE_DEPLOY:-false}
ONLY_DEPLOY=${ONLY_DEPLOY:-false}
KUBE_NAMESPACE=${KUBE_NAMESPACE:-}
KUBE_DEPLOYMENT_NAME=${KUBE_DEPLOYMENT_NAME:-}
KUBE_CONFIG_FILENAME=${KUBE_CONFIG_FILENAME:-${KUBECONFIG:-}}
DOCKER_IMAGE=${DOCKER_IMAGE:-${DOCKER_IMAEG:-}}
GIT_TAG_MESSAGE=${GIT_TAG_MESSAGE:-$(git log -1 --pretty=format:%s)}

require_var DOCKER_IMAGE
require_var KUBE_DEPLOYMENT_NAME
require_var KUBE_CONTAINER_NAME

require_command git
require_command kubectl

if [[ "$FORCE_DEPLOY" != "true" ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    fail "로컬 변경 사항이 있습니다. 커밋 또는 스테이징 해제 후 다시 시도하세요."
  fi

  git fetch --prune
  if ! git show-ref --verify --quiet "refs/heads/$GIT_MAIN_BRANCH"; then
    fail "로컬 브랜치 '$GIT_MAIN_BRANCH'가 존재하지 않습니다."
  fi
  if ! git show-ref --verify --quiet "refs/remotes/origin/$GIT_MAIN_BRANCH"; then
    fail "원격 브랜치 'origin/$GIT_MAIN_BRANCH'가 존재하지 않습니다."
  fi
  if ! git diff --quiet "$GIT_MAIN_BRANCH" "origin/$GIT_MAIN_BRANCH"; then
    fail "메인 브랜치가 원격 브랜치와 동일하지 않습니다. 원격과 동기화 후 다시 시도하세요."
  fi

  echo "로컬 브랜치와 원격 브랜치가 동일합니다. 계속 진행합니다."
fi

last_tag=$(get_latest_tag)

if [[ "$ONLY_DEPLOY" == "true" ]]; then
  if [[ -z "$last_tag" ]]; then
    fail "최근 태그가 없어 바로 배포할 수 없습니다."
  fi
  deploy_k8s "$last_tag"
  echo "완료"
  exit 0
fi

new_tag=$(next_tag "$VERSION_TARGET" "$last_tag")
echo "새 태그: ${last_tag:-없음} -> $new_tag"

if git rev-parse "$new_tag" >/dev/null 2>&1; then
  fail "이미 존재하는 태그입니다: $new_tag"
fi

git tag -a "$new_tag" -m "$GIT_TAG_MESSAGE"
git push origin "$new_tag"

create_release_if_needed "$new_tag" "$GIT_TAG_MESSAGE"

require_command docker
docker build -t "$DOCKER_IMAGE:$new_tag" .
docker push "$DOCKER_IMAGE:$new_tag"

deploy_k8s "$new_tag"

echo "완료"
