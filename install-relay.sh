#!/usr/bin/env bash
# ============================================================
# install-relay.sh — One-shot setup for Cardano Relay
# Usage: sudo ./install-relay.sh
# ============================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${REPO_DIR}/lib"

. "${LIB}/common.sh"

echo -e "${B}╔══════════════════════════════════════════════════════════════════╗${N}"
echo -e "${B}║  Cardano Relay — Automated Setup                                  ║${N}"
echo -e "${B}╚══════════════════════════════════════════════════════════════════╝${N}"

# ────────── Preflight ──────────
. "${LIB}/preflight.sh"

# ────────── Interactive prompts ──────────
section "Configuration"
NODE_ROLE=relay
POOL_NAME=""  # Not needed on relay but kept for config consistency
prompt CARDANO_HOME    "Cardano root directory"               "/opt/cardano"
prompt RELAY_HOSTS     "All your pool's relays (FQDN, comma-separated)" "relay1.example.com,relay2.example.com,relay3.example.com"
prompt RELAY_PORT      "Relay port (public)"                  "6000"
prompt BP_EXPECTED_IP  "BP IP (to verify it is connecting)" ""
prompt CARDANO_NETWORK "Network"                              "mainnet"
prompt CARDANO_IMAGE   "Docker image"                         "ghcr.io/blinklabs-io/cardano-node:latest"

echo
if confirm "Setup Telegram alerts;" "no"; then
  prompt TELEGRAM_BOT_TOKEN "Bot token"
  prompt TELEGRAM_CHAT_ID   "Chat ID"
fi

# Derived
CARDANO_DB_DIR="${CARDANO_HOME}/db"
CARDANO_IPC_DIR="${CARDANO_HOME}/ipc"
CARDANO_CONFIG_DIR="${CARDANO_HOME}/config/${CARDANO_NETWORK}"
CARDANO_PRIV_DIR="${CARDANO_HOME}/priv"
BP_KEYS_DIR="${CARDANO_HOME}/bp-keys"
POOL_DIR="${CARDANO_PRIV_DIR}/pool/relay"

export NODE_ROLE POOL_NAME CARDANO_HOME RELAY_HOSTS RELAY_PORT \
       BP_EXPECTED_IP CARDANO_NETWORK CARDANO_IMAGE \
       TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID \
       CARDANO_DB_DIR CARDANO_IPC_DIR CARDANO_CONFIG_DIR \
       CARDANO_PRIV_DIR BP_KEYS_DIR POOL_DIR

echo
section "Summary"
cat <<EOF
  Home:        ${CARDANO_HOME}
  Relays:      ${RELAY_HOSTS}
  Port:        ${RELAY_PORT}
  BP IP:       ${BP_EXPECTED_IP:-<not set>}
  Network:     ${CARDANO_NETWORK}
  Image:       ${CARDANO_IMAGE}
  Telegram:    ${TELEGRAM_BOT_TOKEN:+enabled}${TELEGRAM_BOT_TOKEN:-disabled}
EOF
echo
confirm "Continue?" "yes" || die "Cancelled."

# ────────── Steps ──────────
. "${LIB}/os-base.sh"
. "${LIB}/zsh-omz.sh"
. "${LIB}/docker.sh"
. "${LIB}/chrony.sh"
. "${LIB}/hardening.sh"

save_config

. "${LIB}/configs-download.sh"
. "${LIB}/topology-relay.sh"
. "${LIB}/firewall-relay.sh"
. "${LIB}/compose-deploy.sh"
. "${LIB}/aliases-install.sh"
. "${LIB}/cron-setup.sh"

# ────────── Final ──────────
section "Done"
ok "Relay container started"
hint "Expect validation+sync (several hours on mainnet)"
hint "Try: docker logs -f relay (or 'r-logs' in a new shell)"
hint "To activate aliases: exec zsh or reconnect via SSH"
echo
