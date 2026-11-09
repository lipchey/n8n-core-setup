#!/bin/bash
# Runs the VPS scripts in throwaway sandboxes: /root/n8n is rewritten to a temp dir
# and docker/curl/restic/ssh are stubs, so nothing leaves this machine.
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
N8N_DIR="$(dirname "$SCRIPTS_DIR")"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/vps-runtime.XXXXXX")
REAL_MKTEMP=$(command -v mktemp)
export REAL_MKTEMP
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/      /'; }
check_rc() { if [ "$2" = "$1" ]; then pass; else fail "$3 (expected exit $1, got $2)" "${OUT:-}"; fi; }
check_nonzero() { if [ "$1" != "0" ]; then pass; else fail "$2 (expected non-zero exit)" "${OUT:-}"; fi; }
check_has() { if printf '%s\n' "$2" | grep -qF -e "$1"; then pass; else fail "$3 (missing '$1')" "$2"; fi; }
check_lacks() { if printf '%s\n' "$2" | grep -qF -e "$1"; then fail "$3 (unexpected '$1')" "$2"; else pass; fi; }

# Sets SB to a fresh sandbox: stubs in SB_BIN and every script's /root/n8n rewritten.
new_sandbox() {
    SB=$(mktemp -d "$TMP_ROOT/sb.XXXXXX")
    export SB
    SB_BIN="$SB/bin"
    mkdir -p "$SB_BIN" "$SB/workflows" "$SB/repo" "$SB/vol"
    cp -R "$SCRIPTS_DIR" "$SB/scripts"
    mkdir -p "$SB/n8n"
    local f
    while IFS= read -r f; do
        sed "s|/root/n8n|$SB|g" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    done < <(find "$SB/scripts" "$SB/n8n" -name '*.sh')
    : > "$SB/calls.log"
    write_stubs
}

stub() { printf '#!/bin/bash\n%s\n' "$2" > "$SB_BIN/$1"; chmod +x "$SB_BIN/$1"; }

write_stubs() {
    stub flock 'exit 0'
    # Keeps the scripts' temp files inside the sandbox whatever the host's default temp dir allows.
    stub mktemp 'case "${1:-}" in
    -d) [ $# -gt 1 ] && exec "$REAL_MKTEMP" "$@"; exec "$REAL_MKTEMP" -d "$SB/tmp.XXXXXX" ;;
    -t) exec "$REAL_MKTEMP" "$SB/$2" ;;
    "") exec "$REAL_MKTEMP" "$SB/tmp.XXXXXX" ;;
    *) exec "$REAL_MKTEMP" "$@" ;;
esac'
    stub crontab '[ "${1:-}" = "-l" ] && echo "* * * * * poll-publish-events.sh"; [ "${1:-}" = "-" ] && cat >/dev/null; exit 0'
    stub stat 'echo 1000'
    stub du 'printf "5000\t%s\n" "$2"'
    stub ssh 'for last; do :; done; VIA_SSH=1 exec bash -c "$last"'

    cat > "$SB_BIN/curl" <<'EOF'
#!/bin/bash
out=""; fmt=""; method=GET; argv_body=0; body_file=""; url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out=$2; shift ;;
        -w) fmt=$2; shift ;;
        -X) method=$2; shift ;;
        -d|--data|--data-raw) argv_body=1; shift ;;
        --data-binary) body_file=${2#@}; shift ;;
        -H|--connect-timeout|--max-time) shift ;;
        http*) url=$1 ;;
    esac
    shift
done
path=${url#https://api.github.com}
echo "curl $method $path argv_body=$argv_body" >> "$SB/calls.log"
case "$method $path" in
    "GET /repos/o/r/git/refs/heads/main") resp='{"object":{"sha":"branchsha"}}' ;;
    "GET /repos/o/r/git/commits/branchsha") resp='{"tree":{"sha":"treesha"}}' ;;
    "GET /repos/o/r/git/trees/treesha?recursive=1") resp=$(cat "$SB/remote-tree.json") ;;
    "POST /repos/o/r/git/blobs") cp "$body_file" "$SB/last-blob.json"; resp='{"sha":"blobsha"}' ;;
    "POST /repos/o/r/git/trees") cp "$body_file" "$SB/last-tree.json"; resp="{\"sha\":\"$(cat "$SB/new-tree-sha")\"}" ;;
    "POST /repos/o/r/git/commits") resp='{"sha":"commitsha"}' ;;
    "PATCH /repos/o/r/git/refs/heads/main") echo "REF_UPDATED" >> "$SB/calls.log"; resp='{}' ;;
    *) resp='{"data":[]}' ;;
