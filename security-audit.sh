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

log "=== Security audit complete ==="
