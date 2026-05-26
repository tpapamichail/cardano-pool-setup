#!/usr/bin/env bash
# ============================================================
# bp-preflight.sh v2 — Επαλήθευση ετοιμότητας Cardano Block Producer
#
# Σημαντικές βελτιώσεις vs v1:
#   • docker exec για read-only queries (γρηγορότερο, λιγότερος container startup overhead)
#   • timeouts σε ΟΛΑ τα blocking docker/network calls
#   • single docker-logs read στο Section 5 (αντί για πολλαπλά passes)
#   • parallel relay reachability checks
#   • realistic tip-lag thresholds (60s/180s αντί 30s/120s)
#   • νέα: pool saturation, mempool size, GC pauses, send-side propagation
#   • --fast (skip 30s wait), --json (machine-readable), --no-telegram flags
#   • optional Telegram alert σε αποτυχία
#
# Exit codes: 0 = ready, 1 = not ready, 2 = bad args
# ============================================================

set -uo pipefail

# ─── CLI Arguments ──────────────────────────────────────────
SKIP_WAIT=0
OUTPUT_FORMAT=text
ENABLE_TELEGRAM=auto

show_help() {
  cat <<EOF
bp-preflight.sh v2 — Cardano BP preflight check

Usage: $0 [OPTIONS]

Options:
  -f, --fast            Skip το 30s wait για chain progress check
      --json            Output αποτελεσμάτων σε JSON (για monitoring)
      --no-telegram     Μην στείλεις Telegram alert ακόμα κι αν υπάρχει token
  -h, --help            Εμφάνιση αυτού του help

Environment:
  TELEGRAM_BOT_TOKEN    Token (αν δεν τεθεί, alerts απενεργοποιημένα)
  TELEGRAM_CHAT_ID      Chat ID
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--fast)        SKIP_WAIT=1; shift ;;
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

: "${POOL_NAME:?POOL_NAME required (config.env)}"
: "${CARDANO_HOME:?CARDANO_HOME required}"
: "${CARDANO_NETWORK:=mainnet}"
: "${CARDANO_IMAGE:=ghcr.io/blinklabs-io/cardano-node:latest}"
: "${RELAY_HOSTS:?RELAY_HOSTS required}"
: "${RELAY_PORT:=6000}"

POOL_DIR="${POOL_DIR:-${CARDANO_HOME}/priv/pool/${POOL_NAME}}"
BP_KEYS_DIR="${BP_KEYS_DIR:-${CARDANO_HOME}/bp-keys}"
IPC_DIR="${CARDANO_IPC_DIR:-${CARDANO_HOME}/ipc}"
CONFIG_DIR="${CARDANO_CONFIG_DIR:-${CARDANO_HOME}/config/${CARDANO_NETWORK}}"

CONTAINER_TOPOLOGY_PATH="/opt/cardano/config/${CARDANO_NETWORK}/topology.json"
CONTAINER_METRICS_URL="http://localhost:12798/metrics"

# Build EXPECTED_RELAYS array από RELAY_HOSTS (comma-separated)
IFS=',' read -ra EXPECTED_RELAYS <<< "$RELAY_HOSTS"
for i in "${!EXPECTED_RELAYS[@]}"; do
  EXPECTED_RELAYS[$i]=$(echo "${EXPECTED_RELAYS[$i]}" | xargs)
done

# Mainnet Shelley genesis
SHELLEY_START_UNIX=1596059091
BYRON_END_SLOT=4492800

# Όρια (βελτιωμένα με βάση Cardano density 0.05)
TIP_LAG_OK=60      # P(gap > 60s) ≈ 4.6%
TIP_LAG_WARN=180   # P(gap > 180s) ≈ 0.01%
CHAIN_PROGRESS_WAIT=30

# Cardano protocol constants
CARDANO_TOTAL_SUPPLY_ADA=45000000000

# Telegram (env vars)
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

# ─── Docker CLI Wrappers ────────────────────────────────────
# Read-only queries: γρήγορα μέσω του running producer container
CLI_READ() {
  timeout 30 docker exec \
    -e CARDANO_NODE_SOCKET_PATH=/ipc/node.socket \
    producer cardano-cli "$@" 2>/dev/null
}

# Queries που χρειάζονται keys: αργά λόγω container startup
CLI_KEYS() {
  timeout 60 docker run --rm \
    -v "${IPC_DIR}:/ipc" \
    -v "${BP_KEYS_DIR}:/keys:ro" \
    -v "${POOL_DIR}:/pool:ro" \
    -v "${CONFIG_DIR}:/config:ro" \
    -e CARDANO_NODE_SOCKET_PATH=/ipc/node.socket \
    ${CARDANO_IMAGE} cli "$@" 2>/dev/null
}

QUERY_TIP() {
  timeout 15 docker exec producer sh -c \
    "CARDANO_NODE_SOCKET_PATH=/ipc/node.socket cardano-cli query tip --${CARDANO_NETWORK}" 2>/dev/null
}

# ─── Pre-flight: pool id ────────────────────────────────────
if [[ ! -f "${POOL_DIR}/pool.id" ]]; then
  echo -e "${R}✗ Δεν βρέθηκε ${POOL_DIR}/pool.id${N}" >&2
  exit 1
fi
POOL_ID_HEX=$(tr -d '[:space:]' < "${POOL_DIR}/pool.id")

# ─── Header ─────────────────────────────────────────────────
if [[ "$OUTPUT_FORMAT" == "text" ]]; then
  echo -e "${B}╔══════════════════════════════════════════════════════════════════╗${N}"
  echo -e "${B}║  BP Preflight Check — ${POOL_NAME}${N}"
  echo -e "${B}║  $(date '+%Y-%m-%d %H:%M:%S %Z')${N}"
  echo -e "${B}╚══════════════════════════════════════════════════════════════════╝${N}"
fi

