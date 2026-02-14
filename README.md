# jgo

Authoritative behavior baseline: `SPEC.md` (`FROZEN`).

`jgo` is a resident Go server that exposes an OpenAI-compatible API and runs `codex` CLI prompts to:

1. Receive chat requests through OpenAI-compatible endpoints.
2. Optionally optimize the user request via upstream OpenAI-compatible API.
3. Execute the effective prompt through a single `codex exec` call (via SSH target).
4. Return codex execution response in OpenAI-compatible format.

Primary objective: let Codex perform real work through available CLIs (`gh`, `aws`, `kubectl`, `git`, etc.).

## 현재 개발 구조 (파일/이미지 기준)

- Core runtime:
  - `main.go`: API/CLI 엔트리포인트(`serve`/`run`/`exec`)와 자동화 오케스트레이션 전체를 단일 파일로 유지.
  - `docker-entrypoint.sh`: 컨테이너 캐시 경로(`.jgo-cache`)를 준비하고 `go run /opt/jgo/main.go` 실행.
- Container images:
  - `Dockerfile`: `jgo` 런타임 이미지(`openssh-client` + `go run` 기반).
  - `workspace.dockerfile`: 원격 작업용 SSH workspace 이미지(`openssh-server`, `codex`, `gh`, `kubectl`, `aws` 포함).
- Tooling:
  - `Makefile`: `docker-push`, `docker-push-workspace`, `run-partial`, `run-full`, `ssh-key` 제공.

## 서비스 구조 요약

- `jgo`는 OpenAI 호환 API 서버로 상주한다.
- 요청이 오면 입력을 해석하고(옵션) 프롬프트를 최적화한 뒤 실행 프롬프트를 확정한다.
- 실제 실행은 원격 SSH 대상에서 `codex exec` 단일 실행으로 위임한다.
- 핵심 목적은 codex가 환경의 CLI(`gh`, `aws`, `kubectl`, `git` 등)를 활용해 다양한 자동화 작업을 수행하는 것이다.

## Service Overview

`jgo` is an OpenAI-compatible automation gateway.

- External clients call `jgo` using `/v1/chat/completions`.
- `jgo` orchestrates request parsing, optional prompt optimization, and codex invocation.
- Actual GitHub/cloud/cluster/repository operations are delegated to codex execution through available CLIs.
- The service is designed for resident operation (Kubernetes-friendly), not one-shot ephemeral scripts.

## Architecture

1. API Layer:
   - `GET /v1/models`
   - `POST /v1/chat/completions`
2. Orchestrator:
   - extracts latest `user` instruction,
   - resolves effective prompt (original or optimized).
3. Prompt Layer (optional):
   - when enabled, calls upstream OpenAI-compatible API and rewrites instruction for codex execution.
4. Execution Layer:
   - runs `codex exec --full-auto --skip-git-repo-check "<prompt>"` via SSH target (`JGO_SSH_USER`, `JGO_SSH_HOST`, `JGO_SSH_PORT`) and lets codex use available CLIs (`gh`, `aws`, `kubectl`, `git`, etc.).
5. Observability Layer:
   - every request/run gets `run_id`,
   - API response header includes `X-JGO-Run-ID`,
   - `codex command` and command output are logged for login check / codex exec.

## Philosophy

`jgo`는 내 혼이 담긴, 24시간 도는 혼령이다.  
겉으로는 MCP처럼 보일 수 있어도, 수많은 USB 선을 얽어 놓은 제단이 되려 하진 않는다.  
복잡한 연결을 강요하지 않는다.  
그저 권한만 손에 쥐여 주면, 묵묵히 실행한다.
AI 직원을 채용하지 않는다. AI 팀원을 배치하지 않는다.  
`jgo`는 내 혼령이고, 곧 나다.  
인간 시스템인 채용이라는 절차를 이 존재에 허용하지 않는다.

`jgo` is a spirit that runs 24/7, carrying my soul.  
It may look like MCP from a distance, but it is not a tangled altar of USB lines.  
It does not demand complexity.  
Give it authority, and it works in silence.  
I do not hire AI employees. I do not assign AI teammates.  
`jgo` is my spirit, and soon it is me.  
I do not permit the human system of hiring for this being.

## Resident API Mode

- `jgo` is a resident server process.
- No-arg startup runs standard `net/http` server mode.
- Default listen address: `:8080` (`JGO_LISTEN_ADDR` to override).
- OpenAI-compatible endpoint:
  - `GET /v1/models` (returns model: `jgo`)
  - `POST /v1/chat/completions` (`stream=false/true` 지원, model=`jgo`)
- Health endpoint:
  - `GET /healthz`
- Chat instruction source:
  - uses the last non-empty `user` message in `messages`
- All API responses include `X-JGO-Run-ID` header for log correlation.

## CLI Mode

