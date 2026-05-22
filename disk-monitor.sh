#!/usr/bin/env bash
set -euo pipefail

source /etc/vm-maintenance.conf

LOG=/var/log/vm-maintenance.log
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [disk-monitor] $*" >> "$LOG"; }

THRESHOLD="${DISK_THRESHOLD:-85}"
ALERT_TRIGGERED=false

while IFS= read -r line; do
  USE=$(echo "$line" | awk '{print $5}' | tr -d '%')
  MOUNT=$(echo "$line" | awk '{print $6}')
  [[ "$USE" =~ ^[0-9]+$ ]] || continue

  if [[ "$USE" -ge "$THRESHOLD" ]]; then
    MSG="DISK ALERT [${VM_HOSTNAME}]: ${MOUNT} is ${USE}% full (threshold: ${THRESHOLD}%)"
    log "$MSG"
    ENCODED_MSG=$(printf '%s' "DISK+ALERT+${MOUNT}+${USE}pct" | sed 's/ /+/g')
    curl -sf --max-time 10 \
      "${ALERT_URL}?status=down&msg=${ENCODED_MSG}&ping=" >> "$LOG" 2>&1 \
      || log "WARNING: alert POST failed (will retry at next run)"
    ALERT_TRIGGERED=true
  fi
done < <(df -h --output=pcent,target 2>/dev/null | tail -n +2 | grep -vE '^(tmpfs|udev|/dev/loop|devtmpfs)')

if [[ "$ALERT_TRIGGERED" == "false" ]]; then
  curl -sf --max-time 10 \
    "${ALERT_URL}?status=up&msg=OK&ping=" >> "$LOG" 2>&1 \
    || log "WARNING: heartbeat POST failed"
  log "Disk check OK — all filesystems below ${THRESHOLD}%"
fi