# Global vars που θα γεμίσουν τα sections
tip_lag=0; remaining_kes=0; epoch=0; slot=0
sat_pct=0; active_peers=0
next_leader_slot=""; next_leader_eta=""

# ────────── 1. Container & Chain Progress ──────────
section "1. Container & Chain Progress"

if ! docker ps --format '{{.Names}}' | grep -q '^producer$'; then
  err "Producer container δεν τρέχει — αδύνατο να συνεχίσουμε"
  exit 1
fi
ok "Producer container running"

tip=$(QUERY_TIP)
if [[ -z "$tip" ]]; then
  err "cardano-cli query tip απέτυχε ή timeout"
  tip='{}'
fi

sync=$(echo "$tip" | jq -r '.syncProgress // "0"')
slot=$(echo "$tip" | jq -r '.slot // 0')
epoch=$(echo "$tip" | jq -r '.epoch // 0')
hash1=$(echo "$tip" | jq -r '.hash // ""')
block=$(echo "$tip" | jq -r '.block // 0')

if [[ "$sync" == "100.00" ]]; then
  ok "Synced 100% — epoch ${epoch}, slot ${slot}, block ${block}"
else
  err "ΟΧΙ synced: ${sync}% — δεν θα παραχθεί block μέχρι να συγχρονιστεί"
fi

# Chain tip lag — το slotNum προχωράει μόνο σε νέο block, οπότε μετράμε
# πόσο πίσω είμαστε από το expected current slot.
wall_now=$(date +%s)
expected_slot=$((wall_now - SHELLEY_START_UNIX + BYRON_END_SLOT))
tip_lag=$((expected_slot - slot))

if [[ $tip_lag -lt $TIP_LAG_OK ]]; then
  ok "Chain tip lag: ${tip_lag}s (φυσιολογικό· P(gap>60s)≈4.6%)"
elif [[ $tip_lag -lt $TIP_LAG_WARN ]]; then
  warn "Chain tip lag: ${tip_lag}s — οριακό, παρακολούθησε αν επιμένει"
else
  err "Chain tip lag: ${tip_lag}s — node δεν δέχεται blocks έγκαιρα"
fi

# Chain progress check (skippable με --fast)
if [[ $SKIP_WAIT -eq 1 ]]; then
  hint "Chain progress check skipped (--fast)"
else
  hint "Περιμένουμε ${CHAIN_PROGRESS_WAIT}s για νέο block..."
  sleep $CHAIN_PROGRESS_WAIT
  tip2=$(QUERY_TIP)
  hash2=$(echo "$tip2" | jq -r '.hash // ""')
  slot_new=$(echo "$tip2" | jq -r '.slot // 0')
  block_new=$(echo "$tip2" | jq -r '.block // 0')

  if [[ "$hash1" != "$hash2" && -n "$hash2" ]]; then
    blocks_received=$((block_new - block))
    ok "Chain progresses (${blocks_received} νέα blocks σε ${CHAIN_PROGRESS_WAIT}s)"
    slot=$slot_new
  else
    warn "Κανένα νέο block σε ${CHAIN_PROGRESS_WAIT}s — sparse period ή propagation issue"
  fi
fi

# Update current_slot για downstream sections
current_slot=${slot_new:-$slot}

# ────────── 2. Time Sync (NTP) ──────────
section "2. Time Sync (NTP)"

if command -v chronyc >/dev/null 2>&1 && systemctl is-active --quiet chronyd 2>/dev/null; then
  tracking=$(timeout 5 chronyc tracking 2>/dev/null)
  offset_sec=$(echo "$tracking" | awk '/Last offset/ {print $4}')
  stratum=$(echo "$tracking" | awk '/Stratum/ {print $3}')
  leap=$(echo "$tracking" | awk -F': ' '/Leap status/ {print $2}' | xargs)

  abs_ms=$(awk -v s="${offset_sec:-0}" \
    'BEGIN { v = s*1000; if (v < 0) v = -v; printf "%d", v }')

  if [[ ${abs_ms:-9999} -lt 50 ]]; then
    ok "NTP offset ${offset_sec}s (stratum ${stratum}, ${leap}) — εξαιρετικό"
  elif [[ ${abs_ms:-9999} -lt 200 ]]; then
    warn "NTP offset ${offset_sec}s — οριακό, στόχευσε <50ms"
  else
    err "NTP offset ${offset_sec}s — ΘΑ ΧΑΣΕΙΣ blocks. Fix chrony ΑΜΕΣΑ."
  fi

  if [[ "$leap" != "Normal" ]]; then
    warn "chrony leap status: ${leap}"
  fi
elif command -v ntpq >/dev/null 2>&1 && systemctl is-active --quiet ntpd 2>/dev/null; then
  offset=$(timeout 5 ntpq -pn 2>/dev/null | awk '/^\*/ {print $9}' | head -1)
  if [[ -n "$offset" ]]; then
    abs_ms=$(awk -v s="$offset" 'BEGIN { v = s; if (v < 0) v = -v; printf "%d", v }')
    if [[ ${abs_ms:-9999} -lt 50 ]]; then
      ok "ntpd offset: ${offset}ms"
    else
      warn "ntpd offset: ${offset}ms — εξέτασε chrony αντί ntpd"
    fi
  fi
else
  err "ΟΥΤΕ chrony ΟΥΤΕ ntpd ενεργό — apt install chrony τώρα"
fi

# ────────── 3. System Resources ──────────
section "3. System Resources"

disk_used=$(df / | awk 'NR==2 {gsub("%",""); print $5}')
if [[ $disk_used -lt 80 ]]; then
  ok "Disk usage / : ${disk_used}%"
elif [[ $disk_used -lt 90 ]]; then
  warn "Disk usage / : ${disk_used}% — καθάρισε σύντομα"
else
  err "Disk ${disk_used}% — ΚΡΙΣΙΜΟ, node θα κρασάρει"
fi

