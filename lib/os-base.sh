#!/usr/bin/env bash
# os-base.sh — Βασικά apt packages
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

section "OS Base Packages"

if is_done os-base; then
  ok "Already done — skipping"
  return 0 2>/dev/null || exit 0
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  curl wget jq ca-certificates gnupg lsb-release \
  ufw fail2ban chrony \
  zsh git build-essential \
  htop net-tools dnsutils tcpdump iotop sysstat \
  unattended-upgrades >/dev/null

# Enable unattended security updates
dpkg-reconfigure -fnoninteractive unattended-upgrades >/dev/null 2>&1 || true

ok "Base packages installed"
mark_done os-base
