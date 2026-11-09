#!/bin/bash
set -eo pipefail

# Per-minute cron: polls n8n's Postgres for explicit publish events and triggers
# github-commit-workflows.sh. Watches workflow_publish_history (Active toggle)
# and workflow_published_version (Publish button) — plain saves are ignored.
# If a future n8n version renames either table, the schema check below fails loudly.

_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$_SCRIPTS_DIR/lib/common.sh"

DB_CONTAINER="n8n_postgres"
DB_NAME="${DB_NAME:-n8n_database}"
CURSOR_FILE="/root/n8n/.last_publish_seen"

exec 9>/root/n8n/.poll-publish.lock
flock -n 9 || {
    log "⚠️  poll-publish.lock busy — previous run still active, skipping"
    exit 0
}

load_backup_creds --optional || true

: "${DB_USER:?DB_USER missing — populate .backup_creds or env}"
# Log timestamps in the operator's display zone; storage/operational time stays UTC.
export TZ="${TZ:-${DISPLAY_TZ:-UTC}}"

# stderr stays separate so psql errors can't contaminate captured values.
# Pass user-controlled values via -v var=val, never string-interpolated.
psql_query() {
    local _q="$1"; shift
    printf '%s' "$_q" | docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" "$@" -tA -f -
}

SANITY=$(psql_query "SELECT to_regclass('public.workflow_publish_history')::text || '|' || to_regclass('public.workflow_published_version')::text || '|' || to_regclass('public.workflow_entity')::text || '|' || to_regclass('public.workflow_history')::text;")
case "$SANITY" in
    workflow_publish_history\|workflow_published_version\|workflow_entity\|workflow_history) ;;
    *)
        log "❌ Schema check failed: '$SANITY'. n8n may have renamed publish tables; update the query in this script."
        exit 1
        ;;
esac

LAST_SEEN=$(cat "$CURSOR_FILE" 2>/dev/null || echo "1970-01-01 00:00:00+00")
# Reject anything that isn't a timestamp — guards against a corrupted cursor file.
[[ "$LAST_SEEN" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?([+-][0-9:]+)?$ ]] || LAST_SEEN="1970-01-01 00:00:00+00"

# Newest event timestamp across both tables, strictly after the cursor.
# Both activate and deactivate commit — else a UI deactivation never reaches git
# and the next deploy's active:true silently reactivates it.
NEW_MAX=$(psql_query "
    SELECT COALESCE(MAX(ts)::text, '') FROM (
        SELECT \"createdAt\" AS ts FROM workflow_publish_history
            WHERE event IN ('activated','deactivated') AND \"createdAt\" > :'LAST_SEEN'::timestamptz
        UNION ALL
        SELECT \"updatedAt\" AS ts FROM workflow_published_version
            WHERE \"updatedAt\" > :'LAST_SEEN'::timestamptz
    ) t;
" -v "LAST_SEEN=$LAST_SEEN")

# Non-timestamp here means psql wrote an error to stdout.
if [ -n "$NEW_MAX" ]; then
    if ! [[ "$NEW_MAX" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?([+-][0-9:]+)?$ ]]; then
        log "❌ Unexpected psql output for NEW_MAX: '${NEW_MAX:0:120}' — aborting"
        exit 1
    fi
fi

if [ -n "$NEW_MAX" ]; then
    # Commit message: "{version_name}: {workflow_name}". Tab separator so workflow
    # names containing '|' can't corrupt the split. Window-bounded by NEW_MAX so a
    # publish arriving between the SELECTs isn't double-committed next cycle.
    RESULT=$(psql_query "
        SELECT
            COALESCE(STRING_AGG(DISTINCT we.name, ', '), 'unknown') || E'\t' ||
            COALESCE(STRING_AGG(DISTINCT wh.name, ', ') FILTER (WHERE wh.name IS NOT NULL AND wh.name <> ''), '')
        FROM (
            SELECT \"workflowId\", \"versionId\"
            FROM workflow_publish_history
            WHERE event IN ('activated','deactivated')
              AND \"createdAt\" >  :'LAST_SEEN'::timestamptz
              AND \"createdAt\" <= :'NEW_MAX'::timestamptz
            UNION ALL
            SELECT \"workflowId\", \"publishedVersionId\" AS \"versionId\"
            FROM workflow_published_version
            WHERE \"updatedAt\" >  :'LAST_SEEN'::timestamptz
              AND \"updatedAt\" <= :'NEW_MAX'::timestamptz
        ) pub
        JOIN workflow_entity we ON we.id = pub.\"workflowId\"
        LEFT JOIN workflow_history wh ON wh.\"versionId\" = pub.\"versionId\";
    " -v "LAST_SEEN=$LAST_SEEN" -v "NEW_MAX=$NEW_MAX")
    WORKFLOW_NAME=$(printf '%s' "$RESULT" | cut -f1)
    PUBLISH_TEXT=$(printf '%s' "$RESULT" | cut -f2)

    if [ -n "$PUBLISH_TEXT" ]; then
        COMMIT_MSG="${PUBLISH_TEXT}: ${WORKFLOW_NAME}"
    else
        COMMIT_MSG="$WORKFLOW_NAME"
    fi

    log "📍 Publish event at $NEW_MAX → '$COMMIT_MSG'"

    # Cursor advances ONLY after a successful commit — failed pushes retry next cycle.
    GITHUB_COMMIT_SCRIPT="$_SCRIPTS_DIR/github-commit-workflows.sh"
    if [ -f "$GITHUB_COMMIT_SCRIPT" ]; then
        if bash "$GITHUB_COMMIT_SCRIPT" "$COMMIT_MSG"; then
            printf '%s\n' "$NEW_MAX" > "$CURSOR_FILE"
        else
            log "❌ GitHub commit failed — cursor NOT advanced; will retry next poll. Causes: a workflow blocked by the secret scan, n8n API down/key rotated (see pull errors above) or bad GITHUB_PERSONAL_ACCESS_TOKEN/GITHUB_REPO in .backup_creds"
        fi
    else
        log "⚠️  github-commit-workflows.sh not found at $GITHUB_COMMIT_SCRIPT"
    fi
fi
