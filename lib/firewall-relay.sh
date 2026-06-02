#!/usr/bin/env bash
# firewall-relay.sh — UFW for Relay (public-facing)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

section "Firewall (Relay)"

: "${RELAY_PORT:=6000}"
SSH_PORT="${SSH_PORT:-22}"

ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null

ufw allow "${SSH_PORT}/tcp" comment 'SSH' >/dev/null
ufw limit "${SSH_PORT}/tcp" >/dev/null
ok "SSH (${SSH_PORT}/tcp) allowed + rate-limited"

ufw allow "${RELAY_PORT}/tcp" comment 'Cardano relay' >/dev/null
ok "Cardano :${RELAY_PORT} allowed inbound (public)"

ufw --force enable >/dev/null
ok "UFW enabled (relay profile)"
mark_done firewall-relay