esac
if [ -n "$out" ]; then printf '%s' "$resp" > "$out"; else printf '%s' "$resp"; fi
[ -z "$fmt" ] || printf '200'
EOF
    chmod +x "$SB_BIN/curl"

    COPYFILE_DISABLE=1 tar czf "$SB/fixture.tar.gz" -C "$SB/repo" . 2>/dev/null
    cat > "$SB_BIN/restic" <<'EOF'
#!/bin/bash
repo=$2; verb=$3
echo "restic $repo $verb" >> "$SB/calls.log"
case "$verb" in
    backup)
        [ "$repo" = "${RESTIC_FAIL_REPO:-}" ] && { echo "restic: repository down" >&2; exit 1; }
        echo "snapshot abcd1234 saved" ;;
    snapshots) echo '[{"id":"abcd1234"}]' ;;
    forget) [ "$repo" != "${RESTIC_FAIL_FORGET_REPO:-}" ] || exit 7 ;;
    ls) printf '%s\n' "$SB/.backup-staging/n8n_db.sql.gz" "$SB/.backup-staging/n8n_files.tar.gz" ;;
    dump)
        case "$*" in
            *.tar.gz) cat "$SB/fixture.tar.gz" ;;
            *) echo 'SELECT 1;' | gzip ;;
        esac ;;
esac
EOF
    chmod +x "$SB_BIN/restic"

    cat > "$SB_BIN/docker" <<'EOF'
#!/bin/bash
echo "docker via_ssh=${VIA_SSH:-0} $*" >> "$SB/calls.log"
case "$1" in
    stop) exit 0 ;;
    start) exit 0 ;;
    inspect) echo true; exit 0 ;;
    volume)
        [ -n "${DOCKER_FAIL_VOLUME:-}" ] && { echo "$SB/calls.log"; exit 0; }
        echo "$SB/vol/$3"; exit 0 ;;
    run) cat >/dev/null; exit 0 ;;
esac
shift
stdin_attached=0
[ "$1" = "-i" ] && { stdin_attached=1; shift; }
container=$1; shift
case "$container $1" in
    "n8n_postgres printenv")
        if [ "$2" = "POSTGRES_DB" ] && [ -n "${DOCKER_BAD_DB_NAME:-}" ]; then echo 'bad;name'; else echo n8n_database; fi ;;
    "n8n_postgres psql")
        [ "$stdin_attached" = 1 ] || exit 0
        query=$(cat)
        case "$query" in
            *to_regclass*) echo 'workflow_publish_history|workflow_published_version|workflow_entity|workflow_history' ;;
            *'MAX(ts)'*) echo '2026-11-09 10:00:00+00' ;;
            *STRING_AGG*) printf 'wf\tv1\n' ;;
            *) [ -z "${DOCKER_FAIL_SQL:-}" ] || exit 3 ;;
        esac ;;
    "n8n_postgres pg_dump") echo '-- dump' ;;
    "n8n_app wget") exit "${DOCKER_HEALTH_RC:-0}" ;;
esac
EOF
    chmod +x "$SB_BIN/docker"
}

run_in_sandbox() {
    OUT=$(PATH="$SB_BIN:$PATH" "$@" 2>&1)
    RC=$?
}

write_workflow() { printf '{"name":"%s","nodes":[{"parameters":{"x":"%s"}}]}\n' "$1" "${2:-clean}" > "$SB/workflows/$1.json"; }

DIRTY_VALUE="https://admin:hunter2secret@api.example.com/x"

