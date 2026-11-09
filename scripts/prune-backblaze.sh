#!/bin/bash
# Manual override: restic retention against B2. Automatic B2 prune runs via
# prune-backups.sh on the VPS (Sun 03:00); use this to force a run or change params.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_CONFIG="$ROOT_DIR/.env.config"
ENV_FILE="$ROOT_DIR/.env"

# shellcheck source=lib/prompts.sh
source "$SCRIPT_DIR/lib/prompts.sh"

if [ ! -f "$ENV_CONFIG" ]; then
    echo "❌ .env.config not found at $ENV_CONFIG" >&2
    exit 1
fi
set -a
load_env_file "$ENV_CONFIG"
if [ -f "$ENV_FILE" ]; then
    load_env_file "$ENV_FILE"
else
    echo "❌ .env not found. Run 'npm run decrypt-env' first." >&2
    exit 1
fi
set +a

: "${BACKBLAZE_KEY_ID:?BACKBLAZE_KEY_ID missing in .env}"
: "${BACKBLAZE_APPLICATION_KEY:?BACKBLAZE_APPLICATION_KEY missing in .env}"
: "${BACKBLAZE_BUCKET:?BACKBLAZE_BUCKET missing in .env.config}"
: "${BACKUP_PASSWORD:?BACKUP_PASSWORD missing in .env}"
: "${PROJECT_NAME:?PROJECT_NAME missing in .env.config}"

command -v restic >/dev/null 2>&1 || {
    echo "❌ restic not installed locally." >&2
    echo "   macOS:  brew install restic" >&2
    echo "   Linux:  apt install restic, or download from:" >&2
    print_link "https://restic.net" >&2
    exit 1
}
command -v rclone >/dev/null 2>&1 || {
    echo "❌ rclone not installed locally (required since B2 deprecated v1 API)." >&2
    echo "   macOS:  brew install rclone" >&2
    echo "   Linux:  follow the installation instructions at:" >&2
    print_link "https://rclone.org/install.sh" >&2
    exit 1
}

# rclone:b2: remote configured via env so we never touch ~/.config/rclone/rclone.conf
# (would clobber the developer's other remotes).
export RCLONE_CONFIG_B2_TYPE=b2 \
       RCLONE_CONFIG_B2_ACCOUNT="$BACKBLAZE_KEY_ID" \
       RCLONE_CONFIG_B2_KEY="$BACKBLAZE_APPLICATION_KEY" \
       RCLONE_CONFIG_B2_HARD_DELETE=true

export RESTIC_PASSWORD="$BACKUP_PASSWORD"

REPO="rclone:b2:${BACKBLAZE_BUCKET}"

# VPS cron prune-backups.sh runs Sun 03:00 UTC against the SAME repo. With
# --no-lock on write ops, concurrent prune from two writers can corrupt packs.
_now_dow=$(date -u +%u); _now_h=$(date -u +%H)
if [ "$_now_dow" = "7" ] && [ "$_now_h" -ge 2 ] && [ "$_now_h" -le 4 ]; then
    echo "⚠️  Sun 02–04 UTC overlaps the VPS weekly prune cron — abort and re-run later," >&2
    echo "    or pass --force-window to override." >&2
    [ "${1:-}" = "--force-window" ] || exit 1
fi

# 30-day governance Object Lock 401s restic's end-of-forget lock-delete AND any
# prune-time pack-delete <30d. --no-lock is silently ignored on write ops, so we
# collapse rclone retries and tolerate non-zero exit; later runs catch up after
# files age out of governance.
export RCLONE_RETRIES=1 RCLONE_LOW_LEVEL_RETRIES=1

echo "🧹 Applying retention policy (7 daily, 4 weekly, 6 monthly) to ${REPO} ..."
echo "   Note: pack files <30 days old are governance-locked; actual deletion"
echo "   happens on later runs once the lock period elapses."
restic -r "$REPO" forget --prune \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 6 \
    --host "$PROJECT_NAME" \
    --tag "n8n-db" || echo "⚠️  restic forget exited non-zero — expected on governance-locked B2"
echo "✅ Backblaze retention pass completed (best-effort)."
