#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

MODE="interactive"
FIRST_RUN=false
case "${1:-}" in
    --yes)     MODE="yes" ;;
    --dry-run) MODE="dry-run" ;;
    --first-run) FIRST_RUN=true ;;
    "")        ;;
    *)
        echo "Usage: $0 [--yes | --dry-run | --first-run]" >&2
        exit 1
        ;;
esac

command -v jq   >/dev/null || { echo "❌ jq required (brew install jq)";   exit 1; }
command -v curl >/dev/null || { echo "❌ curl required";                    exit 1; }

IMAGES=$(cat <<'TABLE'
library/postgres	^16\.[0-9]+-alpine$	n8n/docker-compose.yml	postgres:[^@ ]+@sha256:[a-f0-9]+	postgres:	dockerhub|library/postgres
n8nio/n8n	^2\.[0-9]+\.[0-9]+$	n8n/docker-compose.yml	n8nio/n8n:[^@ ]+@sha256:[a-f0-9]+	n8nio/n8n:	dockerhub|n8nio/n8n
cloudflare/cloudflared	^[0-9]+\.[0-9]+\.[0-9]+$	n8n/docker-compose.yml	cloudflare/cloudflared:[^@ ]+@sha256:[a-f0-9]+	cloudflare/cloudflared:	dockerhub|cloudflare/cloudflared
TABLE
)

