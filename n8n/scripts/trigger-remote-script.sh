#!/bin/bash
# Usage: trigger-remote-script.sh <remote-script-name> [args...]
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/../.."

if [ -f "$ROOT_DIR/.env.config" ]; then
    set -a
    source "$ROOT_DIR/.env.config"
    [ -f "$ROOT_DIR/.env.local" ] && source "$ROOT_DIR/.env.local"
    set +a
else
    echo "❌ .env.config not found at $ROOT_DIR/.env.config"
    exit 1
fi

: "${N8N_VPS_USER:?Missing N8N_VPS_USER in .env.local}"
: "${N8N_VPS_IP:?Missing N8N_VPS_IP in .env.local}"

REMOTE_SCRIPT="$1"
shift || true

if [ -z "$REMOTE_SCRIPT" ]; then
    echo "Usage: trigger-remote-script.sh <remote-script-name> [args...]"
    exit 1
fi

# Reject absolute paths, traversal, and shell metacharacters — blocks injection.
case "$REMOTE_SCRIPT" in
    /*|*..*|*[\;\&\|\$\`\<\>\(\)\{\}\"\'\*\?\[\]\\!]*|*$'\n'*|*$'\t'*|"")
        echo "❌ Invalid REMOTE_SCRIPT '$REMOTE_SCRIPT' — must be a relative path under scripts/." >&2
        exit 1
        ;;
esac
if ! printf '%s' "$REMOTE_SCRIPT" | grep -qE '^[a-zA-Z0-9_./-]+\.sh$'; then
    echo "❌ REMOTE_SCRIPT '$REMOTE_SCRIPT' must end with .sh and only contain [a-zA-Z0-9_./-]." >&2
    exit 1
fi

# With zero args `printf '%q '` would emit a literal '' → spurious empty $1 remotely.
QUOTED_ARGS=""
[ "$#" -gt 0 ] && QUOTED_ARGS=$(printf '%q ' "$@")

SSH_OPTS=()
[ -n "${SSH_PRIVATE_KEY:-}" ] && [ -f "${SSH_PRIVATE_KEY/#\~/$HOME}" ] && \
  SSH_OPTS+=("-i" "${SSH_PRIVATE_KEY/#\~/$HOME}")

exec ssh -t "${SSH_OPTS[@]}" "$N8N_VPS_USER@$N8N_VPS_IP" "bash /root/n8n/scripts/${REMOTE_SCRIPT} ${QUOTED_ARGS}"
