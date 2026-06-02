#!/usr/bin/env bash
# ============================================================
# bp-health.sh — Quick BP health summary (parameterized)
# Reads $CARDANO_HOME/config.env
# ============================================================
set -uo pipefail

CONFIG_FILE="${CARDANO_HOME:-/opt/cardano}/config.env"
[[ -f "$CONFIG_FILE" ]] && { set -a; . "$CONFIG_FILE"; set +a; }

: "${POOL_NAME:?POOL_NAME required}"
: "${CARDANO_HOME:?required}"
: "${POOL_DIR:=${CARDANO_HOME}/priv/pool/${POOL_NAME}}"
: "${BP_KEYS_DIR:=${CARDANO_HOME}/bp-keys}"
: "${CARDANO_IPC_DIR:=${CARDANO_HOME}/ipc}"
: "${CARDANO_CONFIG_DIR:=${CARDANO_HOME}/config/mainnet}"
: "${CARDANO_DB_DIR:=${CARDANO_HOME}/db}"
: "${CARDANO_NETWORK:=mainnet}"
: "${CARDANO_IMAGE:=ghcr.io/blinklabs-io/cardano-node:latest}"

GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'
DIM='\033[2;37m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
warn() { echo -e "  ${YELLOW}⚠${RESET} $1"; }
err()  { echo -e "  ${RED}✗${RESET} $1"; }
section() { echo -e "\n${BOLD}── $1 ──${RESET}"; }

# 1. Container
section "Container"
if docker ps --format '{{.Names}}' | grep -q '^producer$'; then
  started=$(docker inspect producer --format '{{.State.StartedAt}}')
  uptime_h=$(( ($(date +%s) - $(date -d "$started" +%s)) / 3600 ))
  ok "Producer running (uptime: ${uptime_h}h)"
else
  err "Producer NOT running"; exit 1
fi

# 2. Sync
section "Sync"
tip=$(docker exec producer sh -c "CARDANO_NODE_SOCKET_PATH=/ipc/node.socket cardano-cli query tip --${CARDANO_NETWORK}" 2>/dev/null)
if [[ -n "$tip" ]]; then
  progress=$(echo "$tip" | jq -r '.syncProgress')
  epoch=$(echo "$tip" | jq -r '.epoch')
  slot=$(echo "$tip" | jq -r '.slot')
  era=$(echo "$tip" | jq -r '.era')
  if [[ "$progress" == "100.00" ]]; then
    ok "Synced 100% — epoch ${epoch}, slot ${slot} (${era})"
  else
    warn "Syncing: ${progress}% — epoch ${epoch}"
  fi
else
  err "Cannot query tip"
fi

