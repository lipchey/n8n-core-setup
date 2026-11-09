#!/bin/bash
# Unit tests for deploy.yml `Validate required config` regexes.
# Keep these regexes in sync with deploy.yml — the drift check below catches it.
set -uo pipefail

TZ_RE='^[A-Za-z_]+(/[A-Za-z0-9_+-]+){0,2}$'
PROJECT_NAME_RE='^[a-z0-9][a-z0-9-]{0,30}$'

PASS=0
FAIL=0
FAILED_TESTS=()

expect_match() {
    local re="$1" value="$2" expected="$3" name="$4" result
    if [[ "$value" =~ $re ]]; then result=accept; else result=reject; fi
    if [ "$result" = "$expected" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        FAILED_TESTS+=("$name (value='$value' got=$result expected=$expected)")
        echo "  ✗ $name — value='$value' got=$result expected=$expected"
    fi
}

echo "TZ validator:"
expect_match "$TZ_RE" "UTC"                              accept "TZ: bare zone UTC"
expect_match "$TZ_RE" "America/New_York"                 accept "TZ: 2-segment America/New_York"
expect_match "$TZ_RE" "America/Argentina/Buenos_Aires"   accept "TZ: 3-segment America/Argentina/Buenos_Aires"
expect_match "$TZ_RE" "Etc/GMT+3"                        accept "TZ: Etc/GMT+3 (plus allowed in subsegment)"
expect_match "$TZ_RE" "Pacific/Easter"                   accept "TZ: Pacific/Easter"
expect_match "$TZ_RE" ""                                 reject "TZ: empty"
expect_match "$TZ_RE" "/etc/passwd"                      reject "TZ: absolute path"
expect_match "$TZ_RE" "America/New_York; rm -rf /"       reject "TZ: shell-injection attempt"
expect_match "$TZ_RE" "America/New_York/extra/deeper"    reject "TZ: 4 segments (over depth cap)"
expect_match "$TZ_RE" "Europe/\$(whoami)"                reject "TZ: command substitution attempt"
expect_match "$TZ_RE" "America/New_York "                reject "TZ: trailing whitespace"
expect_match "$TZ_RE" "America New_York"                 reject "TZ: space in name"

echo ""
echo "PROJECT_NAME validator:"
expect_match "$PROJECT_NAME_RE" "acme"                    accept "PROJECT_NAME: simple lowercase"
expect_match "$PROJECT_NAME_RE" "abc-123"                 accept "PROJECT_NAME: lowercase with hyphen+digits"
expect_match "$PROJECT_NAME_RE" "a"                       accept "PROJECT_NAME: single char"
expect_match "$PROJECT_NAME_RE" "1client"                 accept "PROJECT_NAME: leading digit"
expect_match "$PROJECT_NAME_RE" "a234567890123456789012345678901" accept "PROJECT_NAME: 31 chars (max)"
expect_match "$PROJECT_NAME_RE" ""                        reject "PROJECT_NAME: empty"
expect_match "$PROJECT_NAME_RE" "Acme"                    reject "PROJECT_NAME: uppercase"
expect_match "$PROJECT_NAME_RE" "-foo"                    reject "PROJECT_NAME: leading hyphen"
expect_match "$PROJECT_NAME_RE" "foo bar"                 reject "PROJECT_NAME: space"
expect_match "$PROJECT_NAME_RE" "foo_bar"                 reject "PROJECT_NAME: underscore not allowed"
expect_match "$PROJECT_NAME_RE" "foo.bar"                 reject "PROJECT_NAME: dot not allowed"
expect_match "$PROJECT_NAME_RE" "a2345678901234567890123456789012" reject "PROJECT_NAME: 32 chars (over max)"
expect_match "$PROJECT_NAME_RE" "project;rm"               reject "PROJECT_NAME: shell-injection attempt"

echo ""
echo "Drift check (deploy.yml regexes match this file):"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_YML="$SCRIPT_DIR/../.github/workflows/deploy.yml"
if [ ! -f "$DEPLOY_YML" ]; then
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("drift: deploy.yml not found at $DEPLOY_YML")
    echo "  ✗ deploy.yml not found at $DEPLOY_YML"
else
    check_drift() {
        local label="$1" needle="$2"
        if grep -qF "$needle" "$DEPLOY_YML"; then
            PASS=$((PASS+1))
        else
            FAIL=$((FAIL+1))
            FAILED_TESTS+=("drift: $label regex differs from deploy.yml")
            echo "  ✗ drift — $label regex differs from deploy.yml (expected: $needle)"
        fi
    }
    check_drift "DISPLAY_TZ"        "$TZ_RE"
    check_drift "PROJECT_NAME"      "$PROJECT_NAME_RE"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
TOTAL=$((PASS+FAIL))
if [ "$FAIL" -eq 0 ]; then
    echo "✅ $PASS / $TOTAL config-validator tests passed"
    exit 0
else
    echo "❌ $FAIL / $TOTAL config-validator tests failed:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "   - $t"
    done
    exit 1
fi
