# jgo SPEC (Frozen)

- Project: `jgo`
- Spec Version: `1.0.21`
- Status: `FROZEN`
- Last Updated: `2026-02-14`

## 1. Purpose

`jgo` is a resident/CLI automation runtime that converts natural-language requests into executable Codex tasks, with optional repository commit/push automation.

Core intent:
- keep orchestration minimal,
- delegate all real repository manipulation to `codex`,
- keep behavior predictable and non-interactive.

## 2. Primary Goals

1. Provide OpenAI-compatible server endpoints for integration (`/v1/chat/completions`, `/v1/models`).
2. Provide direct CLI execution paths without requiring server mode.
3. Support optional prompt optimization into a Codex-optimized prompt via OpenAI-compatible API.
4. Execute tasks through `codex exec --full-auto --skip-git-repo-check` only.
5. For repository-scoped requests, perform edit + commit/push in separate Codex phases.

## 3. Non-Goals

1. `jgo` does not directly edit repository files.
2. `jgo` does not directly run git operations for clone/checkout/add/commit/push.
3. `jgo` does not implement complex internal planners, task queues, or distributed scheduling.
4. `jgo` does not own authentication UX beyond validating `codex login status`.

## 4. Fixed Execution Model (Invariants)

1. Repository operations are Codex-only:
   - All repo manipulation must be performed by `codex`.
   - `jgo` must not call git CLI for repo changes.
2. Prompt optimization contract (when enabled) is fixed:
   - OpenAI Chat Completions compatible endpoint.
   - `MODEL` from environment.
   - `temperature = 1` (fixed).
   - response format is strict JSON with key:
     - `{"optimized_prompt":"string"}`
3. Prompt optimization toggle:
   - default is disabled (`JGO_OPTIMIZE_PROMPT=false`).
   - can be enabled by `JGO_OPTIMIZE_PROMPT=true`.
   - can be enabled per command with `--optimize-prompt` (`jgo serve`, `jgo exec`).
4. Repository reference handling:
   - If request contains repo ref (`owner/repo` or GitHub URL): run repo-scoped flow.
   - If repo ref is absent: run workspace-only flow and skip commit/push phase.
5. Non-interactive execution:
   - Codex prompts must require non-interactive command behavior.
6. Runtime workspace:
   - create remote per-run temporary workspace via `mktemp -d /tmp/jgo-run-XXXXXX`.
   - remove the remote workspace after run (best effort cleanup).
7. Codex process invocation:
   - execute codex commands through SSH target from env:
     - `JGO_SSH_USER`, `JGO_SSH_HOST`, `JGO_SSH_PORT`.
     - optional: `JGO_SSH_STRICT_HOST_KEY_CHECKING` (default false).
   - include `--skip-git-repo-check` in codex exec command.
   - pass codex edit/commit prompts as inline `codex exec` command arguments (not via stdin).
8. SSH key management:
   - `jgo` must not require environment-provided private key material.
   - `jgo` must not persist SSH private key material from environment variables.
   - SSH authentication must rely on key material already available to the runtime `ssh` client.
   - `jgo` must not print SSH public key logs at startup.
9. API behavior:
   - `/v1/chat/completions` supports `stream=false` and `stream=true`.
   - server uses the last non-empty `user` message as instruction.
   - served model is fixed to `jgo`.
10. Startup/CLI behavior:
   - all entrypoints (`serve`, `run`, `exec`) validate SSH settings before execution.
   - `run` and `exec` default to `--env-file .env`; missing file is an error unless `--env-file ""` is used.
11. Observability:
   - each request/execution must have a generated `run_id`.
   - `/v1/chat/completions` response must include `X-JGO-Run-ID` header.
   - codex SSH invocations must log both command and command output for:
     - `codex login status`
     - remote workdir prepare (`mktemp -d /tmp/jgo-run-XXXXXX`)
     - `codex exec`
12. Runtime/Workspace image split:
   - `Dockerfile` defines the `jgo` runtime/server image.
   - `workspace.dockerfile` defines the remote workspace execution image.

## 5. Interfaces

## 5.1 CLI

1. `jgo run [--env-file .env] "<instruction>"`
   - executes prompt optimization only.
   - outputs optimized prompt text.
   - still requires SSH settings because shared startup validation runs first.
2. `jgo exec [--env-file .env] "<instruction>"`
   - executes full automation.
   - `--optimize-prompt` enables prompt optimization for this execution.
   - outputs JSON:
     - `{"status":"ok","branch":"<branch-or-empty>"}`.
3. `jgo serve [--optimize-prompt]`
   - starts OpenAI-compatible resident server.

## 5.2 Server API

1. `GET /healthz`
2. `GET /v1/models` (model id: `jgo`)
3. `POST /v1/chat/completions`
   - reads latest user message as instruction.
   - runs same automation logic as CLI full flow.
   - includes `X-JGO-Run-ID` response header for log correlation.

