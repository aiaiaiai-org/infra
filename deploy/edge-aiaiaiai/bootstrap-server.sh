#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
#
# One-time preparation of a fresh edge-prod-2 server (Ubuntu 24.04 or Debian 12), run as root.
# After it, the deployment workflows reach the server by SSH and do the rest.
#
#   DEPLOY_PUBKEY='ssh-ed25519 AAAA... infra deploy edge-prod-2' bash bootstrap-server.sh
#   bash bootstrap-server.sh --finalize   # once the deploy user logs in on the new SSH port
#
# The first run leaves SSH on port 22 as well as on SSH_PORT, so a mistake cannot lock you out.
# --finalize closes port 22.
set -Eeuo pipefail

deploy_user="${DEPLOY_USER:-deploy}"
deploy_pubkey="${DEPLOY_PUBKEY:-}"
ssh_port="${SSH_PORT:-22022}"
sshd_dropin=/etc/ssh/sshd_config.d/10-infra.conf

die() { echo "bootstrap: $*" >&2; exit 1; }

[[ "$(id -u)" == "0" ]] || die "run as root"
[[ "$deploy_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "DEPLOY_USER is invalid"
if [[ ! "$ssh_port" =~ ^[0-9]+$ ]] || (( ssh_port < 1024 || ssh_port > 65535 )); then
  die "SSH_PORT must be 1024-65535"
fi

write_sshd_dropin() {
  local keep_port_22="$1"
  # Without this Include line the drop-in would be silently ignored.
  grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config \
    || die "/etc/ssh/sshd_config does not include /etc/ssh/sshd_config.d/*.conf"
  mkdir -p "$(dirname "$sshd_dropin")"
  {
    echo "# Managed by aiaiaiai-org/infra deploy/edge-aiaiaiai/bootstrap-server.sh"
    [[ "$keep_port_22" == "yes" ]] && echo "Port 22"
    echo "Port $ssh_port"
    echo "PasswordAuthentication no"
    echo "KbdInteractiveAuthentication no"
    echo "PermitRootLogin prohibit-password"
  } > "$sshd_dropin.new"
  chmod 644 "$sshd_dropin.new"
  mv "$sshd_dropin.new" "$sshd_dropin"
  sshd -t || die "sshd rejected $sshd_dropin"
}

# Ubuntu 24.04 starts sshd from ssh.socket, which takes its ports from the configuration only
# after a daemon-reload.
restart_sshd() {
  if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl restart ssh.socket
  else
    systemctl restart ssh 2>/dev/null || systemctl restart sshd
  fi
}

if [[ "${1:-}" == "--finalize" ]]; then
  [[ -f "$sshd_dropin" ]] || die "no $sshd_dropin: run the first step before --finalize"
  write_sshd_dropin no
  restart_sshd
  ufw --force delete allow 22/tcp >/dev/null 2>&1 || true
  echo "bootstrap: SSH now listens on $ssh_port only"
  exit 0
fi
[[ -z "${1:-}" ]] || die "unknown argument: $1"

[[ "$deploy_pubkey" =~ ^(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa)\ [A-Za-z0-9+/]+={0,2}(\ [^[:cntrl:]]*)?$ ]] \
  || die "DEPLOY_PUBKEY must be one OpenSSH public key line"

# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) die "unsupported system: ${ID:-unknown} (Ubuntu or Debian expected)" ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q ca-certificates curl ufw

# Docker Engine and the Compose plugin from Docker's own repository.
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker
docker compose version >/dev/null

# The deploy user: SSH by key only, runs Docker, no sudo.
if ! id "$deploy_user" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$deploy_user"
fi
usermod -aG docker "$deploy_user"
passwd -l "$deploy_user" >/dev/null
home_dir="$(getent passwd "$deploy_user" | cut -d: -f6)"
install -d -m 700 -o "$deploy_user" -g "$deploy_user" "$home_dir/.ssh"
authorized_keys="$home_dir/.ssh/authorized_keys"
touch "$authorized_keys"
grep -qxF "$deploy_pubkey" "$authorized_keys" || printf '%s\n' "$deploy_pubkey" >> "$authorized_keys"
chown "$deploy_user:$deploy_user" "$authorized_keys"
chmod 600 "$authorized_keys"

write_sshd_dropin yes
restart_sshd

# Only SSH and the edge's public ports. Containers publish nothing else.
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp >/dev/null
ufw allow "$ssh_port/tcp" >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw allow 443/udp >/dev/null
ufw --force enable >/dev/null

cat <<EOF

bootstrap: done.
  Docker:      $(docker --version)
  Deploy user: $deploy_user (group docker)
  SSH:         ports 22 and $ssh_port, keys only
  Firewall:    $ssh_port/tcp, 22/tcp, 80/tcp, 443/tcp, 443/udp

Next, from your own machine:
  ssh -i <deploy key> -p $ssh_port $deploy_user@<server> docker ps
When that works, run here:  bash bootstrap-server.sh --finalize
EOF
