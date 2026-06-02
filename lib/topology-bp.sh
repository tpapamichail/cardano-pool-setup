#!/usr/bin/env bash
# topology-bp.sh — Generate BP topology (locked to RELAY_HOSTS, no ledger discovery)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

section "BP Topology"

: "${CARDANO_CONFIG_DIR:?required}"
: "${RELAY_HOSTS:?required}"
: "${RELAY_PORT:=6000}"

topo="${CARDANO_CONFIG_DIR}/topology.json"

# Build accessPoints JSON array from RELAY_HOSTS
access_points='[]'
IFS=',' read -ra RELAYS <<< "$RELAY_HOSTS"
for host in "${RELAYS[@]}"; do
  host=$(echo "$host" | xargs)
  [[ -z "$host" ]] && continue
  access_points=$(echo "$access_points" | jq \
    --arg addr "$host" --argjson port "$RELAY_PORT" \
    '. += [{"address": $addr, "port": $port}]')
done

# BP topology: ONLY local roots (your relays), no public roots, no ledger peers
jq -n --argjson aps "$access_points" '{
  localRoots: [
    {
      accessPoints: $aps,
      advertise: false,
      trustable: true,
      valency: ($aps | length),
      hotValency: ($aps | length),
      warmValency: ($aps | length)
    }
  ],
  publicRoots: [],
  useLedgerAfterSlot: -1,
  useLedgerPeers: { "useLedgerAfterSlot": -1 },
  bootstrapPeers: null,
  peerSnapshotFile: null
}' > "$topo"

ok "BP topology written: $topo"
ok "Locked to ${#RELAYS[@]} relays, no ledger discovery"
