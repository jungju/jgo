SHELL := /bin/bash

IMAGE ?= ghcr.io/jungju/jgo
TAG ?= latest
PLATFORMS ?= linux/amd64,linux/arm64
ENV_FILE ?= .env
PROMPT ?=
PROMPT_OPTIMIZE ?= false
SSH_KEY_PATH ?= .jgo-cache/ssh/id_ed25519
SSH_KEY_COMMENT ?= jgo-auto

.PHONY: docker-push push serve run-full ssh-key deploy-check ghost-grow autonomous-loop evolve-24h

docker-push:
	docker buildx build \
	  --platform $(PLATFORMS) \
	  -f Dockerfile \
	  -t $(IMAGE):$(TAG) \
	  --push \
	  .

push: docker-push

serve:
	go run main.go serve

run-full:
	@if [ -z "$(PROMPT)" ]; then \
	  echo 'usage: make run-full PROMPT="작업 지시"'; \
	  exit 1; \
	fi
	go run main.go exec --env-file $(ENV_FILE) --optimize-prompt=$(PROMPT_OPTIMIZE) "$(PROMPT)"

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

evolve-24h:
	@bash scripts/ghost-evolve-24h.sh \
	  --owner "$(if $(OWNER),$(OWNER),jungju)" \
	  --repo "$(if $(REPO),$(REPO),jgo)" \
	  --duration-hours "$(if $(HOURS),$(HOURS),24)" \
	  --interval-minutes "$(if $(INTERVAL_MINUTES),$(INTERVAL_MINUTES),30)" \
	  $(if $(LOG_FILE),--log-file "$(LOG_FILE)",)
