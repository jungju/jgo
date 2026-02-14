# Ubuntu + OpenSSH server for VSCode Remote-SSH
# - Key-only login
# - TCP forwarding enabled (needed by VSCode Remote-SSH)
# - Go + git/curl installed (good baseline for your dev)
#
# Build:
#   docker build -t ubuntu-ssh-go .
#
# Run (recommended: mount authorized_keys):
#   docker run -d --name dev-ssh \
#     -p 2222:22 \
#     -e USERNAME=jgo \
#     -v $HOME/.ssh/id_ed25519.pub:/tmp/authorized_key.pub:ro \
#     -v dev-home:/home/jgo \
#     ubuntu-ssh-go
#
# Then on your local:
#   ssh -p 2222 jgo@HOST

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG GO_VERSION=1.23.6
ARG NODE_VERSION=24.13.0
ARG GH_VERSION=2.86.0
ARG KUBECTL_VERSION=v1.34.1

# Base packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    sudo \
    ca-certificates \
    curl \
    git \
    vim \
    bash \
    tzdata \
    xz-utils \
    unzip \
  && rm -rf /var/lib/apt/lists/*

# Install Go (official tarball)
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

# Install node/npm + codex CLI
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

# Install GitHub CLI
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

# Install kubectl
RUN arch="$(dpkg --print-architecture)" && \
    case "$arch" in \
      amd64) kube_arch="amd64" ;; \
      arm64) kube_arch="arm64" ;; \
      *) echo "Unsupported arch: $arch" && exit 1 ;; \
    esac && \
    curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${kube_arch}/kubectl" -o /usr/local/bin/kubectl && \
    chmod 0755 /usr/local/bin/kubectl

# Install AWS CLI v2
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

# OpenSSH server prep
RUN mkdir -p /var/run/sshd

# VSCode Remote-SSH needs TCP forwarding.
# Also keep sessions stable.
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

# Create non-root user (default: jgo) with passwordless sudo
ENV USERNAME=jgo
RUN useradd -m -s /bin/bash "${USERNAME}" && \
    usermod -aG sudo "${USERNAME}" && \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}" && \
    chmod 0440 "/etc/sudoers.d/${USERNAME}"

# Seed default authorized_keys for the default user
RUN install -d -m 700 -o "${USERNAME}" -g "${USERNAME}" "/home/${USERNAME}/.ssh" && \
    printf '%s\n' \
      'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCigXWwZhmZ1FjJmARAa+ZroDYiNPghZue9pLWPqU/OHKF8rrSCGLBlSL0tCgX9+TjzIRalUujLtHKWNs8p8QJ3D7laiN82+EBKexR5M0rvboKZV87MEmlvQ3ZGGgO4hJorAVIkjXbiI2Xgq659cl55uhPrmnduDf+nqXVcbBiyVVULcnBy2K8hrPUWCoz8/iTvgracbln4R+4Hj6knROoyOc9u2mLdEc8W+s45iNtlsn4C5KmKGZ51wq6GwzyBC+Qou5Kx/CDFPAuhshWykllUrvnsFYrGtldU6BcRDTcy4+1D8pN+0oF0l/a/SmKJWQp6I7mCtnoe6/2bDjwKcf1aGiXizD6k8YAdBIVWAQG6dqnJtdhJniCRZNg4t7sYoC40fd7Mg9iwMpJXFNI2mllSSnxvxT/GyvKEOjlOx5gKj/17AKmP5YXucO6Mvx+p3tj0ZkLcn5Ofl9DRxkZl/tg2qG3YLp0HJQjtkbZd2uEkw5QWr5j+Zau/FkBpfa90pos= jeong@DESKTOP-JUNGJU' \
      'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGKRHk7IH7L2hWe8+1J6Gyws0nfZD0c4PxiD+2+c0d1H leejungju.go@gmail.com' \
      'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFByOvEHcc9I9NCmFuBBzullWOnG7enWbRwsZzOkyM3d jgo-auto' \
    > "/home/${USERNAME}/.ssh/authorized_keys" && \
    chmod 600 "/home/${USERNAME}/.ssh/authorized_keys" && \
    chown "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.ssh/authorized_keys"

# Helpful default shell env
RUN echo 'export PATH=/usr/local/go/bin:$PATH' > /etc/profile.d/go.sh

# Entrypoint: (1) optionally install authorized_keys from mounted pubkey, (2) start sshd
RUN cat > /usr/local/bin/entrypoint.sh <<'SH' && chmod +x /usr/local/bin/entrypoint.sh
#!/usr/bin/env bash
set -euo pipefail

USERNAME="${USERNAME:-jgo}"
HOME_DIR="/home/${USERNAME}"
SSH_DIR="${HOME_DIR}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

# If user was overridden at runtime, ensure it exists
if ! id -u "${USERNAME}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "${USERNAME}"
  usermod -aG sudo "${USERNAME}" || true
  echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"
  chmod 0440 "/etc/sudoers.d/${USERNAME}"
fi

mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
touch "${AUTH_KEYS}"
chmod 600 "${AUTH_KEYS}"

# If a public key is mounted at /tmp/authorized_key.pub, install it
if [ -f /tmp/authorized_key.pub ]; then
  cat /tmp/authorized_key.pub >> "${AUTH_KEYS}"
fi

# Remove duplicate keys
awk '!seen[$0]++' "${AUTH_KEYS}" > "${AUTH_KEYS}.tmp" && mv "${AUTH_KEYS}.tmp" "${AUTH_KEYS}"

chown -R "${USERNAME}:${USERNAME}" "${SSH_DIR}"

# Start sshd in foreground
exec /usr/sbin/sshd -D -e
SH

EXPOSE 22
CMD ["/usr/local/bin/entrypoint.sh"]
