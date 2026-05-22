#!/usr/bin/env bash
set -euo pipefail

# Idempotent bootstrap for any Ubuntu VM.
# Run as root. Safe to re-run.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/YOUR-USER/Vm-watchdog/main/vm-bootstrap.sh \
#     | sudo bash -s -- \
#         --hostname myvm \
#         --alert-url "https://uptime.example.com/api/push/TOKEN" \
#         --repo "https://raw.githubusercontent.com/YOUR-USER/Vm-watchdog/main" \
#         --lan-subnet "10.0.0.0/8" \
#         --extra-ports "80/tcp,443/tcp"   # optional
#         --cron-minute 0                  # optional (0-59, stagger weekly upgrades)
#
# On re-run: --alert-url may be omitted if /etc/vm-maintenance.conf already exists.

VM_HOSTNAME=""
ALERT_URL=""
REPO_RAW=""
LAN_SUBNET=""
EXTRA_PORTS=""
CRON_MINUTE="0"
LOG="/var/log/vm-maintenance.log"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname)    VM_HOSTNAME="$2";   shift 2 ;;
    --alert-url)   ALERT_URL="$2";     shift 2 ;;
    --repo)        REPO_RAW="$2";      shift 2 ;;
    --lan-subnet)  LAN_SUBNET="$2";    shift 2 ;;
    --extra-ports) EXTRA_PORTS="$2";   shift 2 ;;
    --cron-minute) CRON_MINUTE="$2";   shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Preserve existing ALERT_URL from conf if not supplied (safe re-run without token)
if [[ -z "$ALERT_URL" && -f /etc/vm-maintenance.conf ]]; then
  ALERT_URL=$(grep '^ALERT_URL=' /etc/vm-maintenance.conf | cut -d= -f2-)
fi

[[ -z "$VM_HOSTNAME" ]] && { echo "ERROR: --hostname required" >&2; exit 1; }
[[ -z "$ALERT_URL"   ]] && { echo "ERROR: --alert-url required (no existing conf found)" >&2; exit 1; }
[[ -z "$REPO_RAW"    ]] && { echo "ERROR: --repo required" >&2; exit 1; }
[[ -z "$LAN_SUBNET"  ]] && { echo "ERROR: --lan-subnet required" >&2; exit 1; }

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [bootstrap] $*" | tee -a "$LOG"; }

log "=== Bootstrap start: hostname=${VM_HOSTNAME} extra_ports=${EXTRA_PORTS:-none} ==="

# Capture extra SSH subnets from existing UFW rules before resetting (preserves manual additions)
SSH_EXTRA_SUBNETS=""
if ufw status 2>/dev/null | grep -q "^Status: active"; then
  SSH_EXTRA_SUBNETS=$(ufw status 2>/dev/null \
    | grep -E "22/tcp.*ALLOW" \
    | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?' \
    | grep -v "^${LAN_SUBNET}$" \
    | tr '\n' ',' | sed 's/,$//')
  [[ -n "$SSH_EXTRA_SUBNETS" ]] && log "  Preserving extra SSH subnets: ${SSH_EXTRA_SUBNETS}"
fi

# Derive staggered reboot time from cron minute (minute=0 → 02:00, minute=15 → 02:15, etc.)
REBOOT_TIME="02:$(printf '%02d' "$CRON_MINUTE")"

# 1. Packages
log "[1/7] Installing packages"
DEBIAN_FRONTEND=noninteractive apt-get install -y -q fail2ban ufw sysstat curl

# 2. UFW
log "[2/7] Configuring ufw"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow from "$LAN_SUBNET" to any port 22 proto tcp comment "SSH LAN"
if [[ -n "${SSH_EXTRA_SUBNETS:-}" ]]; then
  IFS=',' read -ra EXTRA_SSH <<< "$SSH_EXTRA_SUBNETS"
  for subnet in "${EXTRA_SSH[@]}"; do
    ufw allow from "$subnet" to any port 22 proto tcp comment "SSH extra"
    log "  ufw: restored SSH from ${subnet}"
  done
fi
if [[ -n "$EXTRA_PORTS" ]]; then
  IFS=',' read -ra PORTS <<< "$EXTRA_PORTS"
  for entry in "${PORTS[@]}"; do
    ufw allow "${entry}" comment "extra:${entry}"
    log "  ufw: allowed ${entry}"
  done
fi
ufw --force enable

# 3. fail2ban
log "[3/7] Configuring fail2ban"
cat > /etc/fail2ban/jail.local << 'JAILEOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ssh
filter   = sshd
maxretry = 5
bantime  = 3600
JAILEOF
systemctl enable fail2ban
systemctl restart fail2ban

# 4. unattended-upgrades auto-reboot drop-in
log "[4/7] Configuring unattended-upgrades auto-reboot (reboot at ${REBOOT_TIME})"
DEBIAN_FRONTEND=noninteractive apt-get install -y -q unattended-upgrades
cat > /etc/apt/apt.conf.d/52unattended-upgrades-local << UUEOF
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Automatic-Reboot-Time "${REBOOT_TIME}";
UUEOF
systemctl enable unattended-upgrades
systemctl start unattended-upgrades

# 5. Install helper scripts from repo
log "[5/7] Installing helper scripts"
for script in cron-wrapper weekly-upgrade disk-monitor security-audit self-update; do
  curl -fsSL "${REPO_RAW}/${script}.sh" -o "/tmp/vm-watchdog-${script}.sh"
  [[ -s "/tmp/vm-watchdog-${script}.sh" ]] || { log "ERROR: failed to download ${script}.sh"; exit 1; }
  install -m 750 "/tmp/vm-watchdog-${script}.sh" "/usr/local/sbin/${script}.sh"
  rm -f "/tmp/vm-watchdog-${script}.sh"
done

# 6. Cron drop-in
log "[6/7] Writing /etc/cron.d/vm-maintenance"
cat > /etc/cron.d/vm-maintenance << CRONEOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Disk space check + Uptime Kuma heartbeat (every 6 hours)
0 */6 * * *   root  /usr/local/sbin/cron-wrapper.sh /usr/local/sbin/disk-monitor.sh

# Daily security audit
30 4 * * *    root  /usr/local/sbin/cron-wrapper.sh /usr/local/sbin/security-audit.sh

# Weekly full apt upgrade (Sunday 3am, minute staggered per VM)
${CRON_MINUTE} 3 * * 0  root  /usr/local/sbin/cron-wrapper.sh /usr/local/sbin/weekly-upgrade.sh

# Monthly script self-update from repo
0 4 1 * *     root  /usr/local/sbin/cron-wrapper.sh /usr/local/sbin/self-update.sh
CRONEOF
chmod 644 /etc/cron.d/vm-maintenance

# 7. VM config and logrotate
log "[7/7] Writing /etc/vm-maintenance.conf and logrotate"
cat > /etc/vm-maintenance.conf << CONFEOF
VM_HOSTNAME=${VM_HOSTNAME}
ALERT_URL=${ALERT_URL}
DISK_THRESHOLD=85
REPO_URL=${REPO_RAW}
LAN_SUBNET=${LAN_SUBNET}
SSH_EXTRA_SUBNETS=${SSH_EXTRA_SUBNETS}
REBOOT_TIME=${REBOOT_TIME}
CONFEOF
chmod 600 /etc/vm-maintenance.conf

cat > /etc/logrotate.d/vm-maintenance << 'LREOF'
/var/log/vm-maintenance.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 640 root root
}
LREOF

log "=== Bootstrap complete: ufw=$(ufw status | head -1) | fail2ban=$(systemctl is-active fail2ban) ==="