data_used=$(timeout 5 docker exec producer df /data/db 2>/dev/null | awk 'NR==2 {gsub("%",""); print $5}')
if [[ -n "$data_used" ]]; then
  if [[ $data_used -lt 80 ]]; then
    ok "Cardano data disk: ${data_used}%"
  else
    warn "Cardano data disk: ${data_used}%"
  fi
fi

# Single docker stats call για να πάρουμε CPU+MEM+IO μαζί
stats=$(timeout 5 docker stats producer --no-stream --format '{{.MemPerc}}|{{.CPUPerc}}|{{.BlockIO}}' 2>/dev/null)
mem_pct=$(echo "$stats" | cut -d'|' -f1 | tr -d '%')
cpu_pct=$(echo "$stats" | cut -d'|' -f2 | tr -d '%')
block_io=$(echo "$stats" | cut -d'|' -f3)

mem_int=${mem_pct%.*}
if [[ ${mem_int:-0} -lt 75 ]]; then
  ok "Container memory: ${mem_pct}%"
elif [[ ${mem_int:-0} -lt 90 ]]; then
  warn "Container memory: ${mem_pct}% — κοντά στο όριο"
else
  err "Container memory: ${mem_pct}% — OOM risk"
fi

cpu_int=${cpu_pct%.*}
if [[ ${cpu_int:-0} -lt 200 ]]; then  # 200% = 2 cores fully used (OK σε multi-core)
  ok "Container CPU: ${cpu_pct}%"
else
  warn "Container CPU: ${cpu_pct}% — υψηλό φορτίο"
fi

load1=$(awk '{print $1}' /proc/loadavg)
cores=$(nproc)
load_pct=$(awk -v l="$load1" -v c="$cores" 'BEGIN {printf "%d", (l/c)*100}')
if [[ $load_pct -lt 80 ]]; then
  ok "Host load: ${load1} (${load_pct}% of ${cores} cores)"
else
  warn "Host load: ${load1} (${load_pct}% of ${cores} cores) — υψηλό"
fi

# ────────── 4. VRF Key Permissions ──────────
section "4. VRF Key Permissions"

if [[ -f "${POOL_DIR}/vrf.skey" ]]; then
  vrf_perms=$(stat -c '%a' "${POOL_DIR}/vrf.skey")
  if [[ "$vrf_perms" == "400" || "$vrf_perms" == "600" ]]; then
    ok "VRF key permissions: ${vrf_perms}"
  else
    err "VRF key permissions ${vrf_perms} — node θα αρνηθεί restart"
    hint "Fix: chmod 400 ${POOL_DIR}/vrf.skey"
  fi
  vrf_owner=$(stat -c '%U' "${POOL_DIR}/vrf.skey")
  if [[ "$vrf_owner" == "UNKNOWN" ]]; then
    vrf_uid=$(stat -c '%u' "${POOL_DIR}/vrf.skey")
    ok "VRF key owner: UID ${vrf_uid} (no /etc/passwd entry — φυσιολογικό σε containers)"
  else
    ok "VRF key owner: ${vrf_owner}"
  fi
else
  err "Δεν βρέθηκε ${POOL_DIR}/vrf.skey"
fi

if [[ -f "${BP_KEYS_DIR}/node.cert" ]]; then
  cert_perms=$(stat -c '%a' "${BP_KEYS_DIR}/node.cert")
  ok "Op cert exists (perms ${cert_perms})"
else
  err "Δεν βρέθηκε ${BP_KEYS_DIR}/node.cert"
fi

# ────────── 5. Forge Loop & Critical Errors ──────────
section "5. Forge Loop"

# Single logs read — re-use σε όλους τους ελέγχους
logs_recent=$(timeout 10 docker logs --tail 200 producer 2>&1 || true)
logs_24h=$(timeout 30 docker logs --since 24h producer 2>&1 || true)
logs_7d=$(timeout 30 docker logs --since 7d producer 2>&1 || true)

# Forge loop heartbeat
recent_forge=$(echo "$logs_recent" | grep -c "Forge.Loop.StartLeadershipCheck" || true)
if [[ ${recent_forge:-0} -gt 10 ]]; then
  ok "Forge loop ενεργό (${recent_forge} leadership checks/200 lines)"
else
  err "Δεν εκτελείται forge loop επαρκώς — node ίσως δεν είναι σε BP mode"
fi

# Critical patterns (σιωπηλές αποτυχίες)
critical_regex='TraceNoLedgerView|TraceForgeStateUpdateError|TraceNodeCannotForge|KESKeyAlreadyPoisoned|TraceForgedInvalidBlock'
crit_count=$(echo "$logs_24h" | grep -cE "$critical_regex" || true)
if [[ ${crit_count:-0} -gt 0 ]]; then
  err "${crit_count}x critical forge errors τις τελευταίες 24h — ΣΙΩΠΗΛΗ ΑΠΟΤΥΧΙΑ"
  echo "$logs_24h" | grep -E "$critical_regex" | tail -3 | sed 's/^/    /'
else
  ok "Καμία κρίσιμη forge αποτυχία στις τελευταίες 24h"
fi

# Generic forge errors — exclude τα critical που ήδη μέτρησα
generic_errors=$(echo "$logs_24h" | grep -iE "Forge.*Error|Forge.*Failed" \
  | grep -cvE "$critical_regex" || true)
if [[ ${generic_errors:-0} -eq 0 ]]; then
  ok "Καμία γενική αποτυχία στο forging (24h)"
else
  warn "${generic_errors} γενικά forge errors (24h)"
fi

# Last adopted block (max 7 ημέρες πίσω)
last_forged=$(echo "$logs_7d" | grep -E "TraceAdoptedBlock|AdoptedBlock" | tail -1 | awk '{print $1, $2}')
if [[ -n "$last_forged" ]]; then
  ok "Τελευταίο adopted block: ${last_forged}"
else
  warn "Κανένα TraceAdoptedBlock τις τελευταίες 7 ημέρες (φυσιολογικό για μικρά pools)"
