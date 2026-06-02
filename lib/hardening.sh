#!/usr/bin/env bash
# hardening.sh — sshd_config, fail2ban, sysctl tweaks
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

section "Hardening"

# ── SSH ──
sshd_cfg=/etc/ssh/sshd_config.d/99-cardano-pool-setup.conf
cat > "$sshd_cfg" <<'EOF'
# cardano-pool-setup — secure defaults
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30
EOF

# Check that authorized_keys exists before disabling passwords
if [[ -s /root/.ssh/authorized_keys ]]; then
  ok "sshd: password auth disabled (root has authorized_keys)"
  systemctl reload sshd || systemctl reload ssh
else
  warn "/root/.ssh/authorized_keys not found — NOT disabling passwords"
  warn "Add a public key first, then re-run for lockdown"
  rm -f "$sshd_cfg"
fi

# ── fail2ban ──
cat > /etc/fail2ban/jail.d/cardano-pool-setup.local <<'EOF'
[sshd]
enabled = true
maxretry = 4
bantime = 1h
findtime = 10m
EOF
systemctl enable --now fail2ban >/dev/null
systemctl restart fail2ban
ok "fail2ban active"

# ── sysctl tuning ──
cat > /etc/sysctl.d/99-cardano-pool.conf <<'EOF'
# cardano-pool-setup — network/memory tuning
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.core.somaxconn = 1024
net.ipv4.tcp_max_syn_backlog = 4096
fs.file-max = 2097152
vm.swappiness = 10
vm.max_map_count = 262144
EOF
sysctl -p /etc/sysctl.d/99-cardano-pool.conf >/dev/null
ok "sysctl tuning applied"

# Increase ulimits for containers
cat > /etc/security/limits.d/99-cardano.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
ok "ulimits raised (nofile)"

mark_done hardening
