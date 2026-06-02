#!/usr/bin/env bash
# zsh-omz.sh — Install zsh + oh-my-zsh for the root user
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

section "zsh + oh-my-zsh"

if ! command -v zsh >/dev/null; then
  apt-get install -y -qq zsh >/dev/null
fi
ok "zsh: $(zsh --version | awk '{print $2}')"

# Set zsh as root's default shell
current_shell=$(getent passwd root | cut -d: -f7)
if [[ "$current_shell" != "$(command -v zsh)" ]]; then
  chsh -s "$(command -v zsh)" root
  ok "Root's default shell → zsh"
else
  ok "zsh is already the default shell"
fi

# Install oh-my-zsh (unattended, preserves existing ~/.zshrc if present)
ZSH_DIR="/root/.oh-my-zsh"
if [[ -d "$ZSH_DIR" ]]; then
  ok "oh-my-zsh already installed"
else
  log "Installing oh-my-zsh..."
  if RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
       sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
       "" --unattended >/dev/null 2>&1; then
    ok "oh-my-zsh installed"
  else
    warn "oh-my-zsh installation failed — continuing without it"
  fi
fi

# Bootstrap minimal ~/.zshrc if it does not exist
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
