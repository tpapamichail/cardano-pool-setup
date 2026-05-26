#!/usr/bin/env bash
# preflight.sh — Έλεγχοι πριν ξεκινήσει το install
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

section "Preflight"
require_root
require_ubuntu

# Internet check
if timeout 5 curl -s -o /dev/null -w '%{http_code}' https://book.world.dev.cardano.org/ | grep -q '^2\|^3'; then
  ok "Internet reachable"
else
  die "Δεν υπάρχει internet ή IOG site unreachable"
fi

# Architecture
arch="$(uname -m)"
case "$arch" in
  x86_64|aarch64) ok "Architecture: $arch" ;;
  *) die "Μη υποστηριζόμενο arch: $arch" ;;
esac

# RAM
total_mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
total_mem_gb=$((total_mem_kb / 1024 / 1024))
if [[ $total_mem_gb -lt 16 ]]; then
  warn "Memory: ${total_mem_gb}GB (συνιστώνται ≥16GB για mainnet)"
else
  ok "Memory: ${total_mem_gb}GB"
fi

# Disk free
disk_free_gb=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
if [[ $disk_free_gb -lt 200 ]]; then
  warn "Disk free /: ${disk_free_gb}GB (συνιστώνται ≥200GB για mainnet DB)"
else
  ok "Disk free /: ${disk_free_gb}GB"
fi
