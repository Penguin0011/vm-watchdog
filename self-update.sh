#!/usr/bin/env bash
set -euo pipefail

CONF="/etc/vm-maintenance.conf"
LOG="/var/log/vm-maintenance.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [self-update] $*" >> "$LOG"; }

[[ -f "$CONF" ]] || { log "ERROR: ${CONF} not found — cannot determine repo URL"; exit 1; }
source "$CONF"

[[ -z "${REPO_URL:-}" ]] && { log "ERROR: REPO_URL not set in ${CONF}"; exit 1; }

log "=== Monthly script self-update from ${REPO_URL} ==="

download_with_retry() {
  local url="$1" dest="$2"
  local attempt
  for attempt in 1 2 3; do
    if curl -fsSL "$url" -o "$dest" 2>>"$LOG"; then
      return 0
    fi
    log "  download attempt ${attempt}/3 failed for ${url}"
    [[ $attempt -lt 3 ]] && sleep 300
  done
  return 1
}

for script in cron-wrapper weekly-upgrade disk-monitor security-audit self-update; do
  TMP=$(mktemp "/tmp/vm-watchdog-${script}.XXXXXX")
  if download_with_retry "${REPO_URL}/${script}.sh" "$TMP"; then
    if [[ -s "$TMP" ]] && head -1 "$TMP" | grep -q '^#!'; then
      chmod 750 "$TMP"
      mv "$TMP" "/usr/local/sbin/${script}.sh"
      log "  updated: ${script}.sh"
    else
      log "  WARNING: ${script}.sh download invalid (empty or missing shebang) — keeping existing"
      rm -f "$TMP"
    fi
  else
    log "  WARNING: failed to download ${script}.sh after 3 attempts — keeping existing"
    rm -f "$TMP"
  fi
done

log "=== Self-update complete ==="
