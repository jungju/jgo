SHELL := /bin/bash

IMAGE ?= ghcr.io/jungju/jgo
TAG ?= latest
PLATFORMS ?= linux/amd64,linux/arm64

CODEX_TAG ?= rust-v0.101.0
GH_TAG ?= v2.86.0
KUBECTL_VERSION ?=

.PHONY: docker-build docker-push

docker-build:
	docker buildx build \
	  --platform $(PLATFORMS) \
	  --build-arg CODEX_TAG=$(CODEX_TAG) \
	  --build-arg GH_TAG=$(GH_TAG) \
	  --build-arg KUBECTL_VERSION=$(KUBECTL_VERSION) \
	  -t $(IMAGE):$(TAG) \
	  .

docker-push:
	docker buildx build \
	  --platform $(PLATFORMS) \
	  --build-arg CODEX_TAG=$(CODEX_TAG) \
	  --build-arg GH_TAG=$(GH_TAG) \
	  --build-arg KUBECTL_VERSION=$(KUBECTL_VERSION) \
	  -t $(IMAGE):$(TAG) \
	  --push \
	  .