## 5.3 Runtime Artifacts

1. `Dockerfile`
   - runtime API/orchestrator image for `jgo`.
2. `workspace.dockerfile`
   - SSH workspace image for remote codex task execution.

## 6. Environment Requirements

Always required:
1. `JGO_SSH_USER`
2. `JGO_SSH_HOST`
3. `JGO_SSH_PORT`

Required only when prompt optimization is enabled:
1. `OPENAI_API_KEY`
2. `MODEL`

Defaults:
1. `OPENAI_BASE_URL=https://api.openai.com/v1`
2. `CODEX_BIN=codex`
3. `JGO_LISTEN_ADDR=:8080`
4. `JGO_OPTIMIZE_PROMPT=false`
5. `JGO_SSH_STRICT_HOST_KEY_CHECKING=false`

Fallbacks:
1. If `OPENAI_API_KEY` missing: fallback to `OPENWEBUI_API_KEY` then `LITELLM_API_KEY`.
2. If `MODEL` missing: fallback to `OPENWEBUI_MODEL` then `LITELLM_MODEL`.

## 7. Error and Safety Rules

1. Fail fast on invalid/missing required configuration.
2. If `codex login status` fails, return actionable login-required message.
3. Do not use destructive git rewrite flows (force-push/amend/reset).
4. Keep prompts scoped and minimal.

## 8. Spec Freeze Policy

This specification is locked.

Any behavior change that affects goals, interfaces, invariants, or execution model requires:
1. explicit user approval,
2. `SPEC.md` version bump,
3. changelog entry in this section.

## 9. Changelog

- `1.0.21` (`2026-02-14`): changed codex execution prompt delivery from stdin to inline command argument for `codex exec`.
- `1.0.20` (`2026-02-14`): documented runtime/workspace image split and fixed observability contract (`run_id`, `X-JGO-Run-ID`, codex command/output logging).
- `1.0.19` (`2026-02-13`): removed environment-private-key requirement from runtime validation and documentation; SSH now relies on key material already available to the runtime `ssh` client.
- `1.0.18` (`2026-02-13`): removed fixed `.jgo-cache/work` execution workspace; automation now uses remote temporary workdirs under `/tmp/jgo-run-*` with cleanup.
- `1.0.17` (`2026-02-13`): documentation sync with runtime behavior; clarified mode-based env requirements, streaming/model behavior, SSH key permission handling, and shared startup validation.
- `1.0.16` (`2026-02-14`): removed SSH key-path override; an environment private key became required and was persisted to `~/.ssh/id_ed25519` for SSH execution.
- `1.0.15` (`2026-02-14`): removed startup SSH key auto-generation/public-key logging and removed environment-private-key behavior; SSH now uses existing key file path only.
- `1.0.14` (`2026-02-14`): removed environment-based cache-root configuration; cache root is fixed to `.jgo-cache`.
- `1.0.13` (`2026-02-14`): added environment-private-key support to load SSH private key from environment and use it for SSH connections.
- `1.0.12` (`2026-02-14`): removed remote workdir environment override; remote codex workdir is now fixed to `.jgo-cache/work/run-*`.
- `1.0.11` (`2026-02-14`): separated remote codex workspace root to avoid remote absolute-path permission errors.
- `1.0.10` (`2026-02-14`): normalized legacy absolute cache path `/jgo-cache` to `.jgo-cache` for workspace execution compatibility.
- `1.0.9` (`2026-02-14`): added fixed SSH key auto-generation/loading and startup public-key log; added SSH key-path override.
- `1.0.8` (`2026-02-14`): added `JGO_SSH_STRICT_HOST_KEY_CHECKING` (default `false`) to control SSH host key verification behavior.
- `1.0.7` (`2026-02-14`): made SSH target settings required for execution (`JGO_SSH_USER`, `JGO_SSH_HOST`, `JGO_SSH_PORT`); removed localhost/22 defaults.
- `1.0.6` (`2026-02-14`): prompt optimization is now optional for full automation; default OFF (`JGO_OPTIMIZE_PROMPT=false`) and can be enabled via `--optimize-prompt`.
- `1.0.5` (`2026-02-13`): added `--skip-git-repo-check` to codex exec invocation.
- `1.0.4` (`2026-02-13`): SSH codex target is now configurable via `JGO_SSH_USER`, `JGO_SSH_HOST`, `JGO_SSH_PORT`.
- `1.0.3` (`2026-02-13`): codex subprocess invocation changed to `ssh localhost`.
- `1.0.2` (`2026-02-13`): codex subprocess invocation fixed to `bash -lc`.
- `1.0.1` (`2026-02-13`): changed default cache root from `/jgo-cache` to startup-dir `.jgo-cache`.
- `1.0.0` (`2026-02-13`): initial frozen baseline.
