#!/bin/bash
# Unit tests for scan-workflow-secrets.sh, plus the stubbed VPS runtime suite.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER="$SCRIPT_DIR/scan-workflow-secrets.sh"
WORKFLOWS_DIR="$(cd "$SCRIPT_DIR/../workflows" && pwd)"

[ -f "$SCANNER" ] || { echo "❌ Scanner not found at $SCANNER"; exit 1; }

PASS=0
FAIL=0
FAILED_TESTS=()

# Wrap values in a minimal workflow JSON and run the scanner.
scan_value() {
    local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/scan-test.XXXXXX")
    {
        echo '{"name":"t","nodes":['
        local first=1
        for v in "$@"; do
            [ "$first" = "0" ] && echo ","
            printf '{"parameters":{"x":"%s"}}' "$v"
            first=0
        done
        echo ']}'
    } > "$tmp"
    STDOUT=$(bash "$SCANNER" "$tmp" 2>&1)
    SCAN_RC=$?
    rm -f "$tmp"
    return 0
}

assert_exit() {
    local expected="$1" actual="$2" name="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        FAILED_TESTS+=("$name (expected exit $expected, got $actual)")
        echo "  ✗ $name — expected exit $expected, got $actual"
        echo "    stdout: $STDOUT"
    fi
}

assert_contains() {
    local needle="$1" haystack="$2" name="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        FAILED_TESTS+=("$name (output missing '$needle')")
        echo "  ✗ $name — output missing '$needle'"
        echo "    actual: $haystack"
    fi
}

assert_not_contains() {
    local needle="$1" haystack="$2" name="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        FAILED_TESTS+=("$name (output unexpectedly contains '$needle')")
        echo "  ✗ $name — output unexpectedly contains '$needle'"
        echo "    actual: $haystack"
    fi
}

echo "Positive cases:"

# PEM tests use hand-crafted files because the marker spans context the helper
# would JSON-quote. The pattern catches the BEGIN line.
TMP_PEM=$(mktemp "${TMPDIR:-/tmp}/scan-test.XXXXXX")
cat > "$TMP_PEM" <<'EOF'
{"name":"t","nodes":[{"parameters":{"key":"-----BEGIN RSA PRIVATE KEY-----"}}]}
EOF
STDOUT=$(bash "$SCANNER" "$TMP_PEM" 2>&1); SCAN_RC=$?
rm -f "$TMP_PEM"
assert_exit 1 "$SCAN_RC" "private_key_pem (RSA)"
assert_contains "private_key_pem" "$STDOUT" "private_key_pem — name in output"

TMP_PEM2=$(mktemp "${TMPDIR:-/tmp}/scan-test.XXXXXX")
printf '{"name":"t","nodes":[{"parameters":{"key":"-----BEGIN EC PRIVATE KEY-----"}}]}\n' > "$TMP_PEM2"
STDOUT=$(bash "$SCANNER" "$TMP_PEM2" 2>&1); SCAN_RC=$?
rm -f "$TMP_PEM2"
assert_exit 1 "$SCAN_RC" "private_key_pem (EC)"

TMP_PEM3=$(mktemp "${TMPDIR:-/tmp}/scan-test.XXXXXX")
printf '{"name":"t","nodes":[{"parameters":{"key":"-----BEGIN OPENSSH PRIVATE KEY-----"}}]}\n' > "$TMP_PEM3"
STDOUT=$(bash "$SCANNER" "$TMP_PEM3" 2>&1); SCAN_RC=$?
rm -f "$TMP_PEM3"
assert_exit 1 "$SCAN_RC" "private_key_pem (OPENSSH)"

TMP_PEM4=$(mktemp "${TMPDIR:-/tmp}/scan-test.XXXXXX")
printf '{"name":"t","nodes":[{"parameters":{"key":"-----BEGIN PRIVATE KEY-----"}}]}\n' > "$TMP_PEM4"
STDOUT=$(bash "$SCANNER" "$TMP_PEM4" 2>&1); SCAN_RC=$?
rm -f "$TMP_PEM4"
assert_exit 1 "$SCAN_RC" "private_key_pem (bare, no type prefix)"

TMP_PEM5=$(mktemp "${TMPDIR:-/tmp}/scan-test.XXXXXX")
printf '{"name":"t","nodes":[{"parameters":{"key":"-----BEGIN PGP PRIVATE KEY BLOCK-----"}}]}\n' > "$TMP_PEM5"
STDOUT=$(bash "$SCANNER" "$TMP_PEM5" 2>&1); SCAN_RC=$?
rm -f "$TMP_PEM5"
assert_exit 1 "$SCAN_RC" "private_key_pem (PGP block)"

