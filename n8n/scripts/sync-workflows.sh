#!/bin/bash
set -eo pipefail

# Sync workflow JSON: dev-mode rsyncs and re-invokes self over SSH;
# VPS-mode talks directly to the local n8n REST API.

export TZ="UTC"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="$1"
FORCE=""

case "$ACTION" in
    --pull|--push) ;;
    *)
        echo "Usage:"
        echo "  bash sync.sh --pull [--force]"
        echo "  bash sync.sh --push"
        exit 1
        ;;
esac

shift
while [ "$#" -gt 0 ]; do
    case "$1" in
        --force) FORCE="1" ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
    shift
done

WORKFLOWS_DIR="$SCRIPT_DIR/../workflows"

if [ -f /root/n8n/.backup_creds ]; then
    # ── VPS mode ──
    set -a
    source /root/n8n/.backup_creds
    set +a

    if [ -z "$N8N_API_KEY" ] || [ -z "$N8N_LOCAL_API_URL" ]; then
        echo "Error: API credentials are missing from .backup_creds."
        exit 1
    fi
    # Whole authority, not a prefix: http://localhost:5678@attacker/ is a remote host.
    if ! [[ "$N8N_LOCAL_API_URL" =~ ^http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?(/[^[:space:]]*)?$ ]]; then
        echo "❌ N8N_LOCAL_API_URL must point to localhost (got: $N8N_LOCAL_API_URL) — refusing to send API key to a remote host"
        exit 1
    fi
    command -v jq >/dev/null 2>&1      || { echo "❌ jq required on VPS"; exit 1; }
    command -v python3 >/dev/null 2>&1 || { echo "❌ python3 required on VPS (JSON formatting)"; exit 1; }

    diagnose_api_response() {
        local response="$1"
        if echo "$response" | grep -qE '^<!DOCTYPE|^<html'; then
            echo "  ⚠️  n8n returned an HTML error page instead of JSON."
            echo "     Check that N8N_LOCAL_API_URL ends with /api/v1 (current: $N8N_LOCAL_API_URL)"
            return
        fi
        local msg
        msg=$(echo "$response" | jq -r '.message // empty' 2>/dev/null || true)
        if [ "$msg" = "Unauthorized" ]; then
            echo "  ⚠️  401 Unauthorized — API key rejected."
            echo "     If n8n containers were recreated, the API key was reset."
            echo "     Fix: n8n UI → Settings → API → create a new key,"
            echo "     then update N8N_API_KEY via 'npm run edit-env' (commit .env.sops.yaml) and redeploy."
        fi
    }

    # Transport-safe GET — a down n8n container fails loudly instead of letting
    # `curl -s` + set -e kill the script with zero diagnostics.
    n8n_get() {
        curl -sS --max-time 30 -X GET "$1" -H "X-N8N-API-KEY: $N8N_API_KEY" || {
            echo "❌ n8n API unreachable at $N8N_LOCAL_API_URL (is the n8n container up?)" >&2
            return 1
        }
    }

    # /workflows paginates (max 250) via nextCursor — a single GET truncates at
    # page 1 (pull deletes page-2+ as stale; push re-creates them). Accumulate
    # via tmpfile, never jq --argjson (a big accumulator on argv trips ARG_MAX).
    n8n_get_all() {
        local base="$1" url resp cursor tmp
        tmp=$(mktemp)
        url="$base?limit=250"
        while :; do
            resp=$(n8n_get "$url") || { rm -f "$tmp"; return 1; }
            echo "$resp" | jq -e '.data | type == "array"' >/dev/null 2>&1 || { rm -f "$tmp"; printf '%s' "$resp"; return 0; }
            echo "$resp" | jq -c '.data' >> "$tmp"
            cursor=$(echo "$resp" | jq -r '.nextCursor // empty')
            [ -n "$cursor" ] || break
            url="$base?limit=250&cursor=$cursor"
        done
        jq -s '{data: (add // [])}' "$tmp"
        rm -f "$tmp"
    }

    # n8n_api_write METHOD URL BODY_FILE LABEL — stdout: response body, rc 0 = 2xx
    # with no .message. Gates on the HTTP code (a non-2xx whose body lacks .message
    # is a failure, not a success). If the pinned n8n's settings schema rejects the
    # injected availableInMCP key, strips it from BODY_FILE and retries once.
    n8n_api_write() {
        local method="$1" url="$2" body_file="$3" label="$4"
        local tmp http msg attempt
        for attempt in 1 2; do
            tmp=$(mktemp)
            http=$(curl -sS --max-time 60 -w '%{http_code}' -o "$tmp" -X "$method" "$url" \
                -H "X-N8N-API-KEY: $N8N_API_KEY" \
                -H "Content-Type: application/json" \
                --data-binary @"$body_file" 2>/dev/null) || {
                rm -f "$tmp"
                echo "  ❌ n8n API unreachable ($label)" >&2
                return 1
            }
            if ! msg=$(jq -r '.message // empty' "$tmp" 2>/dev/null); then
                # Don't log response body — may contain credentials.
                rm -f "$tmp"
                echo "  ❌ HTTP $http — Non-JSON response ($label) — check N8N_API_KEY/N8N_LOCAL_API_URL" >&2
                return 1
            fi
            if [ "${http:0:1}" = "2" ] && [ -z "$msg" ]; then
                cat "$tmp"; rm -f "$tmp"; return 0
            fi
            rm -f "$tmp"
            if [ "$attempt" = "1" ] && printf '%s' "$msg" | grep -q 'must NOT have additional properties'; then
                jq 'del(.settings.availableInMCP)' "$body_file" > "${body_file}.retry" \
                    && mv "${body_file}.retry" "$body_file"
                echo "  ↻ $label: n8n schema rejected a settings key — retrying without settings.availableInMCP" >&2
                continue
            fi
            echo "  ❌ HTTP $http — Failed ($label): ${msg:-unknown error}" >&2
            return 1
        done
    }

    mkdir -p "$WORKFLOWS_DIR"

    if [ "$ACTION" = "--pull" ]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] Pulling workflows from n8n..."

        WORKFLOWS=$(n8n_get_all "$N8N_LOCAL_API_URL/workflows")

        # A real error response has no .data array; grepping for "message" would
        # false-positive on node params (Set nodes carry a message field).
        if ! echo "$WORKFLOWS" | jq -e '.data | type == "array"' >/dev/null 2>&1; then
            echo "API Error: $(echo "$WORKFLOWS" | jq -r '.message // "unexpected response (no .data array)"' 2>/dev/null || echo 'unparseable response')"
            diagnose_api_response "$WORKFLOWS"
            exit 1
        fi

        # Empty API list + existing local files = abort. Pull would otherwise
        # wipe every JSON as "stale" after a fresh DB / accidental UI delete.
        WORKFLOW_COUNT=$(echo "$WORKFLOWS" | jq -r '.data | length' 2>/dev/null || echo 0)
        EXISTING_COUNT=$(find "$WORKFLOWS_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
        if [ "${WORKFLOW_COUNT:-0}" = "0" ] && [ "${EXISTING_COUNT:-0}" -gt 0 ]; then
            echo "⚠️  n8n API returned 0 workflows but $EXISTING_COUNT local file(s) exist in $WORKFLOWS_DIR."
            echo "   Refusing to delete them — this is almost certainly one of:"
            echo "     • fresh init (push workflows first: deploy or 'sync --push')"
            echo "     • API key invalidated after container recreation"
            echo "     • workflows accidentally deleted in n8n UI"
            echo "   To override, manually clear $WORKFLOWS_DIR and re-run."
            exit 1
        fi

        EXPECTED_FILES=$(mktemp)
        FAILED_FETCHES=$(mktemp)
        trap 'rm -f "$EXPECTED_FILES" "$FAILED_FETCHES"' EXIT

        echo "$WORKFLOWS" | jq -c '.data[]' | while read -r wf; do
            ID=$(echo "$wf" | jq -r '.id')
            NAME=$(echo "$wf" | jq -r '.name' | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/_/g' -e 's/__/_/g')

            FILENAME="${WORKFLOWS_DIR}/${NAME}.json"
            # Two distinct workflows slugging to one filename = silent data loss.
            if grep -qxF "$FILENAME" "$EXPECTED_FILES"; then
                echo "  ❌ Slug collision: two workflows map to ${NAME}.json — rename one in the n8n UI"
                echo "collision:$FILENAME" >> "$FAILED_FETCHES"
                continue
            fi
            echo "$FILENAME" >> "$EXPECTED_FILES"

            # Repo-side `_errorWorkflowName` marker (push-time opt-out/override) is
            # not stored in n8n — carry it over so a pull doesn't strip it.
            _MK='null'; _MK_JQ='.'
            if [ -f "$FILENAME" ] && jq -e 'has("_errorWorkflowName")' "$FILENAME" >/dev/null 2>&1; then
                _MK=$(jq -c '._errorWorkflowName' "$FILENAME" 2>/dev/null || echo null)
                _MK_JQ='{_errorWorkflowName: $mk} + .'
            fi

            # Fetch via tmpfile so a failed/truncated body never overwrites the
            # saved JSON. `active` is included so push can use it as source of truth.
            _TMPWF=$(mktemp)
            if curl --fail-with-body -sS --max-time 30 -X GET "$N8N_LOCAL_API_URL/workflows/$ID" \
                    -H "X-N8N-API-KEY: $N8N_API_KEY" | \
                    jq -e '{name, nodes, connections, settings: (.settings // {}), active}' | \
                    jq -e --argjson mk "$_MK" "$_MK_JQ" | \
                    python3 -c 'import json,sys,re;s=json.dumps(json.load(sys.stdin),indent=2);s=re.sub(r"\[\n\s+(-?\d+(?:\.\d+)?),\n\s+(-?\d+(?:\.\d+)?)\n\s+\]",r"[\1, \2]",s);print(s)' > "$_TMPWF"; then
                mv "$_TMPWF" "$FILENAME"
                echo "  Saved: ${NAME}.json"
            else
                rm -f "$_TMPWF"
                echo "  ❌ Failed to fetch workflow $ID ($NAME)"
                echo "fetch:$ID" >> "$FAILED_FETCHES"
            fi
        done

        # A partial pull must not exit 0 — the caller (github-commit-workflows.sh)
        # would commit stale JSON under a fresh publish message.
        if [ -s "$FAILED_FETCHES" ]; then
            echo "❌ Pull incomplete: $(wc -l < "$FAILED_FETCHES" | tr -d ' ') workflow(s) failed (see above) — not touching stale-file cleanup"
            exit 1
        fi

        # Drop local files no longer present in n8n (renamed, fake IDs, etc.).
        REMOVED=0
        while IFS= read -r -d '' existing_file; do
            if ! grep -qxF "$existing_file" "$EXPECTED_FILES"; then
                echo "  🗑️  Removed stale: $(basename "$existing_file")"
                rm "$existing_file"
                REMOVED=$((REMOVED + 1))
            fi
        done < <(find "$WORKFLOWS_DIR" -maxdepth 1 -name '*.json' -print0)

        [ "$REMOVED" -gt 0 ] && echo "  Cleaned up $REMOVED stale file(s)."
        echo "Done."
    else
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] Pushing workflows to n8n..."

        # Upsert by name, not by filename ID — n8n-generated IDs differ from
        # placeholders, so by-ID would duplicate on every deploy.
        EXISTING_JSON=$(n8n_get_all "$N8N_LOCAL_API_URL/workflows")
        if ! echo "$EXISTING_JSON" | jq -e '.data | type == "array"' > /dev/null 2>&1; then
            echo "  ❌ Could not fetch existing workflows from n8n API."
            diagnose_api_response "$EXISTING_JSON"
            exit 1
        fi
        [[ ${BASH_VERSINFO[0]} -ge 4 ]] || { echo "❌ bash 4.0+ required for --push (got $BASH_VERSION)"; exit 1; }

        # Ambiguous name→id map would compound the problem on every push.
        DUPLICATE_NAMES=$(echo "$EXISTING_JSON" | jq -r \
            '[.data[] | select((.isArchived // false) != true) | .name] | group_by(.) | map(select(length > 1) | .[0]) | .[]' 2>/dev/null || true)
        if [ -n "$DUPLICATE_NAMES" ]; then
            echo "  ❌ Duplicate workflow names in n8n — push aborted to prevent further multiplication:"
            echo "$DUPLICATE_NAMES" | sed 's/^/     /'
            echo "     Rename or delete duplicates in the n8n UI, then retry."
            exit 1
        fi

        declare -A NAME_TO_ID
        # Map size is verified against the API count below — a silent jq failure
        # in the process substitution is invisible to set -e.
        while IFS=$'\t' read -r wf_name wf_id; do
            [ -n "$wf_name" ] && NAME_TO_ID["$wf_name"]="$wf_id"
        done < <(echo "$EXISTING_JSON" | jq -r '.data[] | select((.isArchived // false) != true) | [.name, .id] | @tsv')
        _API_COUNT=$(echo "$EXISTING_JSON" | jq -r '[.data[] | select((.isArchived // false) != true)] | length' 2>/dev/null || echo 0)
        if [ "${#NAME_TO_ID[@]}" -ne "${_API_COUNT:-0}" ]; then
            echo "  ❌ name→id map incomplete (${#NAME_TO_ID[@]} of ${_API_COUNT}) — aborting to avoid duplicate re-POSTs"
            exit 1
        fi

        # Names whose repo JSON was removed in this push (git status D, passed by
        # the deploy as `;`-separated DELETED_WORKFLOWS) → hard-deleted from n8n
        # after the upsert. Only acts on names live in n8n and not re-added locally.
        declare -A LOCAL_NAMES
        for _f in "$WORKFLOWS_DIR"/*.json; do
            [ -f "$_f" ] || continue
            _wname=$(jq -r '.name // empty' "$_f" 2>/dev/null)
            [ -n "$_wname" ] && LOCAL_NAMES["$_wname"]="1"
        done
        TO_DELETE=()
        if [ -n "${DELETED_WORKFLOWS:-}" ]; then
            _old_ifs="$IFS"; IFS=';'
            for _dname in $DELETED_WORKFLOWS; do
                [ -n "$_dname" ] || continue
                [ -n "${NAME_TO_ID[$_dname]:-}" ] && [ -z "${LOCAL_NAMES[$_dname]:-}" ] && TO_DELETE+=("$_dname")
            done
            IFS="$_old_ifs"
        fi

        # On a cold container n8n answers /workflows (200) before its activation
        # subsystem (webhook registration) is ready, so /activate flaps non-200.
        # Retry with backoff (~50s total) instead of a single 5s retry.
        _activate_wf() { # wf_id fname
            local code attempt
            local -a delays=(0 3 5 8 13 21)
            for attempt in "${delays[@]}"; do
                [ "$attempt" -gt 0 ] && sleep "$attempt"
                code=$(curl -s --connect-timeout 5 --max-time 30 -o /dev/null -w '%{http_code}' -X POST \
                    "$N8N_LOCAL_API_URL/workflows/$1/activate" \
                    -H "X-N8N-API-KEY: $N8N_API_KEY") || code="000"
                if [ "$code" = "200" ]; then
                    echo "  🔄 Activated: $2"
                    return 0
                fi
            done
            echo "  ⚠️  Activation failed (HTTP $code) after ${#delays[@]} attempts: $2 — toggle Active manually in n8n UI"
            return 1
        }

        PUSH_FAILED=0
        # Files whose errorWorkflow target wasn't in NAME_TO_ID yet on pass 1
        # (forward reference). Re-pushed on pass 2.  DEFERRED_TARGET maps each
        # file path → the name to resolve, since the source can be either the
        # explicit `_errorWorkflowName` marker or the auto-link default.
        DEFERRED_ERR_WF=()
        declare -A DEFERRED_TARGET
        DEFAULT_ERR_WF_NAME="Global Error Handler"
        # Drops keys n8n API v1 rejects on write (.active → /activate; some
        # .settings.*); defaults availableInMCP on (repo JSON may set false).
        STRIP_JQ='del(.id, .versionId, .meta, .tags, .createdAt, .updatedAt, .active, ._errorWorkflowName, .settings.binaryMode, .settings.timeSavedMode, .settings.callerPolicy) | (if (.settings // {} | has("availableInMCP")) then . else (.settings.availableInMCP = true) end) | (if (.settings // {} | has("timezone")) then . else (.settings.timezone = $tz) end)'

        for FILE in "$WORKFLOWS_DIR"/*.json; do
            [ -f "$FILE" ] || continue
            FNAME=$(basename "$FILE")
            if ! jq empty "$FILE" 2>/dev/null; then
                echo "  ❌ Invalid JSON — skipping $FNAME (run: jq . $FILE)"
                PUSH_FAILED=1
                continue
            fi
            WF_NAME=$(jq -r '.name // empty' "$FILE" 2>/dev/null)
            if [ -z "$WF_NAME" ]; then
                echo "  ❌ Missing .name field — skipping $FNAME"
                PUSH_FAILED=1
                continue
            fi
            LIVE_ID="${NAME_TO_ID[$WF_NAME]:-}"

            WF_ACTIVE=$(jq -r '.active // false' "$FILE" 2>/dev/null)

            _push_body=$(mktemp)
            jq --arg tz "${DISPLAY_TZ:-UTC}" "$STRIP_JQ" "$FILE" > "$_push_body"

            # Decide which workflow name to link as errorWorkflow:
            #   • explicit marker `_errorWorkflowName` always wins (empty = opt-out)
            #   • else, auto-link every workflow except "Global Error Handler" itself
            #     when `settings.errorWorkflow` isn't already set
            ERR_WF_NAME=""
            if jq -e 'has("_errorWorkflowName")' "$FILE" >/dev/null 2>&1; then
                ERR_WF_NAME=$(jq -r '._errorWorkflowName // ""' "$FILE" 2>/dev/null)
            elif [ "$WF_NAME" != "$DEFAULT_ERR_WF_NAME" ] && \
                 ! jq -e '.settings.errorWorkflow | strings | length > 0' "$FILE" >/dev/null 2>&1; then
                ERR_WF_NAME="$DEFAULT_ERR_WF_NAME"
            fi

            if [ -z "$ERR_WF_NAME" ] && jq -e 'has("_errorWorkflowName")' "$FILE" >/dev/null 2>&1; then
                # Explicit opt-out — drop any inherited errorWorkflow.
                jq 'del(.settings.errorWorkflow)' "$_push_body" > "${_push_body}.tmp" \
                    && mv "${_push_body}.tmp" "$_push_body"
            elif [ -n "$ERR_WF_NAME" ]; then
                ERR_WF_ID="${NAME_TO_ID[$ERR_WF_NAME]:-}"
                if [ -n "$ERR_WF_ID" ]; then
                    jq --arg id "$ERR_WF_ID" '.settings.errorWorkflow = $id' "$_push_body" > "${_push_body}.tmp" \
                        && mv "${_push_body}.tmp" "$_push_body"
                else
                    jq 'del(.settings.errorWorkflow)' "$_push_body" > "${_push_body}.tmp" \
                        && mv "${_push_body}.tmp" "$_push_body"
                    DEFERRED_ERR_WF+=("$FILE")
                    DEFERRED_TARGET["$FILE"]="$ERR_WF_NAME"
                fi
            fi

            if [ -n "$LIVE_ID" ]; then
                if RESPONSE=$(n8n_api_write PUT "$N8N_LOCAL_API_URL/workflows/$LIVE_ID" "$_push_body" "update $FNAME"); then
                    echo "  ✅ Updated: $FNAME"
                    if [ "$WF_ACTIVE" = "true" ]; then
                        _activate_wf "$LIVE_ID" "$FNAME" || PUSH_FAILED=1
                    fi
                else
                    PUSH_FAILED=1
                fi
            else
                if RESPONSE=$(n8n_api_write POST "$N8N_LOCAL_API_URL/workflows" "$_push_body" "create $FNAME"); then
                    NEW_ID=$(echo "$RESPONSE" | jq -r '.id // empty')
                    echo "  ✅ Created: $FNAME"
                    if [ "$WF_ACTIVE" = "true" ] && [ -n "$NEW_ID" ]; then
                        _activate_wf "$NEW_ID" "$FNAME" || PUSH_FAILED=1
                    fi
                else
                    PUSH_FAILED=1
                fi
            fi
            rm -f "$_push_body"

            # Pass 1 picked up a new ID for this name — record it for pass 2.
            if [ -z "$LIVE_ID" ] && [ -n "${NEW_ID:-}" ]; then
                NAME_TO_ID["$WF_NAME"]="$NEW_ID"
            fi
            NEW_ID=""
        done

        # Pass 2: re-push files whose errorWorkflow target was unknown on pass 1
        # (forward references). Target name comes from DEFERRED_TARGET so this
        # works both for explicit `_errorWorkflowName` and the auto-link default.
        for FILE in "${DEFERRED_ERR_WF[@]}"; do
            FNAME=$(basename "$FILE")
            WF_NAME=$(jq -r '.name // empty' "$FILE" 2>/dev/null)
            LIVE_ID="${NAME_TO_ID[$WF_NAME]:-}"
            ERR_WF_NAME="${DEFERRED_TARGET[$FILE]:-}"
            ERR_WF_ID="${NAME_TO_ID[$ERR_WF_NAME]:-}"
            if [ -z "$LIVE_ID" ] || [ -z "$ERR_WF_ID" ]; then
                echo "  ⚠️  Could not resolve errorWorkflow for $FNAME (target: '$ERR_WF_NAME')"
                PUSH_FAILED=1
                continue
            fi
            WF_ACTIVE=$(jq -r '.active // false' "$FILE" 2>/dev/null)
            _push_body=$(mktemp)
            # Apply STRIP_JQ first, then set errorWorkflow — separate pipes are
            # safer than bash-concatenating jq filters.
            jq --arg tz "${DISPLAY_TZ:-UTC}" "$STRIP_JQ" "$FILE" \
              | jq --arg id "$ERR_WF_ID" '.settings.errorWorkflow = $id' \
              > "$_push_body"
            if n8n_api_write PUT "$N8N_LOCAL_API_URL/workflows/$LIVE_ID" "$_push_body" "link errorWorkflow for $FNAME" >/dev/null; then
                echo "  🔗 Linked errorWorkflow: $FNAME → $ERR_WF_NAME"
                # PUT resets active=false; re-activate if source says active.
                if [ "$WF_ACTIVE" = "true" ]; then
                    _activate_wf "$LIVE_ID" "$FNAME" || PUSH_FAILED=1
                fi
            else
                PUSH_FAILED=1
            fi
            rm -f "$_push_body"
        done

        # Hard-delete workflows whose repo JSON was removed in this commit (or whose
        # .name changed). Skipped if any upsert failed — a failed rename must not
        # delete the old workflow while its replacement is missing (retry next sync).
        if [ "$PUSH_FAILED" -ne 0 ] && [ "${#TO_DELETE[@]}" -gt 0 ]; then
            echo "  ⏭️  Skipping ${#TO_DELETE[@]} deletion(s) — a push failed this run. Re-run THIS deploy"
            echo "     after fixing the cause; a NEW commit won't re-derive these deletions (the old"
            echo "     workflow stays live until then)."
            TO_DELETE=()
        fi
        for _dname in "${TO_DELETE[@]}"; do
            _del_id="${NAME_TO_ID[$_dname]:-}"
            [ -n "$_del_id" ] || continue
            _del_tmp=$(mktemp)
            _del_http=$(curl -sS --max-time 30 -w '%{http_code}' -o "$_del_tmp" -X DELETE \
                "$N8N_LOCAL_API_URL/workflows/$_del_id" \
                -H "X-N8N-API-KEY: $N8N_API_KEY" 2>/dev/null) || _del_http="000"
            _del_msg=$(jq -r '.message // empty' "$_del_tmp" 2>/dev/null || echo "non-JSON response")
            rm -f "$_del_tmp"
            if [ "$_del_http" = "200" ] && [ -z "$_del_msg" ]; then
                echo "  🗑️  Deleted from n8n (removed in repo): $_dname"
            else
                echo "  ❌ HTTP $_del_http — Failed to delete '$_dname'${_del_msg:+: $_del_msg}"
                PUSH_FAILED=1
            fi
        done

        echo "Done."
        [ "$PUSH_FAILED" -eq 0 ] || exit 1
    fi
else
    # ── Dev mode: rsync + remote invocation ──
    ROOT_DIR="$SCRIPT_DIR/../.."
    if [ -f "$ROOT_DIR/.env.config" ]; then
        set -a
        source "$ROOT_DIR/.env.config"
        [ -f "$ROOT_DIR/.env.local" ] && source "$ROOT_DIR/.env.local"
        set +a
    else
        echo "❌ .env.config not found at $ROOT_DIR/.env.config"
        echo "   • Developer machine: run from the repo root (needs .env.config + .env.local)."
        echo "   • VPS: /root/n8n/.backup_creds is missing — run a deploy (or npm run initialize) first."
        exit 1
    fi

    : "${N8N_VPS_USER:?Missing N8N_VPS_USER in .env.local}"
    : "${N8N_VPS_IP:?Missing N8N_VPS_IP in .env.local}"

    # Honor a configured non-default identity (as initialize.sh does) — otherwise
    # pull/push silently use whatever the agent/ssh_config offers.
    N8N_SSH_OPTS=()
    if [ -n "${SSH_PRIVATE_KEY:-}" ]; then
        _ssh_key="${SSH_PRIVATE_KEY/#\~/$HOME}"
        [ -f "$_ssh_key" ] && N8N_SSH_OPTS=(-i "$_ssh_key" -o IdentitiesOnly=yes)
    fi

    if [ "$ACTION" = "--pull" ]; then
        echo "📥 Telling VPS to extract workflows from database..."
        ssh "${N8N_SSH_OPTS[@]}" "$N8N_VPS_USER@$N8N_VPS_IP" "cd ~/n8n && bash scripts/sync-workflows.sh --pull"

        echo "⬇️  Downloading JSON files to Developer's PC..."
        mkdir -p "$WORKFLOWS_DIR"
        # Empty remote dir + rsync --delete would wipe local workflows.
        _remote_count=$(ssh "${N8N_SSH_OPTS[@]}" "$N8N_VPS_USER@$N8N_VPS_IP" 'ls ~/n8n/workflows/*.json 2>/dev/null | wc -l' | tr -d ' ')
        [ "${_remote_count:-0}" -gt 0 ] || {
            echo "❌ Remote ~/n8n/workflows/ is empty — aborting rsync --delete to preserve local files"
            exit 1
        }

        # Catches DB wipe / restore-to-older-snapshot / wrong-VPS targeting,
        # where rsync --delete would silently destroy workflows that still
        # exist locally. Compare workflow names (JSON .name), not filenames —
        # n8n assigns fresh IDs on first push, so filename diff would always trip.
        _LOCAL_NAMES=$(find "$WORKFLOWS_DIR" -maxdepth 1 -name '*.json' \
            -exec jq -r '.name // empty' {} \; 2>/dev/null | sort -u)
        if [ -n "$_LOCAL_NAMES" ]; then
            _REMOTE_NAMES=$(ssh "${N8N_SSH_OPTS[@]}" "$N8N_VPS_USER@$N8N_VPS_IP" \
                "for f in ~/n8n/workflows/*.json; do jq -r '.name // empty' \"\$f\" 2>/dev/null; done" \
                | sort -u)
            _LOST=$(comm -23 <(printf '%s\n' "$_LOCAL_NAMES" | grep .) <(printf '%s\n' "$_REMOTE_NAMES" | grep .) || true)
            _LOST_COUNT=$(printf '%s' "$_LOST" | grep -c . || true)
            _KEPT_COUNT=$(comm -12 <(printf '%s\n' "$_LOCAL_NAMES" | grep .) <(printf '%s\n' "$_REMOTE_NAMES" | grep .) 2>/dev/null | grep -c . || true)
            if [ "${_LOST_COUNT:-0}" -ge 2 ] && [ "${_LOST_COUNT:-0}" -gt "${_KEPT_COUNT:-0}" ]; then
                echo ""
                echo "⚠️  About to delete ${_LOST_COUNT} local workflow(s) absent from n8n:"
                printf '%s\n' "$_LOST" | sed 's/^/     • /'
                echo ""
                echo "   n8n returns ${_remote_count} workflow(s); ${_KEPT_COUNT} of their names match local files."
                echo "   Common causes: DB wiped/restored, workflows deleted in the n8n UI, pulling against the wrong VPS."
                echo ""
                if [ "$FORCE" = "1" ]; then
                    echo "   --force set → proceeding with destructive sync."
                elif [ -t 0 ] && [ -t 1 ]; then
                    printf "   Type 'yes' to delete the local files anyway, anything else to abort: "
                    read -r _confirm </dev/tty || _confirm=""
                    if [ "$_confirm" != "yes" ]; then
                        echo "   Aborted. Push them first or re-run with --force."
                        exit 1
                    fi
                else
                    echo "   Non-interactive shell — refusing to delete. Re-run with --force to bypass."
                    exit 1
                fi
            fi
        fi
        unset _LOCAL_NAMES _REMOTE_NAMES _LOST _LOST_COUNT _KEPT_COUNT _confirm

        rsync -avz --delete -e "ssh ${N8N_SSH_OPTS[*]}" "$N8N_VPS_USER@$N8N_VPS_IP:~/n8n/workflows/" "$WORKFLOWS_DIR/"

        echo "✅ Pull complete!"
    else
        echo "⬆️  Uploading local JSON files to VPS..."
        # Empty local dir + rsync --delete would wipe every VPS workflow.
        # Count *.json, not `ls -A` — a lone .DS_Store must not pass the guard.
        _local_count=$(find "$WORKFLOWS_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
        [ "${_local_count:-0}" -gt 0 ] || {
            echo "❌ $WORKFLOWS_DIR has no *.json — aborting push to avoid deleting VPS workflows"
            exit 1
        }
        rsync -avz --delete -e "ssh ${N8N_SSH_OPTS[*]}" "$WORKFLOWS_DIR/" "$N8N_VPS_USER@$N8N_VPS_IP:~/n8n/workflows/" && \
          { echo "📤 Telling VPS to update the database..."
            ssh "${N8N_SSH_OPTS[@]}" "$N8N_VPS_USER@$N8N_VPS_IP" "cd ~/n8n && bash scripts/sync-workflows.sh --push"; } || {
            echo "❌ Remote push failed — local rsync may have left stale files on VPS"
            exit 1
          }
        echo "✅ Push complete!"
    fi
fi
