#!/bin/bash
# Alerting helpers on top of send-email.sh. Requires common.sh sourced first.

# shellcheck source=send-email.sh
. "$LIB_DIR/send-email.sh"

# rc 0 when all three Resend/alert vars are present.
email_configured() {
  [ -n "${DEVELOPER_EMAIL:-}" ] && [ -n "${RESEND_API_KEY:-}" ] && [ -n "${RESEND_FROM_EMAIL:-}" ]
}

# throttle_gate STATE_FILE INTERVAL_SECS — rc 0 = proceed (stamps now), rc 1 = throttled.
# Garbage state files coerce to 0 so $((…)) can't crash the caller under set -e.
throttle_gate() {
  local _state="$1" _interval="$2" _now _last=0
  _now=$(date +%s)
  [ -f "$_state" ] && _last=$(cat "$_state" 2>/dev/null || echo 0)
  [[ "$_last" =~ ^[0-9]+$ ]] || _last=0
  [ $((_now - _last)) -ge "$_interval" ] || return 1
  echo "$_now" > "$_state"
}
