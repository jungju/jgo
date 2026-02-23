SHELL := /bin/bash

IMAGE ?= ghcr.io/jungju/jgo
TAG ?= latest
PLATFORMS ?= linux/amd64,linux/arm64
ENV_FILE ?= .env
PROMPT ?=
PROMPT_OPTIMIZE ?= false
EXEC_TRANSPORT ?= local
SSH_KEY_PATH ?= .jgo-cache/ssh/id_ed25519
SSH_KEY_COMMENT ?= jgo-auto
K8S_NAMESPACE ?= ai
K8S_WORKLOAD ?= jgo
K8S_SERVICE_PORT ?= 8080
K8S_LOCAL_PORT ?= 18080
SMOKE_TIMEOUT ?= 15
SMOKE_WAIT_TIMEOUT ?= 60
SMOKE_EXPECT_AUTH_ONLY ?= false
SMOKE_CHECK_STREAM ?= false
SMOKE_TEST_BASE_URL ?=
CODEX_AUTH_EXPECT ?= auto
CODEX_AUTH_SKIP_CODEX_EXEC ?= false

.PHONY: docker-push docker-push-arm64 push serve run-full ssh-key deploy-check ghost-grow autonomous-loop smoke-test codex-auth-test verify

docker-push:
	docker buildx build \
	  --platform $(PLATFORMS) \
	  -f Dockerfile \
	  -t $(IMAGE):$(TAG) \
	  --push \
	  .

docker-push-arm64:
	$(MAKE) docker-push PLATFORMS=linux/arm64

push: docker-push

serve:
	go run main.go serve --transport $(EXEC_TRANSPORT)

run-full:
	@if [ -z "$(PROMPT)" ]; then \
	  echo 'usage: make run-full PROMPT="작업 지시"'; \
	  exit 1; \
	fi
	go run main.go exec --env-file $(ENV_FILE) --transport $(EXEC_TRANSPORT) --optimize-prompt=$(PROMPT_OPTIMIZE) "$(PROMPT)"

ssh-key:
	@mkdir -p "$(dir $(SSH_KEY_PATH))"
	@if [ -f "$(SSH_KEY_PATH)" ]; then \
	  echo "ssh key already exists: $(SSH_KEY_PATH)"; \
	else \
	  ssh-keygen -q -t ed25519 -N "" -C "$(SSH_KEY_COMMENT)" -f "$(SSH_KEY_PATH)"; \
	  echo "ssh key generated: $(SSH_KEY_PATH)"; \
	fi
	@echo "public key path: $(SSH_KEY_PATH).pub"

deploy-check:
	@bash scripts/deploy-check-verify.sh

smoke-test:
	@bash scripts/jgo-smoke-test.sh \
	  --namespace "$(K8S_NAMESPACE)" \
	  --service "$(K8S_WORKLOAD)" \
	  --service-port "$(K8S_SERVICE_PORT)" \
	  --local-port "$(K8S_LOCAL_PORT)" \
	  --timeout "$(SMOKE_TIMEOUT)" \
	  --wait-timeout "$(SMOKE_WAIT_TIMEOUT)" \
	  $(if $(filter true,$(SMOKE_EXPECT_AUTH_ONLY)),--expect-auth-only,) \
	  $(if $(filter true,$(SMOKE_CHECK_STREAM)),--check-stream,) \
	  $(if $(SMOKE_TEST_BASE_URL),--base-url "$(SMOKE_TEST_BASE_URL)",) \
	  $(if $(KUBECONFIG),--kubeconfig "$(KUBECONFIG)",)

codex-auth-test:
	@bash scripts/jgo-codex-auth-test.sh \
	  --namespace "$(K8S_NAMESPACE)" \
	  --service "$(K8S_WORKLOAD)" \
	  --service-port "$(K8S_SERVICE_PORT)" \
	  --local-port "$(K8S_LOCAL_PORT)" \
	  --timeout "$(SMOKE_TIMEOUT)" \
	  --wait-timeout "$(SMOKE_WAIT_TIMEOUT)" \
	  $(if $(filter required,$(CODEX_AUTH_EXPECT)),--expect-login-required,) \
	  $(if $(filter ok,$(CODEX_AUTH_EXPECT)),--expect-login-ok,) \
	  $(if $(filter true,$(CODEX_AUTH_SKIP_CODEX_EXEC)),--skip-codex-exec,) \
	  $(if $(SMOKE_TEST_BASE_URL),--base-url "$(SMOKE_TEST_BASE_URL)",) \
	  $(if $(KUBECONFIG),--kubeconfig "$(KUBECONFIG)",)

verify:
	@$(MAKE) smoke-test
	@$(MAKE) codex-auth-test

ghost-grow:
	@bash scripts/ghost-self-growth-loop.sh --dry-run

autonomous-loop:
	@if [ -z "$(PROMPT)" ]; then \
	  echo 'usage: make autonomous-loop PROMPT="task text" [OWNER=owner] [REPO=repo] [TOPIC=topic] [EXECUTE=true|false]'; \
	  exit 1; \
	fi
	@bash scripts/ghost-autonomous-dev-loop.sh \
	  --task "$(PROMPT)" \
	  --owner "$(if $(OWNER),$(OWNER),jungju)" \
	  --repo "$(if $(REPO),$(REPO),jgo)" \
	  --topic "$(if $(TOPIC),$(TOPIC),autonomous-dev-loop)" \
	  $(if $(filter true,$(EXECUTE)),--execute,--dry-run)