# Order by last_updated — Hub's default sometimes interleaves old tags off page 1.
fetch_latest_tag() {
    local hub_path="$1" filter="$2" page=1 all="" page_data names tag stable_digest
    if [ "$hub_path" = n8nio/n8n ]; then
        if ! stable_digest=$(fetch_tag_digest 'dockerhub|n8nio/n8n' stable 2>&1); then
            printf 'stable tag: %s\n' "${stable_digest:-digest lookup returned no digest}" >&2
            return 1
        fi
        if ! [[ "$stable_digest" =~ ^sha256:[a-f0-9]{64}$ ]]; then
            printf 'stable tag: missing or invalid digest\n' >&2
            return 1
        fi
    fi
    if [[ "$hub_path" == ghcr.io/* ]]; then
        local repo="${hub_path#ghcr.io/}" token
        token=$(fetch_registry_response 'tag listing' \
            "https://ghcr.io/token?scope=repository:${repo}:pull&service=ghcr.io" \
          | jq -r '.token') || return 1
        [ -n "$token" ] || return 1
        page_data=$(printf 'header = "Authorization: Bearer %s"\n' "$token" \
          | fetch_registry_response 'tag listing' -K - \
            "https://ghcr.io/v2/${repo}/tags/list?n=1000") || return 1
        tag=$(echo "$page_data" | jq -r '.tags[]?' | grep -E "$filter" | sort -V -u | tail -1 || true)
        [ -n "$tag" ] && printf '%s' "$tag"
        return 0
    fi
    while [ "$page" -le 5 ]; do
        page_data=$(fetch_registry_response 'tag listing' \
            "https://hub.docker.com/v2/repositories/${hub_path}/tags?page_size=100&ordering=last_updated&page=${page}") || return 1
        names=$(echo "$page_data" | jq -r '.results[].name' 2>/dev/null) || true
        [ -z "$names" ] && break
        if [ "$hub_path" = n8nio/n8n ]; then
            names=$(printf '%s' "$page_data" | jq -r --arg digest "$stable_digest" \
                '.results[] | select(.digest == $digest) | .name') || return 1
        fi
        all="${all}${names}\n"
        echo "$page_data" | jq -e '.next' >/dev/null 2>&1 || break
        page=$((page + 1))
    done
    tag=$(printf '%b' "$all" | grep -E "$filter" | sort -V -u | tail -1 || true)
    if [ "$hub_path" = n8nio/n8n ] && [ -z "$tag" ]; then
        printf 'no tags matched filter: no numeric tag matches the stable digest\n' >&2
        return 1
    fi
    [ -n "$tag" ] && printf '%s' "$tag"
    return 0
}

fetch_registry_response() {
    local operation="$1" response http_status
    shift
    if ! response=$(curl -sS --max-time 15 -w '\n%{http_code}' "$@" 2>/dev/null); then
        printf '%s connection failed\n' "$operation" >&2
        return 1
    fi
    http_status=${response##*$'\n'}
    case "$http_status" in
        2[0-9][0-9]) printf '%s' "${response%$'\n'*}" ;;
        429) printf '%s rate limited (HTTP 429)\n' "$operation" >&2; return 1 ;;
        *) printf '%s failed (HTTP %s)\n' "$operation" "$http_status" >&2; return 1 ;;
    esac
}

fetch_tag_digest() {
    local digest_src="$1" tag="$2"
    local registry="${digest_src%%|*}" repo="${digest_src#*|}"
    case "$registry" in
        dockerhub)
            local _token headers
            _token=$(fetch_registry_response 'digest lookup' \
                "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" \
              | jq -er '.token // empty') || return 1
            # Manifest GET consumes Hub's pull quota; HEAD returns the multi-arch index digest.
            headers=$(printf 'header = "Authorization: Bearer %s"\n' "$_token" \
              | fetch_registry_response 'digest lookup' -I -K - \
                -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
                "https://registry-1.docker.io/v2/${repo}/manifests/${tag}") || return 1
            printf '%s\n' "$headers" | grep -i '^docker-content-digest:' \
              | LC_ALL=C awk '{print $2}' | tr -d '\r\n' | head -c 79
            ;;
        *)
            echo "❌ Unknown digest registry: $registry" >&2
            return 1
            ;;
    esac
}

sed_inplace() {
    local expr="$1" file="$2"
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i "$expr" "$file"
    else
        sed -i '' "$expr" "$file"
    fi
}

REPL_FILES=()
REPL_EXPRS=()
ANY_CHANGE=false
SKIPPED=0
STATEFUL_BUMPS=()

echo "🐳 Checking Docker image pins for updates..."
echo ""
printf '  %-32s  %-20s  %s\n' "Image" "Current" "→ Latest"
echo "  ─────────────────────────────────────────────────────────────────────────"

while IFS=$'\t' read -r HUB FILTER FILE LINE_PAT PREFIX DIGEST_SRC; do
    [ -n "$HUB" ] || continue
    FULL_FILE="$ROOT_DIR/$FILE"
    if [ ! -f "$FULL_FILE" ]; then
        printf '  %-32s  %s\n' "$HUB" "⚠️  missing $FILE — skipped"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # `|| true`: under pipefail a no-match grep would abort the script silently here.
    CURRENT=$(grep -oE "$LINE_PAT" "$FULL_FILE" | head -1 || true)
    if [ -z "$CURRENT" ]; then
        printf '  %-32s  %s\n' "$HUB" "⚠️  no pin found in $FILE — skipped"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    AFTER_COLON=${CURRENT#"$PREFIX"}
    CURRENT_TAG=${AFTER_COLON%@*}
    CURRENT_DIGEST=${CURRENT#*@}

    if ! LATEST_TAG=$(fetch_latest_tag "$HUB" "$FILTER" 2>&1); then
        printf '  %-32s  ❌ %s — skipped\n' "$HUB" "${LATEST_TAG:-tag listing failed}"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    if [ -z "$LATEST_TAG" ]; then
        printf '  %-32s  %s\n' "$HUB" "❌ no tags matched filter — skipped"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    if ! LATEST_DIGEST=$(fetch_tag_digest "$DIGEST_SRC" "$LATEST_TAG" 2>&1) || [ -z "$LATEST_DIGEST" ]; then
        printf '  %-32s  ❌ %s — skipped\n' "$HUB" "${LATEST_DIGEST:-digest fetch failed}"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    if [ "$CURRENT_TAG" = "$LATEST_TAG" ] && [ "$CURRENT_DIGEST" = "$LATEST_DIGEST" ]; then
        printf '  %-32s  %-20s  %s\n' "$HUB" "$CURRENT_TAG" "✓ up-to-date"
        continue
    fi

    ANY_CHANGE=true
    if [ "$CURRENT_TAG" != "$LATEST_TAG" ]; then
        printf '  %-32s  %-20s  → %s\n' "$HUB" "$CURRENT_TAG" "$LATEST_TAG"
        case "$HUB" in
            n8nio/n8n|library/postgres)
                STATEFUL_BUMPS+=("$HUB: $CURRENT_TAG → $LATEST_TAG")
                ;;
        esac
    else
        printf '  %-32s  %-20s  → digest refresh only\n' "$HUB" "$CURRENT_TAG"
    fi

    NEW="${PREFIX}${LATEST_TAG}@${LATEST_DIGEST}"
    # `|` delimiter — image strings have `/` but never `|`.
    ESC_CUR=$(printf '%s' "$CURRENT" | sed 's/[\\&|]/\\&/g')
    ESC_NEW=$(printf '%s' "$NEW"     | sed 's/[\\&|]/\\&/g')
    REPL_FILES+=("$FILE")
    REPL_EXPRS+=("s|${ESC_CUR}|${ESC_NEW}|")
done <<<"$IMAGES"

echo ""

report_skipped_and_exit() {
    if [ "$SKIPPED" -gt 0 ]; then
        echo "❌ ${SKIPPED} image lookup(s) failed — those pins were NOT checked (see ❌/⚠️ rows above). Re-run when the registry is reachable." >&2
        exit 1
    fi
    exit 0
}

if [ "$ANY_CHANGE" = "false" ]; then
    [ "$SKIPPED" -gt 0 ] || echo "✅ All image pins are already up-to-date."
    report_skipped_and_exit
fi

if [ "$FIRST_RUN" = false ] && [ ${#STATEFUL_BUMPS[@]} -gt 0 ]; then
    printf '⚠️  %s: DB migrations are one-way; take a backup first with npm run backup-database. See docs/operations.md#image-updates-and-rollback.\n' "${STATEFUL_BUMPS[*]}"
fi

if [ "$MODE" = "dry-run" ]; then
    echo "ℹ️  --dry-run — no files modified."
    report_skipped_and_exit
fi

if [ "$MODE" = "interactive" ]; then
    PROMPT='Apply these changes? [y/N]: '
    [ "$FIRST_RUN" = false ] || PROMPT='Apply these changes? [Y/n]: '
    # The wizard can exhaust stdin before reaching this prompt.
    if ! printf '%s' "$PROMPT" >/dev/tty || ! IFS= read -r CONFIRM </dev/tty; then
        echo "❌ Aborted — no files modified."
        exit 0
    fi
    case "$CONFIRM" in
        y|Y) ;;
        "") [ "$FIRST_RUN" = true ] || { echo "❌ Aborted — no files modified."; exit 0; } ;;
        *) echo "❌ Aborted — no files modified."; exit 0 ;;
    esac
fi

for i in "${!REPL_FILES[@]}"; do
    FILE="${REPL_FILES[$i]}"
    EXPR="${REPL_EXPRS[$i]}"
    sed_inplace "$EXPR" "$ROOT_DIR/$FILE"
    echo "  ✅ Updated: $FILE"
done

# Versioned comments around image: lines drift silently — flag them.
DRIFT_FOUND=false
declare -a SEEN=()
for FILE in "${REPL_FILES[@]}"; do
    case " ${SEEN[*]:-} " in *" $FILE "*) continue ;; esac
    SEEN+=("$FILE")
    while IFS=$'\t' read -r HUB _FILTER _FILE _LINE_PAT _PREFIX _DIGEST_SRC; do
        [ -n "$HUB" ] || continue
        HITS=$(grep -nE "^[[:space:]]*#.*${HUB}:[A-Za-z0-9._-]+" "$ROOT_DIR/$FILE" || true)
        if [ -n "$HITS" ]; then
            if [ "$DRIFT_FOUND" = "false" ]; then
                echo ""
                echo "⚠️  Versioned comments detected — please remove the version (the"
                echo "    image: line is the source of truth, comments drift silently):"
                DRIFT_FOUND=true
            fi
            echo "$HITS" | while IFS= read -r LINE; do
                echo "    $FILE: $LINE"
            done
        fi
    done <<<"$IMAGES"
done

echo ""
echo "✅ Image pins refreshed. Review with: git diff"
report_skipped_and_exit
