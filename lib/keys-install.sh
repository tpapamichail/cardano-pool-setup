#!/usr/bin/env bash
# keys-install.sh — Validate & install pool keys in the correct locations
#
# The user provides a directory that must contain at least:
#   - cold.skey.gpg     (encrypted cold signing key — REQUIRED)
#   - cold.vkey         (cold verification key)
#   - cold.counter      (operational certificate counter)
#   - vrf.skey + vrf.vkey
#   - hot.skey (KES signing) — IF pre-existing
#   - hot.vkey (KES verification) — IF pre-existing
#   - op.cert (ή node.cert) — operational certificate
#   - pool.id (hex pool id)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

section "Pool Keys"

: "${KEYS_SOURCE_DIR:?KEYS_SOURCE_DIR required}"
: "${POOL_DIR:?POOL_DIR required}"
: "${BP_KEYS_DIR:?BP_KEYS_DIR required}"

[[ -d "$KEYS_SOURCE_DIR" ]] || die "Source dir does not exist: $KEYS_SOURCE_DIR"

# 1) FORBID plaintext cold.skey in source
if [[ -f "${KEYS_SOURCE_DIR}/cold.skey" ]]; then
  die "FORBIDDEN: plaintext cold.skey. Encrypt it first with gpg-encrypt → cold.skey.gpg, then shred the original."
fi

# 2) Required files
REQUIRED=(cold.skey.gpg cold.vkey cold.counter vrf.skey vrf.vkey pool.id)
missing=()
for f in "${REQUIRED[@]}"; do
  [[ -f "${KEYS_SOURCE_DIR}/$f" ]] || missing+=("$f")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  err "The following files are missing from ${KEYS_SOURCE_DIR}:"
  for f in "${missing[@]}"; do echo "    - $f"; done
  die "Resolve the missing keys and re-run."
fi

# 3) Optional: KES (hot.skey/hot.vkey) + op.cert
HAVE_KES=0
if [[ -f "${KEYS_SOURCE_DIR}/hot.skey" && -f "${KEYS_SOURCE_DIR}/hot.vkey" ]]; then
  HAVE_KES=1
fi

HAVE_OPCERT=0
opcert_src=""
for cand in op.cert node.cert; do
  if [[ -f "${KEYS_SOURCE_DIR}/$cand" ]]; then
    opcert_src="${KEYS_SOURCE_DIR}/$cand"
    HAVE_OPCERT=1
    break
  fi
done

if [[ $HAVE_KES -eq 0 || $HAVE_OPCERT -eq 0 ]]; then
  warn "Missing KES keypair and/or op.cert."
  warn "Run the following manually on an OFFLINE machine and add to source:"
  hint "  cardano-cli conway node key-gen-KES \\"
  hint "    --verification-key-file hot.vkey --signing-key-file hot.skey"
  hint "  cardano-cli conway node issue-op-cert \\"
  hint "    --kes-verification-key-file hot.vkey \\"
  hint "    --cold-signing-key-file cold.skey \\"
  hint "    --operational-certificate-issue-counter-file cold.counter \\"
  hint "    --kes-period <current> --out-file op.cert"
  die "Add the keys later with kes-rotate.sh"
fi

# 4) Install
mkdir -p "$POOL_DIR" "$BP_KEYS_DIR"
chmod 700 "$POOL_DIR" "$BP_KEYS_DIR"

# Cold material → POOL_DIR
install -m 400 "${KEYS_SOURCE_DIR}/cold.skey.gpg" "${POOL_DIR}/cold.skey.gpg"
install -m 400 "${KEYS_SOURCE_DIR}/cold.vkey"    "${POOL_DIR}/cold.vkey"
install -m 400 "${KEYS_SOURCE_DIR}/cold.counter" "${POOL_DIR}/cold.counter"
install -m 400 "${KEYS_SOURCE_DIR}/vrf.skey"     "${POOL_DIR}/vrf.skey"
install -m 400 "${KEYS_SOURCE_DIR}/vrf.vkey"     "${POOL_DIR}/vrf.vkey"
install -m 400 "${KEYS_SOURCE_DIR}/hot.skey"     "${POOL_DIR}/hot.skey"
install -m 400 "${KEYS_SOURCE_DIR}/hot.vkey"     "${POOL_DIR}/hot.vkey"
install -m 400 "$opcert_src"                     "${POOL_DIR}/op.cert"
install -m 400 "${KEYS_SOURCE_DIR}/pool.id"      "${POOL_DIR}/pool.id"

# Runtime keys → BP_KEYS_DIR (read-only mount from the container)
install -m 400 "${POOL_DIR}/vrf.skey"  "${BP_KEYS_DIR}/vrf.skey"
install -m 400 "${POOL_DIR}/hot.skey"  "${BP_KEYS_DIR}/kes.skey"
install -m 400 "${POOL_DIR}/op.cert"   "${BP_KEYS_DIR}/node.cert"

ok "Keys installed: POOL_DIR=${POOL_DIR}"
ok "Runtime keys: BP_KEYS_DIR=${BP_KEYS_DIR}"
warn "Run manually: shred -u the files from ${KEYS_SOURCE_DIR} once you confirm the node has started."
