# Development Rules

## Scope

- Keep this project as a minimal MVP.
- Keep implementation in root `main.go`.
- Avoid unnecessary abstraction.
- Keep container/runtime tooling simple (`Dockerfile`, `Makefile`).

## CLI Rules

- Support only `jgo run "<instruction>"`.
- Fail fast on invalid input.
- Print errors to stderr.

## Runtime Rules

- Use dedicated cache root `JGO_CACHE_DIR` (default `/jgo-cache`).
- Cache repository mirrors under `<JGO_CACHE_DIR>/repos`.
- Create per-run work directories under `<JGO_CACHE_DIR>/work`.
- Build Codex env from process environment only.
- Container entrypoint may preload `.env` into process environment.
- Keep `.env.example` as the canonical template for runtime variables.
- Support OpenWebUI/LiteLLM fallback mapping to `OPENAI_BASE_URL`/`OPENAI_API_KEY`.
- Support OpenWebUI/LiteLLM model fallback mapping to `MODEL`.
- Validate request executability via OpenAI API before any repository changes.
- Generate Codex-optimized prompt via OpenAI API.
- Stop immediately if request is not executable.
- Always create branch: `jgo/<timestamp>`.
- Pass `KUBECONFIG` when provided.
- Run `codex exec --full-auto --cd <repo> -` with stdin prompt for code changes.
- Run `codex exec --full-auto --cd <repo> -` again for commit/push.

## Codex Rules

- Codex execution must always use the OpenAI-optimized prompt.
- `codex login status` must pass before execution.
- If not logged in, instruct user to run `codex login` after OpenAI-compatible API server startup.
- Use non-interactive commands only in prompts.
- Assume `aws`, `gh`, and `kubectl` CLIs may be used by Codex during tasks.

## Git Rules

- Ensure `origin` remote exists.
- Do not amend or rewrite commits.
- Do not force-push.
- Commit messages should follow concise Conventional Commits.

## Build Rules

- Keep Docker build targets minimal: `make docker-build`, `make docker-push`.
- `make docker-push` must push multi-arch image for both `linux/amd64` and `linux/arm64`.
- Docker base image must be Ubuntu.
- Docker image must include ARM Codex CLI, AWS CLI, GitHub CLI, `kubectl`, and `go` CLI.
- Docker runtime must execute `jgo` as script (`go run`), not prebuilt binary.
- Docker defaults must set persistent cache paths (`JGO_CACHE_DIR`, `GOCACHE`, `GOMODCACHE`, `CODEX_HOME`).
- Docker runtime must auto-export `.env` variables through entrypoint (`JGO_ENV_FILE`).
- Kubernetes deployment should mount persistent volume to cache root.

## Safety Rules

- Operate only inside temporary cloned repository.
- If codex produces no changes, stop with error.