commit_sandbox() {
    new_sandbox
    stub_sync_noop
    printf 'GITHUB_PERSONAL_ACCESS_TOKEN=x\nGITHUB_REPO=o/r\nDB_USER=n8n\n' > "$SB/.backup_creds"
    echo '{"tree":[]}' > "$SB/remote-tree.json"
    echo newtreesha > "$SB/new-tree-sha"
}
stub_sync_noop() { printf '#!/bin/bash\nexit 0\n' > "$SB/scripts/sync-workflows.sh"; }

echo "Publish path:"

commit_sandbox
# Past one argv slot on Linux (128 KiB) and total ARG_MAX on macOS (1 MiB), so argv fails on both.
BIG_SIZE=$((3 * 1024 * 1024))
{ printf '{"name":"big","nodes":[{"parameters":{"x":"'; head -c "$BIG_SIZE" /dev/zero | tr '\0' a; printf '"}}]}\n'; } > "$SB/workflows/big.json"
run_in_sandbox bash "$SB/scripts/github-commit-workflows.sh" "msg"
check_rc 0 "$RC" "workflow larger than one argv slot commits"
check_has "REF_UPDATED" "$(cat "$SB/calls.log")" "large workflow reaches the ref update"
check_lacks "git/blobs argv_body=1" "$(cat "$SB/calls.log")" "blob payload is not on argv"
check_lacks "git/trees argv_body=1" "$(cat "$SB/calls.log")" "tree payload is not on argv"
EXPECTED_B64=$(base64 < "$SB/workflows/big.json" | tr -d '\n' | wc -c | tr -d ' ')
ACTUAL_B64=$(jq -r '.content | length' "$SB/last-blob.json" 2>/dev/null)
check_rc "$EXPECTED_B64" "$ACTUAL_B64" "blob payload carries the whole file"

commit_sandbox
write_workflow clean
write_workflow dirty "$DIRTY_VALUE"
cat > "$SB/remote-tree.json" <<'EOF'
{"tree":[
  {"type":"blob","path":"n8n/workflows/clean.json"},
  {"type":"blob","path":"n8n/workflows/dirty.json"},
  {"type":"blob","path":"n8n/workflows/gone.json"},
  {"type":"blob","path":"n8n/workflows/README.md"},
  {"type":"blob","path":"n8n/workflows/archive/old.json"},
  {"type":"blob","path":"n8n/other.json"}
]}
EOF
run_in_sandbox bash "$SB/scripts/github-commit-workflows.sh" "msg"
check_nonzero "$RC" "a blocked file fails the run"
check_has "REF_UPDATED" "$(cat "$SB/calls.log")" "clean files still commit beside a blocked one"
check_lacks "hunter2" "$OUT" "blocked secret stays masked in logs"
DELETED=$(jq -c '[.tree[] | select(.sha == null) | .path]' "$SB/last-tree.json")
check_rc '["n8n/workflows/gone.json"]' "$DELETED" "bot deletes only top-level workflow JSON"

echo treesha > "$SB/new-tree-sha"
run_in_sandbox bash "$SB/scripts/github-commit-workflows.sh" "msg"
check_nonzero "$RC" "a blocked file fails the run when nothing else changed"

commit_sandbox
write_workflow dirty "$DIRTY_VALUE"
run_in_sandbox bash "$SB/scripts/github-commit-workflows.sh" "msg"
check_nonzero "$RC" "only blocked files fails the run"

commit_sandbox
write_workflow clean
write_workflow dirty "$DIRTY_VALUE"
run_in_sandbox bash "$SB/scripts/database/poll-publish-events.sh"
if [ -f "$SB/.last_publish_seen" ]; then fail "blocked file must not advance the poll cursor" "$OUT"; else pass; fi

commit_sandbox
write_workflow clean
run_in_sandbox bash "$SB/scripts/database/poll-publish-events.sh"
check_rc "2026-11-09 10:00:00+00" "$(cat "$SB/.last_publish_seen" 2>/dev/null)" "clean publish advances the poll cursor"

echo "Loopback guard:"

