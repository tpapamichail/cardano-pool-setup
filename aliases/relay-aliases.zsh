#!/usr/bin/env zsh
# ============================================================
# Cardano Relay aliases — parameterized από $CARDANO_HOME/config.env
# ============================================================

: ${CARDANO_HOME:=/opt/cardano}
: ${CARDANO_NETWORK:=mainnet}
: ${CARDANO_IMAGE:=ghcr.io/blinklabs-io/cardano-node:latest}
: ${CARDANO_IPC_DIR:=${CARDANO_HOME}/ipc}
: ${CARDANO_CONFIG_DIR:=${CARDANO_HOME}/config/${CARDANO_NETWORK}}
: ${SCRIPTS_DIR:=${CARDANO_HOME}/scripts}

# ────────── cardano-cli wrapper ──────────
alias cardano-cli="docker run --rm -ti \
  -v ${CARDANO_IPC_DIR}:/ipc \
  -v ${CARDANO_CONFIG_DIR}:/config:ro \
  -e CARDANO_NODE_SOCKET_PATH=/ipc/node.socket \
  ${CARDANO_IMAGE} cli"

# ────────── Status ──────────
alias r-tip="cardano-cli query tip --${CARDANO_NETWORK}"
alias r-health="${SCRIPTS_DIR}/relay-health.sh"
alias r-validation='docker logs --tail 200 relay 2>&1 | grep "Validated chunk" | tail -3'

# ────────── Live monitoring ──────────
alias r-logs='docker logs -f --tail 100 relay'
alias r-logs-err='docker logs relay 2>&1 | grep -iE "error|warn|fail" | tail -50'
alias r-stats='docker stats relay --no-stream'
alias r-status='docker ps --filter name=relay --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias r-nview='docker exec -ti relay nview'
alias r-peers='docker exec relay curl -s http://localhost:12798/metrics | grep -E "^cardano_node_metrics_(inbound|outbound|cold|warm|hot)"'

# ────────── Container management ──────────
alias r-restart="cd ${CARDANO_HOME} && docker compose restart relay"
alias r-stop="cd ${CARDANO_HOME} && docker compose stop relay"
alias r-start="cd ${CARDANO_HOME} && docker compose start relay"
alias r-up="cd ${CARDANO_HOME} && docker compose up -d"
alias r-down="cd ${CARDANO_HOME} && docker compose down"
alias r-pull="cd ${CARDANO_HOME} && docker compose pull && docker compose up -d"
alias r-version='docker exec relay cardano-node --version | head -1'
alias r-disk="du -sh ${CARDANO_HOME}/db ${CARDANO_HOME}/ipc ${CARDANO_CONFIG_DIR} 2>/dev/null && echo && df -h /"

