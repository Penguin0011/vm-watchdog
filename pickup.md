# vm-watchdog — Agent Pickup Notes

Last updated: 2026-05-22

## What This Repo Does
Decentralized, GitHub-backed maintenance automation for Ubuntu homelab VMs.
Each VM bootstraps itself from this repo, runs scheduled health checks, and pushes
heartbeats/alerts to Uptime Kuma (which fires Telegram notifications).

No central agent VM is required. Each VM is self-sufficient.

---

## Current State

### Done
- Full system designed, built, and deployed to all 4 VMs
- All hardcoding removed — VM inventory in `deploy/vms.conf`, infra config in `deploy/creds.env`
- 8 reliability fixes committed to `main` (commit `0464b8a`)
- **proxy VM successfully redeployed with all 8 fixes** (confirmed in bootstrap log)
- 4 deploy tooling bugs fixed (commits `96bb23c`, `7d3992a`, `d71605e`)

### Pending — Must Do Next
**VPN was down at last deploy attempt — reconnect VPN then re-run `deploy/deploy-all.sh`**
to push all fixes to immich, vpn, and openclaw. Proxy is already done.

---

## VM Inventory (deploy/vms.conf)

| Name | IP | SSH User | Extra Ports |
|------|-----|----------|-------------|
| proxy | 10.0.0.6 | proxymngr | 80/tcp,81/tcp,443/tcp,8443/tcp |
| immich | 10.0.0.22 | photos | — |
| vpn | 10.0.0.19 | vpn | 51820/udp |
| openclaw | 10.0.0.24 | claw | — |

SSH password for all VMs: `gmkwob`

---

## Infrastructure

| Service | Location | Access |
|---------|----------|--------|
| Uptime Kuma | http://10.0.0.7:3001 | admin / `74QZG*QpG0i^s49h*F8mT!` |
| Uptime Kuma (public) | https://uptime.clouddev.dad | — |
| GitHub repo | https://github.com/Penguin0011/vm-watchdog | — |
| Raw scripts base | https://raw.githubusercontent.com/Penguin0011/vm-watchdog/main | — |

Uptime Kuma host SSH: `sshpass -p 'gmkwob' ssh -o StrictHostKeyChecking=no uptime@10.0.0.7`

---

## Key Files

```
vm-watchdog/
├── vm-bootstrap.sh        # Idempotent bootstrap, run as root on any Ubuntu VM
├── cron-wrapper.sh        # Wraps cron jobs, alerts Uptime Kuma on failure
├── weekly-upgrade.sh      # Weekly apt upgrade (waits for apt lock)
├── disk-monitor.sh        # Every-6h disk check + Uptime Kuma heartbeat
├── security-audit.sh      # Daily audit: UFW, fail2ban, pending updates, ban alerts
├── self-update.sh         # Monthly: pulls latest scripts from GitHub (atomic, with retry)
└── deploy/
    ├── deploy-all.sh      # Parallel SSH deploy to all VMs in vms.conf
    ├── create-monitors.sh # Creates Uptime Kuma push monitors via SQLite
    ├── vms.conf           # GITIGNORED — your VM inventory
    ├── creds.env          # GITIGNORED — passwords, URLs, IDs
    ├── vms.conf.example   # Template
    └── creds.env.example  # Template
```

---

## How to Deploy

```bash
# 1. Connect VPN to homelab first (traffic routes via IPsec, source 10.70.0.33)
# 2. Then:
cd ~/Local\ Doccuments/vm-watchdog/deploy
bash deploy-all.sh
```

Logs per VM: `/tmp/vm-watchdog-deploy-<name>.log`

---

## On-VM Config (`/etc/vm-maintenance.conf`)

After bootstrap, each VM has:
```
VM_HOSTNAME=<name>
ALERT_URL=https://uptime.clouddev.dad/api/push/<token>
DISK_THRESHOLD=85
REPO_URL=https://raw.githubusercontent.com/Penguin0011/vm-watchdog/main
LAN_SUBNET=10.0.0.0/8
SSH_EXTRA_SUBNETS=<any non-LAN subnets preserved on re-run>
REBOOT_TIME=02:XX   (staggered by VM index: 02:00 / 02:15 / 02:30 / 02:45)
```

---

## Uptime Kuma Push Tokens (in SQLite, IDs 23-26)

| VM | Token |
|----|-------|
| proxy | `4121cc0b54e0384f02e39ea25bfc31b4` |
| immich | `df8e4c537ab4c35e31fc609e9d3a9b77` |
| vpn | `9f0df860a69819631ccceb3af7545efb` |
| openclaw | `d5e617bd29bc19b1006ab2524f6ae591` |

Monitor names in Uptime Kuma are capitalized (`Watchdog - Proxy` etc). The deploy scripts
use case-insensitive `LOWER()` matching so this is handled automatically.

---

## What the 8 Reliability Fixes Do

| # | Problem | Fix |
|---|---------|-----|
| 1 | UFW reset on re-run wiped manually-added SSH subnets | Extract IPv4 addresses with regex before reset, re-apply after |
| 2 | All 4 VMs rebooted at 2:00am simultaneously after kernel patches | Reboot time staggered: 02:00 / 02:15 / 02:30 / 02:45 |
| 3 | apt lock race (unattended-upgrades vs weekly-upgrade.sh) | weekly-upgrade.sh waits up to 10 min for lock release |
| 4 | Cron failures were silent (no alert) | cron-wrapper.sh wraps all jobs, POSTs down alert on non-zero exit |
| 5 | self-update.sh could corrupt a script mid-download | Atomic: download to mktemp → validate shebang → mv |
| 6 | Monthly self-update failed permanently if GitHub unreachable | 3 retry attempts with 5-min gaps |
| 7 | Re-running bootstrap without --alert-url overwrote push token | Read existing ALERT_URL from conf if arg not supplied |
| 9 | New fail2ban SSH bans never surfaced as alerts | security-audit.sh tracks ban count delta, alerts on increase |

---

## Deploy Tooling Bugs Fixed (found during deploy session)

- **UFW parser** (`vm-bootstrap.sh`): was using `awk $NF` which captured comment words like
  `LAN-only` instead of IP addresses. Fixed with IPv4 regex `[0-9]{1,3}\.[0-9]...`
- **Uptime Kuma case mismatch** (`create-monitors.sh`): monitors named `Watchdog - Proxy`
  weren't found when querying `Watchdog - proxy`. Fixed with `LOWER()` on both sides.
- **SSH stdin consuming vms.conf** (`create-monitors.sh`): SSH inside a while-read loop
  inherits the loop's stdin (the conf file) and consumes remaining lines after the first.
  Fixed with `-n` on the ssh command so SSH reads from /dev/null instead.
- **TOKENS_FILE deleted too early** (`deploy-all.sh`): file was deleted before all background
  deploy jobs had read their tokens. Moved `rm` to after the wait loop completes.

---

## Networking Note
Mac traffic to homelab routes through IPsec VPN. If deploys fail with
"Network is unreachable", the VPN needs to be reconnected.
Source IP when connected: `10.70.0.33` (subnet `10.70.0.0/16`, covered by `LAN_SUBNET=10.0.0.0/8`).
