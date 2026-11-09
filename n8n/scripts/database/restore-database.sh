#!/bin/bash
set -euo pipefail
umask 077

_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$_SCRIPTS_DIR/lib/common.sh"
# shellcheck source=../lib/restic-env.sh
. "$_SCRIPTS_DIR/lib/restic-env.sh"

load_backup_creds BACKUP_PASSWORD DB_USER PROJECT_NAME RESTIC_REPOSITORY
require_cmds docker gzip tar flock
setup_restic_local

# Shares the backup lock — the nightly cron must not fire mid-restore.
exec 8>/root/n8n/.backup.lock
flock -n 8 || die "a backup/restore is already running — retry when it finishes"

# prompt_choice "<prompt>" "<valid chars regex class>" → echoes the char; q aborts.
prompt_choice() {
    local _prompt="$1" _valid="$2" _attempts=0 _reply
    while :; do
        read -p "$_prompt" -n 1 -r _reply
        echo >&2
        case "$_reply" in
            q|Q) echo "  Aborted." >&2; exit 1 ;;
        esac
        if [[ "$_reply" =~ ^[$_valid]$ ]]; then printf '%s' "$_reply"; return 0; fi
        _attempts=$((_attempts+1))
        [ "$_attempts" -ge 3 ] && die "Too many invalid attempts — aborting"
        echo "  ⚠️  Invalid — expected one of [${_valid}] or q (attempt $((_attempts+1))/3)." >&2
    done
}

if [ -n "${RESTIC_REPOSITORY_BACKBLAZE:-}" ] && [ -n "${BACKBLAZE_KEY_ID:-}" ] && [ -n "${BACKBLAZE_APPLICATION_KEY:-}" ]; then
  echo
  echo "Restore source:"
  echo "  [1] Local VPS    (${RESTIC_REPOSITORY})"
  echo "  [2] Backblaze    (${RESTIC_REPOSITORY_BACKBLAZE})"
  echo
  if [ -t 0 ]; then
    SOURCE_CHOICE=$(prompt_choice "Select source [1/2, default 1, q to abort]: " "12" || exit 1)
  else
    SOURCE_CHOICE="${RESTORE_SOURCE_CHOICE:-1}"
    echo "  (no TTY — using source ${SOURCE_CHOICE}: $([ "$SOURCE_CHOICE" = "2" ] && echo Backblaze || echo 'local VPS'))"
  fi
  RESTIC_NOLOCK=""
  if [ "$SOURCE_CHOICE" = "2" ]; then
    setup_restic_b2 || die "Backblaze selected but not fully configured"
    RESTIC_REPOSITORY="$RESTIC_REPOSITORY_BACKBLAZE"
    # Read-only B2 restore keys can't write lock files (401); restore is read-only anyway.
    RESTIC_NOLOCK="--no-lock"
    echo "  -> Using Backblaze repository"
  else
    echo "  -> Using local repository"
  fi
fi
: "${RESTIC_NOLOCK:=}"

if [ -n "${1:-}" ]; then
    SNAPSHOT_ID="$1"
else
    echo
    echo "Available snapshots:"
    echo
    restic -r "$RESTIC_REPOSITORY" snapshots $RESTIC_NOLOCK --tag "n8n-db" --host "$PROJECT_NAME" \
        2>/dev/null || restic -r "$RESTIC_REPOSITORY" snapshots $RESTIC_NOLOCK 2>/dev/null
    echo
    echo "Which snapshot do you want to restore?"
    echo
    echo "  [1] Latest"
    echo "  [2] Specify a snapshot ID"
    echo
    CHOICE=$(prompt_choice "Enter choice (1, 2, or q to abort): " "12" || exit 1)
    if [ "$CHOICE" = "1" ]; then
        SNAPSHOT_ID="latest"
    else
        printf "\033[2mExpected format: 8-character hex snapshot ID (e.g. a1b2c3d4)\033[0m\n"
        _sub=0
        while :; do
            read -p "Snapshot ID (or 'q' to abort): " -r SNAPSHOT_ID
            case "$SNAPSHOT_ID" in q|Q) echo "  Aborted." >&2; exit 1 ;; esac
            [[ "$SNAPSHOT_ID" =~ ^(latest|[a-f0-9]{8,64})$ ]] && break
            _sub=$((_sub+1))
            [ "$_sub" -ge 3 ] && die "Invalid SNAPSHOT_ID '$SNAPSHOT_ID' — expected 'latest' or 8–64 hex chars"
            echo "  ⚠️  Invalid — try again (or 'q' to abort). Attempt $((_sub+1))/3." >&2
        done
    fi
