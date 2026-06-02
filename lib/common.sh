#!/usr/bin/env bash
# ============================================================
# common.sh — Shared helpers for all install modules
# ============================================================

# Colors
export G='\033[1;32m'
export Y='\033[1;33m'
export R='\033[1;31m'
export B='\033[1m'
export D='\033[2;37m'
export C='\033[1;36m'
export N='\033[0m'

log()     { echo -e "${C}>>${N} $*"; }
ok()      { echo -e "  ${G}✓${N} $*"; }
warn()    { echo -e "  ${Y}⚠${N} $*"; }
err()     { echo -e "  ${R}✗${N} $*" >&2; }
section() { echo -e "\n${B}── $* ──${N}"; }
hint()    { echo -e "    ${D}$*${N}"; }
die()     { err "$*"; exit 1; }

# Prompt with default value
# Usage: prompt VAR_NAME "Question" [default]
prompt() {
  local var="$1" question="$2" default="${3:-}"
  local input
  if [[ -n "$default" ]]; then
    read -rp "$(echo -e "${Y}${question}${N} ${D}[${default}]${N}: ")" input
    input="${input:-$default}"
  else
    read -rp "$(echo -e "${Y}${question}${N}: ")" input
  fi
  eval "$var=\"\$input\""
}

# Yes/No prompt
# Usage: if confirm "Continue?"; then ...
confirm() {
  local question="$1" default="${2:-no}" reply
  local hint_str
  if [[ "$default" == "yes" ]]; then hint_str="[Y/n]"; else hint_str="[y/N]"; fi
  read -rp "$(echo -e "${Y}${question}${N} ${hint_str}: ")" reply
  reply="${reply:-$default}"
  [[ "$reply" =~ ^([yY]|yes|YES|Yes)$ ]]
}

require_root() {
  [[ $EUID -eq 0 ]] || die "Must run as root (sudo $0)"
}

require_ubuntu() {
  [[ -f /etc/os-release ]] || die "/etc/os-release not found"
  . /etc/os-release
  [[ "$ID" == "ubuntu" ]] || die "Only Ubuntu is supported (found $ID)"
  case "$VERSION_ID" in
    22.04|24.04) ok "Ubuntu $VERSION_ID detected" ;;
    *) die "Only Ubuntu 22.04 / 24.04 is supported (found $VERSION_ID)" ;;
  esac
}

# Idempotency: run command only if it has not been executed before.
# Marker: file in /var/lib/cardano-pool-setup/done/
mark_done() {
  local marker="/var/lib/cardano-pool-setup/done/$1"
  mkdir -p "$(dirname "$marker")"
  date -u +%FT%TZ > "$marker"
}

is_done() {
  [[ -f "/var/lib/cardano-pool-setup/done/$1" ]]
}

# Source config.env (if it exists)
load_config() {
  local cfg="${1:-${CARDANO_HOME:-/opt/cardano}/config.env}"
  if [[ -f "$cfg" ]]; then
    # shellcheck disable=SC1090
    set -a; . "$cfg"; set +a
  fi
}

# Write config.env to $CARDANO_HOME
save_config() {
  local cfg="${CARDANO_HOME}/config.env"
  mkdir -p "$CARDANO_HOME"
  cat > "$cfg" <<EOF
# Cardano Pool Setup — generated $(date -u +%FT%TZ)
NODE_ROLE=${NODE_ROLE}
CARDANO_HOME=${CARDANO_HOME}
POOL_NAME=${POOL_NAME:-}
RELAY_HOSTS=${RELAY_HOSTS}
RELAY_PORT=${RELAY_PORT:-6000}
BP_EXPECTED_IP=${BP_EXPECTED_IP:-}
CARDANO_NETWORK=${CARDANO_NETWORK:-mainnet}
CARDANO_IMAGE=${CARDANO_IMAGE:-ghcr.io/blinklabs-io/cardano-node:latest}
CARDANO_DB_DIR=${CARDANO_HOME}/db
CARDANO_IPC_DIR=${CARDANO_HOME}/ipc
CARDANO_CONFIG_DIR=${CARDANO_HOME}/config/${CARDANO_NETWORK:-mainnet}
CARDANO_PRIV_DIR=${CARDANO_HOME}/priv
BP_KEYS_DIR=${CARDANO_HOME}/bp-keys
POOL_DIR=${CARDANO_HOME}/priv/pool/${POOL_NAME:-pool}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-}
EOF
  chmod 600 "$cfg"
  ok "Config saved: $cfg"
}
