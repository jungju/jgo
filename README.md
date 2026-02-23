# jgo

Authoritative behavior baseline: `SPEC/SPEC.md` (`FROZEN`).

`jgo` is a resident Go server that exposes an OpenAI-compatible API and runs `codex` CLI prompts to:

1. Receive chat requests through OpenAI-compatible endpoints.
2. Optionally optimize the user request via upstream OpenAI-compatible API.
3. Execute the effective prompt through a single `codex exec` call (default: local direct execution, optional SSH target).
4. Return codex execution response in OpenAI-compatible format.

Primary objective: let Codex perform real work through available CLIs (`gh`, `aws`, `kubectl`, `git`, etc.).

## 현재 개발 구조 (파일/이미지 기준)

- Core runtime:
  - `main.go`: API/CLI 엔트리포인트(`serve`/`exec`)와 자동화 오케스트레이션 전체를 단일 파일로 유지.
  - `docker-entrypoint.sh`: 컨테이너 캐시 경로(`.jgo-cache`)를 준비하고 `go run /opt/jgo/main.go` 실행.
- Container images:
  - `Dockerfile`: 단일 런타임/워크스페이스 이미지 정의(`codex`, `gh`, `kubectl`, `aws`, `openssh-client` + `main.go` 실행 포함).
- Tooling:
- `Makefile`: `docker-push`, `push`, `run-full`, `ssh-key`, `deploy-check` 제공.
  - self-growth loop dry-run: `make ghost-grow`
  - autonomous dev loop scaffold: `make autonomous-loop PROMPT="task text"`
- Chat monitor site (MVP):
  - `monitor/index.html`, `monitor/styles.css`, `monitor/app.js`
  - GitHub Pages deploy workflow: `.github/workflows/pages-chat-monitor.yml`

## 서비스 구조 요약

- `jgo`는 OpenAI 호환 API 서버로 상주한다.
- 요청이 오면 입력을 해석하고(옵션) 프롬프트를 최적화한 뒤 실행 프롬프트를 확정한다.
- 실제 실행은 기본적으로 컨테이너 내부에서 `codex exec`를 직접 실행하고, 필요 시에만 SSH 대상으로 위임한다.
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
   - runs `codex exec --full-auto --skip-git-repo-check "<prompt>"` on selected transport:
   - default: local process execution (`JGO_EXEC_TRANSPORT=local`)
   - optional: SSH target execution (`JGO_EXEC_TRANSPORT=ssh`)
   - codex can use available CLIs (`gh`, `aws`, `kubectl`, `git`, etc.).
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

- `jgo exec` executes full automation directly from CLI (no API server required).
- Successful `jgo exec` output is limited to raw `codex exec` response text (no wrapper/fallback JSON).
- Prompt optimization in full automation is optional and default is OFF.
- Enable optimization with `--optimize-prompt` or `JGO_OPTIMIZE_PROMPT=true`.
- `jgo exec` default `--env-file .env`:
  - if `.env` is missing, command fails
  - pass `--env-file ""` to skip file loading
- All modes (`serve`/`exec`) validate execution transport settings first (`ssh` 선택 시에만 SSH 설정 검증).
- `Makefile` shortcuts:
  - full run (direct CLI): `make run-full PROMPT="작업 지시"`
  - transport override: `make run-full EXEC_TRANSPORT=ssh PROMPT="작업 지시"`

Makefile examples:

```bash
# 0) jgo CLI 직접 실행 예시
jgo exec --env-file .env "owner/repo README 업데이트하고 커밋/푸시해줘"
jgo exec --env-file .env --optimize-prompt "owner/repo README 업데이트하고 커밋/푸시해줘"
jgo exec --env-file .env --transport ssh "원격 SSH 대상으로 실행해줘"

# 1) 전체 실행 요청 (CLI 직접 실행)
make run-full PROMPT="owner/repo README 업데이트하고 커밋/푸시"

# 1-1) 전체 실행 + 프롬프트 최적화 ON
make run-full PROMPT_OPTIMIZE=true PROMPT="owner/repo README 업데이트하고 커밋/푸시"

# 2) GitHub URL 형태 요청
make run-full PROMPT="https://github.com/owner/repo 이슈 템플릿 추가하고 커밋/푸시"

# 3) Kubernetes 관련 작업 요청
make run-full PROMPT="owner/repo 배포 매니페스트를 점검하고 필요한 수정 후 커밋/푸시"

# 4) 접근 가능한 Repo 전부 나열 요청
make run-full PROMPT="접근 가능한 Repo 전부 나열해줘"

# 5) Kubernetes + 도메인(Ingress) 작업 요청
make run-full PROMPT="k8s에 xxx.okgo.click으로 nginx 띄어줘"

# 6) 배포 사전 체크 + 배포 + 사후 검증을 한 번에 실행
make deploy-check

# 6-1) 체크만 수행(배포 생략)
bash scripts/deploy-check-verify.sh --check-only

# 7) self-growth loop (repo 생성/개발 시작/공개 자동화 시뮬레이션)
make ghost-grow

# 7-1) 실제 실행 (로컬 생성 + gh 원격 생성/푸시)
bash scripts/ghost-self-growth-loop.sh --execute --owner <owner> --repo <repo>

# 8) autonomous dev loop scaffold (run artifacts + checklist + retrospective)
make autonomous-loop PROMPT="owner/repo 에서 최소 변경으로 기능 구현, 테스트, 커밋, 푸시"

# 8-1) execute mode (repo sync + branch + verification + push attempt)
make autonomous-loop EXECUTE=true PROMPT="owner/repo 작업 지시" OWNER=<owner> REPO=<repo> TOPIC=<topic>
```

## Autonomous Dev Live Monitor Site (`chat.okgo.click`)

목적:
- 로그인 없이 접속 가능한 관제실형 모니터링 채팅 MVP
- 좌측 이벤트 스트림 + 우측 요약 패널
- 하단 고정 입력창 + 세션별 로컬 저장(localStorage)
- OpenAI-compatible `/v1/chat/completions` 엔드포인트와 바로 연동

레포 구조:
- `monitor/index.html`: UI 레이아웃
- `monitor/styles.css`: 반응형 관제실 스타일
- `monitor/app.js`: 세션 저장/응답 요청/템플릿 강제
- `monitor/CNAME`: `chat.okgo.click`
- `monitor/.nojekyll`: 정적 파일 처리
- `.github/workflows/pages-chat-monitor.yml`: GitHub Pages 자동 배포

로컬 실행:

```bash
cd monitor
node -e 'const http=require("http"),fs=require("fs"),path=require("path");const root=process.cwd();http.createServer((req,res)=>{const p=req.url==="/"?"index.html":req.url.slice(1);fs.readFile(path.join(root,p),(e,d)=>{if(e){res.statusCode=404;return res.end("not found");}res.end(d);});}).listen(4173)'
# open http://localhost:4173
```

사용 방법:
1. 우측 상단 `Settings`에서 Endpoint URL(예: `https://<host>/v1/chat/completions`) 입력
2. 필요 시 API Key/Model 입력 후 Save
3. 하단 입력창으로 커밋 로그/PR 상태/테스트/배포 로그를 전송
4. 응답은 고정 포맷(상태 요약/이상 징후/구조 분석/개선/Top3 행동/고급 분석)으로 유지

배포 (GitHub Pages):
1. GitHub 저장소 `Settings -> Pages`에서 Source를 `GitHub Actions`로 설정
2. `main` 브랜치에 `monitor/**` 변경이 push되면 `Deploy Chat Monitor to GitHub Pages` 워크플로우 실행
3. DNS에서 `chat.okgo.click`을 GitHub Pages 도메인으로 연결
4. 배포 후 `https://chat.okgo.click` 접속 확인

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
  - Kubernetes 상주 API 서버 + codex 실행 환경을 단일 이미지로 제공.
  - `main.go`를 포함하고 `go run /opt/jgo/main.go`로 실행.
  - `codex`, `gh`, `kubectl`, `aws`, `openssh-client` 등을 포함.
  - 기본 실행은 로컬 직접 실행(`JGO_EXEC_TRANSPORT=local`)이며 SSH 서버 기동이 필요 없다.
  - 필요할 때만 `JGO_EXEC_TRANSPORT=ssh` + `JGO_SSH_*` 설정으로 원격 SSH 실행을 사용한다.

Manual first-run checklist (after container startup):

```bash
jgo-first-run-checklist
# optional target override:
# TARGET_HOME=/home/jgo jgo-first-run-checklist
```

- 체크 항목:
  - codex 로그인 여부 (`codex login status`)
  - gh 로그인 여부 (`gh auth status`)
  - kubectl 연동 여부 (`kubectl config current-context`)
