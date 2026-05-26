#!/usr/bin/env bash
# ============================================================
# relay-health.sh v2 — Comprehensive Cardano Relay Health Check
#
# Έλεγχοι σε 12 σημεία:
#   1. Container & Uptime
#   2. Chain Validation Progress (αρχικός sync)
#   3. Chain Sync & Tip Lag
#   4. Time Sync (NTP)
#   5. System Resources (disk, memory, cpu, DB size)
#   6. Peer Connectivity (inbound/outbound/cold/warm/hot)
#   7. BP Connectivity (συνδέεται το BP εδώ;)
#   8. Block & Header Propagation (served/received metrics)
#   9. External Reachability (port 6000 από έξω)
#  10. Mempool (txs propagating;)
#  11. Critical Errors στα logs (24h)
#  12. Topology Validation
#
# Συνέπεια με bp-preflight.sh v2:
#   • CLI flags (--fast, --json, --no-telegram, --help)
#   • Timeouts σε όλα τα blocking calls
#   • Telegram alerts σε αποτυχία
#   • JSON output mode για monitoring
#
# Exit codes: 0 = healthy, 1 = problems, 2 = bad args
# ============================================================

set -uo pipefail

# ─── CLI Arguments ──────────────────────────────────────────
SKIP_VALIDATION_WAIT=0
OUTPUT_FORMAT=text
ENABLE_TELEGRAM=auto

show_help() {
  cat <<EOF
relay-health.sh v2 — Cardano Relay health check

Usage: $0 [OPTIONS]

Options:
  -f, --fast          Skip χρονοβόρους ελέγχους (external port test)
      --json          Output αποτελεσμάτων σε JSON
      --no-telegram   Μην στείλεις Telegram alert
  -h, --help          Εμφάνιση help

Environment:
  RELAY_CONTAINER         Container name (default: relay)
  BP_EXPECTED_IP          IP του BP για έλεγχο connectivity (optional)
  PEER_RELAY_IPS          Comma-separated άλλοι relays που περιμένεις να συνδέονται
  TELEGRAM_BOT_TOKEN      Token για alerts
  TELEGRAM_CHAT_ID        Chat ID
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--fast)        SKIP_VALIDATION_WAIT=1; shift ;;
    --json)           OUTPUT_FORMAT=json; shift ;;
    --no-telegram)    ENABLE_TELEGRAM=no; shift ;;
    -h|--help)        show_help; exit 0 ;;
    *) echo "Άγνωστο flag: $1" >&2; show_help >&2; exit 2 ;;
  esac
done

# ─── Load config.env ────────────────────────────────────────
CONFIG_FILE="${CARDANO_HOME:-/opt/cardano}/config.env"
if [[ -f "$CONFIG_FILE" ]]; then
  set -a; . "$CONFIG_FILE"; set +a
fi

: "${CARDANO_HOME:?CARDANO_HOME required}"
: "${CARDANO_NETWORK:=mainnet}"

CONTAINER="${RELAY_CONTAINER:-relay}"
RELAY_PORT="${RELAY_PORT:-6000}"
METRICS_PORT=12798

IPC_DIR="${CARDANO_IPC_DIR:-${CARDANO_HOME}/ipc}"
CONFIG_DIR="${CARDANO_CONFIG_DIR:-${CARDANO_HOME}/config/${CARDANO_NETWORK}}"
DB_DIR="${CARDANO_DB_DIR:-${CARDANO_HOME}/db}"

CONTAINER_TOPOLOGY_PATH="/opt/cardano/config/${CARDANO_NETWORK}/topology.json"
CONTAINER_METRICS_URL="http://localhost:${METRICS_PORT}/metrics"

# Mainnet Shelley genesis
SHELLEY_START_UNIX=1596059091
BYRON_END_SLOT=4492800

# Όρια
TIP_LAG_OK=60
TIP_LAG_WARN=180
MIN_INBOUND_PEERS=2     # τουλάχιστον BP + 1 άλλος
MIN_OUTBOUND_PEERS=5    # τουλάχιστον 5 ledger peers
DB_GROWTH_MIN_KB=10     # αν δεν μεγαλώνει >10KB σε 30s → stuck

# Optional: peer IPs που περιμένουμε
BP_EXPECTED_IP="${BP_EXPECTED_IP:-}"
PEER_RELAY_IPS="${PEER_RELAY_IPS:-}"

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# ─── Colors & Helpers ───────────────────────────────────────
if [[ "$OUTPUT_FORMAT" == "text" ]]; then
  G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'
  B='\033[1m'; D='\033[2;37m'; N='\033[0m'
else
  G=''; Y=''; R=''; B=''; D=''; N=''
fi

PASS=0; WARN=0; FAIL=0
WARNINGS=(); FAILURES=()

ok()      { [[ "$OUTPUT_FORMAT" == "text" ]] && echo -e "  ${G}✓${N} $1"; PASS=$((PASS+1)); }
warn()    { [[ "$OUTPUT_FORMAT" == "text" ]] && echo -e "  ${Y}⚠${N} $1"; WARN=$((WARN+1)); WARNINGS+=("$1"); }
err()     { [[ "$OUTPUT_FORMAT" == "text" ]] && echo -e "  ${R}✗${N} $1"; FAIL=$((FAIL+1)); FAILURES+=("$1"); }
section() { [[ "$OUTPUT_FORMAT" == "text" ]] && echo -e "\n${B}── $1 ──${N}"; }
hint()    { [[ "$OUTPUT_FORMAT" == "text" ]] && echo -e "    ${D}$1${N}"; }

