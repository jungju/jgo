# jgo

`jgo` is a minimal Go CLI wrapper that clones a repository and runs `codex` CLI prompts to:

1. Validate whether a chat request is executable.
2. Optimize the request with OpenAI API for Codex execution.
3. Apply the optimized request via `codex`.
4. Commit changes.
5. Push the branch.

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

## Request Handling Rule

For every `jgo run "<chat request>"` call:

1. `jgo` asks OpenAI-compatible API to decide `executable` and generate `optimized_prompt`.
2. If `executable=false`, `jgo` stops with error reason.
3. If `executable=true`, `jgo` always executes through `codex`.

## Kubernetes Resident Operation

- Runtime image: `ghcr.io/jungju/jgo:latest`
- This image is intended to run in Kubernetes with persistent cache volume.
- Docker image uses Ubuntu and runs `jgo` as a script via `go run /opt/jgo/main.go`.
- Docker image uses dedicated cache root (`JGO_CACHE_DIR`, default: `/jgo-cache`) for persistent data.
- Container startup auto-loads `.env` into process environment (`JGO_ENV_FILE`, default: `/work/.env`).

## Cache and Volume

- Dedicated cache root: `JGO_CACHE_DIR` (default `/jgo-cache`)
- Cached data:
  - repo mirror cache: `<JGO_CACHE_DIR>/repos`
  - per-run worktrees: `<JGO_CACHE_DIR>/work`
  - go build/module cache: `<JGO_CACHE_DIR>/go-build`, `<JGO_CACHE_DIR>/go-mod`
  - codex home: `<JGO_CACHE_DIR>/codex`

For Kubernetes, mount a persistent volume to `/jgo-cache` (or your custom `JGO_CACHE_DIR`) to retain cache across pod restarts.

## Environment Variables

- Required:
  - Effective OpenAI settings:
    - `OPENAI_BASE_URL`, `OPENAI_API_KEY`, `MODEL`
    - or fallback from OpenWebUI/LiteLLM variables
- Optional:
  - `CODEX_BIN` (default: `codex`)
  - `JGO_CACHE_DIR` (default: `/jgo-cache`)
  - `JGO_ENV_FILE` (default: `/work/.env`)
  - `OPENWEBUI_BASE_URL`, `OPENWEBUI_API_KEY`, `OPENWEBUI_MODEL`
  - `LITELLM_BASE_URL`, `LITELLM_API_KEY`, `LITELLM_MODEL`
  - `KUBECONFIG`
  - AWS/GitHub/Kubernetes-related variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `GITHUB_TOKEN`, etc.)

Container entrypoint exports variables from `.env` into process environment, and `jgo` reads process environment only.
`jgo` caches repositories under `JGO_CACHE_DIR` and reuses them across runs.
Cache path priority: process env `JGO_CACHE_DIR` > `.env` `JGO_CACHE_DIR` > default `/jgo-cache`.

Fallback mapping for OpenAI-compatible APIs:

- if `OPENAI_BASE_URL` is empty and `OPENWEBUI_BASE_URL` exists, use it.
- else if `OPENAI_BASE_URL` is empty and `LITELLM_BASE_URL` exists, use it.
- if `OPENAI_API_KEY` is empty and `OPENWEBUI_API_KEY` exists, use it.
- else if `OPENAI_API_KEY` is empty and `LITELLM_API_KEY` exists, use it.
- if `MODEL` is empty and `OPENWEBUI_MODEL` exists, use it.
- else if `MODEL` is empty and `LITELLM_MODEL` exists, use it.

## Keybox Format

Keybox is fixed to project root `.env`.

Create it from template:

```bash
cp .env.example .env
```

`.env` style:

```env
OPENWEBUI_BASE_URL=http://openwebui:8080/openai/v1
OPENWEBUI_API_KEY=your_openwebui_key
MODEL=gpt-4.1-mini
JGO_CACHE_DIR=/jgo-cache
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
GITHUB_TOKEN=...
KUBECONFIG=/work/.kube/config
```

## One-Time Login

When your OpenAI-compatible API server is ready, run:

```bash
codex login
```

`jgo` checks `codex login status` before execution.

## Environment Input

### Docker/Container `.env`

```bash
cp .env.example .env
```

Run-time environment loading:

- Docker: `--env-file .env`
- Container entrypoint: reads `JGO_ENV_FILE` (default `/work/.env`) if present
- Kubernetes: recommended via `Secret` + `envFrom`

Create Kubernetes Secret from `.env`:

```bash
kubectl create secret generic jgo-env --from-env-file=.env
```

## Container Run

Use GitHub Container Registry image:

- `ghcr.io/jungju/jgo:latest`

Build multi-arch image (amd64, arm64):

```bash
make docker-build
```

Push multi-arch image (amd64, arm64):

```bash
make docker-push
```

Run once:

```bash
docker run --rm -it \
  --env-file .env \
  -v "$(pwd)/jgo-cache:/jgo-cache" \
  ghcr.io/jungju/jgo:latest \
  run "owner/repo README에 설치 방법 추가하고 Makefile에 make dev 타겟 추가해줘"
```

## Kubernetes Resident Run

`jgo`를 k8s에 상주시킬 때는 Deployment로 띄우고 `kubectl exec`로 명령을 실행한다.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jgo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jgo
  template:
    metadata:
      labels:
        app: jgo
    spec:
      containers:
        - name: jgo
          image: ghcr.io/jungju/jgo:latest
          command: ["bash", "-lc", "sleep infinity"]
          envFrom:
            - secretRef:
                name: jgo-env
          volumeMounts:
            - name: cache
              mountPath: /jgo-cache
      volumes:
        - name: cache
          persistentVolumeClaim:
            claimName: jgo-cache-pvc
```

상주 Pod에 실행:

```bash
kubectl exec -it deploy/jgo -- jgo run "owner/repo 변경사항 반영하고 커밋/푸시해줘"
```

## Runtime Flow

1. Build execution environment from OS env (container can preload `.env`).
2. Use OpenAI API to validate request executability and generate Codex-optimized prompt.
3. Stop on non-executable requests.
4. Resolve repository URL from prompt repository reference (`owner/repo` -> `https://github.com/owner/repo.git`).
5. Sync repo mirror cache under `JGO_CACHE_DIR/repos`.
6. Create run worktree under `JGO_CACHE_DIR/work` and clone from cached mirror.
7. Create branch `jgo/<timestamp>`.
8. Run `codex exec` with optimized prompt (Codex can use `aws`, `gh`, `kubectl`, OpenAI-compatible APIs).
9. Run `codex exec` again (gist-style prompt) to split commits and push to `origin`.
10. Print created branch name.

## Commit/Push Prompt Source

Commit/push behavior follows this gist workflow:

- https://gist.github.com/jungju/abf2184c1f7a8853ab9ba6b1f7e86650