fi

# Whitelist SNAPSHOT_ID — restic accepts flags anywhere, so a value like
# `--cleanup` would be parsed as an option.
if ! [[ "$SNAPSHOT_ID" =~ ^(latest|[a-f0-9]{8,64})$ ]]; then
    die "Invalid SNAPSHOT_ID '$SNAPSHOT_ID' — expected 'latest' or 8–64 hex chars"
fi

# Stop poll-publish before the confirm prompt to close the user-confirm race window.
ORIG_CRON=$(crontab -l 2>/dev/null || true)
_n8n_stopped=0
_db_touched=0
RESTORE_TMP=$(mktemp -d /root/n8n/.restore.XXXXXX)
# Trap must be installed before we touch the crontab — otherwise a pipefail in
# the grep|crontab line below leaves the user with a wiped crontab.
# shellcheck disable=SC2154
trap '
    _rc=$?
    set +e
    rm -rf "$RESTORE_TMP"
    if [ -n "$ORIG_CRON" ]; then
        printf "%s\n" "$ORIG_CRON" | crontab -
    else
        crontab -r 2>/dev/null || true
    fi
    echo "🔄 poll-publish cron restored."
    # Once the DB was dropped, a restart would run live workflows against partial data.
    if [ "$_rc" -ne 0 ] && [ "$_n8n_stopped" = "1" ]; then
        if [ "$_db_touched" = "1" ]; then
            echo "❌ restore failed (exit $_rc) after dropping the database — n8n_app left STOPPED." >&2
            echo "   Re-run the restore; start it by hand only after checking the data: docker start n8n_app" >&2
        else
            echo "⚠️  restore aborted (exit $_rc) before touching the database — restarting n8n_app." >&2
            docker start n8n_app >/dev/null 2>&1 \
              || echo "❌ Failed to restart n8n_app — restart manually: docker start n8n_app" >&2
        fi
    fi
    exit "$_rc"
' EXIT
# `|| true` swallows grep's exit 1 when poll-publish was the only crontab line.
printf '%s\n' "$ORIG_CRON" | { grep -v poll-publish-events.sh || true; } | crontab -

echo
echo "⚠️  WARNING: This will overwrite the current database."
REPLY=$(prompt_choice "Are you sure you want to proceed? (y/n, q to abort) " "YyNn" || exit 1)
case "$REPLY" in [Nn]) echo "  Aborted." >&2; exit 1 ;; esac

STAGED="/root/n8n/.backup-staging"

# Detect snapshot layout: legacy stdin-only had `/n8n_db.sql.gz`; new staging-dir layout has `$STAGED/n8n_db.sql.gz` plus optional `$STAGED/n8n_files.tar.gz`.
LISTING=$(restic -r "$RESTIC_REPOSITORY" ls "$SNAPSHOT_ID" $RESTIC_NOLOCK --host "$PROJECT_NAME" 2>/dev/null || true)
[ -n "$LISTING" ] || die "Could not list snapshot $SNAPSHOT_ID."

LEGACY=0
printf '%s\n' "$LISTING" | grep -qx "/n8n_db.sql.gz" && LEGACY=1
HAS_N8N_FILES=0
printf '%s\n' "$LISTING" | grep -qx "${STAGED}/n8n_files.tar.gz" && HAS_N8N_FILES=1

echo
if [ "$LEGACY" = "1" ]; then
    echo "ℹ️  Legacy snapshot detected (stdin-only DB)."
else
    echo "ℹ️  Snapshot contents:"
    echo "     • n8n database"
    [ "$HAS_N8N_FILES" = "1" ] && echo "     • n8n files volume"
fi

