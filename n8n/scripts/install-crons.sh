#!/bin/bash
# Idempotently install VPS-side cron jobs. Invoked by initialize.sh and deploy.yml.
set -euo pipefail

# NOTE: schedules run in the SYSTEM timezone (UTC on stock droplets) — Ubuntu's
# vixie-cron ignores a crontab TZ= for scheduling; it only sets the jobs' env
# (log timestamps render in DISPLAY_TZ).
CRON_TZ_VALUE="${DISPLAY_TZ:-UTC}"

# `crontab -l` exits 1 on a fresh system — wrap reads to survive set -e.
read_crontab() { crontab -l 2>/dev/null || true; }

# upsert_header KEY VALUE — replace or prepend a KEY= env line.
upsert_header() {
    local key="$1" value="$2"
    if read_crontab | grep -q "^${key}="; then
        read_crontab | sed "s|^${key}=.*|${key}=${value}|" | crontab -
        echo "  ↻ ${key} updated to ${value}"
    else
        { echo "${key}=${value}"; read_crontab; } | crontab -
        echo "  + ${key}=${value} added"
    fi
}

upsert_header "TZ" "$CRON_TZ_VALUE"
# Cron's default PATH is /usr/bin:/bin — without /usr/local/bin restic can't
# spawn rclone for the B2 leg (works over SSH, fails only under cron).
upsert_header "PATH" "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# install_cron <key-grep> <crontab-line> — replace-by-key so schedule changes
# in the repo propagate to an already-provisioned VPS.
install_cron() {
    local key="$1" line="$2"
    if read_crontab | grep -qF "$line"; then
        echo "  = $key already present"
    else
        { read_crontab | grep -vF "$key" || true; echo "$line"; } | crontab -
        echo "  + $key installed/updated"
    fi
}

install_cron "scripts/database/poll-publish-events.sh" \
    "* * * * * bash /root/n8n/scripts/database/poll-publish-events.sh >> /root/n8n/poll-publish.log 2>&1"

install_cron "scripts/database/prune-backups.sh" \
    "0 3 * * 0 bash /root/n8n/scripts/database/prune-backups.sh >> /root/n8n/backup.log 2>&1"

install_cron "scripts/disk-space-check.sh" \
    "0 * * * * bash /root/n8n/scripts/disk-space-check.sh >> /root/n8n/disk-check.log 2>&1"

install_cron "scripts/database/backup-database.sh" \
    "0 2 * * * bash /root/n8n/scripts/database/backup-database.sh >> /root/n8n/backup.log 2>&1"

echo "✅ Crons installed (schedules in system TZ/UTC; job env TZ=${CRON_TZ_VALUE})."