# ────────── Help / Banner ──────────
r-help() {
  local CT="\033[1;36m" CC="\033[1;33m" CM="\033[1;32m" CD="\033[0;37m" DM="\033[2;37m" N="\033[0m"
  local fqdn=$(hostname -f 2>/dev/null || hostname)
  echo
  echo "${CT}╔══════════════════════════════════════════════════════════════════╗${N}"
  echo "${CT}║  Cardano Relay — ${fqdn}${N}"
  echo "${CT}╚══════════════════════════════════════════════════════════════════╝${N}"
  echo
  echo "${CC}── STATUS ──────────────────────────────────────────────────────────${N}"
  printf "  ${CM}%-16s${CD}%s${N}\n" "r-health"     "Health check (12 sections)"
  printf "  ${CM}%-16s${CD}%s${N}\n" "r-tip"        "Sync status & tip"
  printf "  ${CM}%-16s${CD}%s${N}\n" "r-peers"      "Peer counts"
  printf "  ${CM}%-16s${CD}%s${N}\n" "r-validation" "Chain validation progress"
  echo
  echo "${CC}── LIVE MONITORING ─────────────────────────────────────────────────${N}"
  printf "  ${CM}%-16s${CD}%s${N}\n" "r-nview"      "Live dashboard"
  printf "  ${CM}%-16s${CD}%s${N}\n" "r-logs"       "Tail logs"
  printf "  ${CM}%-16s${CD}%s${N}\n" "r-logs-err"   "Errors & warnings"
  printf "  ${CM}%-16s${CD}%s${N}\n" "r-stats"      "Container CPU/RAM"
  printf "  ${CM}%-16s${CD}%s${N}\n" "r-status"     "Container state"
  echo
  echo "${CC}── CONTAINER MANAGEMENT ────────────────────────────────────────────${N}"
  printf "  ${CM}%-16s${CD}%s${N}\n" "r-restart"    "Restart relay"
  printf "  ${CM}%-16s${CD}%s${N}\n" "r-stop"       "Stop"
  printf "  ${CM}%-16s${CD}%s${N}\n" "r-start"      "Start"
  printf "  ${CM}%-16s${CD}%s${N}\n" "r-up"         "Compose up -d"
  printf "  ${CM}%-16s${CD}%s${N}\n" "r-down"       "Compose down"
  printf "  ${CM}%-16s${CD}%s${N}\n" "r-pull"       "Pull image & restart"
  printf "  ${CM}%-16s${CD}%s${N}\n" "r-version"    "Cardano-node version"
  printf "  ${CM}%-16s${CD}%s${N}\n" "r-disk"       "Disk usage"
  echo
  echo "${CC}── RAW CLI ─────────────────────────────────────────────────────────${N}"
  printf "  ${CM}%-16s${CD}%s${N}\n" "cardano-cli"  "Full cardano-cli με mounts"
  echo
  echo "${DM}  r-help anytime για αυτό το menu${N}"
  echo
}

# ────────── Quick health line (on login) ──────────
r-quickcheck() {
  local CO="\033[1;32m" CW="\033[1;33m" CR="\033[1;31m" D="\033[2;37m" N="\033[0m"
  local cont_state
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^relay$'; then
    cont_state="${CO}● running${N}"
  else
    echo "  Relay: ${CR}● stopped${N}"; return
  fi

  local validation
  validation=$(docker logs --tail 50 relay 2>&1 | grep "Validated chunk" | tail -1)
  if [[ -n "$validation" ]]; then
    local prog=$(echo "$validation" | grep -oE "Progress: [0-9.]+" | awk '{print $2}')
    echo "  Relay: $cont_state  ${D}|${N}  ${CW}validating chain: ${prog}%${N}"
    return
  fi

  local tip_json
  tip_json=$(timeout 5 docker exec relay sh -c \
    "CARDANO_NODE_SOCKET_PATH=/ipc/node.socket cardano-cli query tip --${CARDANO_NETWORK} 2>/dev/null" 2>/dev/null)
  if [[ -n "$tip_json" ]]; then
    local p=$(echo "$tip_json" | jq -r '.syncProgress' 2>/dev/null)
    local e=$(echo "$tip_json" | jq -r '.epoch' 2>/dev/null)
    local s=$(echo "$tip_json" | jq -r '.slot' 2>/dev/null)
    if [[ "$p" == "100.00" ]]; then
      local peers=$(docker exec relay curl -s http://localhost:12798/metrics 2>/dev/null \
        | awk '/^cardano_node_metrics_inboundCxns_int/ {ib=$2} /^cardano_node_metrics_outboundCxns_int/ {ob=$2} END {print "in:"ib" out:"ob}')
      echo "  Relay: $cont_state  ${D}|${N}  sync: ${CO}${p}%${N}  ${D}|${N}  epoch: ${e}  ${D}|${N}  ${peers}"
    else
      echo "  Relay: $cont_state  ${D}|${N}  sync: ${CW}${p}%${N}  ${D}|${N}  epoch: ${e}"
    fi
  else
    echo "  Relay: $cont_state  ${D}|${N}  ${CW}cli timeout${N}"
  fi
}

# Auto-run στο interactive shell
if [[ -o interactive ]]; then
  r-help
  r-quickcheck
  echo
fi
