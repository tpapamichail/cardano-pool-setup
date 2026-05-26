#!/usr/bin/env bash
# zsh-omz.sh — Εγκατάσταση zsh + oh-my-zsh για τον root user
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

section "zsh + oh-my-zsh"

if ! command -v zsh >/dev/null; then
  apt-get install -y -qq zsh >/dev/null
fi
ok "zsh: $(zsh --version | awk '{print $2}')"

# Set zsh ως default shell του root
current_shell=$(getent passwd root | cut -d: -f7)
if [[ "$current_shell" != "$(command -v zsh)" ]]; then
  chsh -s "$(command -v zsh)" root
  ok "Default shell του root → zsh"
else
  ok "zsh ήδη default shell"
fi

# Install oh-my-zsh (unattended, διατηρεί υπάρχον ~/.zshrc αν υπάρχει)
ZSH_DIR="/root/.oh-my-zsh"
if [[ -d "$ZSH_DIR" ]]; then
  ok "oh-my-zsh ήδη εγκατεστημένο"
else
  log "Εγκατάσταση oh-my-zsh..."
  if RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
       sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
       "" --unattended >/dev/null 2>&1; then
    ok "oh-my-zsh installed"
  else
    warn "oh-my-zsh installation failed — προχωράμε χωρίς αυτό"
  fi
fi

# Bootstrap minimal ~/.zshrc αν δεν υπάρχει
if [[ ! -f /root/.zshrc ]]; then
  if [[ -f "$ZSH_DIR/templates/zshrc.zsh-template" ]]; then
    cp "$ZSH_DIR/templates/zshrc.zsh-template" /root/.zshrc
  else
    cat > /root/.zshrc <<'EOF'
# Minimal zshrc
autoload -Uz compinit && compinit
HISTSIZE=10000; SAVEHIST=10000
HISTFILE=~/.zsh_history
setopt SHARE_HISTORY HIST_IGNORE_DUPS
PROMPT='%F{cyan}%n@%m%f:%F{yellow}%~%f%# '
EOF
  fi
  ok "~/.zshrc created"
fi
