#!/usr/bin/env bash
set -euo pipefail

# Run as root on any Ubuntu VM to install the Vm-watchdog maintenance system.
# Idempotent — safe to re-run.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/Penguin0011/Vm-watchdog/main/vm-bootstrap.sh \
#     | sudo bash -s -- --hostname proxy --alert-url "https://uptime.clouddev.dad/api/push/TOKEN" \
#                       --extra-ports "80/tcp,443/tcp" --cron-minute 0

REPO_RAW="https://raw.githubusercontent.com/Penguin0011/Vm-watchdog/main"
LAN_SUBNET="10.0.0.0/8"
VM_HOSTNAME=""
ALERT_URL=""
EXTRA_PORTS=""
CRON_MINUTE="0"
LOG="/var/log/vm-maintenance.log"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname)    VM_HOSTNAME="$2";   shift 2 ;;
    --alert-url)   ALERT_URL="$2";     shift 2 ;;
    --extra-ports) EXTRA_PORTS="$2";   shift 2 ;;
    --cron-minute) CRON_MINUTE="$2";   shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$VM_HOSTNAME" ]] && { echo "ERROR: --hostname required" >&2; exit 1; }
[[ -z "$ALERT_URL"   ]] && { echo "ERROR: --alert-url required" >&2; exit 1; }

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [bootstrap] $*" | tee -a "$LOG"; }

log "=== Bootstrap start: hostname=${VM_HOSTNAME} extra_ports=${EXTRA_PORTS:-none} ==="

# 1. Packages
log "[1/7] Installing packages"
DEBIAN_FRONTEND=noninteractive apt-get install -y -q fail2ban ufw sysstat curl

# 2. UFW
log "[2/7] Configuring ufw"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow from "$LAN_SUBNET" to any port 22 proto tcp comment "SSH LAN-only"
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
log "[4/7] Configuring unattended-upgrades auto-reboot"
DEBIAN_FRONTEND=noninteractive apt-get install -y -q unattended-upgrades
cat > /etc/apt/apt.conf.d/52unattended-upgrades-local << 'UUEOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Automatic-Reboot-Time "02:00";
UUEOF
systemctl enable unattended-upgrades
systemctl start unattended-upgrades

# 5. Install helper scripts from GitHub
log "[5/7] Installing helper scripts from GitHub"
for script in weekly-upgrade disk-monitor security-audit self-update; do
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
0 */6 * * *   root  /usr/local/sbin/disk-monitor.sh

# Daily security audit
30 4 * * *    root  /usr/local/sbin/security-audit.sh

# Weekly full apt upgrade (Sunday 3am, minute staggered per VM)
${CRON_MINUTE} 3 * * 0  root  /usr/local/sbin/weekly-upgrade.sh

# Monthly script self-update from GitHub (1st of month, 4am)
0 4 1 * *     root  /usr/local/sbin/self-update.sh
CRONEOF
chmod 644 /etc/cron.d/vm-maintenance

# 7. VM config and logrotate
log "[7/7] Writing /etc/vm-maintenance.conf and logrotate"
cat > /etc/vm-maintenance.conf << CONFEOF
VM_HOSTNAME=${VM_HOSTNAME}
ALERT_URL=${ALERT_URL}
DISK_THRESHOLD=85
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