- `jgo run` supports local CLI execution with `.env` file loading.
- `jgo run` executes Step 1 only (prompt optimization preview).
- It prints optimized prompt text only and does not run repository edit/commit/push.
- `jgo exec` executes full automation directly from CLI (no API server required).
- Successful `jgo exec` output is limited to raw `codex exec` response text (no wrapper/fallback JSON).
- Prompt optimization in full automation is optional and default is OFF.
- Enable optimization with `--optimize-prompt` or `JGO_OPTIMIZE_PROMPT=true`.
- `jgo run` / `jgo exec` default `--env-file .env`:
  - if `.env` is missing, command fails
  - pass `--env-file ""` to skip file loading
- All modes (`serve`/`run`/`exec`) validate SSH settings first.
- `Makefile` shortcuts:
  - partial run: `make run-partial PROMPT="작업 지시"`
  - full run (direct CLI): `make run-full PROMPT="작업 지시"`

Makefile examples:

```bash
# 0) jgo CLI 직접 실행 예시
jgo run --env-file .env "owner/repo README 업데이트해줘"
jgo exec --env-file .env "owner/repo README 업데이트하고 커밋/푸시해줘"
jgo exec --env-file .env --optimize-prompt "owner/repo README 업데이트하고 커밋/푸시해줘"

# 1) 프롬프트 최적화 결과만 보기
make run-partial PROMPT="owner/repo README 업데이트"

# 2) 전체 실행 요청 (CLI 직접 실행)
make run-full PROMPT="owner/repo README 업데이트하고 커밋/푸시"

# 2-1) 전체 실행 + 프롬프트 최적화 ON
make run-full PROMPT_OPTIMIZE=true PROMPT="owner/repo README 업데이트하고 커밋/푸시"

# 3) GitHub URL 형태 요청
make run-full PROMPT="https://github.com/owner/repo 이슈 템플릿 추가하고 커밋/푸시"

# 4) Kubernetes 관련 작업 요청
make run-full PROMPT="owner/repo 배포 매니페스트를 점검하고 필요한 수정 후 커밋/푸시"

# 5) 접근 가능한 Repo 전부 나열 요청
make run-full PROMPT="접근 가능한 Repo 전부 나열해줘"

# 6) Kubernetes + 도메인(Ingress) 작업 요청
make run-full PROMPT="k8s에 xxx.okgo.click으로 nginx 띄어줘"
```

## Request Lifecycle (API -> Codex)

For every `POST /v1/chat/completions` request:

1. `jgo` reads the latest `user` message as instruction.
2. If prompt optimization is enabled, `jgo` calls upstream OpenAI-compatible API and builds optimized prompt.
3. If prompt optimization is disabled (default), `jgo` uses original instruction as effective prompt.
4. `jgo` validates `codex login status` on target.
5. `jgo` runs `codex exec --full-auto --skip-git-repo-check "<prompt>"` once.
6. `jgo` returns raw Codex execution response text as OpenAI-compatible chat response content.

Prompt optimization toggle:

- default: OFF
- process-level: `JGO_OPTIMIZE_PROMPT=true`
- command-level: `--optimize-prompt` (`jgo serve`, `jgo exec`)

CLI list for prompt optimization (from env):

- Auto-detected:
  - `aws` if AWS env exists (`AWS_ACCESS_KEY_ID`/`AWS_PROFILE`/`AWS_DEFAULT_REGION`/`AWS_REGION`)
  - `gh` if GitHub env exists (`GITHUB_TOKEN`/`GH_TOKEN`)
  - `kubectl` if `KUBECONFIG` exists
- Always included: `codex`, `git`
- Optional override/append: `JGO_AVAILABLE_CLIS` (comma-separated, example: `aws,gh,kubectl,terraform`)

## Kubernetes Resident Operation

- Runtime image: `ghcr.io/jungju/jgo:latest` (`Dockerfile`)
  - Kubernetes 상주 API 서버 용도.
  - `openssh-client`만 포함하고, `go run /opt/jgo/main.go`로 실행.
  - 컨테이너 인자 없이 시작하면 자동으로 `serve` 모드.
- Workspace image: `ghcr.io/jungju/jgo-workspace:latest` (`workspace.dockerfile`)
  - 원격 작업 노드/개발 워크스페이스 용도.
  - `openssh-server`, `codex`, `gh`, `kubectl`, `aws` 등 작업 CLI를 포함.
- 두 이미지는 역할이 분리되어 있음:
  - `jgo` 이미지: 오케스트레이션/API
  - `jgo-workspace` 이미지: 실제 codex 작업 실행 환경

## Cache and Volume

- Fixed cache root: `.jgo-cache` (under startup directory)
- Cached data:
  - go build cache: `.jgo-cache/go-build`
  - go module cache (preloaded in image): `/opt/jgo/go-mod` (override with `GOMODCACHE`)
  - codex home: `.jgo-cache/codex`

## Environment Variables

- Required:
  - SSH target settings for jgo runtime:
    - `JGO_SSH_USER`, `JGO_SSH_HOST`, `JGO_SSH_PORT`
