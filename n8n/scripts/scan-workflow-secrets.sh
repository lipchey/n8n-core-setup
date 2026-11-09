#!/bin/bash
# Catches leak shapes GitHub Push Protection ignores; bare partner keys are its job.
# Exit: 0 all clean, 1 any match, 2 usage error or missing/unreadable file.
# Output: <file>:<lineno>:<pattern_name>:<masked_value>

set -uo pipefail
# Matches are word-split below rather than redirected: a here-string needs temp storage, and its failure would read as clean.
set -f
IFS=$'\n'

[ $# -ge 1 ] || { echo "usage: $0 <workflow.json> [more.json ...]" >&2; exit 2; }

# url_basic_auth needs a password and url_token_auth a token-shaped user, so
# port-only and plain user@host URLs don't match. Matching is case-insensitive.
PATTERNS=(
    'private_key_pem|-----BEGIN (RSA |EC |OPENSSH |DSA |ENCRYPTED |PGP )?PRIVATE KEY( BLOCK)?-----'
    'url_basic_auth|[a-z][a-z0-9+.-]*://[^/[:space:]:"@]+:[^/[:space:]"@]+@'
    'url_token_auth|https?://((gh[pousr]|github_pat)_[a-z0-9_]+|[a-z0-9_-]{20,})@'
    'query_secret|[?&](api[_-]?key|access[_-]?token|auth[_-]?token|token|secret|password|passwd|pwd)=[^&"[:space:]{}]{4,}'
    'bearer_token|Bearer[[:space:]]+[a-z0-9._~+/=-]{20,}'
    'telegram_bot_token|bot[0-9]+:[a-z0-9_-]{20,}'
)

DIRTY=0
for FILE in "$@"; do
    [ -f "$FILE" ] && [ -r "$FILE" ] || { echo "cannot read $FILE" >&2; exit 2; }
    for ENTRY in "${PATTERNS[@]}"; do
        NAME="${ENTRY%%|*}"
        RE="${ENTRY#*|}"
        MATCHES=$(grep -inEo -e "$RE" "$FILE" 2>/dev/null)
        GREP_RC=$?
        [ "$GREP_RC" -le 1 ] || { echo "grep failed (rc=$GREP_RC) on $FILE" >&2; exit 2; }
        for LINE in $MATCHES; do
            LINENO_PART="${LINE%%:*}"
            MATCH="${LINE#*:}"
            SECRET="$MATCH"
            if [ "$NAME" = url_basic_auth ]; then
                SECRET="${MATCH#*://}"
                SECRET="${SECRET#*:}"
            fi
            # n8n expressions and JS templates resolve at runtime, but only in the secret itself: an expression username can sit beside a literal password.
            case "$SECRET" in *'{{'*|*'${'*) continue ;; esac
            # Prefix only: most matches end on the secret's tail.
            printf '%s:%s:%s:%s\n' "$FILE" "$LINENO_PART" "$NAME" "${MATCH:0:6}***"
            DIRTY=1
        done
    done
done

exit "$DIRTY"