fi

# GC pauses — μπορούν να σου κάψουν slot
gc_count=$(echo "$logs_24h" | grep -cE "GcPause|gcMajorTime" || true)
if [[ ${gc_count:-0} -lt 100 ]]; then
  ok "GC events (24h): ${gc_count} — φυσιολογικό"
elif [[ ${gc_count:-0} -lt 500 ]]; then
  warn "GC events (24h): ${gc_count} — αυξημένα, παρακολούθησε memory"
else
  err "GC events (24h): ${gc_count} — memory pressure, πιθανές απώλειες slots"
fi

# ────────── 6. KES & Op Cert ──────────
section "6. KES & Op Cert"

kes=$(CLI_KEYS query kes-period-info --${CARDANO_NETWORK} --op-cert-file /keys/node.cert 2>/dev/null | sed -n '/^{/,/^}/p')

if [[ -n "$kes" ]]; then
  cur=$(echo "$kes" | jq -r '.qKesCurrentKesPeriod // 0')
  start=$(echo "$kes" | jq -r '.qKesStartKesInterval // 0')
  end=$(echo "$kes" | jq -r '.qKesEndKesInterval // 0')
  remaining_kes=$((end - cur))
  on_disk=$(echo "$kes" | jq -r '.qKesOnDiskOperationalCertificateNumber // 0')
  on_chain=$(echo "$kes" | jq -r '.qKesNodeStateOperationalCertificateNumber // 0')

  if [[ $cur -ge $start ]] && [[ $cur -le $end ]]; then
    ok "KES period ${cur} εντός valid interval [${start}, ${end}]"
  else
    err "KES period ${cur} ΕΚΤΟΣ [${start}, ${end}] — issue new op cert"
  fi

  # 1 period ≈ 36 hours
  hours_remaining=$((remaining_kes * 36))
  days_remaining=$((hours_remaining / 24))

  if [[ $remaining_kes -le 0 ]]; then
    err "KES EXPIRED"
  elif [[ $remaining_kes -lt 10 ]]; then
    err "KES expires σε ~${days_remaining}d ${hours_remaining}h (${remaining_kes} periods) — issue new op cert ΤΩΡΑ"
  elif [[ $remaining_kes -lt 30 ]]; then
    warn "KES expires σε ~${days_remaining}d (${remaining_kes} periods) — προγραμμάτισε renewal"
  else
    ok "KES remaining: ${remaining_kes} periods (~${days_remaining}d)"
  fi

  diff=$((on_disk - on_chain))
  if [[ $diff -eq 0 ]]; then
    ok "Op cert sync ✓ (counter ${on_disk} = on-chain)"
  elif [[ $diff -eq 1 ]]; then
    warn "Op cert ahead by 1 (on-disk=${on_disk}, on-chain=${on_chain}) — θα συγχρονιστεί με το πρώτο block"
  else
    err "Op cert mismatch: on-disk=${on_disk}, on-chain=${on_chain} — διαφορά ${diff}"
  fi
else
  err "Δεν μπορώ να διαβάσω KES info"
fi

# ────────── 7. Forging Enabled (metrics) ──────────
section "7. Forging Enabled (metrics)"

metrics=$(timeout 10 docker exec producer curl -s "${CONTAINER_METRICS_URL}" 2>/dev/null || true)

# Strict awk matching με trailing space για να μην πιάνει similar metric names
forging=$(echo "$metrics" | awk '/^cardano_node_metrics_forging_enabled_int / {print $2}')
if [[ "${forging:-0}" == "1" ]]; then
  ok "forging_enabled = 1 (BP πλήρως ενεργό)"
else
  err "forging_enabled != 1 — keys ίσως δεν φορτώθηκαν"
fi

kes_metric=$(echo "$metrics" | awk '/^cardano_node_metrics_currentKESPeriod_int / {print $2}')
if [[ -n "$kes_metric" ]]; then
  ok "KES key loaded στο runtime (period ${kes_metric})"
fi

# Mempool size — early indicator για overload
mem_txs=$(echo "$metrics" | awk '/^cardano_node_metrics_txsInMempool_int / {print $2}')
mem_bytes=$(echo "$metrics" | awk '/^cardano_node_metrics_mempoolBytes_int / {print $2}')
if [[ -n "$mem_txs" ]]; then
  mem_kb=$(( ${mem_bytes:-0} / 1024 ))
  ok "Mempool: ${mem_txs} txs / ${mem_kb}KB"
fi

# ── Send-side propagation ──
# P2P-first: στις νέες εκδόσεις λέγονται *_counter (όχι *_count_int)
served_h=$(echo "$metrics" | awk '/^cardano_node_metrics_served_header_counter / {print $2}')
served_b=$(echo "$metrics" | awk '/^cardano_node_metrics_served_block_counter / {print $2}')
served_chainsync_h=$(echo "$metrics" | awk '/^cardano_node_metrics_ChainSync_HeadersServed_counter / {print $2}')

# Legacy fallback
[[ -z "$served_h" ]] && served_h=$(echo "$metrics" | awk '/^cardano_node_metrics_served_header_count_int / {print $2}')
[[ -z "$served_b" ]] && served_b=$(echo "$metrics" | awk '/^cardano_node_metrics_served_block_count_int / {print $2}')

served_h=${served_h:-0}; served_b=${served_b:-0}; served_chainsync_h=${served_chainsync_h:-0}

# Στο BP, το serving μπορεί να είναι χαμηλότερο γιατί έχει μόνο 3-4 relays να σερβίρει
if [[ $served_h -gt 0 ]] && [[ $served_b -gt 0 ]]; then
  ok "Send-side propagation: ${served_h} headers / ${served_b} blocks served"
  [[ $served_chainsync_h -gt 0 ]] && hint "ChainSync headers served: ${served_chainsync_h}"
