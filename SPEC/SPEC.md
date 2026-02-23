# jgo SPEC (Frozen)

- Project: `jgo`
- Spec Version: `1.0.33`
- Status: `FROZEN`
- Last Updated: `2026-02-24`

## 1. Purpose

`jgo` is a resident/CLI automation runtime that converts natural-language requests into executable Codex tasks across repository and infrastructure operations.

Core intent:
- keep orchestration minimal,
- delegate real task execution to `codex` with environment-provided CLIs (`gh`, `aws`, `kubectl`, `git`, etc.),
- keep behavior predictable and non-interactive.

## 2. Primary Goals

1. Provide OpenAI-compatible server endpoints for integration (`/v1/chat/completions`, `/v1/models`).
2. Provide direct CLI execution paths without requiring server mode.
3. Support optional prompt optimization into a Codex-optimized prompt via OpenAI-compatible API.
4. Execute tasks through `codex exec --full-auto --skip-git-repo-check` only.
5. Execute each automation request through a single codex execution phase.
6. Let Codex perform multi-domain automation (GitHub/AWS/Kubernetes/repository workflows) via available CLIs.

## 3. Non-Goals

1. `jgo` does not directly edit repository files.
2. `jgo` does not directly execute domain CLIs (`git`, `gh`, `aws`, `kubectl`) as user-task actions.
3. `jgo` does not implement complex internal planners, task queues, or distributed scheduling.
4. `jgo` does not own authentication UX beyond validating `codex login status`.

## 4. Fixed Execution Model (Invariants)

1. Task execution is Codex-only:
   - Repository/infrastructure operations must be performed by `codex`.
   - `jgo` must not call domain CLIs (`git`, `gh`, `aws`, `kubectl`) for user task execution.
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
4. Non-interactive execution:
   - Codex prompts must require non-interactive command behavior.
5. Codex process invocation:
   - execute codex commands through SSH target from env:
     - `JGO_SSH_USER`, `JGO_SSH_HOST`, `JGO_SSH_PORT`.
     - container default: `JGO_SSH_USER=jgo`, `JGO_SSH_HOST=localhost`, `JGO_SSH_PORT=22`.
   - include `--skip-git-repo-check` in codex exec command.
   - pass prompt as inline `codex exec` command argument (not via stdin).
   - execute codex once per automation request.
6. SSH key management:
   - `jgo` must not require environment-provided private key material.
   - `jgo` must not persist SSH private key material from environment variables.
   - SSH authentication must rely on key material already available to the runtime `ssh` client.
   - `jgo` must not print SSH public key logs at startup.
7. API behavior:
   - `/v1/chat/completions` supports `stream=false` and `stream=true`.
   - server uses the last non-empty `user` message as instruction.
   - served model is fixed to `jgo`.
8. Startup/CLI behavior:
   - all entrypoints (`serve`, `exec`) validate SSH settings before execution.
   - `exec` defaults to `--env-file .env`; missing file is an error unless `--env-file ""` is used.
9. Observability:
   - each request/execution must have a generated `run_id`.
   - `/v1/chat/completions` response must include `X-JGO-Run-ID` header.
   - codex SSH invocations must log both command and command output for:
     - `codex login status`
     - `codex exec`
10. Container image model:
   - `Dockerfile` is the single runtime/execution image definition.
   - image startup launches `sshd` and executes `main.go`; codex SSH target is localhost in-container.
11. Response output rule:
   - for successful question/request execution, response content must be limited to raw `codex exec` output.
   - `jgo` must not prepend wrappers/tags (for example, `[codex]`) or synthesize fallback success payloads.

## 5. Interfaces

## 5.1 CLI

1. `jgo exec [--env-file .env] "<instruction>"`
   - executes full automation.
   - `--optimize-prompt` enables prompt optimization for this execution.
   - outputs raw `codex exec` response text only.
2. `jgo serve [--optimize-prompt]`
   - starts OpenAI-compatible resident server.

## 5.2 Server API

