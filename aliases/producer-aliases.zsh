#!/usr/bin/env zsh
# ============================================================
# Cardano BP aliases — parameterized from $CARDANO_HOME/config.env
# Sourced from ~/.zshrc via aliases-install.sh
# ============================================================

: ${CARDANO_HOME:=/opt/cardano}
: ${POOL_NAME:=pool}
: ${CARDANO_NETWORK:=mainnet}
: ${CARDANO_IMAGE:=ghcr.io/blinklabs-io/cardano-node:latest}
: ${BP_KEYS_DIR:=${CARDANO_HOME}/bp-keys}
: ${CARDANO_IPC_DIR:=${CARDANO_HOME}/ipc}
: ${CARDANO_CONFIG_DIR:=${CARDANO_HOME}/config/${CARDANO_NETWORK}}
: ${POOL_DIR:=${CARDANO_HOME}/priv/pool/${POOL_NAME}}
: ${SCRIPTS_DIR:=${CARDANO_HOME}/scripts}

# ────────── cardano-cli wrapper ──────────
alias cardano-cli="docker run --rm -ti \
  -v ${CARDANO_IPC_DIR}:/ipc \
  -v ${BP_KEYS_DIR}:/keys:ro \
  -v ${CARDANO_CONFIG_DIR}:/config:ro \
  -e CARDANO_NODE_SOCKET_PATH=/ipc/node.socket \
  ${CARDANO_IMAGE} cli"

# ────────── Status ──────────
alias bp-tip="cardano-cli query tip --${CARDANO_NETWORK}"
alias bp-kes="cardano-cli query kes-period-info --${CARDANO_NETWORK} --op-cert-file /keys/node.cert"
alias bp-pool="cardano-cli query pool-state --${CARDANO_NETWORK} --stake-pool-id \$(cat ${POOL_DIR}/pool.id)"
alias bp-schedule="cardano-cli query leadership-schedule --${CARDANO_NETWORK} --genesis /config/shelley-genesis.json --stake-pool-id \$(cat ${POOL_DIR}/pool.id) --vrf-signing-key-file /keys/vrf.skey --current"
alias bp-health="${SCRIPTS_DIR}/bp-health.sh"
alias bp-preflight="${SCRIPTS_DIR}/bp-preflight.sh"

# ────────── Monitoring ──────────
alias bp-logs='docker logs -f --tail 100 producer'
alias bp-logs-err='docker logs producer 2>&1 | grep -iE "error|warn|fail" | tail -50'
alias bp-forge='docker logs -f producer 2>&1 | grep --color -E "IsLeader|Forged|Adopted|NotLeader"'
alias bp-stats='docker stats producer --no-stream'
alias bp-status='docker ps --filter name=producer --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias bp-nview='docker exec -ti producer nview'

# ────────── KES & GPG ──────────
alias kes-rotate="${SCRIPTS_DIR}/kes-rotate.sh"
[[ -f "${SCRIPTS_DIR}/gpg-helpers.sh" ]] && source "${SCRIPTS_DIR}/gpg-helpers.sh"

# ────────── Container management ──────────
alias bp-restart="cd ${CARDANO_HOME} && docker compose restart producer"
alias bp-stop="cd ${CARDANO_HOME} && docker compose stop producer"
alias bp-start="cd ${CARDANO_HOME} && docker compose start producer"
alias bp-up="cd ${CARDANO_HOME} && docker compose up -d"
alias bp-down="cd ${CARDANO_HOME} && docker compose down"
alias bp-pull="cd ${CARDANO_HOME} && docker compose pull && docker compose up -d"
alias bp-version='docker exec producer cardano-node --version | head -1'
alias bp-disk="du -sh ${CARDANO_HOME}/db ${CARDANO_HOME}/ipc ${CARDANO_CONFIG_DIR} 2>/dev/null && echo && df -h /"

