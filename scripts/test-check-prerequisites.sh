#!/bin/bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT_DIR/scripts/check-prerequisites.sh"
TMP=$(mktemp -d "$ROOT_DIR/.test-prerequisites.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir "$BIN"
checks=0
fails=0

eq() {
    checks=$((checks + 1))
    if [ "$2" != "$3" ]; then
        printf 'FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3" >&2
        fails=$((fails + 1))
    fi
}
has() {
    checks=$((checks + 1))
    case "$3" in
        *"$2"*) ;;
        *) printf 'FAIL %s: missing [%s]\n' "$1" "$2" >&2; fails=$((fails + 1)) ;;
    esac
}
hasnt() {
    checks=$((checks + 1))
    case "$3" in
        *"$2"*) printf 'FAIL %s: unexpected [%s]\n' "$1" "$2" >&2; fails=$((fails + 1)) ;;
    esac
}

cat > "$TMP/stub" <<'STUB'
#!/bin/bash
case "${0##*/}" in
    uname) printf '%s\n' "${STUB_PLATFORM:-Darwin}" ;;
    git)
        if [ "${1:-}" = --version ]; then printf 'git version %s\n' "${STUB_GIT_VERSION:-2.28.0}"; else exit 1; fi ;;
    curl) printf 'curl %s (stub)\n' "${STUB_CURL_VERSION:-7.76.0}" ;;
    node) printf 'v%s\n' "${STUB_NODE_VERSION:-14.17.0}" ;;
    npm) printf '%s\n' "${STUB_NPM_VERSION:-7.0.0}" ;;
    gh)
        printf '%s\n' "$*" >> "$GH_CALLS"
        if [ "$*" = --version ]; then printf 'gh version %s\n' "${STUB_GH_VERSION:-2.40.0}"; exit 0; fi
        [ "$*" = 'auth status --active' ] || exit 99
        if [ "${STUB_GH_STATUS:-0}" -ne 0 ]; then
            printf 'github.com: authentication failed (stub)\n' >&2
            exit "$STUB_GH_STATUS"
        fi
        printf 'GitHub success details must stay hidden\n'
        ;;
    brew) printf '%s\n' "$*" >> "$BREW_CALLS"; exit 99 ;;
    *) printf 'Unexpected tool execution: %s\n' "$0" >&2; exit 99 ;;
esac
STUB
chmod +x "$TMP/stub"
required="git gh curl jq openssl rsync sops ssh scp ssh-keygen ssh-keyscan node npm age-keygen"
optional="pbcopy xclip xsel afplay osascript open"
for tool in $required $optional brew uname; do
    cp "$TMP/stub" "$BIN/$tool"
done
export PREREQUISITES_TTY=/dev/null
export HOME="$TMP/home" TMPDIR="$TMP"
mkdir -p "$HOME"
for tool in dirname mktemp rm awk; do ln -s "$(command -v "$tool")" "$BIN/$tool"; done
export BREW_CALLS="$TMP/brew-calls"
export GH_CALLS="$TMP/gh-calls"
: > "$BREW_CALLS"

run_check() {
    status=0
    : > "$GH_CALLS"
    PATH="$BIN" /bin/bash "$CHECK" > "$TMP/stdout" 2> "$TMP/stderr" || status=$?
    out=$(cat "$TMP/stdout")
    err=$(cat "$TMP/stderr")
}

run_check
eq 'all present: status' 0 "$status"
has 'all present: success' 'All prerequisites are available.' "$out"
eq 'all present: no failure text' '' "$err"
eq 'logged in: version and active auth checked' $'--version\nauth status --active' "$(cat "$GH_CALLS")"
hasnt 'logged in: success details suppressed' 'GitHub success details' "$out$err"

export STUB_GH_STATUS=1
run_check
eq 'logged out: status' 1 "$status"
has 'logged out: explanation' 'not logged in to GitHub' "$err"
has 'logged out: connectivity explanation' 'could not reach' "$err"
has 'logged out: original failure retained' 'authentication failed (stub)' "$err"
has 'logged out: login instructions' 'gh auth login' "$err"
has 'logged out: host choice' 'GitHub.com' "$err"
has 'logged out: scopes' 'repo and workflow' "$err"
has 'logged out: existing login recovery' 'gh auth refresh -s repo,workflow' "$err"
eq 'logged out: stdout stays empty' '' "$out"
mv "$BIN/jq" "$TMP/jq"
run_check
eq 'combined auth and missing tool: status' 1 "$status"
has 'combined auth and missing tool: tool' 'jq: JSON processing; install: brew install jq' "$err"
has 'combined auth and missing tool: login' 'not logged in to GitHub' "$err"
printf 'Combined prerequisite failure sample:\n%s\n' "$err"
mv "$TMP/jq" "$BIN/jq"
unset STUB_GH_STATUS

