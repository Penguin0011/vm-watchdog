#!/usr/bin/env bash
set -uo pipefail

# Usage: cron-wrapper.sh /usr/local/sbin/some-script.sh
# Runs the given script and POSTs a down alert to Uptime Kuma if it exits non-zero.

CONF="/etc/vm-maintenance.conf"
LOG="/var/log/vm-maintenance.log"
[[ -f "$CONF" ]] && source "$CONF"
VM_HOSTNAME="${VM_HOSTNAME:-unknown}"
ALERT_URL="${ALERT_URL:-}"

SCRIPT="$1"
SCRIPT_NAME="$(basename "$SCRIPT")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [cron-wrapper] $*" >> "$LOG"; }

"$SCRIPT"
EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
  log "ERROR: ${SCRIPT_NAME} exited ${EXIT_CODE} — alerting"
  if [[ -n "$ALERT_URL" ]]; then
    MSG="CRON+FAIL:+${VM_HOSTNAME}+${SCRIPT_NAME}+exit+${EXIT_CODE}"
    curl -fsS "${ALERT_URL}?status=down&msg=${MSG}" >/dev/null 2>&1 || true
  fi
fi

exit $EXIT_CODE