# ─── Docker Wrappers ────────────────────────────────────────
EXEC_RELAY() {
  timeout 15 docker exec "$CONTAINER" "$@" 2>/dev/null
}

QUERY_TIP() {
  timeout 15 docker exec "$CONTAINER" sh -c \
    "CARDANO_NODE_SOCKET_PATH=/ipc/node.socket cardano-cli query tip --${CARDANO_NETWORK}" 2>/dev/null
}

# ─── Header ─────────────────────────────────────────────────
if [[ "$OUTPUT_FORMAT" == "text" ]]; then
  echo -e "${B}╔══════════════════════════════════════════════════════════════════╗${N}"
  echo -e "${B}║  Relay Health Check — ${CONTAINER}${N}"
  echo -e "${B}║  $(date '+%Y-%m-%d %H:%M:%S %Z')${N}"
  echo -e "${B}╚══════════════════════════════════════════════════════════════════╝${N}"
fi

# Globals για JSON output
tip_lag=0; epoch=0; slot=0
inb=0; outb=0; cold=0; warm=0; hot=0
served_h=0; served_b=0
sync_progress="0"
db_size_bytes=0
public_ip=""

# ────────── 1. Container & Uptime ──────────
section "1. Container & Uptime"

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  err "Relay container '${CONTAINER}' δεν τρέχει"
  if [[ "$OUTPUT_FORMAT" == "text" ]]; then
    echo
    echo -e "${R}${B} ✗ CRITICAL${N} — relay είναι down\n"
  fi
  exit 1
fi

started=$(docker inspect "$CONTAINER" --format '{{.State.StartedAt}}' 2>/dev/null)
if [[ -n "$started" ]]; then
  uptime_sec=$(( $(date +%s) - $(date -d "$started" +%s) ))
  uptime_h=$(( uptime_sec / 3600 ))
  uptime_d=$(( uptime_h / 24 ))

  if [[ $uptime_sec -lt 300 ]]; then
    warn "Relay μόλις ξεκίνησε (uptime: ${uptime_sec}s) — πιθανός recent restart"
  elif [[ $uptime_d -gt 0 ]]; then
    ok "Relay running (uptime: ${uptime_d}d $((uptime_h % 24))h)"
  else
    ok "Relay running (uptime: ${uptime_h}h)"
  fi
else
  warn "Δεν μπόρεσα να διαβάσω uptime"
fi

# Restart count — αν restart-άρει συχνά, υπάρχει πρόβλημα
restarts=$(docker inspect "$CONTAINER" --format '{{.RestartCount}}' 2>/dev/null)
if [[ -n "$restarts" ]]; then
  if [[ ${restarts:-0} -gt 5 ]]; then
    warn "Restart count: ${restarts} — έλεγξε docker logs για crashes"
  else
    ok "Restart count: ${restarts}"
  fi
fi

# ────────── 2. Chain Validation Progress ──────────
section "2. Chain Validation"

logs_recent=$(timeout 10 docker logs --tail 500 "$CONTAINER" 2>&1 || true)
logs_24h=$(timeout 30 docker logs --since 24h "$CONTAINER" 2>&1 || true)

validation=$(echo "$logs_recent" | grep "Validated chunk" | tail -1)
if [[ -n "$validation" ]]; then
  progress=$(echo "$validation" | grep -oE "Progress: [0-9.]+" | awk '{print $2}')
  chunk=$(echo "$validation" | grep -oE "no\. [0-9]+" | awk '{print $2}')
  total=$(echo "$validation" | grep -oE "out of [0-9]+" | awk '{print $3}')

  # Δες αν χρονικά είναι πρόσφατο
  last_line_time=$(echo "$logs_recent" | grep "Validated chunk" | tail -1 | awk '{print $1, $2}')
  warn "Chain validation σε εξέλιξη: chunk ${chunk}/${total} (${progress}%)"
  hint "Τελευταίο validation log: ${last_line_time}"
  hint "Node δεν είναι ακόμα ready — περιμένει validation"
else
  ok "Chain validation complete (ή ήδη έχει τρέξει)"
fi

# Παράλληλα έλεγξε αν υπάρχει db corruption σήμα
corruption=$(echo "$logs_24h" | grep -ciE "corrupted|inconsistent|database error|chainDB.*Error" || true)
if [[ ${corruption:-0} -gt 0 ]]; then
  err "${corruption} σήματα DB corruption στις 24h — έλεγξε logs"
fi

# ────────── 3. Sync & Tip Lag ──────────
section "3. Sync & Tip Lag"

tip=$(QUERY_TIP)
if [[ -z "$tip" ]]; then
  warn "Cannot query tip (πιθανώς ακόμα σε validation)"
  tip='{}'
fi

sync_progress=$(echo "$tip" | jq -r '.syncProgress // "0"')
epoch=$(echo "$tip" | jq -r '.epoch // 0')
slot=$(echo "$tip" | jq -r '.slot // 0')
era=$(echo "$tip" | jq -r '.era // "Unknown"')
block=$(echo "$tip" | jq -r '.block // 0')

if [[ "$sync_progress" == "100.00" ]]; then
  ok "Synced 100% — epoch ${epoch}, slot ${slot}, block ${block} (${era})"
