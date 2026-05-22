# Vm-watchdog

Portable VM maintenance automation for Ubuntu homelab VMs. Fully decentralized — each VM runs its own cron jobs and reports directly to Uptime Kuma. No central controller required.

## What it does on each VM

| Schedule | Task |
|---|---|
| Every 6h | Disk space check + Uptime Kuma heartbeat |
| Daily 4:30am | Security audit (fail2ban, ufw, failed SSH attempts) |
| Sunday 3am | Full `apt upgrade` |
| Monthly | Pull latest scripts from GitHub |
| Daily 2am | Auto-reboot if kernel security patch was applied |

Security hardening applied once:
- **ufw**: deny all incoming, allow SSH from LAN only (`10.0.0.0/24`)
- **fail2ban**: SSH jail, 5 failures → 1h ban

## Bootstrap a new VM

```bash
curl -sSL https://raw.githubusercontent.com/Penguin0011/Vm-watchdog/main/vm-bootstrap.sh \
  | sudo bash -s -- \
    --hostname myhostname \
    --alert-url "https://uptime.website.com/api/push/YOUR_TOKEN" \
    --extra-ports "80/tcp,443/tcp" \   # optional
    --cron-minute 0                    # optional, stagger weekly upgrades
```

## Deploy to all VMs at once (from any machine with sshpass)

```bash
cd deploy/
cp creds.env.example creds.env
# Edit creds.env with your passwords
chmod 600 creds.env
bash deploy-all.sh
```

`deploy-all.sh` will:
1. Create Uptime Kuma push monitors (Telegram notification auto-attached)
2. Deploy to VMs in parallel

## Logs

All maintenance activity logs to `/var/log/vm-maintenance.log` on each VM (weekly rotation, 4 weeks retained).
