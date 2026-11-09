#!/bin/bash
# Resend HTTP API email helper — SMTP-free so it works on hosts that block 25/465/587.
# Usage:  send_email "Subject" "Body" "to@example.com"
# Returns 0 on 2xx, 1 otherwise. Needs RESEND_API_KEY + RESEND_FROM_EMAIL in env.

send_email() {
    local subject="$1"
    local body="$2"
    local recipient="$3"

    if [ -z "${RESEND_API_KEY:-}" ] || [ -z "${RESEND_FROM_EMAIL:-}" ]; then
        echo "send_email: RESEND_API_KEY or RESEND_FROM_EMAIL not set — skipping" >&2
        return 1
    fi
    if [ -z "$recipient" ]; then
        echo "send_email: recipient is required (3rd arg)" >&2
        return 1
    fi

    local payload
    payload=$(jq -n \
        --arg from "$RESEND_FROM_EMAIL" \
        --arg to "$recipient" \
        --arg subject "$subject" \
        --arg text "$body" \
        '{from: $from, to: [$to], subject: $subject, text: $text}') || {
        echo "send_email: jq failed to build payload" >&2
        return 1
    }

    local response_file http_code
    response_file=$(mktemp)
    http_code=$(curl -sS -o "$response_file" -w '%{http_code}' \
        --max-time 15 \
        -X POST 'https://api.resend.com/emails' \
        -H "Authorization: Bearer ${RESEND_API_KEY}" \
        -H 'Content-Type: application/json' \
        -d "$payload" 2>/dev/null) || {
        rm -f "$response_file"
        echo "send_email: curl to Resend API failed (network error)" >&2
        return 1
    }

    if [ "${http_code:-0}" -ge 200 ] && [ "${http_code:-0}" -lt 300 ]; then
        rm -f "$response_file"
        return 0
    fi
    echo "send_email: Resend returned HTTP ${http_code}: $(cat "$response_file")" >&2
    rm -f "$response_file"
    return 1
}