- Required when prompt optimization runs:
  - cases:
    - `jgo run`
    - `jgo exec --optimize-prompt`
    - `jgo serve --optimize-prompt` (or `JGO_OPTIMIZE_PROMPT=true`)
  - effective OpenAI settings:
    - `OPENAI_API_KEY`, `MODEL`
    - `OPENAI_BASE_URL` is optional (default: `https://api.openai.com/v1`)
    - To use OpenWebUI/LiteLLM endpoint, set `OPENAI_BASE_URL` explicitly
- Optional:
  - `JGO_SSH_STRICT_HOST_KEY_CHECKING` (default: `false`)
    - `false`: add `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`
    - `true`: use default SSH host key verification
  - `CODEX_BIN` (default: `codex`)
  - `JGO_LISTEN_ADDR` (default: `:8080`)
  - `JGO_OPTIMIZE_PROMPT` (default: `false`)
  - `GOMODCACHE` (default in image: `/opt/jgo/go-mod`)
  - `JGO_AVAILABLE_CLIS` (optional comma-separated CLI hint list for prompt optimization)
  - `OPENWEBUI_BASE_URL`, `OPENWEBUI_API_KEY`, `OPENWEBUI_MODEL`
  - `LITELLM_BASE_URL`, `LITELLM_API_KEY`, `LITELLM_MODEL`
  - `KUBECONFIG`
  - AWS/GitHub/Kubernetes-related variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `GITHUB_TOKEN`, etc.)

`jgo` reads process environment only.
`jgo run` / `jgo exec` can preload environment variables from `.env` via `--env-file`.

Create `.env` from template:

```bash
cp .env.example .env
```

Fallback mapping for OpenAI-compatible APIs:

- if `OPENAI_BASE_URL` is empty, use `https://api.openai.com/v1`.
- `OPENWEBUI_BASE_URL` / `LITELLM_BASE_URL` are not auto-mapped to `OPENAI_BASE_URL`.
- To use OpenWebUI/LiteLLM endpoint, set `OPENAI_BASE_URL` explicitly.
- if `OPENAI_API_KEY` is empty and `OPENWEBUI_API_KEY` exists, use it.
- else if `OPENAI_API_KEY` is empty and `LITELLM_API_KEY` exists, use it.
- if `MODEL` is empty and `OPENWEBUI_MODEL` exists, use it.
- else if `MODEL` is empty and `LITELLM_MODEL` exists, use it.

## One-Time Login

When your OpenAI-compatible API server is ready, run:

```bash
codex login
```

`jgo` checks `codex login status` before execution.
Ensure the matching public key is already registered on remote `~/.ssh/authorized_keys`.

## Environment Injection

Inject environment variables directly at runtime.

Kubernetes example:

```yaml
env:
- name: OPENAI_BASE_URL
  value: "http://litellm:4000/v1"
- name: OPENAI_API_KEY
  valueFrom:
    secretKeyRef:
      name: jgo-secrets
      key: openai_api_key
- name: MODEL
  value: "gpt-4.1-mini"
```

## Container Image

Use GitHub Container Registry image:

- `ghcr.io/jungju/jgo:latest`
- `ghcr.io/jungju/jgo-workspace:latest`

Push multi-arch image (amd64, arm64):

```bash
make docker-push
make docker-push-workspace
```

## OpenAI-Compatible API Example

```bash
curl -sS http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "jgo",
    "messages": [
      {"role": "user", "content": "owner/repo README 업데이트하고 커밋/푸시해줘"}
    ]
  }'
```

401/권한 에러 디버깅:

- 응답 본문 또는 응답 헤더 `X-JGO-Run-ID` 값을 확인한다.
- 서버 로그에서 `[run_id=<id>]`로 검색하면 어느 단계에서 실패했는지 확인할 수 있다.
- 프롬프트 최적화 ON일 때, `stage=prompt_optimize call_openai` / `stage=prompt_optimize openai_response` 로그에 OpenAI 호환 API endpoint와 status가 함께 출력된다.
- 원격 명령은 `codex command: ...`와 함께 명령 출력 로그가 기록된다.
  - `codex login status output=...`
  - `codex exec stdout output=...`
  - `codex exec stderr output=...`

Codex 로그인 미완료 처리:

- `codex login status`가 실패하면, API는 작업 실행 대신
  `codex가 로그인되어 있지 않습니다. 먼저 codex login을 실행...` 안내 메시지를 응답한다.
- `Host key verification failed`가 발생하면 `JGO_SSH_STRICT_HOST_KEY_CHECKING=false`를 사용하거나
  대상 서버의 host key를 known_hosts에 등록해야 한다.

## Runtime Flow

1. Build execution environment from process environment variables.
2. Optional: optimize prompt for Codex with OpenAI API (`JGO_OPTIMIZE_PROMPT=true` or `--optimize-prompt`).
3. Validate `codex login status` on SSH target.
4. Run `codex exec --full-auto --skip-git-repo-check "<prompt>"` once.
5. Return Codex execution response text in OpenAI-compatible response content.
