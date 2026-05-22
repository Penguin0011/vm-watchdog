#!/usr/bin/env bash
set -euo pipefail

LOG=/var/log/vm-maintenance.log
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [weekly-upgrade] $*" >> "$LOG"; }

wait_for_apt_lock() {
  local deadline=$(( SECONDS + 600 ))
  while fuser /var/lib/dpkg/lock /var/lib/apt/lists/lock \
              /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock \
              >/dev/null 2>&1; do
    [[ $SECONDS -ge $deadline ]] && { log "ERROR: apt lock held >10 min, aborting"; exit 1; }
    log "  apt lock held, waiting 30s..."
    sleep 30
  done
}

log "=== Starting weekly apt upgrade ==="
wait_for_apt_lock

apt-get -o DPkg::Lock::Timeout=300 -qq update >> "$LOG" 2>&1

DEBIAN_FRONTEND=noninteractive apt-get \
  -o DPkg::Lock::Timeout=300 \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  -y upgrade >> "$LOG" 2>&1

apt-get -y autoremove >> "$LOG" 2>&1
apt-get clean >> "$LOG" 2>&1

if [[ -f /var/run/reboot-required ]]; then
  log "Reboot required after upgrade (will happen at scheduled time via unattended-upgrades)"
fi

log "=== Weekly apt upgrade complete ==="
