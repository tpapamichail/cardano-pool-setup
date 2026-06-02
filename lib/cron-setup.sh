#!/usr/bin/env bash
# cron-setup.sh — systemd timers for periodic health checks
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

section "Cron / Systemd Timers"

: "${CARDANO_HOME:?required}"
: "${NODE_ROLE:?required}"

# Script path that will run
case "$NODE_ROLE" in
  producer) health_script="${CARDANO_HOME}/scripts/bp-preflight.sh" ;;
  relay)    health_script="${CARDANO_HOME}/scripts/relay-health.sh" ;;
  *) die "Bad NODE_ROLE" ;;
esac

[[ -x "$health_script" ]] || { warn "Health script not executable: $health_script"; return 0; }

cat > /etc/systemd/system/cardano-health.service <<EOF
[Unit]
Description=Cardano ${NODE_ROLE} health check
After=docker.service

[Service]
Type=oneshot
EnvironmentFile=${CARDANO_HOME}/config.env
ExecStart=${health_script} --fast
EOF

cat > /etc/systemd/system/cardano-health.timer <<EOF
[Unit]
Description=Run Cardano health check every 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now cardano-health.timer >/dev/null
ok "cardano-health.timer enabled (every 15 minutes)"
mark_done cron-setup