# 3. Peers
section "Peers"
metrics=$(docker exec producer curl -s http://localhost:12798/metrics 2>/dev/null)
if [[ -n "$metrics" ]]; then
  # P2P metrics (νέες εκδόσεις cardano-node)
  p2p_hot=$(echo "$metrics"    | awk '/^cardano_node_metrics_peerSelection_Hot_int / {print $2}')
  p2p_warm=$(echo "$metrics"   | awk '/^cardano_node_metrics_peerSelection_Warm_int / {print $2}')
  p2p_cold=$(echo "$metrics"   | awk '/^cardano_node_metrics_peerSelection_Cold_int / {print $2}')
  p2p_active=$(echo "$metrics" | awk '/^cardano_node_metrics_peerSelection_ActivePeers_int / {print $2}')
  duplex=$(echo "$metrics"     | awk '/^cardano_node_metrics_connectionManager_duplexConns_int / {print $2}')
  outb_p2p=$(echo "$metrics"   | awk '/^cardano_node_metrics_connectionManager_outboundConns_int / {print $2}')

  if [[ -n "$p2p_hot" || -n "$p2p_active" || -n "$duplex" ]]; then
    # P2P node
    active=${p2p_active:-${p2p_hot:-0}}
    if [[ "${active:-0}" -gt 0 || "${duplex:-0}" -gt 0 ]]; then
      ok "P2P peers — hot: ${p2p_hot:-0}, warm: ${p2p_warm:-0}, cold: ${p2p_cold:-0}, active: ${p2p_active:-0}"
      [[ -n "$duplex" ]] && ok "Duplex connections: ${duplex}"
    else
      err "0 active P2P peers — relay unreachable?"
    fi
  else
    # Legacy non-P2P fallback
    outb=$(echo "$metrics" | awk '/^cardano_node_metrics_outboundCxns_int / {print $2}')
    inb=$(echo "$metrics"  | awk '/^cardano_node_metrics_inboundCxns_int / {print $2}')
    cold=$(echo "$metrics" | awk '/^cardano_node_metrics_coldPeers_int / {print $2}')
    warm=$(echo "$metrics" | awk '/^cardano_node_metrics_warmPeers_int / {print $2}')
    hot=$(echo "$metrics"  | awk '/^cardano_node_metrics_hotPeers_int / {print $2}')
    if [[ "${outb:-0}" -gt 0 ]]; then
      ok "Outbound: ${outb}  Inbound: ${inb:-0}"
      ok "Peers — cold: ${cold:-0}, warm: ${warm:-0}, hot: ${hot:-0}"
    else
      err "No outbound connections — relay unreachable?"
    fi
  fi
else
  warn "Metrics endpoint unreachable"
fi

# 4. Forging
section "Forging"
bp_env=$(docker exec producer printenv CARDANO_BLOCK_PRODUCER 2>/dev/null)
if [[ "$bp_env" == "true" ]]; then
  ok "BP mode enabled"
  forging=$(echo "$metrics" | awk '/^cardano_node_metrics_forging_enabled_int/ {print $2}')
  if [[ "${forging:-0}" == "1" ]]; then
    ok "Forge loop active"
  else
    err "Forging disabled — KES/op.cert issue?"
  fi
else
  warn "Not in BP mode"
fi

# 5. KES
section "KES"
kes=$(docker run --rm \
  -v "${CARDANO_IPC_DIR}:/ipc" \
  -v "${BP_KEYS_DIR}:/keys:ro" \
  -e CARDANO_NODE_SOCKET_PATH=/ipc/node.socket \
  "$CARDANO_IMAGE" cli \
  query kes-period-info "--${CARDANO_NETWORK}" --op-cert-file /keys/node.cert 2>/dev/null \
  | sed -n '/^{/,/^}/p')

if [[ -n "$kes" ]]; then
  cur=$(echo "$kes" | jq -r '.qKesCurrentKesPeriod')
  endp=$(echo "$kes" | jq -r '.qKesEndKesInterval')
  expiry=$(echo "$kes" | jq -r '.qKesKesKeyExpiry')
  on_disk=$(echo "$kes" | jq -r '.qKesOnDiskOperationalCertificateNumber')
  on_chain=$(echo "$kes" | jq -r '.qKesNodeStateOperationalCertificateNumber')
  remaining=$((endp - cur))
  expiry_human=$(date -d "$expiry" '+%Y-%m-%d' 2>/dev/null || echo "$expiry")

  if [[ $remaining -gt 10 ]]; then
    ok "KES valid: period ${cur}/${endp} (${remaining} left) — expires ${expiry_human}"
  elif [[ $remaining -gt 0 ]]; then
    warn "KES expiring soon: ${remaining} periods — rotate ΑΜΕΣΑ"
  else
    err "KES EXPIRED — rotate now!"
  fi

  diff=$((on_disk - on_chain))
  if [[ $diff -le 1 ]] && [[ $diff -ge 0 ]]; then
    ok "Op cert sync: on-disk=${on_disk}, on-chain=${on_chain}"
  else
    err "Op cert mismatch: on-disk=${on_disk}, on-chain=${on_chain}"
  fi
else
  warn "Cannot read KES info"
fi

# 6. Disk
section "Disk"
db_size=$(du -sh "$CARDANO_DB_DIR" 2>/dev/null | cut -f1)
disk_avail=$(df -h / | awk 'NR==2 {print $4}')
disk_pct=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
ok "DB size: ${db_size}"
if [[ $disk_pct -lt 80 ]]; then
  ok "Free: ${disk_avail} (${disk_pct}% used)"
elif [[ $disk_pct -lt 90 ]]; then
  warn "Free: ${disk_avail} (${disk_pct}% used)"
else
  err "ALMOST FULL: ${disk_pct}% used"
fi
echo