for tool in $required; do
    mv "$BIN/$tool" "$TMP/absent"
    run_check
    eq "$tool missing: status" 1 "$status"
    eq "$tool missing: stdout stays empty" '' "$out"
    has "$tool missing: named" "$tool:" "$err"
    has "$tool missing: rerun advice" 're-run npm run initialize' "$err"
    if [ "$tool" = gh ]; then
        eq 'gh missing: auth not called' '' "$(cat "$GH_CALLS")"
        hasnt 'gh missing: no login failure' 'not logged in to GitHub' "$err"
    fi
    mv "$TMP/absent" "$BIN/$tool"
done

mv "$BIN/jq" "$TMP/jq"
run_check
has 'one missing: purpose and exact install' 'jq: JSON processing; install: brew install jq' "$err"
mv "$TMP/jq" "$BIN/jq"

for tool in jq ssh scp node npm; do mv "$BIN/$tool" "$TMP/$tool"; done
run_check
eq 'several missing: status' 1 "$status"
for tool in jq ssh scp node npm; do
    has 'several missing: every tool named' "$tool:" "$err"
done
combined=$(printf '%s\n' "$err" | grep '^Install missing packages:' || true)
eq 'shared packages: one combined install line' \
    'Install missing packages: brew install jq openssh node' "$combined"
has 'shared packages: ssh install' 'ssh: VPS commands; install: brew install openssh' "$err"
has 'shared packages: scp install' 'scp: VPS file uploads; install: brew install openssh' "$err"
for tool in jq ssh scp node npm; do mv "$TMP/$tool" "$BIN/$tool"; done

mv "$BIN/brew" "$TMP/brew"
mv "$BIN/jq" "$TMP/jq"
run_check
eq 'brew absent: status' 1 "$status"
has 'brew absent: first message' 'https://brew.sh' "${err%%$'\n'*}"
has 'brew absent: still lists tools' 'jq:' "$err"
mv "$TMP/jq" "$BIN/jq"
run_check
eq 'brew absent: complete runtime still works' 0 "$status"
mv "$TMP/brew" "$BIN/brew"

export STUB_PLATFORM=Linux
for tool in jq ssh node npm sops; do mv "$BIN/$tool" "$TMP/$tool"; done
run_check
eq 'non-macOS: status' 1 "$status"
has 'non-macOS: support boundary' 'outside the supported boundary' "$err"
has 'non-macOS: jq package' 'apt-get install jq' "$err"
has 'non-macOS: SSH package' 'apt-get install openssh-client' "$err"
has 'non-macOS: Node package' 'apt-get install nodejs' "$err"
has 'non-macOS: npm package' 'apt-get install npm' "$err"
has 'non-macOS: sops named' 'sops:' "$err"
hasnt 'non-macOS: no guessed sops package' 'apt-get install sops' "$err"
hasnt 'non-macOS: no Homebrew advice' 'brew' "$err"
for tool in jq ssh node npm sops; do mv "$TMP/$tool" "$BIN/$tool"; done
run_check
eq 'non-macOS: complete tools status' 0 "$status"
has 'non-macOS: complete tools still show boundary' 'outside the supported boundary' "$err"
unset STUB_PLATFORM

export STUB_GIT_VERSION=2.27.9
run_check
eq 'old Git: status' 1 "$status"
has 'old Git: found version' 'found 2.27.9' "$err"
has 'old Git: required version' 'requires >=2.28.0' "$err"
has 'old Git: exact upgrade' 'brew upgrade git' "$err"
unset STUB_GIT_VERSION

export STUB_GH_VERSION=2.39.9
run_check
eq 'old gh: status' 1 "$status"
has 'old gh: required version' 'requires >=2.40.0' "$err"
has 'old gh: upgrade' 'brew upgrade gh' "$err"
unset STUB_GH_VERSION

export STUB_CURL_VERSION=7.75.0 STUB_NODE_VERSION=14.16.1 STUB_NPM_VERSION=6.14.18
run_check
eq 'other version floors: status' 1 "$status"
for tool in curl node npm; do has 'other version floors: named' "$tool:" "$err"; done
for package in curl node; do has 'other version floors: upgrade' "brew upgrade $package" "$err"; done
unset STUB_CURL_VERSION STUB_NODE_VERSION STUB_NPM_VERSION