elif [[ $served_h -gt 0 ]] || [[ $served_chainsync_h -gt 0 ]]; then
  warn "Serving headers (${served_h}/${served_chainsync_h}) αλλά μηδέν blocks — relays δεν τραβάνε blocks σου"
else
  err "Served headers=${served_h}, blocks=${served_b} — relays δεν fetch-άρουν από εσένα"
fi

# ── Block fetch quality (πόσο γρήγορα κατεβάζει blocks από relays) ──
# Κρίσιμο για BP: αν είναι αργό, μπορεί να παράξεις block πάνω σε stale tip
blockdelay=$(echo "$metrics" | awk '/^cardano_node_metrics_blockfetchclient_blockdelay_real / {print $2}')
cdf_one=$(echo "$metrics" | awk '/^cardano_node_metrics_blockfetchclient_blockdelay_cdfOne_real / {print $2}')
cdf_three=$(echo "$metrics" | awk '/^cardano_node_metrics_blockfetchclient_blockdelay_cdfThree_real / {print $2}')
cdf_five=$(echo "$metrics" | awk '/^cardano_node_metrics_blockfetchclient_blockdelay_cdfFive_real / {print $2}')
late=$(echo "$metrics" | awk '/^cardano_node_metrics_blockfetchclient_lateblocks_counter / {print $2}')

if [[ -n "$blockdelay" ]]; then
  delay_ms=$(awk -v d="$blockdelay" 'BEGIN {printf "%d", d*1000}')
  if [[ $delay_ms -lt 500 ]]; then
    ok "Block fetch delay: ${delay_ms}ms (εξαιρετικό)"
  elif [[ $delay_ms -lt 1000 ]]; then
    ok "Block fetch delay: ${delay_ms}ms"
  elif [[ $delay_ms -lt 3000 ]]; then
    warn "Block fetch delay: ${delay_ms}ms — αργό, κίνδυνος stale tip"
  else
    err "Block fetch delay: ${delay_ms}ms — θα παράγεις blocks σε λάθος tip"
  fi
fi

if [[ -n "$cdf_one" ]]; then
  cdf_one_pct=$(awk -v c="$cdf_one" 'BEGIN {printf "%.1f", c*100}')
  cdf_three_pct=$(awk -v c="${cdf_three:-0}" 'BEGIN {printf "%.1f", c*100}')
  cdf_five_pct=$(awk -v c="${cdf_five:-0}" 'BEGIN {printf "%.1f", c*100}')
  cdf_one_int=$(awk -v c="$cdf_one" 'BEGIN {printf "%d", c*100}')

  if [[ $cdf_one_int -ge 95 ]]; then
    ok "Block diffusion: ${cdf_one_pct}% <1s, ${cdf_three_pct}% <3s, ${cdf_five_pct}% <5s"
  elif [[ $cdf_one_int -ge 85 ]]; then
    warn "Block diffusion: μόνο ${cdf_one_pct}% blocks φτάνουν <1s (στόχος ≥95%)"
  else
    err "Block diffusion αργή: ${cdf_one_pct}% <1s — height battles σε κίνδυνο"
  fi
fi

if [[ -n "$late" ]]; then
  if [[ ${late:-0} -lt 10 ]]; then
    ok "Late blocks: ${late} (αμελητέο)"
  elif [[ ${late:-0} -lt 100 ]]; then
    warn "Late blocks: ${late}"
  else
    err "Late blocks: ${late} — σοβαρό propagation issue"
  fi
fi

# ────────── 8. Leadership Schedule ──────────
section "8. Leadership Schedule"
hint "Παίρνει 5-10s..."

schedule_tmp=$(mktemp)
CLI_KEYS query leadership-schedule \
  --${CARDANO_NETWORK} \
  --genesis /config/shelley-genesis.json \
  --stake-pool-id "$POOL_ID_HEX" \
  --vrf-signing-key-file /pool/vrf.skey \
  --current > "$schedule_tmp" 2>&1
schedule=$(cat "$schedule_tmp")

parsed=0
slot_count=0
all_slots=""

if echo "$schedule" | head -c 100 | grep -qE '^[[:space:]]*\['; then
  json_count=$(echo "$schedule" | jq 'length' 2>/dev/null)
  if [[ "$json_count" =~ ^[0-9]+$ ]]; then
    parsed=1
    slot_count=$json_count
    if [[ $json_count -gt 0 ]]; then
      all_slots=$(echo "$schedule" | jq -r '.[] | (.slotNumber // .slot // .slotNo) // empty' 2>/dev/null | sort -nu)
    fi
  fi
fi

if [[ $parsed -eq 0 ]]; then
  table_count=$(echo "$schedule" | grep -cE '^[[:space:]]*[0-9]{9,}[[:space:]]')
  has_header=$(echo "$schedule" | grep -cE 'SlotNo|UTC Time' || true)
  if [[ $table_count -gt 0 ]] || [[ $has_header -gt 0 ]]; then
    parsed=1
    slot_count=$table_count
    all_slots=$(echo "$schedule" | grep -oE '[0-9]{9,}' | sort -nu)
  fi
fi

if [[ $parsed -eq 1 ]] && [[ $slot_count -gt 0 ]]; then
  next_slot=$(echo "$all_slots" | awk -v cur="$current_slot" '$1 > cur {print; exit}')
  first_slot=$(echo "$all_slots" | head -1)

  ok "Leadership schedule OK — ${slot_count} slots για epoch ${epoch}"

  if [[ -n "$next_slot" ]]; then
    next_leader_slot=$next_slot
    seconds_until=$((next_slot - current_slot))
    next_leader_eta=$seconds_until
    if [[ $seconds_until -lt 3600 ]]; then
      warn "ΕΠΟΜΕΝΟ block σε ${seconds_until}s ($((seconds_until/60))m) — slot ${next_slot}"
    elif [[ $seconds_until -lt 86400 ]]; then
      ok "Επόμενο block σε $((seconds_until/3600))h $((seconds_until%3600/60))m — slot ${next_slot}"
    else
      ok "Επόμενο block σε $((seconds_until/86400))d $((seconds_until%86400/3600))h — slot ${next_slot}"
    fi
  elif [[ -n "$first_slot" ]]; then
    past_count=$(echo "$all_slots" | awk -v cur="$current_slot" '$1 <= cur' | wc -l)
    ok "Όλα τα ${past_count} scheduled slots έχουν περάσει σε αυτό το epoch"
  fi