1. `GET /healthz`
2. `GET /v1/models` (model id: `jgo`)
3. `POST /v1/chat/completions`
   - reads latest user message as instruction.
   - runs same automation logic as CLI full flow.
   - response message content contains raw `codex exec` output on success.
   - includes `X-JGO-Run-ID` response header for log correlation.

## 5.3 Runtime Artifacts

1. `Dockerfile`
   - unified API/runtime + codex execution image.
2. `scripts/jgo-first-run-checklist.sh`
   - optional manual first-run checklist script:
     - checks `codex login status`,
     - checks `gh auth status`,
     - checks `kubectl config current-context`,
     - copies `homefiles` into `/home/jgo` once and sets ownership to `jgo`,
     - creates marker file `/home/jgo/.jgo-homefiles-initialized`,
     - skips homefiles copy when marker file already exists,
     - ensures `~/.ssh/id_ed25519` / `~/.ssh/id_ed25519.pub`,
     - ensures `~/.ssh/authorized_keys` includes `~/.ssh/id_ed25519.pub`,
     - ensures `[sandbox_workspace_write]` / `network_access = true` in `~/.codex/config.toml` on first copy.

## 6. Environment Requirements

Container defaults:
1. `JGO_SSH_USER=jgo`
2. `JGO_SSH_HOST=localhost`
3. `JGO_SSH_PORT=22`

Optional override:
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

Fallbacks:
1. If `OPENAI_API_KEY` missing: fallback to `OPENWEBUI_API_KEY` then `LITELLM_API_KEY`.
2. If `MODEL` missing: fallback to `OPENWEBUI_MODEL` then `LITELLM_MODEL`.

## 7. Error and Safety Rules

1. Fail fast on invalid/missing required configuration.
2. If `codex login status` fails, return actionable login-required message.
3. Do not use destructive git rewrite flows (force-push/amend/reset).
4. Keep prompts scoped and minimal.

## 8. Kubernetes Reference Deployment & Test Flow (AI Namespace)

Use the following defaults for manual deployment/tests:

- Kubernetes namespace: `ai`
- NodeIP: `192.168.50.160`
- API service: `8080`
- SSH test nodeport: `30110` (SSH only)
- Workload/service name assumed: `jgo` (use your actual Deployment/Service name if different)

```bash
# 1) Prepare reference variables
export K8S_NAMESPACE=ai
export K8S_NODE_IP=192.168.50.160
export K8S_SERVICE_PORT=8080
export K8S_WORKLOAD=jgo
export PLATFORMS=linux/arm64
make docker-push TAG=latest PLATFORMS="$PLATFORMS"

# 2) Confirm current target state
kubectl -n "$K8S_NAMESPACE" get deploy "$K8S_WORKLOAD" -o wide
kubectl -n "$K8S_NAMESPACE" get svc "$K8S_WORKLOAD" -o wide
kubectl -n "$K8S_NAMESPACE" get pods -l app="$K8S_WORKLOAD"

# 3) Roll out a new image (optional)
#    IMAGE=ghcr.io/<owner>/jgo:<tag>
export IMAGE="ghcr.io/jungju/jgo:latest"
kubectl -n "$K8S_NAMESPACE" set image \
  deployment/"$K8S_WORKLOAD" \
  "$K8S_WORKLOAD=$IMAGE" \
  "setup-home-permissions=$IMAGE"
kubectl -n "$K8S_NAMESPACE" rollout status deployment/"$K8S_WORKLOAD" --timeout=180s

# 4) Pod readiness check
kubectl -n "$K8S_NAMESPACE" wait --for=condition=Ready pod -l app="$K8S_WORKLOAD" --timeout=180s

# 5) Local API smoke test (no NodePort dependency)
kubectl -n "$K8S_NAMESPACE" port-forward svc/"$K8S_WORKLOAD" "${K8S_SERVICE_PORT}:$K8S_SERVICE_PORT"
curl -sS "http://127.0.0.1:$K8S_SERVICE_PORT/healthz"
curl -sS -H "Content-Type: application/json" \
  -d '{"model":"jgo","messages":[{"role":"user","content":"ping"}],"stream":false}' \
  "http://127.0.0.1:$K8S_SERVICE_PORT/v1/chat/completions"
```

## 9. Automated Verification Playbook

