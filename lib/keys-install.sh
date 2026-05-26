#!/usr/bin/env bash
# keys-install.sh — Validate & install τα pool keys στις σωστές θέσεις
#
# Ο χρήστης δίνει ένα directory που πρέπει να περιέχει τουλάχιστον:
#   - cold.skey.gpg     (encrypted cold signing key — ΥΠΟΧΡΕΩΤΙΚΟ)
#   - cold.vkey         (cold verification key)
#   - cold.counter      (operational certificate counter)
#   - vrf.skey + vrf.vkey
#   - hot.skey (KES signing) — ΑΝ προϋπάρχει
#   - hot.vkey (KES verification) — ΑΝ προϋπάρχει
#   - op.cert (ή node.cert) — operational certificate
#   - pool.id (hex pool id)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

section "Pool Keys"

: "${KEYS_SOURCE_DIR:?KEYS_SOURCE_DIR απαιτείται}"
: "${POOL_DIR:?POOL_DIR απαιτείται}"
: "${BP_KEYS_DIR:?BP_KEYS_DIR απαιτείται}"

[[ -d "$KEYS_SOURCE_DIR" ]] || die "Source dir δεν υπάρχει: $KEYS_SOURCE_DIR"

# 1) ΑΠΑΓΟΡΕΥΣΗ plaintext cold.skey στο source
if [[ -f "${KEYS_SOURCE_DIR}/cold.skey" ]]; then
  die "ΑΠΑΓΟΡΕΥΕΤΑΙ plaintext cold.skey. Encrypt το πρώτα με gpg-encrypt → cold.skey.gpg, μετά shred το original."
fi

# 2) Required files
REQUIRED=(cold.skey.gpg cold.vkey cold.counter vrf.skey vrf.vkey pool.id)
missing=()
for f in "${REQUIRED[@]}"; do
  [[ -f "${KEYS_SOURCE_DIR}/$f" ]] || missing+=("$f")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  err "Λείπουν τα παρακάτω αρχεία από ${KEYS_SOURCE_DIR}:"
  for f in "${missing[@]}"; do echo "    - $f"; done
  die "Αντιμετώπισε τα missing keys και ξανατρέξε."
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
  warn "Λείπει KES keypair ή/και op.cert."
  warn "Τρέξε χειροκίνητα τα παρακάτω σε ΟΦΛΑΪΝ μηχάνημα και πρόσθεσε στο source:"
  hint "  cardano-cli conway node key-gen-KES \\"
  hint "    --verification-key-file hot.vkey --signing-key-file hot.skey"
  hint "  cardano-cli conway node issue-op-cert \\"
  hint "    --kes-verification-key-file hot.vkey \\"
  hint "    --cold-signing-key-file cold.skey \\"
  hint "    --operational-certificate-issue-counter-file cold.counter \\"
  hint "    --kes-period <current> --out-file op.cert"
  die "Προσθέτεις τα keys αργότερα με kes-rotate.sh"
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

# Runtime keys → BP_KEYS_DIR (read-only mount από το container)
install -m 400 "${POOL_DIR}/vrf.skey"  "${BP_KEYS_DIR}/vrf.skey"
install -m 400 "${POOL_DIR}/hot.skey"  "${BP_KEYS_DIR}/kes.skey"
install -m 400 "${POOL_DIR}/op.cert"   "${BP_KEYS_DIR}/node.cert"

ok "Keys installed: POOL_DIR=${POOL_DIR}"
ok "Runtime keys: BP_KEYS_DIR=${BP_KEYS_DIR}"
warn "Στείλε χειροκίνητα: shred -u τα αρχεία από ${KEYS_SOURCE_DIR} όταν επιβεβαιώσεις ότι ο node ξεκίνησε."
