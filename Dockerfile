FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG GO_VERSION=1.23.6
ARG NODE_VERSION=24.13.0
ARG GH_VERSION=2.86.0
ARG KUBECTL_VERSION=v1.34.1

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    openssh-client \
    sudo \
    ca-certificates \
    curl \
    postgresql-client \
    git \
    vim \
    bash \
    tzdata \
    xz-utils \
    unzip \
  && rm -rf /var/lib/apt/lists/*

RUN arch="$(dpkg --print-architecture)" && \
    case "$arch" in \
      amd64) go_arch="amd64" ;; \
      arm64) go_arch="arm64" ;; \
      *) echo "Unsupported arch: $arch" && exit 1 ;; \
    esac && \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${go_arch}.tar.gz" -o /tmp/go.tgz && \
    rm -rf /usr/local/go && \
    tar -C /usr/local -xzf /tmp/go.tgz && \
    rm -f /tmp/go.tgz

ENV PATH="/usr/local/go/bin:${PATH}"

RUN arch="$(dpkg --print-architecture)" && \
    case "$arch" in \
      amd64) node_arch="x64" ;; \
      arm64) node_arch="arm64" ;; \
      *) echo "Unsupported arch: $arch" && exit 1 ;; \
    esac && \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" -o /tmp/node.tar.xz && \
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 && \
    rm -f /tmp/node.tar.xz && \
    npm install -g @openai/codex && \
    npm cache clean --force

RUN arch="$(dpkg --print-architecture)" && \
    case "$arch" in \
      amd64) gh_arch="amd64" ;; \
      arm64) gh_arch="arm64" ;; \
      *) echo "Unsupported arch: $arch" && exit 1 ;; \
    esac && \
    curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${gh_arch}.tar.gz" -o /tmp/gh.tgz && \
    tar -xzf /tmp/gh.tgz -C /tmp && \
    install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${gh_arch}/bin/gh" /usr/local/bin/gh && \
    rm -rf "/tmp/gh_${GH_VERSION}_linux_${gh_arch}" /tmp/gh.tgz

RUN arch="$(dpkg --print-architecture)" && \
    case "$arch" in \
      amd64) kube_arch="amd64" ;; \
      arm64) kube_arch="arm64" ;; \
      *) echo "Unsupported arch: $arch" && exit 1 ;; \
    esac && \
    curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${kube_arch}/kubectl" -o /usr/local/bin/kubectl && \
    chmod 0755 /usr/local/bin/kubectl

RUN arch="$(dpkg --print-architecture)" && \
    case "$arch" in \
      amd64) aws_arch="x86_64" ;; \
      arm64) aws_arch="aarch64" ;; \
      *) echo "Unsupported arch: $arch" && exit 1 ;; \
    esac && \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}.zip" -o /tmp/awscliv2.zip && \
    unzip -q /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update && \
    rm -rf /tmp/aws /tmp/awscliv2.zip

COPY go.mod /opt/jgo/go.mod
RUN cd /opt/jgo && \
    GOCACHE=/tmp/go-build GOMODCACHE=/opt/jgo/go-mod go mod download

COPY main.go /opt/jgo/main.go
COPY docker-entrypoint.sh /usr/local/bin/jgo
RUN chmod +x /usr/local/bin/jgo

RUN install -d -m 700 /root/.ssh
COPY id_ed25519 /root/.ssh/id_ed25519
COPY id_ed25519.pub /root/.ssh/id_ed25519.pub
RUN chmod 600 /root/.ssh/id_ed25519 && \
    chmod 644 /root/.ssh/id_ed25519.pub

RUN mkdir -p /var/run/sshd
RUN sed -i 's/#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -i 's/#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/#\?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config && \
    sed -i 's/#\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config || true && \
    { \
      echo ''; \
      echo 'AllowTcpForwarding yes'; \
      echo 'PermitTunnel yes'; \
      echo 'X11Forwarding no'; \
      echo 'ClientAliveInterval 60'; \
      echo 'ClientAliveCountMax 3'; \
      echo 'UseDNS no'; \
      echo 'PermitUserEnvironment yes'; \
    } >> /etc/ssh/sshd_config

ENV USERNAME=jgo
RUN useradd -m -s /bin/bash "${USERNAME}" && \
    usermod -aG sudo "${USERNAME}" && \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}" && \
    chmod 0440 "/etc/sudoers.d/${USERNAME}"

RUN install -d -m 700 -o "${USERNAME}" -g "${USERNAME}" "/home/${USERNAME}/.ssh" && \
    touch "/home/${USERNAME}/.ssh/authorized_keys" && \
    chmod 600 "/home/${USERNAME}/.ssh/authorized_keys" && \
    cat /root/.ssh/id_ed25519.pub >> "/home/${USERNAME}/.ssh/authorized_keys" && \
    awk '!seen[$0]++' "/home/${USERNAME}/.ssh/authorized_keys" > "/home/${USERNAME}/.ssh/authorized_keys.tmp" && \
    mv "/home/${USERNAME}/.ssh/authorized_keys.tmp" "/home/${USERNAME}/.ssh/authorized_keys" && \
    chown "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.ssh/authorized_keys"

RUN echo 'export PATH=/usr/local/go/bin:$PATH' > /etc/profile.d/go.sh

RUN cat > /usr/local/bin/entrypoint.sh <<'SH' && chmod +x /usr/local/bin/entrypoint.sh
#!/usr/bin/env bash
set -euo pipefail

USERNAME="${USERNAME:-jgo}"
HOME_DIR="/home/${USERNAME}"
SSH_DIR="${HOME_DIR}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

if ! id -u "${USERNAME}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "${USERNAME}"
  usermod -aG sudo "${USERNAME}" || true
  echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"
  chmod 0440 "/etc/sudoers.d/${USERNAME}"
fi

mkdir -p /var/run/sshd
mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
touch "${AUTH_KEYS}"
chmod 600 "${AUTH_KEYS}"

if [ -f /tmp/authorized_key.pub ]; then
  cat /tmp/authorized_key.pub >> "${AUTH_KEYS}"
fi

if [ -f /root/.ssh/id_ed25519.pub ]; then
  cat /root/.ssh/id_ed25519.pub >> "${AUTH_KEYS}"
fi

awk '!seen[$0]++' "${AUTH_KEYS}" > "${AUTH_KEYS}.tmp" && mv "${AUTH_KEYS}.tmp" "${AUTH_KEYS}"
chown -R "${USERNAME}:${USERNAME}" "${SSH_DIR}"

/usr/sbin/sshd

export JGO_MAIN_FILE="${JGO_MAIN_FILE:-/opt/jgo/main.go}"
export JGO_SSH_USER="${USERNAME}"
export JGO_SSH_HOST="localhost"
export JGO_SSH_PORT="22"

for _ in $(seq 1 40); do
  if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -p "${JGO_SSH_PORT}" "${JGO_SSH_USER}@${JGO_SSH_HOST}" "exit 0" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

exec /usr/local/bin/jgo "$@"
SH

WORKDIR /work
ENV JGO_LISTEN_ADDR=:8080
ENV GOMODCACHE=/opt/jgo/go-mod
ENV JGO_SSH_STRICT_HOST_KEY_CHECKING=false

EXPOSE 22 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