# Download + validate the dump BEFORE any destructive step — an empty/corrupt
# stream discovered mid-pipe would otherwise leave the DB dropped and n8n dead.
DB_DUMP_PATH=$([ "$LEGACY" = "1" ] && echo "/n8n_db.sql.gz" || echo "${STAGED}/n8n_db.sql.gz")
DUMP_FILE="$RESTORE_TMP/n8n_db.sql.gz"
echo "⬇️  Fetching DB dump from snapshot $SNAPSHOT_ID ..."
restic -r "$RESTIC_REPOSITORY" dump "$SNAPSHOT_ID" $RESTIC_NOLOCK --host "$PROJECT_NAME" "$DB_DUMP_PATH" > "$DUMP_FILE"
gzip -t "$DUMP_FILE" || die "Dump failed gzip integrity check — refusing to touch the database"
DUMP_SIZE=$(stat -c %s "$DUMP_FILE" 2>/dev/null || echo 0)
[ "${DUMP_SIZE:-0}" -gt 500 ] || die "Dump suspiciously small (${DUMP_SIZE} bytes) — refusing to touch the database"

if [ "$HAS_N8N_FILES" = "1" ]; then
    FILES_TAR="$RESTORE_TMP/n8n_files.tar.gz"
    echo "⬇️  Fetching files-volume archive ..."
    restic -r "$RESTIC_REPOSITORY" dump "$SNAPSHOT_ID" $RESTIC_NOLOCK --host "$PROJECT_NAME" "${STAGED}/n8n_files.tar.gz" > "$FILES_TAR"
    gzip -t "$FILES_TAR" || die "Files archive failed gzip integrity check — aborting before any destructive step"
fi

echo "🛑 Stopping n8n to prevent concurrent database writes..."
docker stop n8n_app
_n8n_stopped=1

DB_NAME=$(docker exec n8n_postgres printenv POSTGRES_DB)

# DB_NAME is interpolated into psql commands below — whitelist (no quotes/semicolons)
# blocks injection; the identifier itself is double-quoted to survive hyphens.
[[ "$DB_NAME" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || die "DB_NAME '$DB_NAME' contains invalid characters — aborting"

# Superuser needed for DROP/CREATE — the app user lacks DDL privileges.
POSTGRES_SUPERUSER=$(docker exec n8n_postgres printenv POSTGRES_USER)

echo "🔧 Terminating existing connections to $DB_NAME..."
docker exec n8n_postgres psql -U "$POSTGRES_SUPERUSER" -d postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_NAME' AND pid <> pg_backend_pid();" \
    > /dev/null

echo "🗑️  Dropping database $DB_NAME so restore starts clean..."
_db_touched=1
docker exec n8n_postgres psql -U "$POSTGRES_SUPERUSER" -d postgres -c \
    "DROP DATABASE IF EXISTS \"$DB_NAME\";"

echo "🔓 Restoring snapshot $SNAPSHOT_ID ..."
# Strip role DDL (DROP/CREATE/ALTER ROLE) for backward compat with old pg_dumpall
# snapshots — PostgreSQL rejects DROP ROLE for the currently-connected superuser.
gunzip -c "$DUMP_FILE" | \
grep -vE "^(DROP|CREATE|ALTER) ROLE |^COMMENT ON ROLE " | \
docker exec -i n8n_postgres psql -U "$POSTGRES_SUPERUSER" -d postgres \
    -v ON_ERROR_STOP=1

if [ "$HAS_N8N_FILES" = "1" ]; then
    echo "🔓 Restoring n8n files volume ..."
    # Discover the real mountpoint — a custom Docker data-root moves this off the /var/lib/docker default.
    N8N_FILES_VOL="$(docker volume inspect n8n_app_files --format '{{ .Mountpoint }}' 2>/dev/null || true)"
    [ -n "$N8N_FILES_VOL" ] || N8N_FILES_VOL="/var/lib/docker/volumes/n8n_app_files/_data"
    mkdir -p "$N8N_FILES_VOL"
    # NOTE: merge-restore — files created after the snapshot survive. Wipe
    # $N8N_FILES_VOL manually first for an exact point-in-time state.
    tar xzf "$FILES_TAR" -C "$N8N_FILES_VOL"
fi

echo "🚀 Restarting n8n..."
docker start n8n_app
_n8n_stopped=0

echo "🩺 Waiting for n8n readiness..."
_health_timeout="${RESTORE_HEALTH_TIMEOUT_SECS:-300}"
_health_deadline=$((SECONDS + _health_timeout))
# Same probe as the compose healthcheck; plain /healthz would miss a dead DB.
until docker exec n8n_app wget -T 10 -qO- http://localhost:5678/healthz/readiness >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$_health_deadline" ] \
        || die "n8n_app not ready after ${_health_timeout}s — restore NOT confirmed; check: docker logs n8n_app"
    sleep 5
done


echo "✅ Restore complete!"
