#!/usr/bin/env bash
# ============================================================
# gpg-helpers.sh — Simple wrappers for encrypt/decrypt of keys
# Source from ~/.zshrc (via aliases.zsh)
# ============================================================

gpg-encrypt() {
  if [[ $# -ne 1 || ! -f "$1" ]]; then
    echo "Usage: gpg-encrypt <file>"
    return 1
  fi
  local src="$1" dst="${1}.gpg"

  if [[ -f "$dst" ]]; then
    read -rp "$(echo -e \\033[1;33m${dst} exists \342\200\224 overwrite\\; [yes/N]: \\033[0m)" c
    [[ "$c" == "yes" ]] || return 0
  fi

  gpg --quiet --no-symkey-cache --symmetric --cipher-algo AES256 \
    --output "$dst" "$src" \
    && echo -e "\033[1;32m✓\033[0m Encrypted → $dst" \
    || { echo -e "\033[1;31m✗\033[0m Encryption failed"; return 1; }

  read -rp "$(echo -e \\033[1;33mShred the original ${src}\\; [yes/N]: \\033[0m)" c
  if [[ "$c" == "yes" ]]; then
    shred -u "$src" && echo -e "\033[1;32m✓\033[0m Shredded $src"
  fi
}

gpg-decrypt() {
  if [[ $# -ne 1 || ! -f "$1" ]]; then
    echo "Usage: gpg-decrypt <file.gpg>"
    return 1
  fi
  local src="$1" dst="${1%.gpg}"
  [[ "$dst" == "$src" ]] && { echo "ERROR: file does not end in .gpg"; return 1; }

  if [[ -f "$dst" ]]; then
    read -rp "$(echo -e \\033[1;33m${dst} exists \342\200\224 overwrite\\; [yes/N]: \\033[0m)" c
    [[ "$c" == "yes" ]] || return 0
  fi

  gpg --quiet --no-symkey-cache --output "$dst" --decrypt "$src" \
    && chmod 400 "$dst" \
    && echo -e "\033[1;32m✓\033[0m Decrypted → $dst (chmod 400)" \
    || { echo -e "\033[1;31m✗\033[0m Decryption failed"; return 1; }

  echo -e "\033[2m  Remember: shred -u $dst when done\033[0m"
}

gpg-help() {
  cat <<'EOF'

  gpg-encrypt FILE       Encrypt with AES256 + passphrase → FILE.gpg
  gpg-decrypt FILE.gpg   Decrypt → FILE (chmod 400)

  Tips:
    - Strong passphrase (>20 chars, mix)
    - Always shred the plaintext after use
    - Backup .gpg files to offline storage (USB, encrypted cloud)

EOF
}
