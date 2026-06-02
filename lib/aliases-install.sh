#!/usr/bin/env bash
# aliases-install.sh — Source the appropriate aliases into root's ~/.zshrc
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

section "Shell Aliases"

: "${CARDANO_HOME:?required}"
: "${NODE_ROLE:?required}"

REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
case "$NODE_ROLE" in
  producer) src="${REPO_DIR}/aliases/producer-aliases.zsh" ;;
  relay)    src="${REPO_DIR}/aliases/relay-aliases.zsh" ;;
  *) die "Bad NODE_ROLE" ;;
esac

dst="${CARDANO_HOME}/aliases.zsh"
install -m 644 "$src" "$dst"
# Also copy scripts/ so that aliases can use them
mkdir -p "${CARDANO_HOME}/scripts"
for s in bp-health.sh bp-preflight.sh relay-health.sh kes-rotate.sh gpg-helpers.sh; do
  if [[ -f "${REPO_DIR}/scripts/$s" ]]; then
    install -m 755 "${REPO_DIR}/scripts/$s" "${CARDANO_HOME}/scripts/$s"
  fi
done
ok "Scripts deployed → ${CARDANO_HOME}/scripts/"

# Append to root's ~/.zshrc (idempotent)
zshrc=/root/.zshrc
marker="# >>> cardano-pool-setup >>>"
endmarker="# <<< cardano-pool-setup <<<"

# Strip any previous block
if grep -q "$marker" "$zshrc" 2>/dev/null; then
  sed -i "/${marker}/,/${endmarker}/d" "$zshrc"
fi

cat >> "$zshrc" <<EOF

${marker}
export CARDANO_HOME="${CARDANO_HOME}"
[[ -f "\${CARDANO_HOME}/config.env" ]] && source "\${CARDANO_HOME}/config.env"
[[ -f "\${CARDANO_HOME}/aliases.zsh" ]] && source "\${CARDANO_HOME}/aliases.zsh"
${endmarker}
EOF

ok "Aliases sourced from ~/.zshrc (help + quickcheck auto-run on login)"