scan_value "https://admin:secret123@api.example.com/path"
assert_exit 1 "$SCAN_RC" "url_basic_auth (https with user:pass@host)"
assert_contains "url_basic_auth" "$STDOUT" "url_basic_auth — name in output"

scan_value "http://root:hunter2@10.0.0.1:8080/api"
assert_exit 1 "$SCAN_RC" "url_basic_auth (http with port after @)"

scan_value "postgres://app:hunter2@db.example.com:5432/n8n"
assert_exit 1 "$SCAN_RC" "url_basic_auth (postgres DSN)"
assert_contains "url_basic_auth" "$STDOUT" "postgres DSN — name in output"
assert_not_contains "hunter2" "$STDOUT" "postgres DSN — password masked"

scan_value "https://ghp_x@github.com/o/r.git"
assert_exit 1 "$SCAN_RC" "url_token_auth (GitHub token as URL user)"
assert_contains "url_token_auth" "$STDOUT" "url_token_auth — name in output"

scan_value "https://abcdefghijklmnopqrstuvwxyz1234@git.example.com/r.git"
assert_exit 1 "$SCAN_RC" "url_token_auth (long opaque token as URL user)"

scan_value "https://api.example.com/v1?api_key=abcd1234efgh"
assert_exit 1 "$SCAN_RC" "query_secret (?api_key=)"
assert_contains "query_secret" "$STDOUT" "query_secret — name in output"
assert_not_contains "1234efgh" "$STDOUT" "query_secret — value masked"

scan_value "https://api.example.com/v1?foo=1&access_token=abcd1234"
assert_exit 1 "$SCAN_RC" "query_secret (&access_token=)"

scan_value "Bearer abcdefghijklmnopqrstuvwxyz0123"
assert_exit 1 "$SCAN_RC" "bearer_token (literal value)"
assert_contains "bearer_token" "$STDOUT" "bearer_token — name in output"
assert_not_contains "wxyz0123" "$STDOUT" "bearer_token — value masked"

scan_value "https://api.telegram.org/bot123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZ012345/sendMessage"
assert_exit 1 "$SCAN_RC" "telegram_bot_token (token in URL)"
assert_contains "telegram_bot_token" "$STDOUT" "telegram_bot_token — name in output"

echo ""
echo "Negative cases:"

# Partner tokens are GitHub Push Protection's job — must pass clean locally.
scan_value "AKIAIOSFODNN7EXAMPLE"
assert_exit 0 "$SCAN_RC" "aws key not flagged locally (Push Protection handles it)"

scan_value "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
assert_exit 0 "$SCAN_RC" "github pat not flagged locally (Push Protection handles it)"

scan_value "sk-ant-api01-abcdefghijklmnopqrstuvwxyz0123456789ABCDE"
assert_exit 0 "$SCAN_RC" "anthropic key not flagged locally (Push Protection handles it)"

scan_value "sk_live_""abcdefghijklmnopqrstuvwxyz"
assert_exit 0 "$SCAN_RC" "stripe key not flagged locally (Push Protection handles it)"

scan_value "abc12345-6789-4def-9012-3456789abcde"
assert_exit 0 "$SCAN_RC" "uuid not flagged"

scan_value "aBcDeFgHiJkLmNoP"
assert_exit 0 "$SCAN_RC" "n8n workflow id not flagged"

scan_value "https://hc-ping.com/abc12345-6789-4def-9012-3456789abcde"
assert_exit 0 "$SCAN_RC" "healthchecks ping URL not flagged"

scan_value "REPLACE_WITH_SMTP_CRED" "REPLACE_WITH_GMAIL_CRED"
assert_exit 0 "$SCAN_RC" "REPLACE_WITH_ placeholders not flagged"

scan_value ""
assert_exit 0 "$SCAN_RC" "empty value not flagged"

scan_value "https://docs.example.com:443/foo"
assert_exit 0 "$SCAN_RC" "url with port (no auth) not flagged"

scan_value "https://user@github.com/repo.git"
assert_exit 0 "$SCAN_RC" "url with user only (no password) not flagged"

scan_value "https://api.example.com:8080/path?cc=ops@example.com"
assert_exit 0 "$SCAN_RC" "url with port and @ in query not flagged"

scan_value "mailto:alice:bob@example.com"
assert_exit 0 "$SCAN_RC" "mailto-style not flagged"

scan_value '=Bearer {{ $env.RESEND_API_KEY }}'
assert_exit 0 "$SCAN_RC" "Bearer expression not flagged"

scan_value "Bearer token"
assert_exit 0 "$SCAN_RC" "Bearer prose not flagged"

scan_value '=https://api.telegram.org/bot{{ $env.TOKEN }}/sendMessage'
assert_exit 0 "$SCAN_RC" "telegram token expression not flagged"