for url in 'http://localhost:5678@attacker.example/api/v1' 'http://127.0.0.1:80@attacker.example/' \
           'http://localhost.attacker.example/' 'http://localhost:abc/' 'https://localhost:5678/' \
           'http://localhost:5678\@attacker.example/' 'http://localhost#@attacker.example/'; do
    new_sandbox
    printf "N8N_API_KEY=k\nN8N_LOCAL_API_URL='%s'\n" "$url" > "$SB/.backup_creds"
    run_in_sandbox bash "$SB/scripts/sync-workflows.sh" --pull
    check_rc 1 "$RC" "rejects $url"
    check_lacks "curl" "$(cat "$SB/calls.log")" "no API call for $url"
done
for url in 'http://localhost:5678/api/v1' 'http://127.0.0.1/api/v1'; do
    new_sandbox
    printf "N8N_API_KEY=k\nN8N_LOCAL_API_URL='%s'\n" "$url" > "$SB/.backup_creds"
    run_in_sandbox bash "$SB/scripts/sync-workflows.sh" --pull
    check_rc 0 "$RC" "accepts $url"
done

echo "Restore:"

restore_sandbox() {
    new_sandbox
    printf 'BACKUP_PASSWORD=p\nDB_USER=n8n\nPROJECT_NAME=demo\nRESTIC_REPOSITORY=%s/repo\n' "$SB" > "$SB/.backup_creds"
}
run_restore() {
    OUT=$(echo y | PATH="$SB_BIN:$PATH" RESTORE_HEALTH_TIMEOUT_SECS=0 "$@" bash "$SB/scripts/database/restore-database.sh" latest 2>&1)
    RC=$?
}

restore_sandbox
run_restore env
check_rc 0 "$RC" "clean restore succeeds"
check_has "Restore complete" "$OUT" "clean restore reports completion"
check_has "docker via_ssh=0 exec n8n_app wget -T 10" "$(cat "$SB/calls.log")" "completion follows a bounded readiness probe"

for scenario in DOCKER_FAIL_SQL DOCKER_FAIL_VOLUME; do
    restore_sandbox
    run_restore env "$scenario=1"
    check_nonzero "$RC" "$scenario exits non-zero"
    check_lacks "start n8n_app" "$(cat "$SB/calls.log")" "$scenario leaves n8n stopped"
    check_lacks "Restore complete" "$OUT" "$scenario does not report completion"
done

restore_sandbox
run_restore env DOCKER_HEALTH_RC=1
check_nonzero "$RC" "failed readiness exits non-zero"
check_lacks "Restore complete" "$OUT" "failed readiness does not report completion"

restore_sandbox
run_restore env DOCKER_BAD_DB_NAME=1
check_nonzero "$RC" "failure before the drop exits non-zero"
check_has "start n8n_app" "$(cat "$SB/calls.log")" "n8n restarts when the database was never touched"

echo "Backup and prune:"

backup_sandbox() {
    new_sandbox
    printf 'BACKUP_PASSWORD=p\nDB_USER=n8n\nPROJECT_NAME=demo\nRESTIC_REPOSITORY=%s/repo\nRESTIC_REPOSITORY_BACKBLAZE=rclone:b2:bucket\nBACKBLAZE_KEY_ID=k\nBACKBLAZE_APPLICATION_KEY=a\n' "$SB" > "$SB/.backup_creds"
}

backup_sandbox
OUT=$(PATH="$SB_BIN:$PATH" B2_ATTEMPTS=1 bash "$SB/scripts/database/backup-database.sh" 2>&1); RC=$?
check_rc 0 "$RC" "backup succeeds when both repos do"

backup_sandbox
OUT=$(PATH="$SB_BIN:$PATH" B2_ATTEMPTS=1 RESTIC_FAIL_REPO="$SB/repo" bash "$SB/scripts/database/backup-database.sh" 2>&1); RC=$?
check_nonzero "$RC" "local repo failure reaches the exit status"
check_has "restic rclone:b2:bucket backup" "$(cat "$SB/calls.log")" "local repo failure still attempts B2"

