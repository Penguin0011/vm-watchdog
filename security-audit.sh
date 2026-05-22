#!/usr/bin/env bash
set -euo pipefail

LOG=/var/log/vm-maintenance.log
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [security-audit] $*" >> "$LOG"; }

log "=== Daily security audit ==="

log "--- fail2ban sshd status ---"
fail2ban-client status sshd >> "$LOG" 2>&1 || log "fail2ban sshd jail not available"

log "--- ufw status ---"
ufw status verbose >> "$LOG" 2>&1

log "--- last 10 failed SSH attempts (24h) ---"
journalctl -u ssh -u sshd --since "24 hours ago" --no-pager -q 2>/dev/null \
  | grep -iE "failed|invalid|disconnect" \
  | tail -10 >> "$LOG" 2>&1 || true

log "--- pending security updates ---"
apt-get -s upgrade 2>/dev/null \
  | grep -i "^Inst.*security" \
  | wc -l \
  | xargs -I{} echo "{} pending security updates" >> "$LOG" 2>&1 || true

# Alert on new fail2ban SSH bans by tracking count delta
log "--- fail2ban ban tracking ---"
STATE_DIR="/var/lib/vm-watchdog"
mkdir -p "$STATE_DIR"
STATE_FILE="${STATE_DIR}/fail2ban-last-count"

CURRENT_BANS=$(fail2ban-client status sshd 2>/dev/null \
  | grep 'Currently banned' | awk '{print $NF}' || echo "0")
CURRENT_BANS="${CURRENT_BANS:-0}"

LAST_BANS=0
[[ -f "$STATE_FILE" ]] && LAST_BANS=$(cat "$STATE_FILE")

if [[ "$CURRENT_BANS" -gt "$LAST_BANS" ]]; then
  NEW=$(( CURRENT_BANS - LAST_BANS ))
  log "  ALERT: ${NEW} new SSH ban(s) detected — total now ${CURRENT_BANS}"
  source /etc/vm-maintenance.conf
  MSG="SSH+BAN:+${VM_HOSTNAME}+${NEW}+new+ban(s)+total+${CURRENT_BANS}"
  curl -fsS "${ALERT_URL}?status=down&msg=${MSG}" >/dev/null 2>&1 || true
else
  log "  No new SSH bans (currently ${CURRENT_BANS} banned)"
fi
echo "$CURRENT_BANS" > "$STATE_FILE"

log "=== Security audit complete ==="
