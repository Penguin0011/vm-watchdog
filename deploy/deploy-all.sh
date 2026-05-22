#!/usr/bin/env bash
set -uo pipefail  # no -e: collect per-VM exit codes without aborting siblings

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS="${SCRIPT_DIR}/creds.env"
VMS_CONF="${SCRIPT_DIR}/vms.conf"

[[ -f "$CREDS"    ]] || { echo "ERROR: creds.env not found at ${CREDS} (copy from creds.env.example)"; exit 1; }
[[ -f "$VMS_CONF" ]] || { echo "ERROR: vms.conf not found at ${VMS_CONF} (copy from vms.conf.example)"; exit 1; }

# shellcheck source=/dev/null
source "$CREDS"

# Validate required vars — no hardcoded defaults
: "${VM_PASS:?VM_PASS not set in creds.env}"
: "${REPO_RAW:?REPO_RAW not set in creds.env}"
: "${LAN_SUBNET:?LAN_SUBNET not set in creds.env}"
: "${UPTIME_HOST:?UPTIME_HOST not set in creds.env}"
: "${UPTIME_USER:?UPTIME_USER not set in creds.env}"
: "${UPTIME_PASS:?UPTIME_PASS not set in creds.env}"
: "${UPTIME_BASE_URL:?UPTIME_BASE_URL not set in creds.env}"

command -v sshpass &>/dev/null || { echo "ERROR: sshpass not installed (apt install sshpass / brew install sshpass)"; exit 1; }

echo "=== Step 1: Creating Uptime Kuma push monitors ==="
TOKENS_FILE=$(mktemp)
export UPTIME_HOST UPTIME_USER UPTIME_PASS UPTIME_BASE_URL \
       UPTIME_CONTAINER UPTIME_DB_PATH NOTIFICATION_ID USER_ID VMS_CONF
bash "${SCRIPT_DIR}/create-monitors.sh" > "$TOKENS_FILE"
echo ""

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o PubkeyAuthentication=no -o PasswordAuthentication=yes"

deploy_vm() {
  local name="$1" ip="$2" user="$3" extra_ports="$4" cron_minute="$5"

  # Look up push token from tokens file
  local token
  token=$(grep "^${name}=" "$TOKENS_FILE" | cut -d= -f2)
  [[ -n "$token" ]] || { echo "[FAIL] ${name}: no push token found"; return 1; }

  local push_url="${UPTIME_BASE_URL}/api/push/${token}"
  local logfile="/tmp/vm-watchdog-deploy-${name}.log"

  local bootstrap_args="--hostname ${name} --alert-url ${push_url} --repo ${REPO_RAW} --lan-subnet ${LAN_SUBNET} --cron-minute ${cron_minute}"
  [[ -n "$extra_ports" ]] && bootstrap_args="${bootstrap_args} --extra-ports ${extra_ports}"

  echo "[$(date '+%H:%M:%S')] Starting deploy → ${name} (${ip})"

  SSHPASS="$VM_PASS" sshpass -e ssh $SSH_OPTS "${user}@${ip}" \
    "echo '${VM_PASS}' | sudo -S bash -c 'curl -fsSL \"${REPO_RAW}/vm-bootstrap.sh\" | bash -s -- ${bootstrap_args}'" \
    > "$logfile" 2>&1
}

echo "=== Step 2: Deploying to all VMs in parallel ==="

PIDS=()
VM_NAMES_LIST=()
vm_index=0

while IFS= read -r line || [[ -n "$line" ]]; do
  # Skip comments and blank lines
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line// }" ]] && continue

  IFS=':' read -r name ip user extra_ports <<< "$line"
  extra_ports="${extra_ports:-}"

  # Auto-stagger cron minutes: 0, 15, 30, 45, 0, 15, ...
  cron_minute=$(( (vm_index * 15) % 60 ))

  deploy_vm "$name" "$ip" "$user" "$extra_ports" "$cron_minute" &
  PIDS+=($!)
  VM_NAMES_LIST+=("$name")

  vm_index=$(( vm_index + 1 ))
done < "$VMS_CONF"

rm -f "$TOKENS_FILE"

if [[ ${#PIDS[@]} -eq 0 ]]; then
  echo "ERROR: no VMs found in vms.conf"
  exit 1
fi

echo ""
echo "=== Waiting for deploys to complete ==="
FAILURES=0
for i in "${!PIDS[@]}"; do
  wait "${PIDS[$i]}"
  code=$?
  name="${VM_NAMES_LIST[$i]}"
  logfile="/tmp/vm-watchdog-deploy-${name}.log"
  if [[ $code -eq 0 ]]; then
    echo "[OK]   ${name}"
  else
    echo "[FAIL] ${name} (exit ${code}) — see ${logfile}"
    FAILURES=$(( FAILURES + 1 ))
  fi
done

echo ""
echo "=== Deploy summary: $(( ${#VM_NAMES_LIST[@]} - FAILURES ))/${#VM_NAMES_LIST[@]} succeeded ==="

if [[ $FAILURES -gt 0 ]]; then
  echo "Check logs in /tmp/vm-watchdog-deploy-*.log for details"
  exit 1
fi
