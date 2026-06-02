#!/usr/bin/env bash
# compose-deploy.sh — Render docker-compose.yaml from template and start the node
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

section "Docker Compose Deploy"

: "${CARDANO_HOME:?required}"
: "${NODE_ROLE:?required}"
: "${CARDANO_IMAGE:=ghcr.io/blinklabs-io/cardano-node:latest}"

REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
case "$NODE_ROLE" in
  producer) tpl="${REPO_DIR}/templates/producer-compose.yaml.tpl" ;;
  relay)    tpl="${REPO_DIR}/templates/relay-compose.yaml.tpl" ;;
  *) die "Unknown NODE_ROLE: $NODE_ROLE" ;;
esac

[[ -f "$tpl" ]] || die "Template not found: $tpl"

mkdir -p "$CARDANO_HOME"
out="${CARDANO_HOME}/docker-compose.yaml"

# Render with envsubst — allows ${VAR} substitution
export CARDANO_HOME CARDANO_IMAGE
envsubst < "$tpl" > "$out"
ok "Rendered: $out"

# Pre-create directories
mkdir -p "${CARDANO_HOME}/db" "${CARDANO_HOME}/ipc" \
  "${CARDANO_HOME}/config/mainnet" "${CARDANO_HOME}/priv" \
  "${CARDANO_HOME}/bp-keys"

# Pull image
log "Pulling image: ${CARDANO_IMAGE}"
docker pull "$CARDANO_IMAGE" >/dev/null

# Start
cd "$CARDANO_HOME"
docker compose up -d
sleep 3
ok "Container started"
docker compose ps
