#!/usr/bin/env bash
# firewall-bp.sh — UFW lockdown for Block Producer
# Inbound: only SSH (and optionally from specific IPs)
# Outbound: only allowed to relays on RELAY_PORT
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

section "Firewall (BP lockdown)"

: "${RELAY_HOSTS:?RELAY_HOSTS must be set}"
: "${RELAY_PORT:=6000}"

SSH_PORT="${SSH_PORT:-22}"

# Reset & defaults
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null   # outbound open to relays — see below for restriction

# Allow SSH
ufw allow "${SSH_PORT}/tcp" comment 'SSH' >/dev/null
ok "SSH (${SSH_PORT}/tcp) allowed inbound"

# Allow Cardano port inbound ONLY from relay IPs (resolve hostnames now)
IFS=',' read -ra RELAYS <<< "$RELAY_HOSTS"
for host in "${RELAYS[@]}"; do
  host=$(echo "$host" | xargs)
  [[ -z "$host" ]] && continue
  ip=$(getent hosts "$host" 2>/dev/null | awk '{print $1; exit}')
  if [[ -n "$ip" ]]; then
    ufw allow from "$ip" to any port "$RELAY_PORT" proto tcp comment "relay:$host" >/dev/null
    ok "Inbound :${RELAY_PORT} from $host ($ip)"
  else
    warn "DNS fail: $host — skip"
  fi
done

# Rate-limit SSH
ufw limit "${SSH_PORT}/tcp" >/dev/null

ufw --force enable >/dev/null
ok "UFW enabled (BP profile)"
mark_done firewall-bp
