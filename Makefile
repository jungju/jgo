SHELL := /bin/bash

IMAGE ?= ghcr.io/jungju/jgo
TAG ?= latest
PLATFORMS ?= linux/amd64,linux/arm64
ENV_FILE ?= .env
PROMPT ?=
PROMPT_OPTIMIZE ?= false
SSH_KEY_PATH ?= .jgo-cache/ssh/id_ed25519
SSH_KEY_COMMENT ?= jgo-auto

.PHONY: docker-push push serve run-full ssh-key

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
