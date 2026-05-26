#!/usr/bin/env bash
# configs-download.sh — Pull authoritative mainnet configs from IOG
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

section "Mainnet Configs (IOG)"

: "${CARDANO_CONFIG_DIR:?CARDANO_CONFIG_DIR required}"
: "${CARDANO_NETWORK:=mainnet}"

mkdir -p "$CARDANO_CONFIG_DIR"

BASE="https://book.world.dev.cardano.org/environments/${CARDANO_NETWORK}"
FILES=(
  config.json
  topology.json
  byron-genesis.json
  shelley-genesis.json
  alonzo-genesis.json
  conway-genesis.json
)

for f in "${FILES[@]}"; do
  url="${BASE}/${f}"
  dst="${CARDANO_CONFIG_DIR}/${f}"
  if curl -fsSL -o "${dst}.tmp" "$url"; then
    mv "${dst}.tmp" "$dst"
    ok "Downloaded: $f"
  else
    rm -f "${dst}.tmp"
    err "Failed: $url"
    return 1 2>/dev/null || exit 1
  fi
done

# Patch config.json για να δείχνει στα σωστά genesis paths (IOG uses relative paths)
# και ενεργοποίηση Prometheus metrics στο 12798
cfg="${CARDANO_CONFIG_DIR}/config.json"
tmp=$(mktemp)
jq '
  .hasPrometheus = ["0.0.0.0", 12798] |
  .hasEKG = 12788
' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
ok "config.json: Prometheus :12798, EKG :12788 enabled"

mark_done configs-download
