#!/usr/bin/env bash
set -euo pipefail

# Creates Uptime Kuma push monitors for all Vm-watchdog VMs via SQLite.
# Idempotent — skips creation if a monitor with the same name already exists.
# Outputs: "hostname=push_token" lines to stdout.
#
# Requires: UPTIME_HOST, UPTIME_USER, UPTIME_PASS in env (sourced from creds.env)

: "${UPTIME_HOST:?UPTIME_HOST not set}"
: "${UPTIME_USER:?UPTIME_USER not set}"
: "${UPTIME_PASS:?UPTIME_PASS not set}"

UPTIME_BASE_URL="${UPTIME_BASE_URL:-https://uptime.clouddev.dad}"
NOTIFICATION_ID="${NOTIFICATION_ID:-4}"
USER_ID="${USER_ID:-1}"
HEARTBEAT_INTERVAL=25200  # 7 hours

DOCKER_CMD="echo '${UPTIME_PASS}' | sudo -S docker exec uptime-kuma sqlite3 /app/data/kuma.db"

ssh_exec() {
  SSHPASS="$UPTIME_PASS" sshpass -e ssh \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 \
    "${UPTIME_USER}@${UPTIME_HOST}" "$@"
}

declare -A VM_NAMES=(
  [proxy]="Watchdog - Proxy"
  [immich]="Watchdog - Immich"
  [vpn]="Watchdog - VPN"
  [openclaw]="Watchdog - OpenClaw"
)

for key in proxy immich vpn openclaw; do
  MONITOR_NAME="${VM_NAMES[$key]}"

  # Check if monitor already exists
  EXISTING_TOKEN=$(ssh_exec \
    "echo '${UPTIME_PASS}' | sudo -S docker exec uptime-kuma sqlite3 /app/data/kuma.db \
    \"SELECT push_token FROM monitor WHERE name='${MONITOR_NAME}' AND type='push' LIMIT 1;\"" \
    2>/dev/null || true)

  if [[ -n "$EXISTING_TOKEN" ]]; then
    echo "${key}=${EXISTING_TOKEN}" >&2
    echo "  [skip] '${MONITOR_NAME}' already exists" >&2
    echo "${key}=${EXISTING_TOKEN}"
    continue
  fi

  # Generate token and insert
  TOKEN=$(openssl rand -hex 16)

  MONITOR_ID=$(ssh_exec \
    "echo '${UPTIME_PASS}' | sudo -S docker exec uptime-kuma sqlite3 /app/data/kuma.db \
    \"INSERT INTO monitor (name, type, active, user_id, interval, push_token) \
      VALUES ('${MONITOR_NAME}', 'push', 1, ${USER_ID}, ${HEARTBEAT_INTERVAL}, '${TOKEN}'); \
      SELECT last_insert_rowid();\"" 2>/dev/null)

  # Link to Telegram notification
  NOTIF_ROW_ID=$(ssh_exec \
    "echo '${UPTIME_PASS}' | sudo -S docker exec uptime-kuma sqlite3 /app/data/kuma.db \
    \"SELECT COALESCE(MAX(id),0)+1 FROM monitor_notification;\"" 2>/dev/null)

  ssh_exec \
    "echo '${UPTIME_PASS}' | sudo -S docker exec uptime-kuma sqlite3 /app/data/kuma.db \
    \"INSERT INTO monitor_notification (id, monitor_id, notification_id) \
      VALUES (${NOTIF_ROW_ID}, ${MONITOR_ID}, ${NOTIFICATION_ID});\"" 2>/dev/null

  echo "  [created] '${MONITOR_NAME}' → token=${TOKEN}" >&2
  echo "${key}=${TOKEN}"
done
