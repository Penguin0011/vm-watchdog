#!/usr/bin/env bash
set -euo pipefail

LOG=/var/log/vm-maintenance.log
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [weekly-upgrade] $*" >> "$LOG"; }

log "=== Starting weekly apt upgrade ==="

apt-get -o DPkg::Lock::Timeout=300 -qq update >> "$LOG" 2>&1

DEBIAN_FRONTEND=noninteractive apt-get \
  -o DPkg::Lock::Timeout=300 \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  -y upgrade >> "$LOG" 2>&1

apt-get -y autoremove >> "$LOG" 2>&1
apt-get clean >> "$LOG" 2>&1

if [[ -f /var/run/reboot-required ]]; then
  log "Reboot required after upgrade (will happen at 2am via unattended-upgrades)"
fi

log "=== Weekly apt upgrade complete ==="