elif [[ -z "${sync_progress// }" || "$sync_progress" == "0" ]]; then
  err "Cannot determine sync state"
else
  warn "Syncing: ${sync_progress}% — epoch ${epoch}"
fi

# Tip lag (ίδιος υπολογισμός με BP)
wall_now=$(date +%s)
expected_slot=$((wall_now - SHELLEY_START_UNIX + BYRON_END_SLOT))
tip_lag=$((expected_slot - slot))

if [[ $slot -eq 0 ]]; then
  hint "Δεν υπολογίζεται tip lag (δεν έχει slot ακόμα)"
elif [[ $tip_lag -lt $TIP_LAG_OK ]]; then
  ok "Chain tip lag: ${tip_lag}s"
elif [[ $tip_lag -lt $TIP_LAG_WARN ]]; then
  warn "Chain tip lag: ${tip_lag}s — οριακό"
else
  err "Chain tip lag: ${tip_lag}s — relay χάνει tip, BP δεν θα δεχτεί έγκαιρα blocks"
fi

# Density — αν είναι σημαντικά διαφορετικό από κανονικό 0.05 = πρόβλημα
density=$(EXEC_RELAY curl -s "${CONTAINER_METRICS_URL}" 2>/dev/null | \
  awk '/^cardano_node_metrics_density_real/ {print $2}')
if [[ -n "$density" ]]; then
  # Σύγκριση με 0.05 (μέσος όρος) - αποδεκτό 0.03-0.07
  density_int=$(awk -v d="$density" 'BEGIN {printf "%d", d*1000}')
  if [[ $density_int -ge 30 ]] && [[ $density_int -le 70 ]]; then
    ok "Chain density: ${density} (φυσιολογικό)"
  else
    warn "Chain density: ${density} — εκτός κανονικού 0.030-0.070"
  fi
fi

# ────────── 4. Time Sync (NTP) ──────────
section "4. Time Sync (NTP)"

if command -v chronyc >/dev/null 2>&1 && systemctl is-active --quiet chronyd 2>/dev/null; then
  tracking=$(timeout 5 chronyc tracking 2>/dev/null)
  offset_sec=$(echo "$tracking" | awk '/Last offset/ {print $4}')
  stratum=$(echo "$tracking" | awk '/Stratum/ {print $3}')
  leap=$(echo "$tracking" | awk -F': ' '/Leap status/ {print $2}' | xargs)

  abs_ms=$(awk -v s="${offset_sec:-0}" \
    'BEGIN { v = s*1000; if (v < 0) v = -v; printf "%d", v }')

  if [[ ${abs_ms:-9999} -lt 100 ]]; then
    ok "NTP offset ${offset_sec}s (stratum ${stratum})"
  elif [[ ${abs_ms:-9999} -lt 500 ]]; then
    warn "NTP offset ${offset_sec}s — οριακό για relay"
  else
    err "NTP offset ${offset_sec}s — block propagation θα έχει drift"
  fi

  [[ "$leap" != "Normal" ]] && warn "chrony leap: ${leap}"
elif command -v ntpq >/dev/null 2>&1 && systemctl is-active --quiet ntpd 2>/dev/null; then
  offset=$(timeout 5 ntpq -pn 2>/dev/null | awk '/^\*/ {print $9}' | head -1)
  [[ -n "$offset" ]] && ok "ntpd offset: ${offset}ms"
else
  warn "Καμία NTP υπηρεσία ενεργή — apt install chrony"
fi

# ────────── 5. System Resources ──────────
section "5. System Resources"

# DB size + growth check
db_size_human=$(timeout 10 du -sh "$DB_DIR" 2>/dev/null | cut -f1)
db_size_bytes=$(timeout 10 du -sb "$DB_DIR" 2>/dev/null | cut -f1)
if [[ -n "$db_size_human" ]]; then
  ok "DB size: ${db_size_human}"
fi

# Disk
disk_avail=$(df -h / | awk 'NR==2 {print $4}')
disk_pct=$(df / | awk 'NR==2 {gsub("%",""); print $5}')
if [[ $disk_pct -lt 80 ]]; then
  ok "Disk free: ${disk_avail} (${disk_pct}% used)"
elif [[ $disk_pct -lt 90 ]]; then
  warn "Disk free: ${disk_avail} (${disk_pct}% used) — καθάρισε σύντομα"
else
  err "Disk ${disk_pct}% used — KΡΙΣΙΜΟ"
fi

# Container stats
stats=$(timeout 5 docker stats "$CONTAINER" --no-stream --format '{{.MemPerc}}|{{.CPUPerc}}|{{.BlockIO}}' 2>/dev/null)
mem_pct=$(echo "$stats" | cut -d'|' -f1 | tr -d '%')
cpu_pct=$(echo "$stats" | cut -d'|' -f2 | tr -d '%')

mem_int=${mem_pct%.*}
if [[ ${mem_int:-0} -lt 75 ]]; then
  ok "Memory: ${mem_pct}%"
elif [[ ${mem_int:-0} -lt 90 ]]; then
  warn "Memory: ${mem_pct}% — κοντά στο όριο"
else
  err "Memory: ${mem_pct}% — OOM risk"
fi

cpu_int=${cpu_pct%.*}
if [[ ${cpu_int:-0} -lt 200 ]]; then
  ok "CPU: ${cpu_pct}%"
else
  warn "CPU: ${cpu_pct}% — υψηλό"
fi

