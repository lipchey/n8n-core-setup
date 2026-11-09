#!/bin/bash
set -euo pipefail

# pg_dump output is plaintext SQL — keep the temp file mode 600.
umask 077

_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$_SCRIPTS_DIR/lib/common.sh"
# shellcheck source=../lib/restic-env.sh
. "$_SCRIPTS_DIR/lib/restic-env.sh"

load_backup_creds BACKUP_PASSWORD DB_USER PROJECT_NAME RESTIC_REPOSITORY
require_cmds docker jq gzip tar flock
setup_restic_local

# One backup/restore at a time — a hung B2 upload must not collide with the
# next night's cron (its staging wipe would yank files out from under restic).
exec 8>/root/n8n/.backup.lock
flock -n 8 || { log "another backup/restore holds the lock — skipping this run"; exit 0; }

# Fixed staging path so restore-database.sh can reference the snapshot members
# by absolute path. Rebuilt each run; wiped on exit.
STAGING="/root/n8n/.backup-staging"
rm -rf "$STAGING"; mkdir -p "$STAGING"
trap 'rm -rf "$STAGING"' EXIT

echo "📦 Dumping database..."
DB_NAME=$(docker exec n8n_postgres printenv POSTGRES_DB)
[[ "$DB_NAME" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || die "DB_NAME '$DB_NAME' contains invalid characters — aborting"
# pg_dump instead of pg_dumpall: single-database dump avoids role DDL (DROP ROLE
# for the current user errors on restore). --create adds CREATE DATABASE + \connect.
docker exec n8n_postgres pg_dump -U "$DB_USER" -d "$DB_NAME" \
    --create --clean --if-exists | gzip > "$STAGING/n8n_db.sql.gz"

# Read/Write File node writes here (N8N_RESTRICT_FILE_ACCESS_TO sandbox path) — tar so workflow artifacts ride with the snapshot.
# Discover the real mountpoint — a custom Docker data-root moves this off the /var/lib/docker default.
N8N_FILES_VOL="$(docker volume inspect n8n_app_files --format '{{ .Mountpoint }}' 2>/dev/null || true)"
[ -n "$N8N_FILES_VOL" ] || N8N_FILES_VOL="/var/lib/docker/volumes/n8n_app_files/_data"
if [ -d "$N8N_FILES_VOL" ] && [ -n "$(ls -A "$N8N_FILES_VOL" 2>/dev/null)" ]; then
    echo "📦 Archiving n8n files volume..."
    tar czf "$STAGING/n8n_files.tar.gz" -C "$N8N_FILES_VOL" .
else
    echo "ℹ️  n8n files volume empty or absent — skipping."
fi

# Guard against a silently empty staging dir producing a useless snapshot.
STAGE_SIZE=$(du -sb "$STAGING" 2>/dev/null | cut -f1 || echo 0)
[ "${STAGE_SIZE:-0}" -gt 1000 ] || die "Staging dir too small (${STAGE_SIZE} bytes) — aborting to avoid a corrupt snapshot"

# A local-repo failure must not cost the offsite copy: record it, try B2, fail at the end.
LOCAL_BACKUP_FAILED=0
echo "📦 Pushing snapshot to $RESTIC_REPOSITORY (${STAGE_SIZE} bytes staged)..."
if restic -r "$RESTIC_REPOSITORY" backup "$STAGING" \
    --host "$PROJECT_NAME" \
    --tag "n8n-db"; then
    # `|| true` inside the substitution: under pipefail a restic failure would
    # otherwise kill the script BEFORE the guard prints its diagnostic.
    SNAP_ID=$(restic -r "$RESTIC_REPOSITORY" snapshots --latest 1 --tag n8n-db --host "$PROJECT_NAME" --json 2>/dev/null \
        | jq -r '.[0].id // empty' || true)
    if [ -n "$SNAP_ID" ]; then
        echo "✅ Snapshot ${SNAP_ID:0:8} confirmed."
    else
        log "❌ Snapshot not found after backup — restic repository may be corrupt"
        LOCAL_BACKUP_FAILED=1
    fi
else
    log "❌ Local restic backup failed — still attempting the Backblaze copy"
    LOCAL_BACKUP_FAILED=1
fi
# Retention pruning runs from prune-backups.sh weekly cron — never inline,
# to avoid lock contention with the next backup.

if setup_restic_b2; then
  # Kill restic once "snapshot … saved" prints — B2 governance 401s the end-of-run lock-file delete and would otherwise hang.
  echo "☁️  Pushing snapshot to Backblaze: ${RESTIC_REPOSITORY_BACKBLAZE} ..."
  B2_BACKUP_LOG=$(mktemp); trap 'rm -rf "$STAGING" "$B2_BACKUP_LOG"' EXIT
  # Retry: under load rclone+B2-auth can exceed restic's connect timeout, exiting (no lock) before any snapshot — transient, so retry; a real stall still trips B2_TIMEOUT_SECS below.
  B2_ATTEMPTS=${B2_ATTEMPTS:-3}
  SNAP_ID_BACKBLAZE=""
  for _b2_try in $(seq 1 "$B2_ATTEMPTS"); do
    : > "$B2_BACKUP_LOG"   # fresh log so the "snapshot … saved" grep can't match a prior attempt
    restic -r "$RESTIC_REPOSITORY_BACKBLAZE" backup "$STAGING" \
        --host "$PROJECT_NAME" \
        --tag "n8n-db" > "$B2_BACKUP_LOG" 2>&1 &
    RESTIC_PID=$!
    # Tail log live so the operator sees progress; pkill once snapshot lands.
    tail -n +1 -F --pid="$RESTIC_PID" "$B2_BACKUP_LOG" 2>/dev/null &
    TAIL_PID=$!
    # Deadline: a stalled rclone/B2 transfer must not hang the nightly cron forever.
    B2_DEADLINE=$(( SECONDS + ${B2_TIMEOUT_SECS:-3600} ))
    B2_TIMED_OUT=0
    while kill -0 "$RESTIC_PID" 2>/dev/null; do
      if grep -q 'snapshot [a-f0-9]\+ saved' "$B2_BACKUP_LOG" 2>/dev/null; then
        sleep 1
        pkill -TERM -P "$RESTIC_PID" 2>/dev/null || true
        kill -TERM "$RESTIC_PID" 2>/dev/null || true
        sleep 2
        pkill -KILL -P "$RESTIC_PID" 2>/dev/null || true
        kill -KILL "$RESTIC_PID" 2>/dev/null || true
        break
      fi
      if [ "$SECONDS" -ge "$B2_DEADLINE" ]; then
        B2_TIMED_OUT=1
        pkill -KILL -P "$RESTIC_PID" 2>/dev/null || true
        kill -KILL "$RESTIC_PID" 2>/dev/null || true
        break
      fi
      sleep 1
    done
    wait "$RESTIC_PID" 2>/dev/null || true
    wait "$TAIL_PID"   2>/dev/null || true
    [ "$B2_TIMED_OUT" = "0" ] || die "Backblaze upload timed out after ${B2_TIMEOUT_SECS:-3600}s — snapshot NOT confirmed"

    SNAP_ID_BACKBLAZE=$(grep -oE 'snapshot [a-f0-9]+ saved' "$B2_BACKUP_LOG" | awk '{print $2}' | head -1 || true)
    if [ -n "$SNAP_ID_BACKBLAZE" ]; then break; fi
    if [ "$_b2_try" -lt "$B2_ATTEMPTS" ]; then
      echo "⚠️  Backblaze push attempt ${_b2_try}/${B2_ATTEMPTS} confirmed no snapshot — retrying in $(( _b2_try * 10 ))s..."
      tail -3 "$B2_BACKUP_LOG" 2>/dev/null | sed 's/^/    /' || true
      sleep "$(( _b2_try * 10 ))"
    fi
  done
  [ -n "$SNAP_ID_BACKBLAZE" ] || die "Backblaze snapshot not saved after ${B2_ATTEMPTS} attempt(s) (no 'snapshot … saved' line) — aborting"
  echo "✅ Backblaze snapshot ${SNAP_ID_BACKBLAZE:0:8} confirmed."
else
  echo "ℹ️  Backblaze not configured — local snapshot only."
fi

[ "$LOCAL_BACKUP_FAILED" = "0" ] || die "Local restic backup failed — see the error above"
