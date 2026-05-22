#!/usr/bin/env bash
set -euo pipefail

CONF="/etc/vm-maintenance.conf"
LOG="/var/log/vm-maintenance.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [self-update] $*" >> "$LOG"; }

[[ -f "$CONF" ]] || { log "ERROR: ${CONF} not found — cannot determine repo URL"; exit 1; }
source "$CONF"

[[ -z "${REPO_URL:-}" ]] && { log "ERROR: REPO_URL not set in ${CONF}"; exit 1; }

log "=== Monthly script self-update from ${REPO_URL} ==="

for script in weekly-upgrade disk-monitor security-audit self-update; do
  if curl -fsSL "${REPO_URL}/${script}.sh" -o "/tmp/vm-watchdog-${script}.sh" 2>>"$LOG"; then
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