export STUB_GIT_VERSION='2.28.0 (Apple Git-129)' STUB_CURL_VERSION=8.0.0 STUB_NODE_VERSION=22.0.0 STUB_NPM_VERSION=10.0.0
run_check
eq 'new versions and Apple suffix: status' 0 "$status"
unset STUB_GIT_VERSION STUB_CURL_VERSION STUB_NODE_VERSION STUB_NPM_VERSION

export STUB_GIT_VERSION=unknown
run_check
eq 'unreadable version: status' 1 "$status"
has 'unreadable version: explains minimum' 'requires >=2.28.0' "$err"
unset STUB_GIT_VERSION

mv "$BIN/pbcopy" "$TMP/pbcopy"
mv "$BIN/afplay" "$TMP/afplay"
run_check
eq 'optional alternatives: status' 0 "$status"
eq 'optional alternatives: no lost-feature note while fallback exists' '' "$err"
mv "$TMP/pbcopy" "$BIN/pbcopy"
mv "$TMP/afplay" "$BIN/afplay"

for tool in $optional; do mv "$BIN/$tool" "$TMP/$tool"; done
run_check
eq 'optional absent: status' 0 "$status"
has 'optional absent: clipboard note' 'clipboard copying unavailable; copy manually' "$err"
has 'optional absent: notification note' 'sound notifications use the terminal bell' "$err"
has 'optional absent: watcher note' 'deploy watcher runs without a Terminal window' "$err"
hasnt 'optional absent: no install failure' 'Missing required' "$err"
for tool in $optional; do mv "$TMP/$tool" "$BIN/$tool"; done

for tool in $required; do mv "$BIN/$tool" "$TMP/$tool"; done
run_check
eq 'empty toolchain: status' 1 "$status"
for tool in $required; do has 'empty toolchain: every tool named' "$tool:" "$err"; done
for tool in $required; do mv "$TMP/$tool" "$BIN/$tool"; done
eq 'checker never invokes brew' '' "$(cat "$BREW_CALLS")"
hasnt 'failure output: no ANSI colour' $'\033' "$err"

python3 - "$ROOT_DIR" <<'PY'
import json
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
checks = []
actions = [line.strip() for line in (root / 'scripts/initialize.sh').read_text().splitlines()
           if line.strip() and not line.lstrip().startswith('#')]
call = 'bash "$SCRIPT_DIR/check-prerequisites.sh" || exit 1'
checks.append(('checker is the first action after SCRIPT_DIR',
               len(actions) > 1 and actions[0].startswith('SCRIPT_DIR=') and actions[1] == call))
checks.append(('checker precedes library source and repository guard',
               call in actions and actions.index(call) < next(i for i, line in enumerate(actions) if line.startswith('source '))
               and actions.index(call) < next(i for i, line in enumerate(actions) if line.startswith('initialize_repo_guard '))))
initializer = '\n'.join(actions)
checks.append(('inline tool loop removed', '_missing_tools' not in initializer and '_brew_pkgs' not in initializer))
scripts = json.loads((root / 'package.json').read_text())['scripts']
checks.append(('standalone npm entry', scripts.get('check-prerequisites') == 'bash scripts/check-prerequisites.sh'))
checks.append(('unit suite includes checker tests', 'bash scripts/test-check-prerequisites.sh' in scripts['test:unit']))
checker_path = root / 'scripts/check-prerequisites.sh'
table = re.search(r'^TOOLS=\(\n(.*?)^\)', checker_path.read_text() if checker_path.exists() else '', re.M | re.S)
rows = re.findall(r"^    '([^']+)'$", table[1], re.M) if table else []
checks.append(('tool table exists at top', bool(rows)))
readme = (root / 'README.md').read_text().split('## Prerequisites and costs', 1)[1].split('\n## ', 1)[0]
for row in rows:
    for tool in row.split('|')[0].split(','):
        checks.append((f'README prerequisites cover {tool}', f'`{tool}`' in readme))
for label, ok in checks:
    if not ok:
        print(f'FAIL {label}', file=sys.stderr)
print(f'{sum(ok for _, ok in checks)}/{len(checks)} prerequisite integration/doc checks passed')
sys.exit(0 if all(ok for _, ok in checks) else 1)
PY
integration_status=$?
eq 'integration and documentation drift' 0 "$integration_status"
printf '%s/%s prerequisite assertions passed\n' "$((checks - fails))" "$checks"
[ "$fails" -eq 0 ]
