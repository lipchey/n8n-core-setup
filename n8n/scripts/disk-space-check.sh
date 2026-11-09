#!/bin/bash
# Hourly cron: disk usage alert via Resend at MEDIUM/HIGH thresholds.
set -euo pipefail

_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$_SCRIPTS_DIR/lib/common.sh"

LOG="/root/n8n/disk-check.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

if ! load_backup_creds --optional; then
  echo "${TIMESTAMP}: .backup_creds missing — skipping disk check (run a deploy first)." >> "$LOG"
  exit 0
fi

# shellcheck source=lib/notify.sh
. "$LIB_DIR/notify.sh"

THRESHOLD_MEDIUM="${ALERT_DISK_THRESHOLD_MEDIUM:-85}"
THRESHOLD_HIGH="${ALERT_DISK_THRESHOLD_HIGH:-95}"
RECIPIENT="${DEVELOPER_EMAIL:-}"

USAGE=$(df -P / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
FREE=$((100 - USAGE))

LEVEL=""
if [ "$USAGE" -ge "$THRESHOLD_HIGH" ]; then
  LEVEL="HIGH"
elif [ "$USAGE" -ge "$THRESHOLD_MEDIUM" ]; then
  LEVEL="MEDIUM"
fi

if [ -z "$LEVEL" ]; then
  echo "${TIMESTAMP}: OK used=${USAGE}% free=${FREE}% (medium≥${THRESHOLD_MEDIUM}% high≥${THRESHOLD_HIGH}%)" >> "$LOG"
  exit 0
fi

echo "${TIMESTAMP}: ${LEVEL} ALERT used=${USAGE}% free=${FREE}% (medium≥${THRESHOLD_MEDIUM}% high≥${THRESHOLD_HIGH}%)" >> "$LOG"

if ! email_configured; then
  echo "${TIMESTAMP}: Email not configured (RESEND_API_KEY/RESEND_FROM_EMAIL/DEVELOPER_EMAIL) — no email sent." >> "$LOG"
  exit 0
fi

HOST_NAME=$(hostname)
[ "$LEVEL" = "HIGH" ] && EMOJI="🚨" || EMOJI="⚠️"

SUBJECT=$(printf '%s [%s] Disk %s%% used on %s' "$EMOJI" "$LEVEL" "$USAGE" "${PROJECT_NAME:-$HOST_NAME}")
BODY=$(
  printf '%s disk space alert on %s (%s)\n\n' "$LEVEL" "${PROJECT_NAME:-$HOST_NAME}" "$HOST_NAME"
  printf 'Used:             %s%%\n' "$USAGE"
  printf 'Free:             %s%%\n' "$FREE"
  printf 'MEDIUM threshold: >= %s%% used\n' "$THRESHOLD_MEDIUM"
  printf 'HIGH threshold:   >= %s%% used\n\n' "$THRESHOLD_HIGH"
  df -h /
)

if send_email "$SUBJECT" "$BODY" "$RECIPIENT" 2>>"$LOG"; then
  echo "${TIMESTAMP}: ${LEVEL} alert email sent to ${RECIPIENT}." >> "$LOG"
else
  echo "${TIMESTAMP}: FAILED to send email via Resend (see error above in this log)." >> "$LOG"
fi
