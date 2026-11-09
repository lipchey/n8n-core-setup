#!/bin/bash
# Commits n8n/workflows/ state to GitHub via Trees API; invoked on the VPS by poll-publish-events.sh.
# Exit 0 advances the caller's poll cursor; any blocked or failed file must exit non-zero.
# Usage: bash github-commit-workflows.sh ["commit message"]

# pipefail is mandatory: every API call is `cmd | jq -r ...`, and jq exits 0 on a curl error body.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# Resend HTTP API, not SMTP — DigitalOcean blocks outbound SMTP ports.
# shellcheck source=lib/notify.sh
. "$SCRIPT_DIR/lib/notify.sh"

WORKFLOWS_DIR="/root/n8n/workflows"
WORKFLOWS_REPO_PATH="n8n/workflows"
COMMIT_MSG="${1:-chore: sync n8n workflows}"

load_backup_creds --optional || true

: "${GITHUB_PERSONAL_ACCESS_TOKEN:?GITHUB_PERSONAL_ACCESS_TOKEN missing — add to .env.sops.yaml (npm run edit-env) + redeploy to refresh .backup_creds}"
: "${GITHUB_REPO:?GITHUB_REPO missing — add to .env.config}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"

GH="https://api.github.com"

# Per-file alerts rate-limited to one/hour so a stuck dirty workflow doesn't spam.
SCANNER="$SCRIPT_DIR/scan-workflow-secrets.sh"
ALERT_STATE_DIR="/root/n8n/.secret-alerts"
ALERT_INTERVAL=3600
mkdir -p "$ALERT_STATE_DIR"
chmod 700 "$ALERT_STATE_DIR"

# Fail-closed: a missing scanner aborts the commit rather than silently no-scanning.
[ -f "$SCANNER" ] || die "Secret scanner missing at $SCANNER — aborting commit"

PAYLOAD_DIR=$(mktemp -d)
trap 'rm -rf "$PAYLOAD_DIR"' EXIT

send_secret_alert() {
    local fname="$1" scan_out="$2"
    local host_name; host_name=$(hostname)
    email_configured || return 0
    local subject body
    subject=$(printf '🚨 [SECRET DETECTED] %s — workflow %s blocked from auto-commit' \
        "${PROJECT_NAME:-$host_name}" "$fname")
    body=$(
        printf 'A workflow JSON contains a value matching a known credential format.\n'
        printf 'It was BLOCKED from the auto-commit to GitHub to keep secrets out of git.\n\n'
        printf 'Project:  %s\n' "${PROJECT_NAME:-$host_name}"
        printf 'Host:     %s\n' "$host_name"
        printf 'File:     %s\n\n' "$fname"
        printf 'Matches (masked):\n'
        printf '%s\n\n' "$scan_out"
        printf 'What to do:\n'
        printf '  1. Open this workflow in n8n UI.\n'
        printf '  2. Move the inlined value into an n8n Credential of the right type.\n'
        printf '  3. Replace the parameter with a credential reference.\n'
        printf '  4. Re-save / re-publish — next poll cycle will commit cleanly.\n\n'
        printf 'NOTE: the workflow is still ACTIVE in n8n and running with the secret;\n'
        printf '      only the GitHub auto-commit is blocked.\n\n'
        printf 'Re-alerts for this file are rate-limited to once per hour.\n'
    )
    send_email "$subject" "$body" "$DEVELOPER_EMAIL" >&2 || true
}