elif [[ $parsed -eq 1 ]] && [[ $slot_count -eq 0 ]]; then
  warn "0 scheduled slots για epoch ${epoch} — δεν θα παίξεις block αυτό το epoch"
  hint "Φυσιολογικό για pools με χαμηλό active stake"

elif echo "$schedule" | grep -qiE 'error|fail|exception|cannot|usage:|invalid'; then
  err "Leadership schedule απέτυχε. Πρώτες 10 γραμμές:"
  echo "$schedule" | head -10 | sed 's/^/    /'
  echo "$schedule" | grep -qi "genesis" && hint "→ Έλεγξε path του genesis"
  echo "$schedule" | grep -qi "vrf"     && hint "→ Έλεγξε VRF key"
  echo "$schedule" | grep -qi "usage"   && hint "→ Πιθανή αλλαγή syntax σε νέα cardano-cli"
  echo "$schedule" | grep -qi "era"     && hint "→ Era mismatch — δοκίμασε --next αντί --current"
else
  debug_file="/tmp/leadership-schedule-debug-$(date +%s).txt"
  cp "$schedule_tmp" "$debug_file"
  warn "Άγνωστο output. Πρώτες 10 γραμμές:"
  echo "$schedule" | head -10 | sed 's/^/    /'
  hint "Πλήρες output: ${debug_file}"
fi

rm -f "$schedule_tmp"

# ────────── 9. Pool On-Chain ──────────
section "9. Pool On-Chain"

pool_state=$(CLI_READ query pool-state --${CARDANO_NETWORK} --stake-pool-id "$POOL_ID_HEX" 2>/dev/null)

if echo "$pool_state" | jq -e --arg pid "$POOL_ID_HEX" '.[$pid].poolParams' >/dev/null 2>&1; then
  ok "Pool registered & found στο ledger"

  retiring=$(echo "$pool_state" | jq -r --arg pid "$POOL_ID_HEX" '.[$pid].retiring')
  if [[ "$retiring" == "null" || -z "$retiring" ]]; then
    ok "Pool δεν είναι σε retiring state"
  else
    err "Pool σε RETIRING state — αποχώρηση στο epoch ${retiring}"
  fi

  future=$(echo "$pool_state" | jq -r --arg pid "$POOL_ID_HEX" '.[$pid].futurePoolParams')
  if [[ "$future" != "null" && -n "$future" ]]; then
    warn "Pending pool parameter changes (futurePoolParams)"
  fi

  pledge=$(echo "$pool_state" | jq -r --arg pid "$POOL_ID_HEX" \
    '.[$pid].poolParams.spsPledge // .[$pid].poolParams.pledge // 0')
  pledge_ada=$((pledge / 1000000))
  hint "Pledge on-chain: ${pledge_ada} ADA"

  # Stake snapshot
  stake_snap=$(CLI_READ query stake-snapshot --${CARDANO_NETWORK} --stake-pool-id "$POOL_ID_HEX" 2>/dev/null)

  if [[ -n "$stake_snap" ]]; then
    go=$(echo "$stake_snap" | jq -r --arg pid "$POOL_ID_HEX" '
      .pools[$pid].stakeGo // .pools[$pid].poolStakeGo // .poolStakeGo // 0' 2>/dev/null)
    set_=$(echo "$stake_snap" | jq -r --arg pid "$POOL_ID_HEX" '
      .pools[$pid].stakeSet // .pools[$pid].poolStakeSet // .poolStakeSet // 0' 2>/dev/null)
    mark=$(echo "$stake_snap" | jq -r --arg pid "$POOL_ID_HEX" '
      .pools[$pid].stakeMark // .pools[$pid].poolStakeMark // .poolStakeMark // 0' 2>/dev/null)

    go=${go:-0}; set_=${set_:-0}; mark=${mark:-0}
    go_ada=$((go / 1000000))
    set_ada=$((set_ / 1000000))
    mark_ada=$((mark / 1000000))

    if [[ $go -gt 0 ]]; then
      ok "Active stake (epoch ${epoch}): ${go_ada} ADA"
      hint "set (next): ${set_ada} ADA | mark: ${mark_ada} ADA"

      # Saturation check
      k_param=$(CLI_READ query protocol-parameters --${CARDANO_NETWORK} 2>/dev/null | jq -r '.stakePoolTargetNum // 500')
      sat_point=$(( CARDANO_TOTAL_SUPPLY_ADA / k_param ))
      sat_pct=$(( go_ada * 100 / sat_point ))

      if [[ $sat_pct -gt 100 ]]; then
        err "Pool OVER-SATURATED: ${sat_pct}% (πάνω από ${sat_point} ADA) — κόβει rewards"
      elif [[ $sat_pct -gt 90 ]]; then
        warn "Saturation ${sat_pct}% (από ${sat_point} ADA) — κοντά στο όριο"
      else
        ok "Saturation: ${sat_pct}% (max ${sat_point} ADA, k=${k_param})"
      fi

      # Pledge check
      if [[ $go -ge $pledge ]]; then
        ok "Pledge satisfied (active stake ≥ pledge)"
      else
        err "PLEDGE NOT MET — active stake ${go_ada} < pledge ${pledge_ada} ADA"
        hint "Δεν θα παραχθούν blocks σε αυτό το epoch"
      fi
    else
      err "ZERO active stake — δεν θα προγραμματιστούν blocks"
    fi
  fi
else
  err "Pool ΔΕΝ βρέθηκε στο ledger — registration issue"
fi

# ────────── 10. Relay Reachability (Parallel) ──────────
section "10. Relay Reachability"

relays_onchain=$(echo "$pool_state" | jq -r --arg pid "$POOL_ID_HEX" \
  '.[$pid].poolParams.spsRelays[]?."single host name" | "\(.dnsName):\(.port)"' 2>/dev/null)

if [[ -z "$relays_onchain" ]]; then
  warn "Δεν βρήκα DNS-based relays στο pool params"
fi

# Parallel reachability — write results σε temp dir
relay_tmp=$(mktemp -d)
trap "rm -rf $relay_tmp" EXIT

i=0
while IFS=: read -r host port; do
  [[ -z "$host" ]] && continue
  i=$((i+1))
  (
    ip=$(timeout 3 getent hosts "$host" 2>/dev/null | awk '{print $1; exit}')
    if [[ -z "$ip" ]]; then
      echo "DNS_FAIL|${host}|" > "${relay_tmp}/r${i}"
    elif timeout 3 bash -c "</dev/tcp/${ip}/${port}" 2>/dev/null; then
      echo "OK|${host}|${ip}:${port}" > "${relay_tmp}/r${i}"
    else
      echo "UNREACH|${host}|${ip}:${port}" > "${relay_tmp}/r${i}"
    fi
  ) &
done <<< "$relays_onchain"
wait

# Διάβασε αποτελέσματα
for result_file in "${relay_tmp}"/r*; do
  [[ -f "$result_file" ]] || continue
  IFS='|' read -r status host endpoint < "$result_file"
  case "$status" in
    OK)        ok "Relay ${host} (${endpoint}) reachable" ;;
    DNS_FAIL)  err "DNS fail: ${host} δεν resolve-άρει" ;;
    UNREACH)   err "Relay ${host} (${endpoint}) UNREACHABLE — block won't propagate" ;;
  esac
