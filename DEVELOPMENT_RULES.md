# Development Rules

## Spec Lock

- `SPEC.md` is the source of truth for purpose/goal/scope/invariants.
- Do not change frozen behavior without explicit user approval.
- If behavior changes are approved, update `SPEC.md` version and changelog in the same change.

## Scope

- Keep this project as a minimal MVP.
- Keep implementation in root `main.go`.
- Avoid unnecessary abstraction.
- Keep container/runtime tooling simple (`Dockerfile`, `Makefile`).

## CLI Rules

- Support `jgo serve`, `jgo run`, and `jgo exec`.
- `jgo run` is prompt-optimization preview mode only.
- `jgo exec` is full automation mode.
- Fail fast on invalid input.
- Print errors to stderr.

## Runtime Rules

- Use dedicated cache root `.jgo-cache` under startup directory.
- Do not create jgo-managed per-run temporary workspaces.
- Build Codex env from process environment only.
- Require SSH target envs: `JGO_SSH_USER`, `JGO_SSH_HOST`, `JGO_SSH_PORT`.
- Never print SSH public key logs at startup.
- Keep default `OPENAI_BASE_URL` as `https://api.openai.com/v1` when unset.
- Support OpenWebUI/LiteLLM fallback mapping to `OPENAI_API_KEY`.
- Support OpenWebUI/LiteLLM model fallback mapping to `MODEL`.
- Generate Codex-optimized prompt via OpenAI API only when optimization is enabled.
- Prompt optimization default is OFF (`JGO_OPTIMIZE_PROMPT=false`).
- Build available CLI hints for prompt optimization from environment variables.
- Execute all repository modification work through `codex exec --full-auto --skip-git-repo-check`.
- Pass `KUBECONFIG` when provided.
- Run `codex exec --full-auto --skip-git-repo-check "<prompt>"` with inline prompt argument.
- Execute codex once per automation request.

## Codex Rules

- Codex execution uses the optimized prompt only when optimization is enabled.
- Otherwise Codex execution must use the original user instruction.
- Invoke codex subprocess via SSH target from env (`JGO_SSH_USER`, `JGO_SSH_HOST`, `JGO_SSH_PORT`).
- `codex login status` must pass before execution.
- If not logged in, instruct user to run `codex login` after OpenAI-compatible API server startup.
- Use non-interactive commands only in prompts.
- Assume `aws`, `gh`, and `kubectl` CLIs may be used by Codex during tasks.

## Git Rules

- Do not amend or rewrite commits.
- Do not force-push.
- Commit messages should follow concise Conventional Commits.

## Build Rules

- Keep Docker build targets minimal: `make docker-push`.
- `make docker-push` must push multi-arch image for both `linux/amd64` and `linux/arm64`.
- Docker image may use an official Go runtime base image.
- Keep runtime/build definitions to `Dockerfile` and `workspace.dockerfile`.
- Docker image must install `openssh-client` only (no local codex/aws/gh/kubectl install).
- Docker runtime must execute `jgo` as script (`go run`), not prebuilt binary.
- Docker defaults must set persistent cache paths (`GOCACHE`, `GOMODCACHE`, `CODEX_HOME`).
- Kubernetes deployment should mount persistent volume to cache root.

## Safety Rules

- Avoid jgo-managed temporary workspace creation.