# Push-Protection rejection emails — GitHub groups by commit not by file, so we
# forward the whole response body. Rate-limited globally to one/hour.
PP_ALERT_STATE="/root/n8n/.pp-last-alert"
send_pp_alert() {
    local response_body="$1"
    local host_name; host_name=$(hostname)
    email_configured || return 0
    throttle_gate "$PP_ALERT_STATE" "$ALERT_INTERVAL" || return 0

    local subject body
    subject=$(printf '🚨 [SECRET DETECTED] %s — GitHub Push Protection blocked auto-commit' \
        "${PROJECT_NAME:-$host_name}")
    body=$(
        printf 'GitHub Push Protection rejected the auto-commit from this VPS because\n'
        printf 'one of the staged workflow files contains a value matching a partner-\n'
        printf 'issued credential format (AWS, Stripe, OpenAI, GitHub PAT, etc.).\n\n'
        printf 'Project:  %s\n' "${PROJECT_NAME:-$host_name}"
        printf 'Host:     %s\n' "$host_name"
        printf 'Repo:     %s (%s)\n\n' "$GITHUB_REPO" "$GITHUB_BRANCH"
        printf 'GitHub response (truncated to 2KB):\n'
        printf '%s\n\n' "$(printf '%s' "$response_body" | head -c 2048)"
        printf 'What to do:\n'
        printf '  1. Open the Security tab on the repo — Secret scanning alerts list\n'
        printf '     the offending file path and the partner pattern that matched.\n'
        printf '  2. In n8n UI, open that workflow and move the inlined value into\n'
        printf '     a Credential of the right type.\n'
        printf '  3. Replace the parameter with a credential reference.\n'
        printf '  4. Re-save / re-publish — next poll cycle will commit cleanly.\n\n'
        printf 'NOTE: the workflow is still ACTIVE in n8n and running with the secret;\n'
        printf '      only the GitHub auto-commit is blocked. Rotate the credential\n'
        printf '      ASAP — once GitHub has seen it, the partner (e.g. AWS, Stripe)\n'
        printf '      may have already been notified and revoked the key.\n\n'
        printf 'Re-alerts are rate-limited to once per hour.\n'
    )
    send_email "$subject" "$body" "$DEVELOPER_EMAIL" >&2 || true
}

