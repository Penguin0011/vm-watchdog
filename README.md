# Vm-watchdog

Portable VM maintenance automation for Ubuntu homelab VMs. Fully decentralized — each VM runs its own cron jobs and reports directly to Uptime Kuma. No central controller required at runtime.

## What it does on each VM

| Schedule | Task |
|---|---|
| Every 6h | Disk space check + Uptime Kuma heartbeat |
| Daily 4:30am | Security audit (fail2ban, ufw, failed SSH attempts) |
| Sunday 3am | Full `apt upgrade` |
| Monthly | Pull latest scripts from GitHub |
| Daily 2am | Auto-reboot if kernel security patch was applied |

Security hardening applied once:
- **ufw**: deny all incoming, allow SSH from your LAN subnet only
- **fail2ban**: SSH jail, 5 failures → 1h ban

## Setup

### 1. Clone or fork this repo

```bash
git clone https://github.com/YOUR-USER/Vm-watchdog.git
cd Vm-watchdog/deploy
```

### 2. Configure your inventory and credentials

```bash
cp vms.conf.example vms.conf
cp creds.env.example creds.env
```

Edit `vms.conf` — one VM per line:
```
# name:ip:ssh_user:extra_ufw_ports
proxy:192.168.1.10:admin:80/tcp,443/tcp
mediaserver:192.168.1.11:ubuntu:
vpn:192.168.1.12:vpn:51820/udp
```

Edit `creds.env` — fill in your SSH password, repo URL, LAN subnet, and Uptime Kuma details.

Both files are gitignored and never committed.

### 3. Deploy to all VMs

```bash
bash deploy-all.sh
```

This will:
1. Create Uptime Kuma push monitors for each VM (idempotent)
2. Deploy the bootstrap to all VMs in parallel

## Bootstrap a single VM manually

```bash
curl -sSL https://raw.githubusercontent.com/YOUR-USER/Vm-watchdog/main/vm-bootstrap.sh \
  | sudo bash -s -- \
    --hostname myhostname \
    --alert-url "https://your-uptime-kuma.com/api/push/TOKEN" \
    --repo "https://raw.githubusercontent.com/YOUR-USER/Vm-watchdog/main" \
    --lan-subnet "10.0.0.0/8" \
    --extra-ports "80/tcp,443/tcp"   # optional
```

## Logs

All maintenance activity logs to `/var/log/vm-maintenance.log` on each VM (weekly rotation, 4 weeks retained).

## Config on each VM

After bootstrap, `/etc/vm-maintenance.conf` holds the VM's identity and repo reference:

```
VM_HOSTNAME=myvm
ALERT_URL=https://your-uptime-kuma.com/api/push/TOKEN
DISK_THRESHOLD=85
REPO_URL=https://raw.githubusercontent.com/YOUR-USER/Vm-watchdog/main
LAN_SUBNET=10.0.0.0/8
```

The monthly self-update reads `REPO_URL` from this file, so forking the repo and pointing `REPO_RAW` to your fork in `creds.env` is all that's needed.