done

# ────────── 11. Block Propagation (Peers) ──────────
section "11. Block Propagation"

active_peers=""
peer_source=""

# Tier 1: P2P metrics (σωστά names με capital case + strict matching)
# Στο BP περιμένουμε λίγα peers (συνήθως μόνο οι 3-4 expected relays)
# γι' αυτό μετράμε connections, όχι hot peers
for metric_name in \
  "cardano_node_metrics_connectionManager_duplexConns_int" \
  "cardano_node_metrics_connectionManager_outboundConns_int" \
  "cardano_node_metrics_peerSelection_Hot_int" \
  "cardano_node_metrics_peerSelection_ActivePeers_int" \
  "cardano_node_metrics_inboundGovernor_hot_int"; do
  val=$(echo "$metrics" | awk -v m="$metric_name" '$1 == m {print $2; exit}')
  if [[ -n "$val" ]]; then
    active_peers=$val
    peer_source="metric ${metric_name##*_metrics_}"
    break
  fi
done

# Tier 2: Legacy non-P2P
if [[ -z "$active_peers" ]]; then
  val=$(echo "$metrics" | awk '/^cardano_node_metrics_outboundCxns_int / {print $2}')
  if [[ -n "$val" ]]; then
    active_peers=$val
    peer_source="legacy outboundCxns_int"
  fi
fi

# Tier 3: ss fallback
if [[ -z "$active_peers" ]]; then
  ss_count=$(timeout 5 docker exec producer ss -tn state established 2>/dev/null | \
    awk -v p=":${RELAY_PORT}" '$0 ~ p {c++} END {print c+0}')
  if [[ -n "$ss_count" ]]; then
    active_peers=$ss_count
    peer_source="ss count (ESTAB on :${RELAY_PORT})"
  fi
fi

# Tier 4: /proc/net/tcp fallback
if [[ -z "$active_peers" ]]; then
  hex_port=$(printf '%04X' $RELAY_PORT)
  proc_count=$(timeout 5 docker exec producer sh -c \
    "awk -v p=\"$hex_port\" '\$2~p\":\" || \$3~p\":\" {if(\$4==\"01\")c++} END{print c+0}' /proc/net/tcp" 2>/dev/null)
  if [[ -n "$proc_count" ]]; then
    active_peers=$proc_count
    peer_source="/proc/net/tcp"
  fi
fi

if [[ -z "$active_peers" ]]; then
  err "Δεν μπόρεσα να μετρήσω peers"
  active_peers=0
elif [[ "$active_peers" -gt 0 ]]; then
  ok "Active peers: ${active_peers} (πηγή: ${peer_source})"
else
  err "0 active peers (${peer_source}) — block won't propagate"
fi

# ── Detailed P2P breakdown (αν διαθέσιμο) ──
p2p_hot=$(echo "$metrics"  | awk '/^cardano_node_metrics_peerSelection_Hot_int / {print $2}')
p2p_warm=$(echo "$metrics" | awk '/^cardano_node_metrics_peerSelection_Warm_int / {print $2}')
p2p_cold=$(echo "$metrics" | awk '/^cardano_node_metrics_peerSelection_Cold_int / {print $2}')
p2p_active=$(echo "$metrics" | awk '/^cardano_node_metrics_peerSelection_ActivePeers_int / {print $2}')
local_root_active=$(echo "$metrics" | awk '/^cardano_node_metrics_peerSelection_ActiveLocalRootPeers_int / {print $2}')
duplex=$(echo "$metrics" | awk '/^cardano_node_metrics_connectionManager_duplexConns_int / {print $2}')

if [[ -n "$p2p_hot" ]]; then
  ok "P2P breakdown — hot: ${p2p_hot:-0}, warm: ${p2p_warm:-0}, cold: ${p2p_cold:-0}, active: ${p2p_active:-0}"

  # Στο BP, ο local root (relay σου) πρέπει να είναι active
  if [[ -n "$local_root_active" ]] && [[ ${local_root_active:-0} -gt 0 ]]; then
    ok "Active local root peers: ${local_root_active} (relay σου συνδεδεμένος)"
  else
    err "0 active local root peers — ο BP δεν συνδέεται με τους δικούς σου relays!"
  fi

  if [[ -n "$duplex" ]] && [[ ${duplex:-0} -gt 0 ]]; then
    ok "Duplex connections: ${duplex} (bi-directional P2P)"
  fi