scan_value '=https://api.example.com/v1?api_key={{ $env.KEY }}'
assert_exit 0 "$SCAN_RC" "query param expression not flagged"

scan_value "https://api.example.com/v1?api_key="
assert_exit 0 "$SCAN_RC" "empty query param not flagged"

scan_value '=https://{{$env.USER}}:literal-secret@api.example.com'
assert_exit 1 "$SCAN_RC" "expression username beside a literal password is flagged"

TMP_NO_STORAGE=$(mktemp "${TMPDIR:-/tmp}/scan-test.XXXXXX")
echo '{"x":"postgres://u:literal-secret@db.example.com/n8n"}' > "$TMP_NO_STORAGE"
TMPDIR=/nonexistent/scan-test bash "$SCANNER" "$TMP_NO_STORAGE" >/dev/null 2>&1
assert_exit 1 "$?" "a match is still flagged when temp storage is unavailable"
rm -f "$TMP_NO_STORAGE"

scan_value 'postgres://{{$env.U}}:{{$env.P}}@db.example.com/n8n'
assert_exit 0 "$SCAN_RC" "DSN built from expressions not flagged"

# Real repo workflows must all pass — guards against an over-broad pattern.
echo ""
echo "Repo workflow JSONs (must all be clean):"
for f in "$WORKFLOWS_DIR"/*.json; do
    STDOUT=$(bash "$SCANNER" "$f" 2>&1); SCAN_RC=$?
    BNAME=$(basename "$f")
    assert_exit 0 "$SCAN_RC" "real workflow: $BNAME"
done

echo ""
echo "Edge cases:"

STDOUT=$(bash "$SCANNER" "/nonexistent/file.json" 2>&1); SCAN_RC=$?
assert_exit 2 "$SCAN_RC" "nonexistent file → exit 2 (fails closed)"

TMP_CLEAN=$(mktemp "${TMPDIR:-/tmp}/scan-test.XXXXXX")
echo '{"name":"t","nodes":[]}' > "$TMP_CLEAN"
STDOUT=$(bash "$SCANNER" "$TMP_CLEAN" "/nonexistent/file.json" 2>&1); SCAN_RC=$?
assert_exit 2 "$SCAN_RC" "clean file + nonexistent file → exit 2"

# root reads through chmod 000, so the case would prove nothing there.
if [ "$(id -u)" != "0" ]; then
    chmod 000 "$TMP_CLEAN"
    STDOUT=$(bash "$SCANNER" "$TMP_CLEAN" 2>&1); SCAN_RC=$?
    chmod 600 "$TMP_CLEAN"
    assert_exit 2 "$SCAN_RC" "unreadable file → exit 2 (fails closed)"
fi
rm -f "$TMP_CLEAN"

STDOUT=$(bash "$SCANNER" 2>&1); SCAN_RC=$?
assert_exit 2 "$SCAN_RC" "no args → exit 2"

TMP_MULTI=$(mktemp "${TMPDIR:-/tmp}/scan-test.XXXXXX")
cat > "$TMP_MULTI" <<'EOF'
{"name":"t","nodes":[
  {"parameters":{"a":"-----BEGIN RSA PRIVATE KEY-----"}},
  {"parameters":{"b":"https://admin:secret123@api.example.com/path"}}
]}
EOF
STDOUT=$(bash "$SCANNER" "$TMP_MULTI" 2>&1); SCAN_RC=$?
rm -f "$TMP_MULTI"
assert_exit 1 "$SCAN_RC" "multiple patterns in one file"
assert_contains "private_key_pem" "$STDOUT" "multi-pattern: pem detected"
assert_contains "url_basic_auth" "$STDOUT" "multi-pattern: url_basic_auth detected"

scan_value "https://admin:secret123@api.example.com/path"
LINE=$(echo "$STDOUT" | head -1)
COLONS=$(echo "$LINE" | tr -cd ':' | wc -c | tr -d ' ')
if [ "$COLONS" -ge 3 ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("output format: expected ≥3 colons, got $COLONS in '$LINE'")
    echo "  ✗ output format — expected ≥3 colons, got $COLONS"
    echo "    line: $LINE"
fi

scan_value "https://admin:secret123@api.example.com/path"
assert_contains "https:***" "$STDOUT" "masking: url_basic_auth shows prefix only"
assert_not_contains "123@" "$STDOUT" "masking: url_basic_auth never leaks the password tail"

echo ""
echo "─────────────────────────────────────────"
TOTAL=$((PASS+FAIL))
if [ "$FAIL" -eq 0 ]; then
    echo "✅ $PASS / $TOTAL tests passed"
    exit 0
else
    echo "❌ $FAIL / $TOTAL tests failed:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "   - $t"
    done
    exit 1
fi
