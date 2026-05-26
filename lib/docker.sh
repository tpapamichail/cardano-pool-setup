#!/usr/bin/env bash
# docker.sh — Docker Engine + compose plugin (επίσημο apt repo)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

section "Docker"

if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
  ok "Docker ήδη εγκατεστημένο: $(docker --version)"
  mark_done docker
  return 0 2>/dev/null || exit 0
fi

. /etc/os-release
codename="${VERSION_CODENAME}"

# GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Repo
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${codename} stable" \
  > /etc/apt/sources.list.d/docker.list

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin >/dev/null

systemctl enable --now docker >/dev/null

ok "Docker installed: $(docker --version)"
ok "Compose: $(docker compose version)"
mark_done docker