# ────────── Help / Banner ──────────
bp-help() {
  local CT="\033[1;36m" CC="\033[1;33m" CM="\033[1;32m" CD="\033[0;37m" DM="\033[2;37m" N="\033[0m"
  echo
  echo "${CT}╔══════════════════════════════════════════════════════════════════╗${N}"
  echo "${CT}║  Cardano BP — ${POOL_NAME} Pool${N}"
  echo "${CT}╚══════════════════════════════════════════════════════════════════╝${N}"
  echo
  echo "${CC}── STATUS ──────────────────────────────────────────────────────────${N}"
  printf "  ${CM}%-16s${CD}%s${N}\n" "bp-health"   "All-in-one health check (summary)"
  printf "  ${CM}%-16s${CD}%s${N}\n" "bp-preflight" "Preflight check (12 sections)"
  printf "  ${CM}%-16s${CD}%s${N}\n" "bp-tip"      "Sync status & current network tip"
  printf "  ${CM}%-16s${CD}%s${N}\n" "bp-kes"      "KES period info & expiry"
  printf "  ${CM}%-16s${CD}%s${N}\n" "bp-pool"     "On-chain pool state"
  printf "  ${CM}%-16s${CD}%s${N}\n" "bp-schedule" "Leadership schedule"
  echo
  echo "${CC}── LIVE MONITORING ─────────────────────────────────────────────────${N}"
  printf "  ${CM}%-16s${CD}%s${N}\n" "bp-nview"    "Live dashboard"
  printf "  ${CM}%-16s${CD}%s${N}\n" "bp-logs"     "Tail logs"
  printf "  ${CM}%-16s${CD}%s${N}\n" "bp-logs-err" "Errors & warnings"
  printf "  ${CM}%-16s${CD}%s${N}\n" "bp-forge"    "Live forge activity"
  printf "  ${CM}%-16s${CD}%s${N}\n" "bp-stats"    "Container CPU/RAM"
  printf "  ${CM}%-16s${CD}%s${N}\n" "bp-status"   "Container state"
  echo
  echo "${CC}── KEY MANAGEMENT ──────────────────────────────────────────────────${N}"
  printf "  ${CM}%-16s${CD}%s${N}\n" "kes-rotate"  "KES rotation (interactive)"
  printf "  ${CM}%-16s${CD}%s${N}\n" "gpg-encrypt" "Encrypt file → .gpg"
  printf "  ${CM}%-16s${CD}%s${N}\n" "gpg-decrypt" "Decrypt .gpg → plain"
  printf "  ${CM}%-16s${CD}%s${N}\n" "gpg-help"    "GPG helper docs"
  echo
  echo "${CC}── CONTAINER MANAGEMENT ────────────────────────────────────────────${N}"
  printf "  ${CM}%-16s${CD}%s${N}\n" "bp-restart"  "Restart producer"
  printf "  ${CM}%-16s${CD}%s${N}\n" "bp-stop"     "Stop"
  printf "  ${CM}%-16s${CD}%s${N}\n" "bp-start"    "Start"
  printf "  ${CM}%-16s${CD}%s${N}\n" "bp-up"       "Compose up -d"
  printf "  ${CM}%-16s${CD}%s${N}\n" "bp-down"     "Compose down"
  printf "  ${CM}%-16s${CD}%s${N}\n" "bp-pull"     "Pull image & restart"
  printf "  ${CM}%-16s${CD}%s${N}\n" "bp-version"  "Cardano-node version"
  printf "  ${CM}%-16s${CD}%s${N}\n" "bp-disk"     "Disk usage"
  echo
  echo "${CC}── RAW CLI ─────────────────────────────────────────────────────────${N}"
  printf "  ${CM}%-16s${CD}%s${N}\n" "cardano-cli" "Full cardano-cli with mounts"
  echo
  echo "${DM}  bp-help anytime for this menu${N}"
  echo
}

# ────────── Quick health line (on login) ──────────
bp-quickcheck() {
  local CO="\033[1;32m" CW="\033[1;33m" CR="\033[1;31m" D="\033[2;37m" N="\033[0m"
  local cont_state
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^producer$'; then
    cont_state="${CO}● running${N}"
  else
    echo "  Producer: ${CR}● stopped${N}"; return
  fi
  local tip_json
  tip_json=$(timeout 5 docker exec producer sh -c \
    "CARDANO_NODE_SOCKET_PATH=/ipc/node.socket cardano-cli query tip --${CARDANO_NETWORK} 2>/dev/null" 2>/dev/null)
  if [[ -n "$tip_json" ]]; then
    local p=$(echo "$tip_json" | jq -r '.syncProgress' 2>/dev/null)
    local s=$(echo "$tip_json" | jq -r '.slot' 2>/dev/null)
    local e=$(echo "$tip_json" | jq -r '.epoch' 2>/dev/null)
    if [[ "$p" == "100.00" ]]; then
      echo "  Producer: $cont_state  ${D}|${N}  sync: ${CO}${p}%${N}  ${D}|${N}  epoch: ${e}  ${D}|${N}  slot: ${s}"
    else
      echo "  Producer: $cont_state  ${D}|${N}  sync: ${CW}${p}%${N}  ${D}|${N}  epoch: ${e}"
    fi
  else
    echo "  Producer: $cont_state  ${D}|${N}  ${CW}cli timeout${N}"
  fi
}

# Auto-run on interactive shell
if [[ -o interactive ]]; then
  bp-help
  bp-quickcheck
  echo
fi
