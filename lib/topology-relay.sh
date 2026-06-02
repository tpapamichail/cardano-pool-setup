#!/usr/bin/env bash
# topology-relay.sh — Generate relay topology
# Local roots: BP + (optionally) sibling relays
# Public roots: IOG defaults + ledger discovery enabled
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

section "Relay Topology"

: "${CARDANO_CONFIG_DIR:?required}"
: "${RELAY_PORT:=6000}"

topo="${CARDANO_CONFIG_DIR}/topology.json"

# Local roots: your pool's BP
local_aps='[]'
if [[ -n "${BP_EXPECTED_IP:-}" ]]; then
  local_aps=$(echo '[]' | jq \
    --arg addr "$BP_EXPECTED_IP" --argjson port "$RELAY_PORT" \
    '. += [{"address": $addr, "port": $port}]')
fi

# Sibling relays (if more than 1)
if [[ -n "${RELAY_HOSTS:-}" ]]; then
  # Try to find my own hostnames and exclude the current host
  myhost=$(hostname -f 2>/dev/null || hostname)
  IFS=',' read -ra RELAYS <<< "$RELAY_HOSTS"
  for host in "${RELAYS[@]}"; do
    host=$(echo "$host" | xargs)
    [[ -z "$host" || "$host" == "$myhost" ]] && continue
    local_aps=$(echo "$local_aps" | jq \
      --arg addr "$host" --argjson port "$RELAY_PORT" \
      '. += [{"address": $addr, "port": $port}]')
  done
fi

# Public roots: IOG mainnet defaults
public_roots='[
  {
    "accessPoints": [
      {"address": "backbone.cardano.iog.io", "port": 3001},
      {"address": "backbone.mainnet.cardanofoundation.org", "port": 3001},
      {"address": "backbone.mainnet.emurgornd.com", "port": 3001}
    ],
    "advertise": false
  }
]'

local_count=$(echo "$local_aps" | jq 'length')

jq -n \
  --argjson laps "$local_aps" \
  --argjson lcount "$local_count" \
  --argjson pub "$public_roots" '{
  localRoots: (if $lcount > 0 then [{
    accessPoints: $laps,
    advertise: false,
    trustable: true,
    valency: $lcount,
    hotValency: $lcount,
    warmValency: $lcount
  }] else [] end),
  publicRoots: $pub,
  useLedgerAfterSlot: 128908821,
  useLedgerPeers: { "useLedgerAfterSlot": 128908821 },
  bootstrapPeers: [
    {"address": "backbone.cardano.iog.io", "port": 3001},
    {"address": "backbone.mainnet.cardanofoundation.org", "port": 3001}
  ],
  peerSnapshotFile: null
}' > "$topo"

ok "Relay topology written: $topo"
ok "Local roots: ${local_count}, public roots: 3, ledger discovery: enabled"