fi

# Σύγκριση με expected relays
expected_count=${#EXPECTED_RELAYS[@]}
if [[ -n "$active_peers" ]] && [[ "$active_peers" -lt "$expected_count" ]]; then
  warn "Active peers (${active_peers}) < expected relays (${expected_count}) — μερικοί unreachable"
fi

# ────────── 12. BP Topology Lockdown ──────────
section "12. BP Topology Lockdown"

topology_json=$(timeout 5 docker exec producer cat "${CONTAINER_TOPOLOGY_PATH}" 2>/dev/null)

if [[ -n "$topology_json" ]]; then
  topology_peers=$(echo "$topology_json" | jq -r '
    [.. | objects | select(.address) | .address] | unique | .[]
  ' 2>/dev/null)

  unknown_peers=0
  for peer in $topology_peers; do
    found=0
    for expected in "${EXPECTED_RELAYS[@]}"; do
      if [[ "$peer" == "$expected" ]]; then
        found=1; break
      fi
    done
    if [[ $found -eq 0 ]]; then
      err "BP topology έχει unknown peer: ${peer} — πιθανή διαρροή IP"
      unknown_peers=$((unknown_peers + 1))
    fi
  done

  if [[ $unknown_peers -eq 0 ]] && [[ -n "$topology_peers" ]]; then
    ok "BP topology lockdown OK — μόνο γνωστά relays"
  fi

  configured_count=$(echo "$topology_peers" | grep -c . || true)
  if [[ ${configured_count:-0} -lt $expected_count ]]; then
    warn "Topology έχει μόνο ${configured_count}/${expected_count} expected relays — μειωμένη redundancy"
  fi

  # Check για useLedgerAfterSlot (legacy) ή useLedgerPeers (P2P)
  use_ledger_legacy=$(echo "$topology_json" | jq -r '.useLedgerAfterSlot // "missing"')
  use_ledger_p2p=$(echo "$topology_json" | jq -r '.useLedgerPeers.useLedgerAfterSlot // "missing"')

  if [[ "$use_ledger_legacy" == "-1" || "$use_ledger_legacy" == "missing" ]] && \
     [[ "$use_ledger_p2p" == "-1" || "$use_ledger_p2p" == "missing" ]]; then
    ok "Ledger peer discovery disabled — BP δεν διαρρέει IP"
  elif [[ "$use_ledger_p2p" != "missing" ]]; then
    err "useLedgerPeers.useLedgerAfterSlot=${use_ledger_p2p} — BP κάνει peer discovery (διαρροή IP)"
  else
    err "useLedgerAfterSlot=${use_ledger_legacy} — BP κάνει peer discovery (διαρροή IP)"
  fi
else
  warn "Δεν μπόρεσα να διαβάσω ${CONTAINER_TOPOLOGY_PATH}"
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
    echo -e "${G}${B} ✓ READY${N} — Ο BP θα παράξει block επιτυχώς όταν έρθει η σειρά του.\n"
    EXIT_CODE=0
  elif [[ $FAIL -eq 0 ]]; then
    echo -e "${Y}${B} ⚠ READY με προσοχή${N} — Έλεγξε τα warnings.\n"
    EXIT_CODE=0
  else
    echo -e "${R}${B} ✗ NOT READY${N} — ${FAIL} προβλήματα θα εμποδίσουν παραγωγή.\n"
    EXIT_CODE=1
  fi
fi

# ─────────────────── JSON Output ───────────────────
if [[ "$OUTPUT_FORMAT" == "json" ]]; then
  ready=$(if [[ $FAIL -eq 0 ]]; then echo true; else echo false; fi)
  
  # Convert arrays σε JSON
  warn_json=$(printf '%s\n' "${WARNINGS[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]')
  fail_json=$(printf '%s\n' "${FAILURES[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]')

  jq -n \
    --argjson ready "$ready" \
    --arg pool "$POOL_NAME" \
    --argjson pass "$PASS" \
    --argjson warn "$WARN" \
    --argjson fail "$FAIL" \
    --argjson epoch "${epoch:-0}" \
    --argjson slot "${slot:-0}" \
    --argjson tip_lag "${tip_lag:-0}" \
    --argjson kes_remaining "${remaining_kes:-0}" \
    --argjson saturation "${sat_pct:-0}" \
    --argjson active_peers "${active_peers:-0}" \
    --arg next_leader_slot "${next_leader_slot:-}" \
    --arg next_leader_eta "${next_leader_eta:-}" \
    --argjson warnings "$warn_json" \
    --argjson failures "$fail_json" \
    '{
      timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      pool: $pool,
      ready: $ready,
      summary: {pass: $pass, warn: $warn, fail: $fail},
      chain: {epoch: $epoch, slot: $slot, tip_lag_sec: $tip_lag},
      kes_periods_remaining: $kes_remaining,
      saturation_pct: $saturation,
      active_peers: $active_peers,
      next_leader: (if $next_leader_slot == "" then null else {slot: ($next_leader_slot|tonumber), eta_sec: ($next_leader_eta|tonumber)} end),
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
  msg="🚨 *${POOL_NAME} BP NOT READY*
Failures: ${FAIL} | Warnings: ${WARN}
Epoch: ${epoch} | Tip lag: ${tip_lag}s | KES left: ${remaining_kes}p

*Problems:*
${failure_list}"

  timeout 10 curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${msg}" \
    --data-urlencode "parse_mode=Markdown" \
    >/dev/null 2>&1 || true
fi

exit ${EXIT_CODE:-0}

