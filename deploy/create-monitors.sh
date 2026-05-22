#!/usr/bin/env bash
set -euo pipefail

# Creates Uptime Kuma push monitors for all VMs in vms.conf via SQLite.
# Idempotent — skips creation if a monitor with the same name already exists.
# Outputs: "hostname=push_token" lines to stdout (stderr gets progress messages).
#
# Required env vars (all sourced from creds.env via deploy-all.sh):
#   UPTIME_HOST, UPTIME_USER, UPTIME_PASS, UPTIME_BASE_URL
#   UPTIME_CONTAINER, UPTIME_DB_PATH, NOTIFICATION_ID, USER_ID, VMS_CONF

: "${UPTIME_HOST:?UPTIME_HOST not set}"
: "${UPTIME_USER:?UPTIME_USER not set}"
: "${UPTIME_PASS:?UPTIME_PASS not set}"
: "${UPTIME_BASE_URL:?UPTIME_BASE_URL not set}"
: "${UPTIME_CONTAINER:?UPTIME_CONTAINER not set}"
: "${UPTIME_DB_PATH:?UPTIME_DB_PATH not set}"
: "${NOTIFICATION_ID:?NOTIFICATION_ID not set}"
: "${USER_ID:?USER_ID not set}"
: "${VMS_CONF:?VMS_CONF not set}"

[[ -f "$VMS_CONF" ]] || { echo "ERROR: vms.conf not found at ${VMS_CONF}" >&2; exit 1; }

HEARTBEAT_INTERVAL=25200  # 7 hours in seconds

ssh_exec() {
  SSHPASS="$UPTIME_PASS" sshpass -e ssh \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 \
    "${UPTIME_USER}@${UPTIME_HOST}" "$@"
}

db_query() {
  ssh_exec "echo '${UPTIME_PASS}' | sudo -S docker exec ${UPTIME_CONTAINER} sqlite3 ${UPTIME_DB_PATH} \"$1\""
}

create_or_get_monitor() {
  local key="$1"
  local monitor_name="Watchdog - ${key}"

  local existing_token
  existing_token=$(db_query "SELECT push_token FROM monitor WHERE name='${monitor_name}' AND type='push' LIMIT 1;" 2>/dev/null || true)

  if [[ -n "$existing_token" ]]; then
    echo "  [skip] '${monitor_name}' already exists" >&2
    echo "${key}=${existing_token}"
    return
  fi

  local token
  token=$(openssl rand -hex 16)

  local monitor_id
  monitor_id=$(db_query "INSERT INTO monitor (name, type, active, user_id, interval, push_token) VALUES ('${monitor_name}', 'push', 1, ${USER_ID}, ${HEARTBEAT_INTERVAL}, '${token}'); SELECT last_insert_rowid();" 2>/dev/null)

  local notif_row_id
  notif_row_id=$(db_query "SELECT COALESCE(MAX(id),0)+1 FROM monitor_notification;" 2>/dev/null)

  db_query "INSERT INTO monitor_notification (id, monitor_id, notification_id) VALUES (${notif_row_id}, ${monitor_id}, ${NOTIFICATION_ID});" 2>/dev/null

  echo "  [created] '${monitor_name}' → token: ${token}" >&2
  echo "${key}=${token}"
}

# Read VM names from vms.conf (first field of each non-comment line)
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line// }" ]] && continue

  name=$(echo "$line" | cut -d: -f1)
  [[ -n "$name" ]] && create_or_get_monitor "$name"
done < "$VMS_CONF"