# Load
load1=$(awk '{print $1}' /proc/loadavg)
cores=$(nproc)
load_pct=$(awk -v l="$load1" -v c="$cores" 'BEGIN {printf "%d", (l/c)*100}')
if [[ $load_pct -lt 80 ]]; then
  ok "Host load: ${load1} (${load_pct}% of ${cores} cores)"
else
  warn "Host load: ${load1} (${load_pct}% of ${cores} cores)"
fi

# ────────── 6. Peer Connectivity ──────────
section "6. Peer Connectivity"

metrics=$(timeout 10 docker exec "$CONTAINER" curl -s "${CONTAINER_METRICS_URL}" 2>/dev/null || true)

if [[ -z "$metrics" ]]; then
  err "Metrics endpoint unreachable"
else
  # ── Connection counts ──
  # P2P-first (νέες εκδόσεις), legacy fallback
  inb=$(echo "$metrics"  | awk '/^cardano_node_metrics_connectionManager_inboundConns_int /  {print $2}')
  outb=$(echo "$metrics" | awk '/^cardano_node_metrics_connectionManager_outboundConns_int / {print $2}')
  duplex=$(echo "$metrics" | awk '/^cardano_node_metrics_connectionManager_duplexConns_int / {print $2}')

  # Legacy fallback (παλιό non-P2P)
  [[ -z "$inb" ]]  && inb=$(echo "$metrics"  | awk '/^cardano_node_metrics_inboundCxns_int /  {print $2}')
  [[ -z "$outb" ]] && outb=$(echo "$metrics" | awk '/^cardano_node_metrics_outboundCxns_int / {print $2}')

  # ── Peer selection states (overall P2P) ──
  # Strict awk match με trailing space για να μην πιάνει HotBigLedgerPeers κτλ
  hot=$(echo "$metrics"  | awk '/^cardano_node_metrics_peerSelection_Hot_int /  {print $2}')
  warm=$(echo "$metrics" | awk '/^cardano_node_metrics_peerSelection_Warm_int / {print $2}')
  cold=$(echo "$metrics" | awk '/^cardano_node_metrics_peerSelection_Cold_int / {print $2}')
  active=$(echo "$metrics" | awk '/^cardano_node_metrics_peerSelection_ActivePeers_int / {print $2}')

  # Legacy fallback
  [[ -z "$hot" ]]  && hot=$(echo "$metrics"  | awk '/^cardano_node_metrics_hotPeers_int /  {print $2}')
  [[ -z "$warm" ]] && warm=$(echo "$metrics" | awk '/^cardano_node_metrics_warmPeers_int / {print $2}')
  [[ -z "$cold" ]] && cold=$(echo "$metrics" | awk '/^cardano_node_metrics_coldPeers_int / {print $2}')

  # ── Inbound governor breakdown (νέο σε P2P) ──
  inb_hot=$(echo "$metrics"  | awk '/^cardano_node_metrics_inboundGovernor_hot_int /  {print $2}')
  inb_warm=$(echo "$metrics" | awk '/^cardano_node_metrics_inboundGovernor_warm_int / {print $2}')
  inb_cold=$(echo "$metrics" | awk '/^cardano_node_metrics_inboundGovernor_cold_int / {print $2}')

  inb=${inb:-0}; outb=${outb:-0}; cold=${cold:-0}; warm=${warm:-0}; hot=${hot:-0}
  active=${active:-0}; duplex=${duplex:-0}
  inb_hot=${inb_hot:-0}; inb_warm=${inb_warm:-0}; inb_cold=${inb_cold:-0}

  # Inbound connections — relay role
  if [[ $inb -ge $MIN_INBOUND_PEERS ]]; then
    ok "Inbound: ${inb} connections (συνδέονται σε εσένα)"
  elif [[ $inb -gt 0 ]]; then
    warn "Inbound: ${inb} — αναμένουμε ≥${MIN_INBOUND_PEERS}"
  else
    err "Inbound: 0 — κανείς δεν συνδέεται. Έλεγξε firewall/port forward"
  fi

  # Outbound
  if [[ $outb -ge $MIN_OUTBOUND_PEERS ]]; then
    ok "Outbound: ${outb} connections (συνδέεσαι σε ledger peers)"
  elif [[ $outb -gt 0 ]]; then
    warn "Outbound: ${outb} — αναμένουμε ≥${MIN_OUTBOUND_PEERS}"
  else
    err "Outbound: 0 — δεν συνδέεσαι σε ledger. Έλεγξε topology/DNS"
  fi

  # Duplex connections (full-duplex = θετικό για P2P efficiency)
  if [[ $duplex -gt 0 ]]; then
    ok "Duplex connections: ${duplex} (bi-directional P2P)"
  fi

  # Peer selection states
  ok "Peer states (overall) — hot: ${hot}, warm: ${warm}, cold: ${cold}, active: ${active}"

  # Inbound governor breakdown (αν P2P)
  if [[ $((inb_hot + inb_warm + inb_cold)) -gt 0 ]]; then
    ok "Inbound governor — hot: ${inb_hot}, warm: ${inb_warm}, cold: ${inb_cold}"
  fi

  # Hot peers κρίσιμο
  if [[ $hot -eq 0 ]]; then
    err "0 hot peers στο peer selection — δεν υπάρχει active chain-sync"
  elif [[ $hot -lt 5 ]]; then
    warn "Μόνο ${hot} hot peers — λίγα για robust propagation (στόχος ≥10)"
  fi
