#!/usr/bin/env bash
# ============================================================
# kes-rotate.sh — KES key rotation (parameterized)
# Διαβάζει: $CARDANO_HOME/config.env
# ============================================================
set -euo pipefail

# ────────── Load config ──────────
CONFIG_FILE="${CARDANO_HOME:-/opt/cardano}/config.env"
if [[ -f "$CONFIG_FILE" ]]; then
  set -a; . "$CONFIG_FILE"; set +a
fi

: "${POOL_NAME:?POOL_NAME απαιτείται (δες $CONFIG_FILE)}"
: "${CARDANO_HOME:?CARDANO_HOME απαιτείται}"
: "${POOL_DIR:=${CARDANO_HOME}/priv/pool/${POOL_NAME}}"
: "${BP_KEYS_DIR:=${CARDANO_HOME}/bp-keys}"
: "${CARDANO_IPC_DIR:=${CARDANO_HOME}/ipc}"
: "${CARDANO_CONFIG_DIR:=${CARDANO_HOME}/config/mainnet}"
: "${CARDANO_IMAGE:=ghcr.io/blinklabs-io/cardano-node:latest}"
: "${CARDANO_NETWORK:=mainnet}"

COLD_GPG="${POOL_DIR}/cold.skey.gpg"
COLD_PLAIN="${POOL_DIR}/cold.skey"
COLD_COUNTER="${POOL_DIR}/cold.counter"
KES_SKEY="${POOL_DIR}/hot.skey"
KES_VKEY="${POOL_DIR}/hot.vkey"
OP_CERT="${POOL_DIR}/op.cert"

G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; B='\033[1m'; D='\033[2m'; N='\033[0m'

cleanup() {
  if [[ -f "$COLD_PLAIN" ]]; then
    echo -e "\n${Y}>> Securely deleting plaintext cold.skey...${N}"
    shred -u "$COLD_PLAIN" 2>/dev/null || rm -f "$COLD_PLAIN"
  fi
}
trap cleanup EXIT INT TERM ERR

echo -e "${B}═══════════════════════════════════════════════${N}"
echo -e "${B} KES Rotation — ${POOL_NAME}${N}"
echo -e "${B}═══════════════════════════════════════════════${N}\n"

[[ -f "$COLD_GPG" ]]     || { echo -e "${R}ERROR:${N} Missing $COLD_GPG"; exit 1; }
[[ -f "$COLD_COUNTER" ]] || { echo -e "${R}ERROR:${N} Missing $COLD_COUNTER"; exit 1; }
[[ -d "$BP_KEYS_DIR" ]]  || { echo -e "${R}ERROR:${N} Missing $BP_KEYS_DIR"; exit 1; }

read -rp "$(echo -e ${Y}Συνεχίζουμε με το KES rotation; [yes/N]: ${N})" confirm
[[ "$confirm" == "yes" ]] || { echo "Ακυρώθηκε."; exit 0; }

# 1. Current KES period
echo -e "\n${B}>> Querying current KES period...${N}"
tip=$(docker exec producer sh -c \
  "CARDANO_NODE_SOCKET_PATH=/ipc/node.socket cardano-cli query tip --${CARDANO_NETWORK}" 2>/dev/null)
slot=$(echo "$tip" | jq -r '.slot')
slots_per_period=129600
KES_PERIOD=$((slot / slots_per_period))
echo -e "   Current slot: ${slot}"
echo -e "   ${G}Current KES period: ${KES_PERIOD}${N}"

# 2. Backup
BACKUP_DIR="${POOL_DIR}/backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp "$KES_SKEY" "$KES_VKEY" "$OP_CERT" "$COLD_COUNTER" "$BACKUP_DIR/" 2>/dev/null || true
echo -e "\n${B}>> Backup:${N} ${D}${BACKUP_DIR}${N}"

# 3. Decrypt cold
echo -e "\n${B}>> Decrypting cold.skey${N} ${D}(GPG passphrase)${N}"
gpg --quiet --no-symkey-cache --output "$COLD_PLAIN" --decrypt "$COLD_GPG"
[[ -s "$COLD_PLAIN" ]] || { echo -e "${R}ERROR:${N} Decryption failed"; exit 1; }
chmod 400 "$COLD_PLAIN"
echo -e "   ${G}✓ Decrypted${N}"

# 4. New KES keypair
echo -e "\n${B}>> Generating νέο KES keypair...${N}"
docker run --rm \
  -v "${POOL_DIR}:/keys" \
  "$CARDANO_IMAGE" cli \
  conway node key-gen-KES \
  --verification-key-file /keys/hot.vkey \
  --signing-key-file /keys/hot.skey
chmod 400 "$KES_SKEY" "$KES_VKEY"
echo -e "   ${G}✓ Generated${N}"

# 5. Issue op cert
echo -e "\n${B}>> Issuing op cert (period ${KES_PERIOD})...${N}"
docker run --rm \
  -v "${POOL_DIR}:/keys" \
  "$CARDANO_IMAGE" cli \
  conway node issue-op-cert \
  --kes-verification-key-file /keys/hot.vkey \
  --cold-signing-key-file /keys/cold.skey \
  --operational-certificate-issue-counter-file /keys/cold.counter \
  --kes-period "$KES_PERIOD" \
  --out-file /keys/op.cert
chmod 400 "$OP_CERT" "$COLD_COUNTER"
echo -e "   ${G}✓ Op cert issued${N}"

# 6. Deploy
echo -e "\n${B}>> Deploying στο ${BP_KEYS_DIR}/...${N}"
cp "$KES_SKEY" "$BP_KEYS_DIR/kes.skey"
cp "$OP_CERT"  "$BP_KEYS_DIR/node.cert"
chmod 400 "$BP_KEYS_DIR/kes.skey" "$BP_KEYS_DIR/node.cert"
echo -e "   ${G}✓ Keys deployed${N}"

# 7. Restart
echo -e "\n${B}>> Restart producer...${N}"
cd "$CARDANO_HOME" && docker compose restart producer
echo -e "   ${G}✓ Restart triggered${N}"

# 8. Verify
echo -e "\n${B}>> Wait 30s για load...${N}"
sleep 30
echo -e "\n${B}>> Verification:${N}"
docker run --rm \
  -v "${CARDANO_IPC_DIR}:/ipc" \
  -v "${BP_KEYS_DIR}:/keys:ro" \
  -e CARDANO_NODE_SOCKET_PATH=/ipc/node.socket \
  "$CARDANO_IMAGE" cli \
  query kes-period-info "--${CARDANO_NETWORK}" --op-cert-file /keys/node.cert

echo -e "\n${G}${B}═══════════════════════════════════════════════${N}"
echo -e "${G}${B} ✓ KES Rotation Complete${N}"
echo -e "${G}${B}═══════════════════════════════════════════════${N}"
echo -e "${D} Next rotation πριν την λήξη (~80 μέρες)${N}\n"
