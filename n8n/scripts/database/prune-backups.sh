#!/bin/bash
# Weekly retention + integrity check on local and (if configured) B2 restic repos.
# B2 Object Lock (30-day governance) protects recent snapshots even from VPS.
set -euo pipefail

_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$_SCRIPTS_DIR/lib/common.sh"
# shellcheck source=../lib/restic-env.sh
. "$_SCRIPTS_DIR/lib/restic-env.sh"

load_backup_creds BACKUP_PASSWORD PROJECT_NAME RESTIC_REPOSITORY
require_cmds flock
setup_restic_local

# Never prune while a backup/restore is running — lock contention corrupts nothing
# but wastes the weekly window; waiting up to 30 min is cheaper than skipping.
exec 8>/root/n8n/.backup.lock
flock -w 1800 8 || die "backup lock busy for 30 min — skipping prune this week"

# Adaptive retention by free disk % on the repo partition.
FREE_PCT=$(df -P "$RESTIC_REPOSITORY" 2>/dev/null \
    | awk 'NR==2 { gsub(/%/,"",$5); print 100 - $5 }')
[ -n "$FREE_PCT" ] || FREE_PCT=50

if   [ "$FREE_PCT" -lt 10 ]; then
    KEEP_DAILY=3;  KEEP_WEEKLY=2; KEEP_MONTHLY=2; TIER_LABEL="aggressive (free <10%)"
elif [ "$FREE_PCT" -lt 25 ]; then
    KEEP_DAILY=5;  KEEP_WEEKLY=3; KEEP_MONTHLY=4; TIER_LABEL="moderate (free <25%)"
elif [ "$FREE_PCT" -lt 50 ]; then
    KEEP_DAILY=7;  KEEP_WEEKLY=4; KEEP_MONTHLY=6; TIER_LABEL="default (free <50%)"
else
    KEEP_DAILY=14; KEEP_WEEKLY=8; KEEP_MONTHLY=12; TIER_LABEL="relaxed (free ≥50%)"
fi

echo "🧹 Free space on repo partition: ${FREE_PCT}% → tier: ${TIER_LABEL}"
echo "    Retention: ${KEEP_DAILY} daily / ${KEEP_WEEKLY} weekly / ${KEEP_MONTHLY} monthly"
restic -r "$RESTIC_REPOSITORY" forget --prune \
    --keep-daily "$KEEP_DAILY" \
    --keep-weekly "$KEEP_WEEKLY" \
    --keep-monthly "$KEEP_MONTHLY" \
    --host "$PROJECT_NAME" \
    --tag "n8n-db"
echo "✅ Retention applied."

echo "🔍 Running integrity check (5% data sample)..."
restic -r "$RESTIC_REPOSITORY" check --no-lock --read-data-subset 5%
echo "✅ Integrity check passed."

if setup_restic_b2; then
    # rclone:b2: + 30-day governance Object Lock: restic's end-of-forget lock-delete
    # AND its prune-time pack-delete both 401; --no-lock is ignored for write ops.
    # Collapse rclone retries so failures surface in ~30s.
    # Pack files <30d age out of governance naturally; later prune runs catch up.
    case "$RESTIC_REPOSITORY_BACKBLAZE" in
      rclone:*) export RCLONE_RETRIES=1 RCLONE_LOW_LEVEL_RETRIES=1 ;;
    esac
    echo "🧹 Applying retention (7 daily / 4 weekly / 6 monthly) to B2: ${RESTIC_REPOSITORY_BACKBLAZE} ..."
    echo "   Note: pack files <30d are governance-locked; actual deletion happens on later runs."
    B2_FORGET_RC=0
    restic -r "$RESTIC_REPOSITORY_BACKBLAZE" forget --prune \
        --keep-daily 7 \
        --keep-weekly 4 \
        --keep-monthly 6 \
        --host "$PROJECT_NAME" \
        --tag "n8n-db" || B2_FORGET_RC=$?
    if [ "$B2_FORGET_RC" -eq 0 ]; then
        echo "✅ B2 retention pass completed."
    else
        # A governance refusal and an auth/transport error exit alike, so neither reads as expected.
        log "❌ B2 retention failed (restic exit ${B2_FORGET_RC}) — check the restic output above"
    fi
    # Metadata-only: B2 verifies pack checksums on upload; --read-data-subset adds bandwidth cost for little gain.
    echo "🔍 Running B2 metadata integrity check..."
    restic -r "$RESTIC_REPOSITORY_BACKBLAZE" check --no-lock
    echo "✅ B2 integrity check passed."
    [ "$B2_FORGET_RC" -eq 0 ] || exit "$B2_FORGET_RC"
fi