- `homefiles`를 `/home/jgo/`로 최초 1회 복사한다.
- 최초 복사 시 marker file (`/home/jgo/.jgo-homefiles-initialized`)을 생성한다.
- marker file이 있으면 재실행해도 `homefiles` 복사를 건너뛴다.
- `~/.ssh/id_ed25519`, `~/.ssh/id_ed25519.pub`를 준비한다.
- `JGO_EXEC_TRANSPORT=ssh`일 때만 `~/.ssh/authorized_keys`에 `~/.ssh/id_ed25519.pub`를 포함한다.
- 최초 복사 시 `~/.codex/config.toml`에 아래 설정을 보장한다.
  - `[sandbox_workspace_write]`
  - `network_access = true`

## Cache and Volume

- Fixed cache root: `.jgo-cache` (under startup directory)
- Cached data:
  - go build cache: `.jgo-cache/go-build`
  - go module cache (preloaded in image): `/home/jgo/.cache/go-mod` (override with `GOMODCACHE`)
  - codex home: `~/.codex` (기본값)

## Environment Variables

- Execution transport:
  - `JGO_EXEC_TRANSPORT` (default: `local`, allowed: `local|ssh`)
- Optional SSH target settings (used only when `JGO_EXEC_TRANSPORT=ssh`):
  - `JGO_SSH_USER`, `JGO_SSH_HOST`, `JGO_SSH_PORT`
- Required when prompt optimization runs:
  - cases:
    - `jgo exec --optimize-prompt`
    - `jgo serve --optimize-prompt` (or `JGO_OPTIMIZE_PROMPT=true`)
  - effective OpenAI settings:
    - `OPENAI_API_KEY`, `MODEL`
    - `OPENAI_BASE_URL` is optional (default: `https://api.openai.com/v1`)
    - To use OpenWebUI/LiteLLM endpoint, set `OPENAI_BASE_URL` explicitly
- Optional:
  - `CODEX_HOME` (default in image: `/home/jgo/.codex`)
  - `CODEX_BIN` (default: `codex`)
  - `JGO_LISTEN_ADDR` (default: `:8080`)
  - `JGO_OPTIMIZE_PROMPT` (default: `false`)
  - `GOMODCACHE` (default in image: `/home/jgo/.cache/go-mod`)
  - `JGO_AVAILABLE_CLIS` (optional comma-separated CLI hint list for prompt optimization)
  - `OPENWEBUI_BASE_URL`, `OPENWEBUI_API_KEY`, `OPENWEBUI_MODEL`
  - `LITELLM_BASE_URL`, `LITELLM_API_KEY`, `LITELLM_MODEL`
  - `KUBECONFIG`
  - AWS/GitHub/Kubernetes-related variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `GITHUB_TOKEN`, etc.)

`jgo` reads process environment only.
`jgo exec` can preload environment variables from `.env` via `--env-file`.

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
When `JGO_EXEC_TRANSPORT=ssh`, ensure the matching public key is already registered on remote `~/.ssh/authorized_keys`.

## Verification Scripts

`jgo` 운영 검증은 다음 명령으로 자동화할 수 있습니다.

```bash
# API smoke-test (k8s 서비스 기반 포트포워드)
make smoke-test

# Codex 로그인/실행 검증
make codex-auth-test
```

환경이 다를 경우:

```bash
# API만 직접 URL로 검사
make K8S_NAMESPACE=ai K8S_WORKLOAD=jgo K8S_SERVICE_PORT=8080 SMOKE_TEST_BASE_URL="http://127.0.0.1:18080" smoke-test

# 로그인 상태를 강제 가정해서 검사
make CODEX_AUTH_EXPECT=required codex-auth-test   # 로그인 미완료 케이스
make CODEX_AUTH_EXPECT=ok codex-auth-test         # 로그인 완료 케이스(로그인된 환경 필요)
```

## Environment Injection

Inject environment variables directly at runtime.

Kubernetes example:

```yaml
env:
- name: JGO_EXEC_TRANSPORT
  value: "local"
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

Push multi-arch image (amd64, arm64):

```bash
make docker-push
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

## Runtime Flow

1. Build execution environment from process environment variables.
2. Optional: optimize prompt for Codex with OpenAI API (`JGO_OPTIMIZE_PROMPT=true` or `--optimize-prompt`).
3. Validate `codex login status` on selected target (local or SSH).
4. Run `codex exec --full-auto --skip-git-repo-check "<prompt>"` once.
5. Return Codex execution response text in OpenAI-compatible response content.
