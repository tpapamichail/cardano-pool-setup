#!/usr/bin/env bash
# ============================================================
# install-producer.sh — One-shot setup για Cardano Block Producer
# Usage: sudo ./install-producer.sh
# ============================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${REPO_DIR}/lib"

. "${LIB}/common.sh"

echo -e "${B}╔══════════════════════════════════════════════════════════════════╗${N}"
echo -e "${B}║  Cardano Block Producer — Automated Setup                         ║${N}"
echo -e "${B}╚══════════════════════════════════════════════════════════════════╝${N}"

# ────────── Preflight ──────────
. "${LIB}/preflight.sh"

# ────────── Interactive prompts ──────────
section "Configuration"
NODE_ROLE=producer
prompt POOL_NAME       "Pool name (ticker)"                              "MYPOOL"
prompt CARDANO_HOME    "Cardano root directory"                          "/opt/cardano"
prompt RELAY_HOSTS     "Relay FQDNs (comma-separated)"                   "relay1.example.com,relay2.example.com,relay3.example.com"
prompt RELAY_PORT      "Relay port"                                      "6000"
prompt KEYS_SOURCE_DIR "Φάκελος με τα pool keys (cold.skey.gpg, vrf.*, hot.*, op.cert, pool.id)" "/tmp/pool-keys"
prompt CARDANO_NETWORK "Network"                                         "mainnet"
prompt CARDANO_IMAGE   "Docker image"                                    "ghcr.io/blinklabs-io/cardano-node:latest"

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
POOL_DIR="${CARDANO_PRIV_DIR}/pool/${POOL_NAME}"

export NODE_ROLE POOL_NAME CARDANO_HOME RELAY_HOSTS RELAY_PORT \
       KEYS_SOURCE_DIR CARDANO_NETWORK CARDANO_IMAGE \
       TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID \
       CARDANO_DB_DIR CARDANO_IPC_DIR CARDANO_CONFIG_DIR \
       CARDANO_PRIV_DIR BP_KEYS_DIR POOL_DIR

echo
section "Summary"
cat <<EOF
  Pool:        ${POOL_NAME}
  Home:        ${CARDANO_HOME}
  Relays:      ${RELAY_HOSTS}
  Port:        ${RELAY_PORT}
  Keys src:    ${KEYS_SOURCE_DIR}
  Network:     ${CARDANO_NETWORK}
  Image:       ${CARDANO_IMAGE}
  Telegram:    ${TELEGRAM_BOT_TOKEN:+enabled}${TELEGRAM_BOT_TOKEN:-disabled}
EOF
echo
confirm "Συνεχίζουμε;" "yes" || die "Ακυρώθηκε."

# ────────── Steps ──────────
. "${LIB}/os-base.sh"
. "${LIB}/zsh-omz.sh"
. "${LIB}/docker.sh"
. "${LIB}/chrony.sh"
. "${LIB}/hardening.sh"

# Save config ΠΡΙΝ τα steps που το χρειάζονται
save_config

. "${LIB}/configs-download.sh"
. "${LIB}/topology-bp.sh"
. "${LIB}/keys-install.sh"
. "${LIB}/firewall-bp.sh"
. "${LIB}/compose-deploy.sh"
. "${LIB}/aliases-install.sh"
. "${LIB}/cron-setup.sh"

# ────────── Final ──────────
section "Done"
ok "Producer container started"
ok "Δοκίμασε: docker logs -f producer (ή 'bp-logs' σε νέο shell)"
hint "Αναμένεται validation+sync. Μετά τρέξε: bp-preflight"
hint "Για να ενεργοποιηθούν τα aliases: exec zsh ή ξανασυνδέσου με SSH"
echo
