#!/usr/bin/env bash
# chrony.sh — NTP for Cardano (tight thresholds)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

section "Chrony NTP"

if ! command -v chronyc >/dev/null; then
  apt-get install -y -qq chrony >/dev/null
fi

# Backup existing chrony.conf if it is not already from us
if [[ -f /etc/chrony/chrony.conf ]] && ! grep -q "# cardano-pool-setup" /etc/chrony/chrony.conf; then
  cp /etc/chrony/chrony.conf "/etc/chrony/chrony.conf.bak.$(date +%s)"
fi

cat > /etc/chrony/chrony.conf <<'EOF'
# cardano-pool-setup — tight NTP config for block timing
# Multiple stratum-1 sources for redundancy

server time.cloudflare.com iburst minpoll 3 maxpoll 6
server time.google.com    iburst minpoll 3 maxpoll 6
server time.nist.gov      iburst minpoll 3 maxpoll 6
pool   pool.ntp.org       iburst maxsources 4 minpoll 3 maxpoll 6

driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
maxupdateskew 100.0
# Tighter slewing to avoid drift
maxslewrate 1000

# Allow only local
bindcmdaddress 127.0.0.1
bindcmdaddress ::1
EOF

systemctl enable --now chrony >/dev/null
systemctl restart chrony
sleep 2

# Validate
if chronyc tracking >/dev/null 2>&1; then
  offset=$(chronyc tracking | awk '/Last offset/ {print $4}')
  ok "Chrony active — offset: ${offset}s"
else
  warn "Chrony is active but not yet responding to queries"
fi
mark_done chrony