Use the helper scripts for repeatable validation:

```bash
# API smoke test (health, models, chat completion)
make smoke-test

# Codex login status + codex exec + API login behavior verification
make codex-auth-test
```

Common options:

- `K8S_NAMESPACE`, `K8S_WORKLOAD`, `K8S_SERVICE_PORT`, `K8S_LOCAL_PORT`: Kubernetes defaults for the smoke setup.
- `SMOKE_TEST_BASE_URL`: direct API URL to bypass kubectl.
- `CODEX_AUTH_EXPECT=required|ok|auto`: force expectation in `codex-auth-test`.
- `CODEX_AUTH_SKIP_CODEX_EXEC=true`: skip CLI execution check and only verify API behavior.

## 10. Spec Freeze Policy

This specification is locked.

Any behavior change that affects goals, interfaces, invariants, or execution model requires:
1. explicit user approval,
2. `SPEC.md` version bump,
3. changelog entry in this section.

## 11. Changelog

- `1.0.33` (`2026-02-24`): documented automated verification flow and added Makefile/script integration for smoke-test and codex auth/exec checks.
- `1.0.32` (`2026-02-24`): added ARM64 deployment flow to SPEC and clarified that NodePort 30110 maps SSH(22), not API traffic.
- `1.0.31` (`2026-02-14`): removed CLI `run` mode and `make run-partial`; execution CLI path is now `jgo exec` (`make run-full`) only.
- `1.0.30` (`2026-02-14`): simplified SSH host-key behavior in runtime/docs and extended first-run checklist to provision SSH key files plus `~/.ssh/authorized_keys` registration.
- `1.0.29` (`2026-02-14`): renamed manual bootstrap script to `jgo-first-run-checklist`, added codex/gh/kubectl checks, and enforced one-time homefiles copy with marker-file guard.
- `1.0.28` (`2026-02-14`): added manual `apply-homefiles` bootstrap script and included it in Docker image to copy `homefiles` into target home and enforce sandbox workspace-write network access config.
- `1.0.27` (`2026-02-14`): renamed unified image definition to `Dockerfile` (removed `workspace.dockerfile`) and simplified Makefile push flow to a single image target.
- `1.0.26` (`2026-02-14`): replaced runtime/workspace split with unified `workspace.dockerfile` image, aliased `Dockerfile` to it, and set in-container SSH execution default to `jgo@localhost:22`.
- `1.0.25` (`2026-02-14`): constrained successful question/request responses to raw codex output only (removed wrapper/fallback success formatting and updated CLI exec output contract).
- `1.0.24` (`2026-02-14`): clarified the product purpose as Codex-led multi-CLI automation (GitHub/AWS/Kubernetes/repository workflows) and aligned goals/non-goals/invariants wording.
- `1.0.23` (`2026-02-14`): removed branch field from `jgo exec`/chat fallback success output; response now returns status only.
- `1.0.22` (`2026-02-14`): removed temporary remote workspace and repo-scoped two-phase execution model; automation now runs a single `codex exec` call per request.
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
- `1.0.7` (`2026-02-14`): made SSH target settings required for execution (`JGO_SSH_USER`, `JGO_SSH_HOST`, `JGO_SSH_PORT`); removed localhost/22 defaults.
- `1.0.6` (`2026-02-14`): prompt optimization is now optional for full automation; default OFF (`JGO_OPTIMIZE_PROMPT=false`) and can be enabled via `--optimize-prompt`.
- `1.0.5` (`2026-02-13`): added `--skip-git-repo-check` to codex exec invocation.
- `1.0.4` (`2026-02-13`): SSH codex target is now configurable via `JGO_SSH_USER`, `JGO_SSH_HOST`, `JGO_SSH_PORT`.
- `1.0.3` (`2026-02-13`): codex subprocess invocation changed to `ssh localhost`.
- `1.0.2` (`2026-02-13`): codex subprocess invocation fixed to `bash -lc`.
- `1.0.1` (`2026-02-13`): changed default cache root from `/jgo-cache` to startup-dir `.jgo-cache`.
- `1.0.0` (`2026-02-13`): initial frozen baseline.