# Body comes from a file: one argv slot caps at 128 KiB, which a workflow's blob can exceed.
gh_api() {
    local method="$1" path="$2" data_file="${3:-}"
    local args=(-sS --fail-with-body --connect-timeout 15 --max-time 120 -X "$method"
        -H "Authorization: Bearer $GITHUB_PERSONAL_ACCESS_TOKEN"
        -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28")
    [ -n "$data_file" ] && args+=(-H "Content-Type: application/json" --data-binary "@$data_file")
    curl "${args[@]}" "$GH$path"
}

# Like gh_api but lets caller inspect 4xx — needed to catch Push Protection 422.
# rc: 0=2xx (body on stdout), 1=PP-signal matched (alert sent), 2=other failure.
gh_api_inspect() {
    local method="$1" path="$2" data="${3:-}"
    local body_file http_code rc=0
    body_file=$(mktemp)
    local args=(-sS --connect-timeout 15 --max-time 120 -o "$body_file" -w '%{http_code}' -X "$method"
        -H "Authorization: Bearer $GITHUB_PERSONAL_ACCESS_TOKEN"
        -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28")
    [ -n "$data" ] && args+=(-H "Content-Type: application/json" -d "$data")
    http_code=$(curl "${args[@]}" "$GH$path" 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then
        log "❌ curl failed (rc=$rc) for $method $path" >&2
        rm -f "$body_file"
        return 2
    fi
    if [ "${http_code:-0}" -ge 200 ] && [ "${http_code:-0}" -lt 300 ]; then
        cat "$body_file"
        rm -f "$body_file"
        return 0
    fi
    local body_lower
    body_lower=$(tr '[:upper:]' '[:lower:]' < "$body_file")
    if echo "$body_lower" | grep -qE 'push.protection|push cannot contain secrets|secret_scanning|secret_detected|repository rule violations|gh013'; then
        log "🚨 GitHub Push Protection blocked $method $path (HTTP $http_code)" >&2
        sed 's/^/      /' "$body_file" >&2
        send_pp_alert "$(cat "$body_file")"
        rm -f "$body_file"
        return 1
    fi
    log "❌ GitHub API error: $method $path → HTTP $http_code" >&2
    sed 's/^/      /' "$body_file" >&2
    rm -f "$body_file"
    return 2
}

log "🔄 Pulling workflows from n8n API..."
bash "$SCRIPT_DIR/sync-workflows.sh" --pull

log "📡 Resolving branch HEAD ($GITHUB_REPO/$GITHUB_BRANCH)..."
BRANCH_SHA=$(gh_api GET "/repos/$GITHUB_REPO/git/refs/heads/$GITHUB_BRANCH" \
    | jq -r '.object.sha')
# Null/empty SHA → branch missing or API call failed; would orphan blobs.
[ "$BRANCH_SHA" != "null" ] && [ -n "$BRANCH_SHA" ] || {
    log "❌ Failed to resolve branch SHA for $GITHUB_REPO/$GITHUB_BRANCH — branch may not exist"
    exit 1
}
TREE_SHA=$(gh_api GET "/repos/$GITHUB_REPO/git/commits/$BRANCH_SHA" \
    | jq -r '.tree.sha')
[ "$TREE_SHA" != "null" ] && [ -n "$TREE_SHA" ] || {
    log "❌ Failed to resolve tree SHA for commit $BRANCH_SHA"
    exit 1
}

GITHUB_FILES=$(gh_api GET "/repos/$GITHUB_REPO/git/trees/$TREE_SHA?recursive=1" \
    | jq -r --arg dir "$WORKFLOWS_REPO_PATH/" \
      '[.tree[] | select(.type == "blob" and (.path | test("^" + $dir + "[^/]+\\.json$"))) | .path]')

TREE_ITEMS_FILE="$PAYLOAD_DIR/tree-items.json"
echo '[]' > "$TREE_ITEMS_FILE"
LOCAL_FILES=()
DIRTY_FILES=()  # blocked by secret scan — kept untouched on GitHub

# add_tree_item REPO_PATH SHA_AS_JSON — a null sha deletes the path.
add_tree_item() {
    jq --arg path "$1" --argjson sha "$2" \
        '. + [{"path":$path,"mode":"100644","type":"blob","sha":$sha}]' \
        "$TREE_ITEMS_FILE" > "$TREE_ITEMS_FILE.tmp" && mv "$TREE_ITEMS_FILE.tmp" "$TREE_ITEMS_FILE"
}

# A blocked file keeps the run failed even when the clean ones were committed:
# the caller advances the poll cursor on exit 0 and would never retry it.
finish_run() {
    if [ ${#DIRTY_FILES[@]} -gt 0 ]; then
        log "❌ ${#DIRTY_FILES[@]} workflow(s) still blocked by secret scan (${DIRTY_FILES[*]}) — failing so the cursor holds"
        exit 1
    fi
    exit 0
}

for fpath in "$WORKFLOWS_DIR"/*.json; do
    [ -f "$fpath" ] || continue
    fname="$(basename "$fpath")"

    jq -e 'has("name") and has("nodes")' "$fpath" > /dev/null || {
        log "❌ Invalid workflow JSON (missing name/nodes): $fname — aborting"
        exit 1
    }

    SCAN_OUT=$(bash "$SCANNER" "$fpath" 2>/dev/null) || SCAN_RC=$?
    SCAN_RC="${SCAN_RC:-0}"
    if [ "$SCAN_RC" -ge 2 ]; then
        log "❌ Scanner exited with rc=${SCAN_RC} for $fname — aborting commit"
        exit 1
    fi
    # Fail-closed: rc=1 marks the file dirty even if the scanner printed nothing.
    if [ "$SCAN_RC" = "1" ]; then
        log "🚨 SECRETS in $fname — skipping commit:"
        echo "${SCAN_OUT:-(scanner gave no details)}" | sed 's/^/      /'
        DIRTY_FILES+=("$fname")

        if throttle_gate "$ALERT_STATE_DIR/${fname}.last-alert" "$ALERT_INTERVAL"; then
            send_secret_alert "$fname" "$SCAN_OUT"
        fi
        unset SCAN_RC
        continue
    fi
    unset SCAN_RC

    LOCAL_FILES+=("$fname")

    base64 < "$fpath" | tr -d '\n' > "$PAYLOAD_DIR/blob.b64"
    jq -n --rawfile c "$PAYLOAD_DIR/blob.b64" '{"content":$c,"encoding":"base64"}' > "$PAYLOAD_DIR/blob.json"
    BLOB_SHA=$(gh_api POST "/repos/$GITHUB_REPO/git/blobs" "$PAYLOAD_DIR/blob.json" \
        | jq -r '.sha')
    [ -n "$BLOB_SHA" ] && [ "$BLOB_SHA" != "null" ] || {
        log "❌ Blob creation returned no .sha for $fname — aborting"
        exit 1
    }

    add_tree_item "$WORKFLOWS_REPO_PATH/$fname" "\"$BLOB_SHA\""
    echo "  📄 staged: $fname"
done

# Abort on empty pull — otherwise the deletion pass below would wipe the repo.
if [ ${#LOCAL_FILES[@]} -eq 0 ]; then
    if [ ${#DIRTY_FILES[@]} -gt 0 ]; then
        log "❌ All ${#DIRTY_FILES[@]} workflow(s) blocked by secret scan — nothing to commit"
        exit 1
    fi
    log "❌ No local workflow files after pull — aborting to prevent wiping repo"
    exit 1
fi

# Delete GitHub files absent locally. Dirty files count as "present" so a clean
# version on GitHub isn't deleted just because the live one now has a secret.
while IFS= read -r gh_path; do
    fname="$(basename "$gh_path")"
    found=0
    for lf in "${LOCAL_FILES[@]}" "${DIRTY_FILES[@]}"; do
        [ "$lf" = "$fname" ] && found=1 && break
    done
    if [ "$found" -eq 0 ]; then
        add_tree_item "$gh_path" null
        echo "  🗑️  deleted: $fname"
    fi
done < <(echo "$GITHUB_FILES" | jq -r '.[]' 2>/dev/null || true)

if [ "$(jq 'length' "$TREE_ITEMS_FILE")" -eq 0 ]; then
    log "ℹ️  No workflow files to commit."
    finish_run
fi

jq -n --arg base "$TREE_SHA" --slurpfile items "$TREE_ITEMS_FILE" \
    '{"base_tree":$base,"tree":$items[0]}' > "$PAYLOAD_DIR/tree.json"
NEW_TREE_SHA=$(gh_api POST "/repos/$GITHUB_REPO/git/trees" "$PAYLOAD_DIR/tree.json" \
    | jq -r '.sha')
[ -n "$NEW_TREE_SHA" ] && [ "$NEW_TREE_SHA" != "null" ] || {
    log "❌ Tree creation returned no .sha — aborting"
    exit 1
}

if [ "$NEW_TREE_SHA" = "$TREE_SHA" ]; then
    log "ℹ️  No changes detected (tree SHA unchanged)."
    finish_run
fi

# gh_api_inspect here and on the ref PATCH below — Push Protection blocks at
# one of these two points with 422 and we want to alert before exiting.
FULL_MSG="${COMMIT_MSG} [publish] [skip ci]"
COMMIT_PAYLOAD=$(jq -n \
    --arg msg    "$FULL_MSG" \
    --arg tree   "$NEW_TREE_SHA" \
    --arg parent "$BRANCH_SHA" \
    '{"message":$msg,"tree":$tree,"parents":[$parent]}')
COMMIT_RESPONSE=$(gh_api_inspect POST "/repos/$GITHUB_REPO/git/commits" "$COMMIT_PAYLOAD") || exit 1
NEW_COMMIT_SHA=$(printf '%s' "$COMMIT_RESPONSE" | jq -r '.sha')
[ -n "$NEW_COMMIT_SHA" ] && [ "$NEW_COMMIT_SHA" != "null" ] || {
    log "❌ Commit created but response had no .sha — aborting"
    exit 1
}

gh_api_inspect PATCH "/repos/$GITHUB_REPO/git/refs/heads/$GITHUB_BRANCH" \
    "{\"sha\":\"$NEW_COMMIT_SHA\"}" > /dev/null || exit 1

log "✅ Committed: $FULL_MSG"
echo "   SHA: $NEW_COMMIT_SHA → $GITHUB_REPO/$GITHUB_BRANCH"
finish_run
