#!/usr/bin/env bash
# ============================================================
# gpg-helpers.sh — Simple wrappers για encrypt/decrypt κλειδιών
# Source from ~/.zshrc (via aliases.zsh)
# ============================================================

gpg-encrypt() {
  if [[ $# -ne 1 || ! -f "$1" ]]; then
    echo "Usage: gpg-encrypt <file>"
    return 1
  fi
  local src="$1" dst="${1}.gpg"

  if [[ -f "$dst" ]]; then
    read -rp "$(echo -e \\033[1;33m${dst} υπάρχει — overwrite; [yes/N]: \\033[0m)" c
    [[ "$c" == "yes" ]] || return 0
  fi

  gpg --quiet --no-symkey-cache --symmetric --cipher-algo AES256 \
    --output "$dst" "$src" \
    && echo -e "\033[1;32m✓\033[0m Encrypted → $dst" \
    || { echo -e "\033[1;31m✗\033[0m Encryption failed"; return 1; }

  read -rp "$(echo -e \\033[1;33mShred το original ${src}; [yes/N]: \\033[0m)" c
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
  [[ "$dst" == "$src" ]] && { echo "ERROR: αρχείο δεν τελειώνει σε .gpg"; return 1; }

  if [[ -f "$dst" ]]; then
    read -rp "$(echo -e \\033[1;33m${dst} υπάρχει — overwrite; [yes/N]: \\033[0m)" c
    [[ "$c" == "yes" ]] || return 0
  fi

  gpg --quiet --no-symkey-cache --output "$dst" --decrypt "$src" \
    && chmod 400 "$dst" \
    && echo -e "\033[1;32m✓\033[0m Decrypted → $dst (chmod 400)" \
    || { echo -e "\033[1;31m✗\033[0m Decryption failed"; return 1; }

  echo -e "\033[2m  Θυμήσου: shred -u $dst όταν τελειώσεις\033[0m"
}

gpg-help() {
  cat <<'EOF'

  gpg-encrypt FILE       Encrypt με AES256 + passphrase → FILE.gpg
  gpg-decrypt FILE.gpg   Decrypt → FILE (chmod 400)

  Tips:
    - Ισχυρό passphrase (>20 chars, mix)
    - Πάντα shred το plaintext μετά τη χρήση
    - Backup τα .gpg σε offline storage (USB, encrypted cloud)

EOF
}
