#!/usr/bin/env bash
set -uo pipefail  # no -e: collect per-VM exit codes without aborting siblings

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS="${SCRIPT_DIR}/creds.env"

[[ -f "$CREDS" ]] || { echo "ERROR: creds.env not found at ${CREDS}"; exit 1; }
source "$CREDS"

command -v sshpass &>/dev/null || { echo "ERROR: sshpass not installed (apt install sshpass)"; exit 1; }

UPTIME_BASE_URL="${UPTIME_BASE_URL:-https://uptime.clouddev.dad}"
REPO_RAW="https://raw.githubusercontent.com/Penguin0011/Vm-watchdog/main"

echo "=== Step 1: Creating Uptime Kuma push monitors ==="
TOKENS_FILE=$(mktemp)
export UPTIME_HOST UPTIME_USER UPTIME_PASS UPTIME_BASE_URL NOTIFICATION_ID USER_ID
bash "${SCRIPT_DIR}/create-monitors.sh" > "$TOKENS_FILE"
echo ""

# Parse tokens file into associative array
declare -A PUSH_TOKENS
while IFS='=' read -r key val; do
  PUSH_TOKENS["$key"]="$val"
done < "$TOKENS_FILE"
rm -f "$TOKENS_FILE"

# Verify we got tokens for all VMs
for vm in proxy immich vpn openclaw; do
  [[ -n "${PUSH_TOKENS[$vm]:-}" ]] || { echo "ERROR: no push token for $vm"; exit 1; }
done

echo "=== Step 2: Deploying to all VMs in parallel ==="

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o UserKnownHostsFile=${HOME}/.ssh/known_hosts"

deploy_vm() {
  local name="$1" ip="$2" user="$3" extra_ports="$4" cron_minute="$5"
  local token="${PUSH_TOKENS[$name]}"
  local push_url="${UPTIME_BASE_URL}/api/push/${token}"
  local logfile="/tmp/vm-watchdog-deploy-${name}.log"

  local bootstrap_args="--hostname ${name} --alert-url '${push_url}' --cron-minute ${cron_minute}"
  [[ -n "$extra_ports" ]] && bootstrap_args="${bootstrap_args} --extra-ports '${extra_ports}'"

  echo "[$(date '+%H:%M:%S')] Starting deploy → ${name} (${ip})"

  SSHPASS="$VM_PASS" sshpass -e ssh $SSH_OPTS "${user}@${ip}" \
    "curl -fsSL '${REPO_RAW}/vm-bootstrap.sh' | sudo bash -s -- ${bootstrap_args}" \
    > "$logfile" 2>&1
}

PIDS=()
VM_NAMES=()

deploy_vm "proxy"    "10.0.0.6"  "proxymngr" "80/tcp,443/tcp,8443/tcp" "0"  & PIDS+=($!); VM_NAMES+=("proxy")
deploy_vm "immich"   "10.0.0.22" "photos"    ""                         "15" & PIDS+=($!); VM_NAMES+=("immich")
deploy_vm "vpn"      "10.0.0.19" "vpn"       "51820/udp"               "30" & PIDS+=($!); VM_NAMES+=("vpn")
deploy_vm "openclaw" "10.0.0.24" "claw"      ""                         "45" & PIDS+=($!); VM_NAMES+=("openclaw")

echo ""
echo "=== Waiting for deploys to complete ==="
FAILURES=0
for i in "${!PIDS[@]}"; do
  wait "${PIDS[$i]}"
  code=$?
  name="${VM_NAMES[$i]}"
  logfile="/tmp/vm-watchdog-deploy-${name}.log"
  if [[ $code -eq 0 ]]; then
    echo "[OK]   ${name}"
  else
    echo "[FAIL] ${name} (exit ${code}) — see ${logfile}"
    FAILURES=$((FAILURES + 1))
  fi
done

echo ""
echo "=== Deploy summary: $((${#VM_NAMES[@]} - FAILURES))/${#VM_NAMES[@]} succeeded ==="

if [[ $FAILURES -gt 0 ]]; then
  echo ""
  echo "Check logs in /tmp/vm-watchdog-deploy-*.log for details"
  exit 1
fi
