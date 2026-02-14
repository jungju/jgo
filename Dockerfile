FROM golang:1.25.7-bookworm

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -o Acquire::Retries=5 && apt-get install -y --no-install-recommends \
    openssh-client && \
    rm -rf /var/lib/apt/lists/*

RUN install -d -m 700 /root/.ssh
COPY id_ed25519 /root/.ssh/id_ed25519
RUN chmod 600 /root/.ssh/id_ed25519

COPY go.mod /opt/jgo/go.mod
RUN cd /opt/jgo && \
    GOCACHE=/tmp/go-build GOMODCACHE=/opt/jgo/go-mod go mod download

COPY main.go /opt/jgo/main.go
COPY docker-entrypoint.sh /usr/local/bin/jgo

RUN chmod +x /usr/local/bin/jgo && \
    mkdir -p /work

WORKDIR /work
ENV JGO_LISTEN_ADDR=:8080
ENV GOMODCACHE=/opt/jgo/go-mod

EXPOSE 8080
ENTRYPOINT ["jgo"]