backup_sandbox
OUT=$(PATH="$SB_BIN:$PATH" B2_ATTEMPTS=1 RESTIC_FAIL_REPO=rclone:b2:bucket bash "$SB/scripts/database/backup-database.sh" 2>&1); RC=$?
check_nonzero "$RC" "B2 failure reaches the exit status"

backup_sandbox
OUT=$(PATH="$SB_BIN:$PATH" RESTIC_FAIL_FORGET_REPO=rclone:b2:bucket bash "$SB/scripts/database/prune-backups.sh" 2>&1); RC=$?
check_nonzero "$RC" "B2 prune failure reaches the exit status"
check_lacks "expected" "$OUT" "B2 prune failure is not called expected"
check_lacks "retention pass completed" "$OUT" "B2 prune failure is not called completed"
check_has "restic rclone:b2:bucket check" "$(cat "$SB/calls.log")" "B2 integrity check still runs"

echo "Global error handler:"

OUT=$(node - "$N8N_DIR/workflows/global_error_handler.json" 2>&1 <<'EOF'
const assert = require('assert');
const wf = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
const staticData = {};
const run = (name, input) => new Function('$input', '$', '$getWorkflowStaticData',
  wf.nodes.find(n => n.name === name).parameters.jsCode)(
    { first: () => ({ json: input }) },
    () => ({ first: () => ({ json: { workflow: { name: 'W' }, execution: { error: { message: 'boom' } } } }) }),
    () => staticData);
const cfg = { developer_email: 'a@b.c', resend_api_key_set: 'yes', resend_from_email: 'f@b.c', project_name: 'p' };
const LIMITER = 'Rate Limiter (15 min)', RECORD = 'Record Delivery';

const names = new Set(wf.nodes.map(n => n.name));
assert.strictEqual(names.size, wf.nodes.length, 'node names must be unique');
assert.strictEqual(new Set(wf.nodes.map(n => n.id)).size, wf.nodes.length, 'node IDs must be unique');
assert.deepStrictEqual([...names].sort(), [
  'Error Trigger', 'Skip Manual Runs', 'Alert Config', LIMITER,
  'Email configured?', 'Send Error Email', RECORD,
].sort());
for (const [source, outputs] of Object.entries(wf.connections)) {
  assert.ok(names.has(source), `missing connection source: ${source}`);
  for (const branches of Object.values(outputs))
    for (const branch of branches)
      for (const edge of branch)
        assert.ok(names.has(edge.node), `missing connection target: ${edge.node}`);
}
const reachable = new Set();
const visit = name => {
  if (reachable.has(name)) return;
  reachable.add(name);
  for (const branches of Object.values(wf.connections[name] || {}))
    for (const branch of branches)
      for (const edge of branch) visit(edge.node);
};
visit('Error Trigger');
assert.deepStrictEqual(reachable, names, 'every node must be reachable from the trigger');
assert.strictEqual(wf.connections['Send Error Email'].main[0][0].node, RECORD);
assert.strictEqual(run(LIMITER, {}).length, 0, 'unconfigured email stays silent');

assert.strictEqual(run(LIMITER, cfg).length, 1, 'first error alerts');
run(RECORD, { error: { message: 'delivery failed' } });
assert.ok(!staticData.lastErrorEmailSent, 'failed delivery starts no cooldown');

const retry = run(LIMITER, cfg);
assert.strictEqual(retry.length, 1, 'next error retries after failed delivery');
assert.strictEqual(retry[0].json._errorCount, 2, 'retry keeps the pending count');

run(RECORD, { id: 'sent' });
assert.ok(staticData.lastErrorEmailSent, 'delivery starts the cooldown');
assert.strictEqual(staticData.errorCount, 0, 'delivery clears the count');
assert.strictEqual(run(LIMITER, cfg).length, 0, 'errors inside the cooldown stay silent');
EOF
)
RC=$?
check_rc 0 "$RC" "cooldown recorded only after a delivered alert"

echo ""
TOTAL=$((PASS+FAIL))
if [ "$FAIL" -eq 0 ]; then
    echo "✅ $PASS / $TOTAL runtime tests passed"
    exit 0
fi
echo "❌ $FAIL / $TOTAL runtime tests failed"
exit 1
