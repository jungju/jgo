FROM ubuntu:24.04

ARG TARGETARCH
ARG CODEX_TAG=rust-v0.101.0
ARG GH_TAG=v2.86.0
ARG KUBECTL_VERSION=
ARG GO_VERSION=1.22.12

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -o Acquire::Retries=5 && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    bash \
    curl \
    tar \
    unzip && \
    rm -rf /var/lib/apt/lists/*

RUN \
    case "$TARGETARCH" in \
      arm64) CODEX_ARCHIVE="codex-aarch64-unknown-linux-musl.tar.gz"; CODEX_BIN="codex-aarch64-unknown-linux-musl"; GH_ARCH="arm64"; KUBE_ARCH="arm64"; GO_ARCH="arm64"; AWS_ARCH="aarch64" ;; \
      amd64) CODEX_ARCHIVE="codex-x86_64-unknown-linux-musl.tar.gz"; CODEX_BIN="codex-x86_64-unknown-linux-musl"; GH_ARCH="amd64"; KUBE_ARCH="amd64"; GO_ARCH="amd64"; AWS_ARCH="x86_64" ;; \
      *) echo "unsupported TARGETARCH: $TARGETARCH" && exit 1 ;; \
    esac && \
    curl -L --fail "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -o /tmp/go.tar.gz && \
    tar -xzf /tmp/go.tar.gz -C /usr/local && \
    ln -sf /usr/local/go/bin/go /usr/local/bin/go && \
    ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt && \
    curl -L --fail "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" -o /tmp/awscliv2.zip && \
    unzip -q /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update && \
    curl -L --fail "https://github.com/openai/codex/releases/download/${CODEX_TAG}/${CODEX_ARCHIVE}" -o /tmp/codex.tar.gz && \
    tar -xzf /tmp/codex.tar.gz -C /usr/local/bin && \
    mv "/usr/local/bin/${CODEX_BIN}" /usr/local/bin/codex && \
    chmod +x /usr/local/bin/codex && \
    GH_VERSION="${GH_TAG#v}" && \
    curl -L --fail "https://github.com/cli/cli/releases/download/${GH_TAG}/gh_${GH_VERSION}_linux_${GH_ARCH}.tar.gz" -o /tmp/gh.tar.gz && \
    tar -xzf /tmp/gh.tar.gz -C /tmp && \
    mv "/tmp/gh_${GH_VERSION}_linux_${GH_ARCH}/bin/gh" /usr/local/bin/gh && \
    chmod +x /usr/local/bin/gh && \
    if [ -z "$KUBECTL_VERSION" ]; then KUBECTL_VERSION="$(curl -L --fail https://dl.k8s.io/release/stable.txt)"; fi && \
    curl -L --fail "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${KUBE_ARCH}/kubectl" -o /usr/local/bin/kubectl && \
    chmod +x /usr/local/bin/kubectl && \
    rm -rf /tmp/go.tar.gz /tmp/awscliv2.zip /tmp/aws /tmp/codex.tar.gz /tmp/gh.tar.gz "/tmp/gh_${GH_VERSION}_linux_${GH_ARCH}"

COPY go.mod /opt/jgo/go.mod
COPY main.go /opt/jgo/main.go
COPY .env.example /opt/jgo/.env.example
COPY docker-entrypoint.sh /usr/local/bin/jgo

RUN chmod +x /usr/local/bin/jgo && \
    mkdir -p /jgo-cache/repos /jgo-cache/work /jgo-cache/go-build /jgo-cache/go-mod /jgo-cache/codex /work/.kube

WORKDIR /work
ENV JGO_CACHE_DIR=/jgo-cache
ENV KUBECONFIG=/work/.kube/config
ENV GOCACHE=/jgo-cache/go-build
ENV GOMODCACHE=/jgo-cache/go-mod
ENV CODEX_HOME=/jgo-cache/codex
ENV JGO_ENV_FILE=/work/.env
ENV PATH=/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin

VOLUME ["/jgo-cache"]

ENTRYPOINT ["jgo"]
