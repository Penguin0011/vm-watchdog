#!/usr/bin/env bash
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/Penguin0011/Vm-watchdog/main"
LOG=/var/log/vm-maintenance.log
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [self-update] $*" >> "$LOG"; }

log "=== Monthly script self-update from GitHub ==="

for script in weekly-upgrade disk-monitor security-audit self-update; do
  if curl -fsSL "${REPO_RAW}/${script}.sh" -o "/tmp/vm-watchdog-${script}.sh" 2>>"$LOG"; then
    if [[ -s "/tmp/vm-watchdog-${script}.sh" ]]; then
      install -m 750 "/tmp/vm-watchdog-${script}.sh" "/usr/local/sbin/${script}.sh"
      log "  updated: ${script}.sh"
    fi
  else
    log "  WARNING: failed to download ${script}.sh — keeping existing version"
  fi
  rm -f "/tmp/vm-watchdog-${script}.sh"
done

log "=== Self-update complete ==="
