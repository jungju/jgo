# GitHub Copilot Instructions — jgo

## Project Context
jgo is an OpenAI-compatible resident Go server that delegates task execution to `codex` CLI. Single-file architecture (`main.go`), Go standard library only, no external dependencies.

## Critical Rules
- **SPEC/SPEC.md is FROZEN**: Do not change behavior defined in the spec without explicit user approval.
- **Single file**: All logic stays in `main.go`. Do not split into packages.
- **Codex-only execution**: jgo never directly calls `git`, `gh`, `aws`, `kubectl` for user tasks. All work goes through `codex exec --full-auto --skip-git-repo-check`.
- **No external Go dependencies**: Use only the Go standard library.
- **No force-push/amend**: Follow safe Git practices with Conventional Commits.

## Code Style
- Error wrapping: `fmt.Errorf("context: %w", err)`
- HTTP handlers: `http.NewServeMux` + `HandleFunc` closures
- JSON responses: use existing `writeJSON` and `writeOpenAIError` helpers
- Every request gets a `run_id` via `nextRunID()`, included in `X-JGO-Run-ID` header
- Logging: structured stderr via `logRunf(ctx, ...)`
- Config: loaded from environment variables via `loadConfigFromEnv()`

## Architecture
- Subcommands: `serve` (API server) and `exec` (CLI direct execution)
- API endpoints: `/healthz`, `/v1/models`, `/v1/chat/completions`, `/api/runs`
- Prompt optimization: optional (default OFF), uses upstream OpenAI-compatible API
- Execution transport: `local` (default) or `ssh`
- Model ID is fixed to `jgo`
- Successful responses contain raw codex output only — no wrappers or fallback JSON

## Environment Variables
- `JGO_LISTEN_ADDR` (default `:8080`), `JGO_EXEC_TRANSPORT` (default `local`)
- `JGO_SSH_USER`, `JGO_SSH_HOST`, `JGO_SSH_PORT` — SSH transport config
- `JGO_OPTIMIZE_PROMPT` (default `false`) — prompt optimization toggle
- `OPENAI_API_KEY`, `MODEL` — required when optimization enabled
- `CODEX_BIN` (default `codex`), `CODEX_REASONING_EFFORT` (default `xhigh`)

## Testing
- No unit tests (MVP). Validation via `make verify` (smoke-test + codex-auth-test).
- Kubernetes defaults: namespace=`ai`, workload=`jgo`, port=`8080`.

## Files to Know
- `main.go` — all server/CLI/automation logic
- `SPEC/SPEC.md` — frozen behavioral spec (read first)
- `SPEC/DEVELOPMENT_RULES.md` — development constraints
- `Makefile` — build/deploy/test targets
- `Dockerfile` — single runtime image
- `docker-entrypoint.sh` — container startup
- `monitor/` — web UI for chat monitoring
- `scripts/` — deployment/verification scripts