fi

# ────────── 7. BP Connectivity ──────────
section "7. BP Connectivity"

# Πάρε λίστα ESTABLISHED inbound connections στο port 6000
inbound_ips=$(timeout 5 docker exec "$CONTAINER" sh -c "
  ss -tn state established 2>/dev/null | \
    awk -v p=':${RELAY_PORT}' '\$3 ~ p {split(\$4, a, \":\"); print a[1]}' | sort -u
" 2>/dev/null || true)

# Fallback μέσω /proc/net/tcp αν δεν έχει ss
if [[ -z "$inbound_ips" ]]; then
  hex_port=$(printf '%04X' $RELAY_PORT)
  inbound_ips=$(timeout 5 docker exec "$CONTAINER" sh -c "
    awk -v p=\"${hex_port}\" '\$2 ~ \":\" p\"\$\" && \$4 == \"01\" {
      n = split(\$3, a, \":\");
      ip = a[1];
      # convert hex to dotted decimal (little-endian)
      printf \"%d.%d.%d.%d\\n\", strtonum(\"0x\" substr(ip,7,2)), strtonum(\"0x\" substr(ip,5,2)), strtonum(\"0x\" substr(ip,3,2)), strtonum(\"0x\" substr(ip,1,2))
    }' /proc/net/tcp 2>/dev/null | sort -u
  " 2>/dev/null || true)
fi

inbound_count=$(echo "$inbound_ips" | grep -c . || true)

if [[ ${inbound_count:-0} -gt 0 ]]; then
  ok "Established inbound: ${inbound_count} IPs"
  if [[ "$OUTPUT_FORMAT" == "text" ]]; then
    echo "$inbound_ips" | head -10 | sed 's/^/    /'
    [[ $inbound_count -gt 10 ]] && hint "(+$((inbound_count - 10)) ακόμα)"
  fi

  # Αν έχει δοθεί BP_EXPECTED_IP, επιβεβαίωσε
  if [[ -n "$BP_EXPECTED_IP" ]]; then
    if echo "$inbound_ips" | grep -qFx "$BP_EXPECTED_IP"; then
      ok "BP συνδεδεμένο (${BP_EXPECTED_IP})"
    else
      err "BP (${BP_EXPECTED_IP}) ΔΕΝ είναι συνδεδεμένο — δεν θα διαδοθούν τα blocks σου"
    fi
  else
    hint "Set BP_EXPECTED_IP για auto-verify ότι το BP συνδέεται"
  fi

  # Άλλοι expected peer relays
  if [[ -n "$PEER_RELAY_IPS" ]]; then
    IFS=',' read -ra PEER_ARR <<< "$PEER_RELAY_IPS"
    for peer_ip in "${PEER_ARR[@]}"; do
      peer_ip=$(echo "$peer_ip" | xargs)  # trim
      [[ -z "$peer_ip" ]] && continue
      if echo "$inbound_ips" | grep -qFx "$peer_ip"; then
        ok "Peer relay ${peer_ip} συνδεδεμένος"
      else
        warn "Peer relay ${peer_ip} ΟΧΙ συνδεδεμένος (μπορεί να συνδέεται μέσω outbound)"
      fi
    done
  fi
else
  err "0 inbound TCP connections στο :${RELAY_PORT}"
fi

# ────────── 8. Block & Header Propagation ──────────
section "8. Block & Header Propagation"

if [[ -n "$metrics" ]]; then
  # Served counts — στις P2P εκδόσεις λέγονται *_counter (όχι *_count_int)
  served_h=$(echo "$metrics" | awk '/^cardano_node_metrics_served_header_counter / {print $2}')
  served_b=$(echo "$metrics" | awk '/^cardano_node_metrics_served_block_counter / {print $2}')
  served_chainsync_h=$(echo "$metrics" | awk '/^cardano_node_metrics_ChainSync_HeadersServed_counter / {print $2}')

  # Legacy fallback
  [[ -z "$served_h" ]] && served_h=$(echo "$metrics" | awk '/^cardano_node_metrics_served_header_count_int / {print $2}')
  [[ -z "$served_b" ]] && served_b=$(echo "$metrics" | awk '/^cardano_node_metrics_served_block_count_int / {print $2}')

  served_h=${served_h:-0}; served_b=${served_b:-0}; served_chainsync_h=${served_chainsync_h:-0}

  if [[ $served_h -gt 0 ]] && [[ $served_b -gt 0 ]]; then
    ok "Serving: ${served_h} headers / ${served_b} blocks (peers fetch-άρουν από εσένα)"
    [[ $served_chainsync_h -gt 0 ]] && hint "ChainSync headers served: ${served_chainsync_h}"
  elif [[ $served_h -gt 0 ]] || [[ $served_chainsync_h -gt 0 ]]; then
    warn "Serving headers (${served_h}/${served_chainsync_h}) αλλά μηδέν blocks (${served_b})"
  else
    err "0 served headers/blocks — relay δεν διαδίδει chain"
  fi

  # ── Block fetch quality (πόσο γρήγορα κατεβάζει blocks) ──
  blockdelay=$(echo "$metrics" | awk '/^cardano_node_metrics_blockfetchclient_blockdelay_real / {print $2}')
  cdf_one=$(echo "$metrics" | awk '/^cardano_node_metrics_blockfetchclient_blockdelay_cdfOne_real / {print $2}')
  cdf_three=$(echo "$metrics" | awk '/^cardano_node_metrics_blockfetchclient_blockdelay_cdfThree_real / {print $2}')
  cdf_five=$(echo "$metrics" | awk '/^cardano_node_metrics_blockfetchclient_blockdelay_cdfFive_real / {print $2}')
  late=$(echo "$metrics" | awk '/^cardano_node_metrics_blockfetchclient_lateblocks_counter / {print $2}')

  if [[ -n "$blockdelay" ]]; then
    # Convert σε ms για ευκολία ανάγνωσης
    delay_ms=$(awk -v d="$blockdelay" 'BEGIN {printf "%d", d*1000}')
    if [[ $delay_ms -lt 500 ]]; then
      ok "Block fetch delay: ${delay_ms}ms (εξαιρετικό)"
    elif [[ $delay_ms -lt 1000 ]]; then
      ok "Block fetch delay: ${delay_ms}ms"
    elif [[ $delay_ms -lt 3000 ]]; then
      warn "Block fetch delay: ${delay_ms}ms — αργό για relay"
    else
      err "Block fetch delay: ${delay_ms}ms — block propagation σε κίνδυνο"
    fi
  fi

  # CDF: ποσοστό blocks σε <1s, <3s, <5s (κρίσιμο για propagation quality)
  if [[ -n "$cdf_one" ]]; then
    cdf_one_pct=$(awk -v c="$cdf_one" 'BEGIN {printf "%.1f", c*100}')
    cdf_three_pct=$(awk -v c="${cdf_three:-0}" 'BEGIN {printf "%.1f", c*100}')
    cdf_five_pct=$(awk -v c="${cdf_five:-0}" 'BEGIN {printf "%.1f", c*100}')

    cdf_one_int=$(awk -v c="$cdf_one" 'BEGIN {printf "%d", c*100}')
    if [[ $cdf_one_int -ge 95 ]]; then
      ok "Block diffusion: ${cdf_one_pct}% <1s, ${cdf_three_pct}% <3s, ${cdf_five_pct}% <5s"
    elif [[ $cdf_one_int -ge 85 ]]; then
      warn "Block diffusion: ${cdf_one_pct}% <1s (στόχος ≥95%)"
    else
      err "Block diffusion αργή: μόνο ${cdf_one_pct}% blocks φτάνουν <1s"
    fi
  fi

  # Late blocks counter
  if [[ -n "$late" ]]; then
    if [[ ${late:-0} -lt 10 ]]; then
      ok "Late blocks: ${late} (αμελητέο)"
    elif [[ ${late:-0} -lt 100 ]]; then
      warn "Late blocks: ${late}"
    else
      err "Late blocks: ${late} — σοβαρό propagation issue"
    fi
  fi

  # Block height
  forge_block=$(echo "$metrics" | awk '/^cardano_node_metrics_blockNum_int / {print $2}')
  [[ -n "$forge_block" ]] && ok "Current block height: ${forge_block}"

  # Forwarded txs
  txs_sub=$(echo "$metrics" | awk '/^cardano_node_metrics_txsProcessedNum_int/ {print $2}')
  if [[ -n "$txs_sub" ]]; then
    ok "Transactions processed: ${txs_sub}"
  fi
else
  warn "Metrics δεν είναι διαθέσιμα"
fi

# ────────── 9. External Reachability ──────────
section "9. External Reachability"

public_ip=$(timeout 5 curl -s ifconfig.me 2>/dev/null || timeout 5 curl -s api.ipify.org 2>/dev/null || echo "")

if [[ -n "$public_ip" ]]; then
  ok "Public IP: ${public_ip}"

  if [[ $SKIP_VALIDATION_WAIT -eq 1 ]]; then
    hint "External port check skipped (--fast). Inbound count είναι έμμεσος δείκτης."
  else
    # Δοκίμασε να συνδεθείς στο public IP από το container
    # (NAT loopback test — αν έχει inbound > 0, ξέρουμε σίγουρα ότι λειτουργεί)
    if timeout 5 docker exec "$CONTAINER" sh -c \
         "</dev/tcp/${public_ip}/${RELAY_PORT}" 2>/dev/null; then
      ok "Port ${RELAY_PORT} προσβάσιμο από έξω (NAT loopback test passed)"
    elif [[ ${inb:-0} -gt 0 ]]; then
      ok "NAT loopback failed αλλά έχεις ${inb} inbound — port είναι externally OK"
      hint "Router σου ίσως δεν υποστηρίζει NAT loopback (φυσιολογικό)"
    else
      err "Port ${RELAY_PORT} ΟΧΙ προσβάσιμο + 0 inbound — έλεγξε firewall/port forward"
    fi
  fi

  # Local listening — βρίσκουμε το πεδίο που περιέχει :PORT (varies σε ss versions)
  listening=$(timeout 5 docker exec "$CONTAINER" ss -ln 2>/dev/null | \
    grep -E ":${RELAY_PORT}([^0-9]|$)" | \
    grep -oE '[0-9a-fA-F.:*]+:[0-9]+' | \
    awk -v p="${RELAY_PORT}" '$0 ~ ":" p "$" {print; exit}')
  if [[ -n "$listening" ]]; then
    ok "Listening: ${listening}"
  else
    err "Δεν ακούει στο :${RELAY_PORT} εσωτερικά"
  fi
else
  warn "Δεν μπόρεσα να πάρω public IP"
fi

# ────────── 10. Mempool ──────────
section "10. Mempool"

if [[ -n "$metrics" ]]; then
  mem_txs=$(echo "$metrics" | awk '/^cardano_node_metrics_txsInMempool_int/ {print $2}')
  mem_bytes=$(echo "$metrics" | awk '/^cardano_node_metrics_mempoolBytes_int/ {print $2}')

  if [[ -n "$mem_txs" ]]; then
    mem_kb=$(( ${mem_bytes:-0} / 1024 ))
    ok "Mempool: ${mem_txs} txs / ${mem_kb}KB"

    # Αν είναι 0 για μεγάλο χρόνο, ίσως υπάρχει connectivity issue
    if [[ ${mem_txs:-0} -eq 0 ]]; then
      hint "0 txs στο mempool — φυσιολογικό σε quiet περιόδους"
    fi
  fi
fi

# ────────── 11. Critical Errors στα logs ──────────
section "11. Critical Errors (24h)"

# Single pass scan για όλα τα patterns
critical_patterns=(
  "ConnectionTimeoutError"
  "PeerSharingProtocolMisuse"
  "MuxBearerClosed"
  "ChainSyncError"
  "BlockFetchProtocolFailure"
  "DemotedToColdRemote.*Exception"
)

# GC pauses
gc_count=$(echo "$logs_24h" | grep -cE "GcPause|gcMajorTime" || true)
if [[ ${gc_count:-0} -lt 100 ]]; then
  ok "GC events (24h): ${gc_count}"
elif [[ ${gc_count:-0} -lt 500 ]]; then
  warn "GC events (24h): ${gc_count} — αυξημένα"
else
  err "GC events (24h): ${gc_count} — memory pressure"
fi

# Σύνθετο pattern σε ένα grep
all_critical_regex=$(IFS='|'; echo "${critical_patterns[*]}")
crit_total=$(echo "$logs_24h" | grep -cE "$all_critical_regex" || true)

if [[ ${crit_total:-0} -eq 0 ]]; then
  ok "Καμία κρίσιμη σφάλμα στις τελευταίες 24h"
elif [[ ${crit_total:-0} -lt 10 ]]; then
  warn "${crit_total} κρίσιμα errors (24h) — έλεγξε αν επαναλαμβάνονται"
  hint "docker logs --since 24h ${CONTAINER} | grep -E '${all_critical_regex}' | tail -5"
else
  err "${crit_total} κρίσιμα errors (24h) — μάλλον υπαρκτό πρόβλημα"
fi

# Αυξημένα network errors;
network_errors=$(echo "$logs_24h" | grep -ciE "Network.Mux.*Error|ConnectionAttemptFailed" || true)
if [[ ${network_errors:-0} -gt 100 ]]; then
  warn "${network_errors} network errors (24h) — πιθανή αστάθεια"
fi

# ────────── 12. Topology Validation ──────────
section "12. Topology Validation"

topology_json=$(timeout 5 docker exec "$CONTAINER" cat "${CONTAINER_TOPOLOGY_PATH}" 2>/dev/null)

if [[ -n "$topology_json" ]]; then
  topology_peers=$(echo "$topology_json" | jq -r '
    [.. | objects | select(.address) | .address] | unique | .[]
  ' 2>/dev/null)

  topology_count=$(echo "$topology_peers" | grep -c . || true)
  if [[ ${topology_count:-0} -gt 0 ]]; then
    ok "Topology έχει ${topology_count} configured peer hosts"
  else
    warn "Καμία peer entry στο topology"
  fi

  # P2P-aware: relay πρέπει να έχει useLedgerAfterSlot ≥ 0 (αντίθετα από BP)
  use_ledger_legacy=$(echo "$topology_json" | jq -r '.useLedgerAfterSlot // "missing"')
  use_ledger_p2p=$(echo "$topology_json" | jq -r '.useLedgerPeers.useLedgerAfterSlot // "missing"')

  if [[ "$use_ledger_p2p" =~ ^[0-9]+$ ]] && [[ "$use_ledger_p2p" -ge 0 ]]; then
    ok "useLedgerPeers ενεργό (slot ${use_ledger_p2p}) — relay κάνει peer discovery"
  elif [[ "$use_ledger_legacy" =~ ^[0-9]+$ ]] && [[ "$use_ledger_legacy" -ge 0 ]]; then
    ok "useLedgerAfterSlot ενεργό (slot ${use_ledger_legacy})"
  elif [[ "$use_ledger_legacy" == "-1" ]] || [[ "$use_ledger_p2p" == "-1" ]]; then
    warn "useLedgerAfterSlot=-1 σε relay — δεν θα κάνει peer discovery (όπως BP)"
    hint "Φυσιολογικό αν είσαι private relay, αλλιώς ενεργοποίησέ το"
  else
    warn "useLedgerAfterSlot ΟΧΙ ορισμένο — relay μπορεί να έχει περιορισμένα peers"
  fi

  # Public roots count
  public_roots=$(echo "$topology_json" | jq -r '
    [.publicRoots[]?.accessPoints[]?] | length
  ' 2>/dev/null)
  if [[ -n "$public_roots" ]] && [[ ${public_roots:-0} -gt 0 ]]; then
    ok "Public roots configured: ${public_roots}"
  fi

  # Local roots (το BP σου είναι εδώ)
  local_roots=$(echo "$topology_json" | jq -r '
    [.localRoots[]?.accessPoints[]?] | length
  ' 2>/dev/null)
  if [[ -n "$local_roots" ]] && [[ ${local_roots:-0} -gt 0 ]]; then
    ok "Local roots configured: ${local_roots} (πιθανώς το BP σου)"
  else
    warn "Καμία local root — το BP δεν θα συνδεθεί ως trusted peer"
  fi
else
  warn "Δεν μπόρεσα να διαβάσω το topology"
fi

# ─────────────────── Σύνοψη ───────────────────
if [[ "$OUTPUT_FORMAT" == "text" ]]; then
  echo
  echo -e "${B}═══════════════════════════════════════════════${N}"
  echo -e "${B} Αποτελέσματα${N}"
  echo -e "${B}═══════════════════════════════════════════════${N}"
  echo -e "  ${G}✓ Passed:${N}   ${PASS}"
  echo -e "  ${Y}⚠ Warnings:${N} ${WARN}"
  echo -e "  ${R}✗ Failed:${N}   ${FAIL}"
  echo

  if [[ $FAIL -eq 0 ]] && [[ $WARN -le 2 ]]; then
    echo -e "${G}${B} ✓ HEALTHY${N} — Relay σερβίρει σωστά την αλυσίδα.\n"
    EXIT_CODE=0
  elif [[ $FAIL -eq 0 ]]; then
    echo -e "${Y}${B} ⚠ HEALTHY με προσοχή${N} — Έλεγξε τα warnings.\n"
    EXIT_CODE=0
  else
    echo -e "${R}${B} ✗ UNHEALTHY${N} — ${FAIL} προβλήματα.\n"
    EXIT_CODE=1
  fi
fi

# ─────────────────── JSON Output ───────────────────
if [[ "$OUTPUT_FORMAT" == "json" ]]; then
  healthy=$(if [[ $FAIL -eq 0 ]]; then echo true; else echo false; fi)

  warn_json=$(printf '%s\n' "${WARNINGS[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]')
  fail_json=$(printf '%s\n' "${FAILURES[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]')

  jq -n \
    --argjson healthy "$healthy" \
    --arg container "$CONTAINER" \
    --argjson pass "$PASS" \
    --argjson warn "$WARN" \
    --argjson fail "$FAIL" \
    --argjson epoch "${epoch:-0}" \
    --argjson slot "${slot:-0}" \
    --argjson tip_lag "${tip_lag:-0}" \
    --arg sync_progress "${sync_progress:-0}" \
    --argjson inbound "${inb:-0}" \
    --argjson outbound "${outb:-0}" \
    --argjson duplex "${duplex:-0}" \
    --argjson hot "${hot:-0}" \
    --argjson warm "${warm:-0}" \
    --argjson cold "${cold:-0}" \
    --argjson active "${active:-0}" \
    --argjson served_headers "${served_h:-0}" \
    --argjson served_blocks "${served_b:-0}" \
    --arg block_delay "${blockdelay:-0}" \
    --arg cdf_one "${cdf_one:-0}" \
    --arg cdf_three "${cdf_three:-0}" \
    --arg cdf_five "${cdf_five:-0}" \
    --argjson late_blocks "${late:-0}" \
    --argjson db_size_bytes "${db_size_bytes:-0}" \
    --arg public_ip "${public_ip:-}" \
    --argjson warnings "$warn_json" \
    --argjson failures "$fail_json" \
    '{
      timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      container: $container,
      healthy: $healthy,
      summary: {pass: $pass, warn: $warn, fail: $fail},
      chain: {
        epoch: $epoch,
        slot: $slot,
        tip_lag_sec: $tip_lag,
        sync_progress: $sync_progress
      },
      peers: {
        inbound: $inbound,
        outbound: $outbound,
        duplex: $duplex,
        hot: $hot,
        warm: $warm,
        cold: $cold,
        active: $active
      },
      propagation: {
        served_headers: $served_headers,
        served_blocks: $served_blocks,
        block_delay_sec: ($block_delay | tonumber),
        diffusion_cdf: {
          under_1s: ($cdf_one | tonumber),
          under_3s: ($cdf_three | tonumber),
          under_5s: ($cdf_five | tonumber)
        },
        late_blocks: $late_blocks
      },
      db_size_bytes: $db_size_bytes,
      public_ip: $public_ip,
      warnings: $warnings,
      failures: $failures
    }'

  EXIT_CODE=$(if [[ $FAIL -eq 0 ]]; then echo 0; else echo 1; fi)
fi

# ─────────────────── Telegram Alert ───────────────────
should_alert=0
if [[ $FAIL -gt 0 ]] && \
   [[ "$ENABLE_TELEGRAM" != "no" ]] && \
   [[ -n "$TELEGRAM_BOT_TOKEN" ]] && \
   [[ -n "$TELEGRAM_CHAT_ID" ]]; then
  should_alert=1
fi

if [[ $should_alert -eq 1 ]]; then
  failure_list=$(printf '• %s\n' "${FAILURES[@]}")
  msg="🚨 *${CONTAINER} UNHEALTHY*
Failures: ${FAIL} | Warnings: ${WARN}
Epoch: ${epoch} | Tip lag: ${tip_lag}s
Inbound: ${inb} | Outbound: ${outb} | Hot: ${hot}

*Problems:*
${failure_list}"

  timeout 10 curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${msg}" \
    --data-urlencode "parse_mode=Markdown" \
    >/dev/null 2>&1 || true
fi

exit ${EXIT_CODE:-0}

