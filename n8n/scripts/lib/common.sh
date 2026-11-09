#!/bin/bash
# shellcheck disable=SC2034
# Source before other VPS libraries; supports Bash 3.2.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_CREDS="${BACKUP_CREDS:-/root/n8n/.backup_creds}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "❌ $*" >&2; exit 1; }

require_cmds() {
  local _c
  for _c in "$@"; do
    command -v "$_c" >/dev/null 2>&1 || die "required command '$_c' not found on this host"
  done
}

# load_backup_creds [--optional] [REQUIRED_VAR...]
# Sources .backup_creds (set -a) and dies per missing required var.
# --optional: return 1 instead of dying when the file is absent.
load_backup_creds() {
  local _optional=0
  [ "${1:-}" = "--optional" ] && { _optional=1; shift; }
  if [ ! -f "$BACKUP_CREDS" ]; then
    [ "$_optional" = "1" ] && return 1
    die ".backup_creds not found at $BACKUP_CREDS — run a deploy (or npm run initialize) first"
  fi
  set -a
  # shellcheck source=/dev/null
  . "$BACKUP_CREDS"
  set +a
  local _v
  for _v in "$@"; do
    [ -n "${!_v:-}" ] || die "$_v missing in $BACKUP_CREDS"
  done
}
