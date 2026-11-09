#!/bin/bash
# Resolves the age key (~/.config/sops/age/<PROJECT_NAME>.txt, then keys.txt, then <root>/.age-key.age)
# then runs sops encrypt or decrypt. --check-only decrypts to /dev/null; --decrypt-stdout
# streams plaintext to stdout (used by tests that need one value without materialising .env).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRIMARY_KEY="$HOME/.config/sops/age/keys.txt"
FALLBACK_KEY="$ROOT_DIR/.age-key.age"
PROJECT_KEY=""
if [ -f "$ROOT_DIR/.env.config" ]; then
    _project=$(awk -F= '$1=="PROJECT_NAME" { v=$2 } END { print v }' "$ROOT_DIR/.env.config")
    [ -z "$_project" ] || PROJECT_KEY="$HOME/.config/sops/age/${_project}.txt"
fi

# The per-project file wins: keys.txt on a restored or shared machine may not hold this project's key.
if [ -n "$PROJECT_KEY" ] && [ -f "$PROJECT_KEY" ]; then
    KEY_FILE="$PROJECT_KEY"
elif [ -f "$PRIMARY_KEY" ]; then
    KEY_FILE="$PRIMARY_KEY"
elif [ -f "$FALLBACK_KEY" ]; then
    echo "⚠️  Age key not found at $PRIMARY_KEY — using project-root fallback (.age-key.age)" >&2
    KEY_FILE="$FALLBACK_KEY"
else
    echo "❌ No age key found." >&2
    echo "   Expected: ${PROJECT_KEY:-$HOME/.config/sops/age/<PROJECT_NAME>.txt} or $PRIMARY_KEY" >&2
    echo "   Fallback: $FALLBACK_KEY" >&2
    echo "   Drop your age key file at either location and retry." >&2
    exit 1
fi

case "${1:-}" in
  --encrypt)
    # Cleanup the .tmp on any failure path so a half-written blob doesn't linger.
    trap 'rm -f "$ROOT_DIR/.env.sops.yaml.tmp"' EXIT
    SOPS_AGE_KEY_FILE="$KEY_FILE" sops --config "$ROOT_DIR/.sops.yaml" --input-type dotenv --output-type dotenv -e "$ROOT_DIR/.env" \
      > "$ROOT_DIR/.env.sops.yaml.tmp"
    mv "$ROOT_DIR/.env.sops.yaml.tmp" "$ROOT_DIR/.env.sops.yaml"
    rm "$ROOT_DIR/.env"
    trap - EXIT
    ;;
  --decrypt)
    _tmp=$(mktemp "$ROOT_DIR/.env.XXXXXX")
    chmod 600 "$_tmp"
    # Plaintext temp — clean up on interrupt too, not just sops's own failure.
    trap 'rm -f "$_tmp"' EXIT INT TERM
    if SOPS_AGE_KEY_FILE="$KEY_FILE" sops --config "$ROOT_DIR/.sops.yaml" --input-type dotenv --output-type dotenv -d "$ROOT_DIR/.env.sops.yaml" > "$_tmp"; then
        mv "$_tmp" "$ROOT_DIR/.env"
        trap - EXIT INT TERM
    else
        exit 1
    fi
    ;;
  --check-only)
    SOPS_AGE_KEY_FILE="$KEY_FILE" sops --config "$ROOT_DIR/.sops.yaml" --input-type dotenv --output-type dotenv -d "$ROOT_DIR/.env.sops.yaml" > /dev/null
    ;;
  --decrypt-stdout)
    SOPS_AGE_KEY_FILE="$KEY_FILE" sops --config "$ROOT_DIR/.sops.yaml" --input-type dotenv --output-type dotenv -d "$ROOT_DIR/.env.sops.yaml"
    ;;
  *)
    echo "Usage: $0 --encrypt | --decrypt | --check-only | --decrypt-stdout" >&2
    exit 1
    ;;
esac
