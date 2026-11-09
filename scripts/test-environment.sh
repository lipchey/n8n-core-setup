#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034
# Each test returns 0 for pass, 2 for skip, and any other status for failure.
set -u
set -o pipefail

# Byte-oriented tools can otherwise abort on non-UTF-8 bytes from terminal or API output.
export LC_ALL=C
export LANG=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$SCRIPT_DIR" || exit 1

# Strip escapes when piped (CI logs).
if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_GREEN=$'\033[32m'; C_RED=$'\033[31m'
    C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
    C_RESET=''; C_BOLD=''; C_DIM=''
    C_GREEN=''; C_RED=''; C_YELLOW=''; C_BLUE=''
fi

PASS=0; FAIL=0; SKIP=0
RESULTS=()

# shellcheck source=lib/prompts.sh
source "$SCRIPT_DIR/lib/prompts.sh"

step() { echo; echo "${C_BLUE}${C_BOLD}━━━ $* ━━━${C_RESET}"; }
info() { echo "  ${C_DIM}$*${C_RESET}"; }
warn() { echo "  ${C_YELLOW}$*${C_RESET}"; }
err()  { echo "  ${C_RED}$*${C_RESET}"; }

run_test() {
    local name="$1"; shift
    local fn="$1"; shift
    echo
    echo "${C_BOLD}▶ $name${C_RESET}"
    local rc=0 reply low
    while :; do
        rc=0
        "$fn" "$@" || rc=$?
        case "$rc" in
            0) PASS=$((PASS+1)); RESULTS+=("${C_GREEN}✅ PASS${C_RESET}  | $name"); echo "  ${C_GREEN}✅ PASS${C_RESET}"; return;;
            2)
                echo "  ${C_YELLOW}⏭  SKIP${C_RESET}"
                # Offer retry on skip — auto-skip reasons (missing var, container not yet up)
                # often resolve after one fix; surface that instead of moving on silently.
                if [ -r /dev/tty ]; then
                    reply=""
                    read -r -p "  ${C_YELLOW}[r]etry / [a]ccept skip${C_RESET} (default: accept): " reply </dev/tty || true
                    # Normalize: strip control chars + lowercase + first char only,
                    # so 'r\r' / 'R[200~' from bracketed-paste still match 'r'.
                    low=$(printf '%s' "$reply" | tr -cd 'A-Za-z' | tr 'A-Z' 'a-z' | cut -c1)
                    case "$low" in
                        r) echo "  ${C_DIM}↻ retrying...${C_RESET}"; continue;;
                    esac
                fi
                SKIP=$((SKIP+1)); RESULTS+=("${C_YELLOW}⏭  SKIP${C_RESET}  | $name"); return;;
        esac
        # FAIL — offer retry/skip/accept. Non-tty falls through to accept (CI behavior unchanged).
        echo "  ${C_RED}❌ FAIL (exit $rc)${C_RESET}"
        if [ ! -r /dev/tty ]; then
            FAIL=$((FAIL+1)); RESULTS+=("${C_RED}❌ FAIL${C_RESET}  | $name"); return
        fi
        _beep
        reply=""
        read -r -p "  ${C_YELLOW}[r]etry / [s]kip / [a]ccept fail${C_RESET} (default: accept): " reply </dev/tty || true
        low=$(printf '%s' "$reply" | tr -cd 'A-Za-z' | tr 'A-Z' 'a-z' | cut -c1)
        case "$low" in
            r)        echo "  ${C_DIM}↻ retrying...${C_RESET}"; continue;;
            s)        SKIP=$((SKIP+1)); RESULTS+=("${C_YELLOW}⏭  SKIP${C_RESET}  | $name (after fail)"); return;;
            *)        FAIL=$((FAIL+1)); RESULTS+=("${C_RED}❌ FAIL${C_RESET}  | $name"); return;;
        esac
    done
}

# Reads from /dev/tty so piped stdin still works.
prompt_dev() {
    _beep
    echo
    echo "${C_YELLOW}${C_BOLD}🔔 ─────────────────────────────────────────────────────${C_RESET}"
    echo "${C_YELLOW}${C_BOLD}🔔  DEVELOPER ACTION REQUIRED${C_RESET}"
    echo "${C_YELLOW}${C_BOLD}🔔 ─────────────────────────────────────────────────────${C_RESET}"
    echo "$1"
    echo
    local reply=""
    read -r -p "  Press [Enter] when ready, or type 'skip' + Enter to skip: " reply </dev/tty \
        || { err "No answer (EOF on /dev/tty) — failing rather than assuming ready"; return 1; }
    # Letters-only + lowercase: tolerates bracketed-paste wrappers like
    # \e[200~skip\e[201~ (escape stripped, [200~ + [201~ digits/tildes dropped).
    local norm
    norm=$(printf '%s' "$reply" | tr -cd 'A-Za-z' | tr 'A-Z' 'a-z')
    [ "$norm" = "skip" ] && return 2
    return 0
}

# `tr` lowercase — bash 3.2 on macOS lacks ${var,,}.
confirm_dev() {
    _beep
    echo
    echo "${C_YELLOW}${C_BOLD}🔔 ─────────────────────────────────────────────────────${C_RESET}"
    echo "${C_YELLOW}${C_BOLD}🔔  DEVELOPER CONFIRMATION REQUIRED${C_RESET}"
    echo "${C_YELLOW}${C_BOLD}🔔 ─────────────────────────────────────────────────────${C_RESET}"
    echo "$1"
    echo
    while :; do
        local reply=""
        read -r -p "  Reply [y]es / [n]o / [s]kip + Enter: " reply </dev/tty \
            || { err "No answer (EOF on /dev/tty) — failing rather than skipping"; return 1; }
        # Letters only + lowercase + first char. Robust against bracketed-paste
        # wrappers (\e[200~y\e[201~), CR, or trailing whitespace.
        local low
        low=$(printf '%s' "$reply" | tr -cd 'A-Za-z' | tr 'A-Z' 'a-z' | cut -c1)
        case "$low" in
            y) return 0;;
            n) return 1;;
            s|"") return 2;;
            *) printf "  ⚠️  Expected y / n / s.\n" >/dev/tty;;
        esac
    done
}

# Don't source .env — it's deleted in production.
ENV_CONFIG="$(dirname "$SCRIPT_DIR")/.env.config"
ENV_LOCAL="$(dirname "$SCRIPT_DIR")/.env.local"

set -a
[ -f "$ENV_CONFIG" ] && source "$ENV_CONFIG"
[ -f "$ENV_LOCAL" ]  && source "$ENV_LOCAL"
set +a

SSH_BASE_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR)
[ -n "${SSH_PRIVATE_KEY:-}" ] && [ -f "${SSH_PRIVATE_KEY/#\~/$HOME}" ] && \
  SSH_BASE_OPTS+=(-i "${SSH_PRIVATE_KEY/#\~/$HOME}")

ssh_n8n() {
    ssh "${SSH_BASE_OPTS[@]}" "${N8N_VPS_USER:-root}@${N8N_VPS_IP:-127.0.0.1}" "$@"
}

# id|name|active per row — covers rename/toggle/create/delete in round-trip test.
snapshot_workflows() {
    ssh_n8n bash -s <<'REMOTE_EOF' 2>/dev/null
set -e
[ -f /root/n8n/.backup_creds ] && { set -a; . /root/n8n/.backup_creds; set +a; }
[ -z "${DB_USER:-}" ] && exit 1
DBNAME=$(docker exec n8n_postgres printenv POSTGRES_DB 2>/dev/null)
[ -z "$DBNAME" ] && DBNAME="$DB_USER"
docker exec n8n_postgres psql -U "$DB_USER" -d "$DBNAME" -At -F '|' \
    -c "SELECT id, name, active FROM workflow_entity ORDER BY id;" 2>/dev/null
REMOTE_EOF
}

# Tests are self-contained — one failure must not cascade.

# ─── 1. Local environment ───────────────────────────────────────────────────

test_env_config_present() {
    [ -f "$ENV_CONFIG" ] && { info "Found at $ENV_CONFIG"; return 0; }
    err ".env.config not found at $ENV_CONFIG"
    return 1
}

test_env_config_required_keys() {
    local missing_config=() missing_local=()
    for k in PROJECT_NAME GITHUB_REPO GITHUB_BRANCH; do
        [ -z "${!k:-}" ] && missing_config+=("$k")
    done
    for k in N8N_VPS_USER N8N_VPS_IP; do
        [ -z "${!k:-}" ] && missing_local+=("$k")
    done
    if [ ${#missing_config[@]} -eq 0 ] && [ ${#missing_local[@]} -eq 0 ]; then
        info "All required keys set (PROJECT_NAME=$PROJECT_NAME, GITHUB_REPO=$GITHUB_REPO)"
        return 0
    fi
    local msg=""
    [ ${#missing_config[@]} -gt 0 ] && msg="Missing in .env.config: ${missing_config[*]}"
    if [ ${#missing_local[@]} -gt 0 ]; then
        [ -n "$msg" ] && msg+=" | "
        msg+="Missing in .env.local: ${missing_local[*]}"
    fi
    err "$msg"
    return 1
}

test_node_modules() {
    local pkg; pkg="$(dirname "$SCRIPT_DIR")/package.json"
    local dep_count; dep_count=$(jq '(.dependencies // {}) + (.devDependencies // {}) | length' "$pkg" 2>/dev/null || echo 0)
    if [ "$dep_count" -eq 0 ]; then
        info "no npm dependencies — skipping node_modules check"
        return 0
    fi
    if [ -d "$(dirname "$SCRIPT_DIR")/node_modules" ]; then
        info "node_modules present"
        return 0
    fi
    err "node_modules missing — run 'npm install' first"
    return 1
}

test_required_cli_tools() {
    local missing=()
    for cmd in npm git ssh rsync curl; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ ${#missing[@]} -eq 0 ]; then
        info "Found: npm, git, ssh, rsync, curl"
        return 0
    fi
    err "Missing: ${missing[*]}"
    return 1
}

test_env_sops_decryptable() {
    local sops_file
    sops_file="$(dirname "$SCRIPT_DIR")/.env.sops.yaml"
    if [ ! -f "$sops_file" ]; then
        info ".env.sops.yaml not found — secrets not yet encrypted, skipping"
        return 2
    fi
    if ! command -v sops >/dev/null 2>&1; then
        err "'sops' not installed — install with 'brew install sops' to verify"
        return 1
    fi
    if bash "$SCRIPT_DIR/sops-env.sh" --check-only 2>/dev/null; then
        info ".env.sops.yaml decrypts cleanly with current age key"
        return 0
    fi
    err ".env.sops.yaml does not decrypt with the current age key"
    echo "     No matching age key at \$HOME/.config/sops/age/keys.txt" >&2
    echo "     or <project-root>/.age-key.age. Restore from password manager." >&2
    return 1
}

test_env_fingerprint() {
    local root_dir env_file sops_file
    root_dir="$(dirname "$SCRIPT_DIR")"
    env_file="$root_dir/.env"
    sops_file="$root_dir/.env.sops.yaml"

    # Plaintext .env only exists between decrypt/encrypt; .env.sops.yaml is the
    # authoritative source in CI and post-deploy. Read from whichever is present.
    local source pinned
    if [ -f "$env_file" ]; then
        source="plaintext"
        pinned=$(grep '^N8N_VPS_HOST_FINGERPRINT=' "$env_file" | cut -d= -f2-)
    elif [ -f "$sops_file" ]; then
        source="sops"
        pinned=$(bash "$SCRIPT_DIR/sops-env.sh" --decrypt-stdout 2>/dev/null \
            | grep '^N8N_VPS_HOST_FINGERPRINT=' | cut -d= -f2-) || pinned=""
        if [ -z "$pinned" ]; then
            warn "Could not decrypt .env.sops.yaml — age key missing or fingerprint not set"
            return 2
        fi
    else
        info "Neither .env nor .env.sops.yaml found — skipping"
        return 2
    fi

    if [ -z "$pinned" ] || [ "$pinned" = "SHA256:paste_fingerprint_here" ]; then
        info "N8N_VPS_HOST_FINGERPRINT not set — skipping"
        return 2
    fi

    local raw_key live
    raw_key=$(ssh-keyscan -t ed25519 "${N8N_VPS_IP:-}" 2>/dev/null) || raw_key=""
    if [ -z "$raw_key" ]; then
        warn "ssh-keyscan returned nothing for ${N8N_VPS_IP:-} — cannot verify fingerprint"
        return 2
    fi
    live=$(echo "$raw_key" | ssh-keygen -lf - | awk '{ print $2 }')

    if [ "$pinned" = "$live" ]; then
        info "✓ N8N_VPS_HOST_FINGERPRINT matches live VPS ($live) [source: $source]"
        return 0
    fi

    err "Fingerprint mismatch [source: $source] — refusing to change the saved pin."
    info "  Stored: $pinned"
    info "  Live:   $live"
    err "Check the VPS IP and verify its ed25519 fingerprint in the provider console; an unexpected change may be an interception."
    err "After a real rebuild, deliberately update the pin only after that independent verification:"
    err "    1. npm run decrypt-env (only if .env is absent)"
    err "    2. Set N8N_VPS_HOST_FINGERPRINT in .env to the independently verified value"
    err "    3. npm run encrypt-env"
    err "    4. git add .env.sops.yaml && git commit -m 'chore: refresh VPS fingerprint' && git push"
    return 1
}

# ─── 2. SSH connectivity ────────────────────────────────────────────────────

test_ssh_n8n() {
    local out
    out=$(ssh_n8n "echo ok 2>/dev/null" 2>&1) || true
    if echo "$out" | grep -qx "ok"; then
        info "Reached ${N8N_VPS_USER}@${N8N_VPS_IP}"
        return 0
    fi
    err "Cannot SSH to n8n VPS (${N8N_VPS_USER}@${N8N_VPS_IP})"
    err "  $(echo "$out" | head -1)"
    return 1
}

# ─── 3. n8n VPS stack ───────────────────────────────────────────────────────

test_n8n_containers() {
    local containers
    containers=$(ssh_n8n "docker ps --format '{{.Names}}'" 2>/dev/null) || { err "docker ps failed"; return 1; }
    info "Running: $(echo "$containers" | tr '\n' ' ')"
    local expected=(n8n_app n8n_postgres n8n_cloudflared)
    local missing=()
    for c in "${expected[@]}"; do
        echo "$containers" | grep -qx "$c" || missing+=("$c")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        err "Missing containers: ${missing[*]}"
        return 1
    fi
    return 0
}

test_n8n_postgres_ready() {
    local out
    out=$(ssh_n8n "docker exec n8n_postgres pg_isready" 2>&1) || { err "$out"; return 1; }
    info "$out"
    return 0
}

test_n8n_local_api() {
    local code
    code=$(ssh_n8n "curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://localhost:5678/healthz || true")
    if [ -z "$code" ] || [ "$code" = "000" ]; then
        err "n8n local API on :5678 not responding"
        return 1
    fi
    info "n8n /healthz returned HTTP $code"
    [ "$code" = "200" ] && return 0
    return 1
}

# 401/403 still proves tunnel forwards traffic.
test_n8n_public_url() {
    local url
    url=$(ssh_n8n "docker inspect n8n_app --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -E '^WEBHOOK_URL=' | head -1 | cut -d= -f2-")
    if [ -z "$url" ]; then
        warn "WEBHOOK_URL not present in n8n_app env — skipping"
        return 2
    fi
    info "WEBHOOK_URL:"
    print_link "$url"
    local code
    code=$(curl -s -L --max-time 15 -o /dev/null -w '%{http_code}' "$url" || echo 000)
    info "HTTP $code from:"
    print_link "$url"
    if [[ "$code" =~ ^(200|301|302|401|403)$ ]]; then
        return 0
    fi
    err "Public Cloudflare tunnel did not respond (got $code)"
    return 1
}

test_n8n_cron_jobs() {
    local cron
    cron=$(ssh_n8n "crontab -l 2>/dev/null") || true
    local ok=1
    if echo "$cron" | grep -q "backup-database.sh"; then
        info "✓ Nightly backup cron present"
    else
        err "✗ Nightly backup cron missing"; ok=0
    fi
    if echo "$cron" | grep -q "poll-publish-events.sh"; then
        info "✓ Per-minute publish-poll cron present"
    else
        err "✗ Per-minute publish-poll cron missing"; ok=0
    fi
    if echo "$cron" | grep -q "prune-backups.sh"; then
        info "✓ Weekly prune cron present"
    else
        err "✗ Weekly prune cron missing"; ok=0
    fi
    [ $ok -eq 1 ] && return 0 || return 1
}

test_n8n_backup_creds() {
    if ssh_n8n "test -f /root/n8n/.backup_creds"; then
        local perms
        perms=$(ssh_n8n "stat -c %a /root/n8n/.backup_creds 2>/dev/null")
        info "/root/n8n/.backup_creds present (mode $perms)"
        [ "$perms" = "600" ] || { warn "Expected mode 600, found $perms"; return 1; }
        local missing_keys=()
        for k in GITHUB_PERSONAL_ACCESS_TOKEN GITHUB_REPO GITHUB_BRANCH RESTIC_REPOSITORY; do
            ssh_n8n "grep -qE '^${k}=.+' /root/n8n/.backup_creds" 2>/dev/null || missing_keys+=("$k")
        done
        if [ ${#missing_keys[@]} -gt 0 ]; then
            err "Missing or empty in .backup_creds: ${missing_keys[*]}"
            err "  Run a full deploy or re-run: npm run initialize"
            return 1
        fi
        info "✓ Required keys present (GITHUB_PERSONAL_ACCESS_TOKEN, GITHUB_REPO, GITHUB_BRANCH, RESTIC_REPOSITORY)"
        return 0
    fi
    err "/root/n8n/.backup_creds not found — run a deploy first"
    return 1
}

# Watch /root/n8n/poll-publish.log for "Schema check failed" (n8n renamed
# its publish tables → poll script blind) and "GitHub commit failed" (PAT/repo
# misconfigured). SKIP on empty log (cron may not have fired yet).
test_poll_publish_log_healthy() {
    local log
    # 10 lines ≈ recent runs only — wider windows surface stale failures.
    log=$(ssh_n8n "tail -10 /root/n8n/poll-publish.log 2>/dev/null") || true
    if [ -z "$log" ]; then
        warn "No /root/n8n/poll-publish.log yet — cron may not have fired (wait 60s)"
        return 2
    fi
    local ok=1
    if echo "$log" | grep -q "Schema check failed"; then
        err "poll-publish-events.sh: schema check failure — n8n tables may have changed"
        echo "$log" | grep -A2 "Schema check failed" | sed 's/^/    /'
        ok=0
    fi
    if echo "$log" | grep -q "GitHub commit failed"; then
        err "github-commit-workflows.sh: commit failed — check GITHUB_PERSONAL_ACCESS_TOKEN/GITHUB_REPO in .backup_creds"
        echo "$log" | grep "GitHub commit failed" | head -2 | sed 's/^/    /'
        ok=0
    fi
    [ "$ok" -eq 1 ] && info "Recent poll-publish.log clean (last $(echo "$log" | wc -l | tr -d ' ') runs)"
    return $((1 - ok))
}

test_github_commit_prereqs() {
    if ! ssh_n8n "test -x /root/n8n/scripts/github-commit-workflows.sh" 2>/dev/null; then
        err "github-commit-workflows.sh not found or not executable on n8n VPS"
        err "  Run a full deploy to upload it."
        return 1
    fi
    info "✓ github-commit-workflows.sh present and executable"

    local result
    if ! result=$(ssh_n8n bash -s <<'REMOTE_EOF' 2>/dev/null
set -a; source /root/n8n/.backup_creds || exit 1; set +a
github_value() {
    local response status curl_rc=0 reason value
    response=$(curl -s --max-time 10 -w '\n%{http_code}' \
      -H "Authorization: Bearer $GITHUB_PERSONAL_ACCESS_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/$1" 2>/dev/null) || curl_rc=$?
    status=${response##*$'\n'}
    status=${status:-000}
    if [ "$curl_rc" -eq 0 ] && [ "$status" = "200" ]; then
        value=$(printf '%s' "${response%$'\n'*}" | jq -er --arg field "$2" '.[$field] // empty' 2>/dev/null) || value=""
        if [ -n "$value" ]; then
            printf '%s' "$value"
            return 0
        fi
    fi
    # Balanced case patterns keep this heredoc compatible with macOS Bash.
    case "$status" in
        (401) reason="token invalid or expired" ;;
        (403) reason="token lacks a required permission" ;;
        (404) reason="token has no access to that repo, or the repository name is wrong" ;;
        (*) reason="unexpected response (curl exit $curl_rc)" ;;
    esac
    printf 'GitHub %s: HTTP %s — GITHUB_REPO=%s — %s\n' "$1" "$status" "${GITHUB_REPO:-unset}" "$reason"
    return 1
}
login=$(github_value user login) || { printf '%s\n' "$login"; exit 1; }
printf '✓ GITHUB_PERSONAL_ACCESS_TOKEN valid — authenticated as: %s\n' "$login"
repo_name=$(github_value "repos/$GITHUB_REPO" full_name) || { printf '%s\n' "$repo_name"; exit 1; }
printf '✓ Repo accessible: %s\n' "$repo_name"
REMOTE_EOF
    ); then
        err "${result:-GitHub token check failed over SSH — GITHUB_REPO=${GITHUB_REPO:-unset}}"
        return 1
    fi
    info "$result"
    return 0
}

test_scan_workflow_secrets_present() {
    if ssh_n8n "test -x /root/n8n/scripts/scan-workflow-secrets.sh" 2>/dev/null; then
        info "✓ /root/n8n/scripts/scan-workflow-secrets.sh present and executable"
        return 0
    fi
    err "scan-workflow-secrets.sh not found or not executable on n8n VPS"
    err "  Missing scanner aborts all workflow auto-commits — run a full deploy"
    return 1
}

# ─── 3b. Health ping (optional — requires explicit developer skip; retry supported) ────────
_HEALTH_PING_SKIP=false  # set true once dev explicitly skips; silences downstream tests

test_health_ping_configured() {
    while true; do
        local url
        url=$(ssh_n8n "grep '^HEALTH_PING_URL=' /root/n8n/.backup_creds 2>/dev/null | cut -d= -f2-") || true
        if [ -n "$url" ]; then
            info "✓ HEALTH_PING_URL configured"
            return 0
        fi
        local rc=0
        prompt_dev "HEALTH_PING_URL not found in .backup_creds — health ping not enabled.
   To fix: set HEALTH_PING_URL in .env, run 'npm run encrypt-env', push, wait for deploy." || rc=$?
        [ "$rc" -eq 0 ] && continue
        [ "$rc" -eq 2 ] && _HEALTH_PING_SKIP=true
        return "$rc"
    done
}

test_health_ping_workflow_active() {
    [ "$_HEALTH_PING_SKIP" = "true" ] && { info "health ping skipped — skipping workflow check"; return 2; }
    local url
    url=$(ssh_n8n "grep '^HEALTH_PING_URL=' /root/n8n/.backup_creds 2>/dev/null | cut -d= -f2-") || true
    [ -z "$url" ] && { info "HEALTH_PING_URL not configured — skipping workflow check"; return 2; }
    local result
    result=$(ssh_n8n bash -s <<'REMOTE_EOF' 2>/dev/null
set -a; source /root/n8n/.backup_creds; set +a
curl -s "${N8N_LOCAL_API_URL}/workflows" \
  -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
  | jq -r '.data[] | select(.name == "Health Ping") | "found active=\(.active)"' 2>/dev/null | head -1
REMOTE_EOF
    ) || true
    if echo "$result" | grep -q "active=true"; then
        info "✓ Health Ping workflow is active in n8n"
        return 0
    elif echo "$result" | grep -q "active=false"; then
        err "Health Ping workflow exists but is NOT active — activate it in the n8n UI"
        return 1
    fi
    err "Health Ping workflow not found in n8n — run a full deploy: git push"
    return 1
}

test_health_ping_reachable() {
    [ "$_HEALTH_PING_SKIP" = "true" ] && { info "health ping skipped — skipping reachability check"; return 2; }
    local url
    url=$(ssh_n8n "grep '^HEALTH_PING_URL=' /root/n8n/.backup_creds 2>/dev/null | cut -d= -f2-") || true
    [ -z "$url" ] && { info "HEALTH_PING_URL not configured — skipping reachability check"; return 2; }
    local http
    http=$(ssh_n8n "curl -s -o /dev/null -w '%{http_code}' --max-time 10 '${url}' 2>/dev/null || echo 000") || true
    if [ "$http" = "200" ]; then
        info "✓ healthchecks.io ping URL reachable from VPS (HTTP 200) — check is 'Up'"
        return 0
    fi
    err "healthchecks.io ping URL returned HTTP ${http} from VPS — check outbound internet or URL validity"
    return 1
}

# ─── 4. End-to-end backup ──────────────────────────────────────────────────
# Compares snapshot IDs not counts — inline retention can prune as it adds.
test_backup_end_to_end() {
    local before_ids after_ids new_ids
    local backblaze_enabled=false backblaze_before_ids="" backblaze_after_ids="" backblaze_new_ids
    if ssh_n8n "grep -q -E '^RESTIC_REPOSITORY_BACKBLAZE=(b2:|rclone:b2:)' /root/n8n/.backup_creds 2>/dev/null"; then
        backblaze_enabled=true
    fi

    before_ids=$(ssh_n8n bash -s <<'REMOTE_EOF' 2>/dev/null
set -e
[ -f /root/n8n/.backup_creds ] || exit 1
set -a; source /root/n8n/.backup_creds; set +a
export RESTIC_PASSWORD="$BACKUP_PASSWORD"
restic -r "$RESTIC_REPOSITORY" snapshots --compact 2>/dev/null \
  | grep -oE "^[0-9a-f]{8}" | sort
REMOTE_EOF
    ) || true
    info "Restic snapshot IDs before: $(echo "$before_ids" | tr '\n' ' ' | sed 's/ $//')"

    if [ "$backblaze_enabled" = true ]; then
        backblaze_before_ids=$(ssh_n8n bash -s <<'REMOTE_EOF' 2>/dev/null
[ -f /root/n8n/.backup_creds ] || exit 0
set -a; source /root/n8n/.backup_creds; set +a
[ -n "${RESTIC_REPOSITORY_BACKBLAZE:-}" ] || exit 0
export RESTIC_PASSWORD="$BACKUP_PASSWORD"
export RCLONE_CONFIG_B2_TYPE=b2 RCLONE_CONFIG_B2_ACCOUNT="$BACKBLAZE_KEY_ID" RCLONE_CONFIG_B2_KEY="$BACKBLAZE_APPLICATION_KEY" RCLONE_CONFIG_B2_HARD_DELETE=true
restic -r "$RESTIC_REPOSITORY_BACKBLAZE" snapshots --no-lock --compact 2>/dev/null \
  | grep -oE "^[0-9a-f]{8}" | sort
REMOTE_EOF
        ) || true
        info "Backblaze IDs before:       $(echo "$backblaze_before_ids" | tr '\n' ' ' | sed 's/ $//')"
    fi

    info "Running backup-database.sh on n8n VPS (pg_dumpall → gzip → restic, ~10–30s)..."
    if ! ssh_n8n "bash /root/n8n/scripts/database/backup-database.sh" >/tmp/test-env-backup.log 2>&1; then
        err "backup-database.sh exited non-zero"
        tail -5 /tmp/test-env-backup.log | sed 's/^/    /'
        return 1
    fi

    after_ids=$(ssh_n8n bash -s <<'REMOTE_EOF' 2>/dev/null
set -e
[ -f /root/n8n/.backup_creds ] || exit 1
set -a; source /root/n8n/.backup_creds; set +a
export RESTIC_PASSWORD="$BACKUP_PASSWORD"
restic -r "$RESTIC_REPOSITORY" snapshots --compact 2>/dev/null \
  | grep -oE "^[0-9a-f]{8}" | sort
REMOTE_EOF
    ) || true
    info "Restic snapshot IDs after:  $(echo "$after_ids" | tr '\n' ' ' | sed 's/ $//')"

    new_ids=$(comm -13 <(echo "$before_ids") <(echo "$after_ids") 2>/dev/null || true)
    if [ -n "$new_ids" ]; then
        info "✓ Local snapshot created: $new_ids"
    else
        err "No new local snapshot ID appeared — backup-database.sh may have failed silently"
        err "  backup.log tail:"
        tail -5 /tmp/test-env-backup.log | sed 's/^/    /'
        return 1
    fi

    if [ "$backblaze_enabled" = true ]; then
        backblaze_after_ids=$(ssh_n8n bash -s <<'REMOTE_EOF' 2>/dev/null
[ -f /root/n8n/.backup_creds ] || exit 0
set -a; source /root/n8n/.backup_creds; set +a
[ -n "${RESTIC_REPOSITORY_BACKBLAZE:-}" ] || exit 0
export RESTIC_PASSWORD="$BACKUP_PASSWORD"
export RCLONE_CONFIG_B2_TYPE=b2 RCLONE_CONFIG_B2_ACCOUNT="$BACKBLAZE_KEY_ID" RCLONE_CONFIG_B2_KEY="$BACKBLAZE_APPLICATION_KEY" RCLONE_CONFIG_B2_HARD_DELETE=true
restic -r "$RESTIC_REPOSITORY_BACKBLAZE" snapshots --no-lock --compact 2>/dev/null \
  | grep -oE "^[0-9a-f]{8}" | sort
REMOTE_EOF
        ) || true
        info "Backblaze IDs after:        $(echo "$backblaze_after_ids" | tr '\n' ' ' | sed 's/ $//')"
        backblaze_new_ids=$(comm -13 <(echo "$backblaze_before_ids") <(echo "$backblaze_after_ids") 2>/dev/null || true)
        if [ -n "$backblaze_new_ids" ]; then
            info "✓ Backblaze snapshot created: $backblaze_new_ids"
        else
            err "No new Backblaze snapshot — backup-database.sh pushed locally but Backblaze push may have failed"
            err "  backup.log tail:"
            tail -10 /tmp/test-env-backup.log | sed 's/^/    /'
            return 1
        fi
    fi

    return 0
}

# ─── 4b. Restic repository accessibility (read-only) ─────────────────────

test_backup_local_repo() {
    local out rc=0
    out=$(ssh_n8n bash -s <<'REMOTE_EOF' 2>/dev/null
set -e
[ -f /root/n8n/.backup_creds ] || { echo "no .backup_creds"; exit 1; }
set -a; source /root/n8n/.backup_creds; set +a
: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY missing}"
: "${BACKUP_PASSWORD:?BACKUP_PASSWORD missing}"
export RESTIC_PASSWORD="$BACKUP_PASSWORD"
SNAPSHOTS=$(restic -r "$RESTIC_REPOSITORY" snapshots --compact 2>/dev/null)
COUNT=$(printf '%s\n' "$SNAPSHOTS" | grep -cE "^[0-9a-f]{8}" || true)
echo "$COUNT snapshot(s) in $RESTIC_REPOSITORY"
REMOTE_EOF
    ) || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
        err "Cannot access local restic repository — run: npm run initialize"
        return 1
    fi
    info "✓ $out"
    return 0
}

test_backup_backblaze_repo() {
    local backblaze_set
    backblaze_set=$(ssh_n8n "grep -c -E '^RESTIC_REPOSITORY_BACKBLAZE=(b2:|rclone:b2:)' /root/n8n/.backup_creds 2>/dev/null || true") || true
    if [ "${backblaze_set:-0}" = "0" ]; then
        info "Backblaze not configured in .backup_creds — skipping"
        return 2
    fi
    local out rc=0
    out=$(ssh_n8n bash -s <<'REMOTE_EOF' 2>/dev/null
set -e
[ -f /root/n8n/.backup_creds ] || { echo "no .backup_creds"; exit 1; }
set -a; source /root/n8n/.backup_creds; set +a
: "${RESTIC_REPOSITORY_BACKBLAZE:?RESTIC_REPOSITORY_BACKBLAZE missing}"
: "${BACKBLAZE_KEY_ID:?BACKBLAZE_KEY_ID missing}"
: "${BACKBLAZE_APPLICATION_KEY:?BACKBLAZE_APPLICATION_KEY missing}"
: "${BACKUP_PASSWORD:?BACKUP_PASSWORD missing}"
export RESTIC_PASSWORD="$BACKUP_PASSWORD"
export RCLONE_CONFIG_B2_TYPE=b2 RCLONE_CONFIG_B2_ACCOUNT="$BACKBLAZE_KEY_ID" RCLONE_CONFIG_B2_KEY="$BACKBLAZE_APPLICATION_KEY" RCLONE_CONFIG_B2_HARD_DELETE=true
SNAPSHOTS=$(restic -r "$RESTIC_REPOSITORY_BACKBLAZE" snapshots --no-lock --compact 2>/dev/null)
COUNT=$(printf '%s\n' "$SNAPSHOTS" | grep -cE "^[0-9a-f]{8}" || true)
echo "$COUNT snapshot(s) in $RESTIC_REPOSITORY_BACKBLAZE"
REMOTE_EOF
    ) || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
        err "Cannot access Backblaze restic repository — check BACKBLAZE_KEY_ID/APPLICATION_KEY in .backup_creds"
        return 1
    fi
    info "✓ $out"
    return 0
}

# ─── 5b. npm run pull ──────────────────────────────────────────────────────
test_npm_pull() {
    # Fresh DB → --pull is a no-op; push first.
    local wf_count
    wf_count=$(ssh_n8n bash -s <<'REMOTE_EOF' 2>/dev/null
set -e
[ -f /root/n8n/.backup_creds ] || exit 0
set -a; source /root/n8n/.backup_creds; set +a
DBN=$(docker exec n8n_postgres printenv POSTGRES_DB 2>/dev/null) || exit 0
docker exec n8n_postgres psql -U "$DB_USER" -d "$DBN" -tAc \
    'SELECT COUNT(*) FROM workflow_entity' 2>/dev/null
REMOTE_EOF
    )
    wf_count=$(echo "$wf_count" | tr -d ' \n\r')
    if [ "${wf_count:-0}" = "0" ]; then
        info "n8n DB has 0 workflows — fresh install, nothing to pull yet."
        info "  Push workflows first: deploy via GitHub Actions, or 'bash n8n/scripts/sync-workflows.sh --push'"
        return 0
    fi

    local out rc
    out=$(npm run pull --silent 2>&1)
    rc=$?
    if [ $rc -ne 0 ]; then
        err "npm run pull exited $rc"
        echo "$out" | tail -10 | sed 's/^/    /'
        return 1
    fi
    local count
    count=$(ls "$(dirname "$SCRIPT_DIR")/n8n/workflows/"*.json 2>/dev/null | wc -l | tr -d ' ')
    info "Pulled OK — $count workflow JSON files in n8n/workflows/ (DB had $wf_count)"
    return 0
}

# ─── 6. Interactive: GitHub auto-commit on publish ─────────────────────────
test_publish_chain_github() {
    local url
    url=$(ssh_n8n "docker inspect n8n_app --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -E '^WEBHOOK_URL=' | head -1 | cut -d= -f2-")
    [ -z "$url" ] && url="(your n8n public URL)"

    local baseline
    baseline=$(ssh_n8n "wc -l < /root/n8n/poll-publish.log 2>/dev/null || echo 0" | tr -d ' ')

    printf '  Open n8n: '
    print_link "$url"
    prompt_dev "AUTO-COMMIT ON PUBLISH TEST

  This exercises the full GitOps chain:
    n8n Publish → cron detects event → VPS commits to GitHub via API

  Open the n8n URL above.

  1. Open any workflow
  2. Change a node (rename it, update a parameter, or add a sticky note)
  3. Click ${C_BOLD}Publish${C_RESET} (blue button, top-right) — NOT just the Active toggle

  The cron fires every minute. After Publish, the script polls for up to 90s
  waiting for the GitHub commit.
" || return $?

    info "Polling poll-publish.log for a new '✅ Committed' entry (up to 90s)..."
    local commit_line=""
    local i
    for i in $(seq 1 18); do
        local new_log
        new_log=$(ssh_n8n "tail -n +$((baseline + 1)) /root/n8n/poll-publish.log 2>/dev/null") || true
        commit_line=$(printf '%s' "$new_log" | grep "✅ Committed:" | tail -1)
        if [ -n "$commit_line" ]; then
            info "✓ $commit_line"
            return 0
        fi
        local event_line
        event_line=$(printf '%s' "$new_log" | grep "📍 Publish event" | tail -1)
        [ -n "$event_line" ] && info "  Publish event detected — waiting for commit to complete..."
        sleep 5
    done

    err "No '✅ Committed' line in poll-publish.log after 90s"
    local tail_new
    tail_new=$(ssh_n8n "tail -n +$((baseline + 1)) /root/n8n/poll-publish.log 2>/dev/null | tail -10") || true
    if [ -n "$tail_new" ]; then
        err "New log output:"
        printf '%s\n' "$tail_new" | sed 's/^/    /'
    else
        err "  No new log lines at all — did the cron fire? Did you click Publish (not just Save/Active toggle)?"
    fi
    return 1
}

# ─── 7. Interactive: local edit → git push → deploy.yml → n8n ────────────
test_deploy_chain() {
    local proj_root workflows_dir json_count before_snapshot
    proj_root="$(dirname "$SCRIPT_DIR")"
    workflows_dir="$proj_root/n8n/workflows"

    before_snapshot=$(ssh_n8n bash -s <<'REMOTE_EOF' 2>/dev/null
set -a; source /root/n8n/.backup_creds; set +a
curl -s "${N8N_LOCAL_API_URL}/workflows" \
  -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
  | jq -r '.data[] | "\(.id)\t\(.updatedAt)"' | sort
REMOTE_EOF
    ) || true

    # Don't auto-pull — local workflow JSON belongs to the developer's working
    # tree. If empty, ask the user to pull manually rather than silently
    # overwriting whatever they had open.
    json_count=$(find "$workflows_dir" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$json_count" -eq 0 ]; then
        err "No workflow JSON files in n8n/workflows/ — run 'npm run pull' once, then re-run this test."
        return 1
    fi

    local sample; sample=$(find "$workflows_dir" -name "*.json" | head -1 | xargs basename)

    prompt_dev "DEPLOY CHAIN TEST: local edit → git push → deploy.yml → n8n

  Workflow JSON files are in: n8n/workflows/  ($json_count file(s))
  Example file: $sample

  1. Open any file in ${C_BOLD}n8n/workflows/${C_RESET} in your editor
  2. Make any change (e.g. add a space to a node note, or change a setting)
  3. Run in the project root:
       git add n8n/workflows/
       git commit -m 'test: deploy chain'
       git push
  4. Press ${C_BOLD}[Enter]${C_RESET} — the test polls n8n every 15s for up to 5 min
     until deploy.yml finishes and the change appears" || return $?

    local waited=0 max_wait=90 after_snapshot=""
    info "Polling n8n API every 15s for up to ${max_wait}s..."
    while [ "$waited" -lt "$max_wait" ]; do
        after_snapshot=$(ssh_n8n bash -s <<'REMOTE_EOF' 2>/dev/null
set -a; source /root/n8n/.backup_creds; set +a
curl -s "${N8N_LOCAL_API_URL}/workflows" \
  -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
  | jq -r '.data[] | "\(.id)\t\(.updatedAt)"' | sort
REMOTE_EOF
        ) || true

        if [ -n "$after_snapshot" ] && [ "$after_snapshot" != "$before_snapshot" ]; then
            _beep
            info "✓ n8n workflow state changed — deploy landed"
            return 0
        fi

        waited=$((waited + 15))
        info "  Waiting... (${waited}s / ${max_wait}s)"
        sleep 15
    done

    err "No workflow change detected in n8n after ${max_wait}s"
    err "  Check GitHub Actions:"
    print_link "https://github.com/${GITHUB_REPO}/actions"
    return 1
}

# ─── 8b/8c. Standalone restore round-trip from a specific repo ───────────────
# Shared driver: snapshot DB → make a fresh backup → dev modifies workflow →
# restore latest from {local|backblaze} → verify DB returns to pre-modification
# state. Self-contained so each repo gets a real round-trip, not a smoke test.
_restore_round_trip_from() {
    local source="$1"
    local repo_label restore_env restore_log

    case "$source" in
        local)
            repo_label="LOCAL RESTIC (on-disk /var/backups/restic)"
            restore_env=""
            restore_log="/tmp/test-env-restore-local.log"
            ;;
        backblaze)
            repo_label="BACKBLAZE (REMOTE B2)"
            restore_env="RESTORE_SOURCE_CHOICE=2 "
            restore_log="/tmp/test-env-restore-b2.log"
            ;;
        *) err "internal: unknown source '$source'"; return 1;;
    esac

    local snap_count
    if [ "$source" = "local" ]; then
        snap_count=$(ssh_n8n bash -s <<'REMOTE_EOF' 2>/dev/null
set -e
[ -f /root/n8n/.backup_creds ] || exit 1
set -a; source /root/n8n/.backup_creds; set +a
export RESTIC_PASSWORD="$BACKUP_PASSWORD"
restic -r "$RESTIC_REPOSITORY" snapshots --compact 2>/dev/null \
  | grep -cE "^[0-9a-f]{8}" || true
REMOTE_EOF
        ) || true
    else
        snap_count=$(ssh_n8n bash -s <<'REMOTE_EOF' 2>/dev/null
set -e
[ -f /root/n8n/.backup_creds ] || exit 1
set -a; source /root/n8n/.backup_creds; set +a
export RESTIC_PASSWORD="$BACKUP_PASSWORD"
export RCLONE_CONFIG_B2_TYPE=b2 RCLONE_CONFIG_B2_ACCOUNT="$BACKBLAZE_KEY_ID" RCLONE_CONFIG_B2_KEY="$BACKBLAZE_APPLICATION_KEY" RCLONE_CONFIG_B2_HARD_DELETE=true
restic -r "$RESTIC_REPOSITORY_BACKBLAZE" snapshots --no-lock --compact 2>/dev/null \
  | grep -cE "^[0-9a-f]{8}" || true
REMOTE_EOF
        ) || true
    fi
    snap_count=$(echo "$snap_count" | tr -d ' \n\r')
    if [ "${snap_count:-0}" = "0" ]; then
        warn "No ${repo_label} snapshots found — run 'npm run backup-database' first"
        return 2
    fi
    info "${snap_count} ${repo_label} snapshot(s) available"

    # Snapshot DB state — this is what the restore must bring us back to.
    info "Snapshotting workflow_entity state (before)..."
    local before
    before=$(snapshot_workflows)
    if [ -z "$before" ]; then
        err "Snapshot returned no rows — cannot run restore round-trip"
        return 1
    fi
    local row_count
    row_count=$(echo "$before" | wc -l | tr -d ' ')
    info "Captured $row_count workflow row(s)."

    # Push a fresh snapshot so 'latest' in the repo matches current "before" state.
    info "Creating a fresh backup so 'latest' in ${repo_label} matches current DB..."
    if ! ssh_n8n "bash /root/n8n/scripts/database/backup-database.sh" \
            >/tmp/test-env-restore-prebackup.log 2>&1; then
        err "backup-database.sh failed — cannot guarantee 'latest' state"
        tail -5 /tmp/test-env-restore-prebackup.log | sed 's/^/    /'
        return 1
    fi
    info "✓ Fresh backup snapshot pushed."

    local url
    url=$(ssh_n8n "docker inspect n8n_app --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -E '^WEBHOOK_URL=' | head -1 | cut -d= -f2-")
    [ -z "$url" ] && url="(your n8n public URL)"

    printf '  Open n8n: '
    print_link "$url"
    prompt_dev "${C_BOLD}RESTORE ROUND-TRIP — FROM ${repo_label}${C_RESET}

  Open the n8n URL above.
  Pick ONE workflow and MODIFY it (rename it, or toggle its Active switch).
  Make sure n8n saves the change.

  We will then restore the latest snapshot from ${C_BOLD}${repo_label}${C_RESET}
  and verify the workflow returns to its pre-modification state." || return $?

    # Verify the modification actually reached the DB.
    info "Verifying the DB reflects your change..."
    local modified
    modified=$(snapshot_workflows)
    if [ "$modified" = "$before" ]; then
        err "DB state is identical to before — your change wasn't saved or didn't reach the DB."
        prompt_dev "Re-open the workflow in n8n, save the change explicitly, then press [Enter] — or 'skip' to abort." || return $?
        modified=$(snapshot_workflows)
        if [ "$modified" = "$before" ]; then
            warn "DB state still unchanged — recording test failure."
            return 1
        fi
    fi
    info "✓ DB change detected. Diff (before → modified):"
    diff <(echo "$before") <(echo "$modified") | head -10 | sed 's/^/    /'

    confirm_dev "${C_RED}${C_BOLD}Ready to restore from ${repo_label} now?${C_RESET}
  This will STOP n8n, roll the DB back to the latest snapshot in ${repo_label}, then restart.
  Your modification will be erased — that is the point of the test.
  Type 'n' or 's' to abort." || {
        warn "Restore from ${repo_label} skipped by developer."
        return 2
    }

    info "Restoring from latest ${repo_label} snapshot (~30–90s)..."
    if ! ssh_n8n "echo y | ${restore_env}bash /root/n8n/scripts/database/restore-database.sh latest" \
            >"$restore_log" 2>&1; then
        err "restore-database.sh (${repo_label}) failed"
        tail -10 "$restore_log" | sed 's/^/    /'
        return 1
    fi
    info "✓ Restore script completed. Last 3 lines:"
    tail -3 "$restore_log" | sed 's/^/    /'

    # Restore script's trap re-installs the poll-publish cron; if it's gone, the trap failed.
    if ssh_n8n "crontab -l 2>/dev/null" | grep -q "poll-publish-events.sh"; then
        info "✓ poll-publish cron present after restore (trap fired correctly)"
    else
        err "✗ poll-publish cron missing after restore — restore script trap may have failed"
        return 1
    fi

    info "Waiting up to 90s for n8n to be healthy..."
    local healthy=0 i code
    for i in $(seq 1 18); do
        code=$(ssh_n8n "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:5678/healthz || true")
        [ "$code" = "200" ] && healthy=1 && break
        sleep 5
    done
    if [ $healthy -ne 1 ]; then
        err "n8n did not return 200 within 90s after ${repo_label} restore"
        return 1
    fi
    info "✓ n8n /healthz back to 200 after ${repo_label} restore"

    # Verify the DB returned to the pre-modification state.
    info "Snapshotting workflow_entity state (after restore)..."
    local after
    after=$(snapshot_workflows)
    local db_match=0
    if [ "$after" = "$before" ]; then
        info "✓ DB matches the pre-modification state — restore from ${repo_label} worked."
        db_match=1
    else
        warn "DB snapshot does NOT exactly match the pre-modification state after restore."
        echo "  --- Diff (before vs after) ---"
        diff <(echo "$before") <(echo "$after") | head -20 | sed 's/^/    /'
    fi

    printf '  Refresh n8n in your browser: '
    print_link "$url"
    confirm_dev "Check the n8n page above.

  Verify the workflow you just modified is back to its ORIGINAL state
  (the rename / Active toggle you made above should be gone).

  • [y]es — workflow looks correct (test PASSES)
  • [n]o  — workflow is NOT back to its original state (test FAILS)
  • [s]kip — can't tell; trust the automated DB comparison"
    local rc=$?
    case "$rc" in
        0) info "Developer confirmed the UI is back to its original state."
           return 0;;
        1) err "Developer reports the workflow is NOT back to its original state — restore from ${repo_label} is broken."
           return 1;;
        *) info "Developer skipped UI confirmation; deferring to the DB comparison result."
           [ "$db_match" -eq 1 ] && return 0 || return 1;;
    esac
}

test_restore_local() {
    _restore_round_trip_from local
}

test_restore_backblaze() {
    local backblaze_set
    backblaze_set=$(ssh_n8n "grep -c -E '^RESTIC_REPOSITORY_BACKBLAZE=(b2:|rclone:b2:)' /root/n8n/.backup_creds 2>/dev/null || true") || true
    if [ "${backblaze_set:-0}" = "0" ]; then
        info "Backblaze not configured in .backup_creds — skipping"
        return 2
    fi
    _restore_round_trip_from backblaze
}

# ─── 5. Disk space monitoring ──────────────────────────────────────────────

test_disk_check_cron() {
    local cron
    cron=$(ssh_n8n "crontab -l 2>/dev/null") || true
    if echo "$cron" | grep -q "disk-space-check.sh"; then
        info "✓ Hourly disk check cron present"
        return 0
    fi
    err "Hourly disk check cron missing — run a full deploy or re-run: npm run initialize"
    return 1
}

test_disk_check_script() {
    if ssh_n8n "test -x /root/n8n/scripts/disk-space-check.sh" 2>/dev/null; then
        info "✓ /root/n8n/scripts/disk-space-check.sh present and executable"
        return 0
    fi
    err "disk-space-check.sh not found or not executable — run a full deploy"
    return 1
}

test_disk_check_resend_config() {
    local key_set
    key_set=$(ssh_n8n "grep -c '^RESEND_API_KEY=.' /root/n8n/.backup_creds 2>/dev/null || true") || true
    if [ "${key_set:-0}" = "0" ]; then
        info "RESEND_API_KEY not set in .backup_creds — email alerts not configured"
        return 2
    fi

    local ok=1
    if ssh_n8n "grep -q '^RESEND_FROM_EMAIL=.' /root/n8n/.backup_creds 2>/dev/null"; then
        info "✓ RESEND_FROM_EMAIL set in .backup_creds"
    else
        err "RESEND_FROM_EMAIL missing in .backup_creds — alerts will skip"
        ok=0
    fi

    if ssh_n8n "command -v curl >/dev/null 2>&1"; then
        info "✓ curl available on VPS"
    else
        err "curl not installed — re-run: npm run initialize"
        ok=0
    fi

    if ssh_n8n "test -r /root/n8n/scripts/lib/send-email.sh"; then
        info "✓ /root/n8n/scripts/lib/send-email.sh present"
    else
        err "send-email.sh missing — deploy n8n/ tree to VPS"
        ok=0
    fi

    [ "$ok" -eq 1 ] && return 0 || return 1
}

test_disk_check_dry_run() {
    if ! ssh_n8n "test -x /root/n8n/scripts/disk-space-check.sh" 2>/dev/null; then
        err "disk-space-check.sh not found — run a full deploy first"
        return 1
    fi

    local medium high
    medium=$(ssh_n8n "grep '^ALERT_DISK_THRESHOLD_MEDIUM=' /root/n8n/.backup_creds 2>/dev/null | cut -d= -f2-") || true
    high=$(ssh_n8n  "grep '^ALERT_DISK_THRESHOLD_HIGH='   /root/n8n/.backup_creds 2>/dev/null | cut -d= -f2-") || true
    info "Configured thresholds: MEDIUM ≥${medium:-85}% used, HIGH ≥${high:-95}% used"

    if ! ssh_n8n "bash /root/n8n/scripts/disk-space-check.sh" >/dev/null 2>&1; then
        err "disk-space-check.sh exited non-zero"
        local log_tail
        log_tail=$(ssh_n8n "tail -3 /root/n8n/disk-check.log 2>/dev/null") || true
        [ -n "$log_tail" ] && printf '%s\n' "$log_tail" | sed 's/^/    /'
        return 1
    fi

    local last_line
    last_line=$(ssh_n8n "tail -1 /root/n8n/disk-check.log 2>/dev/null") || true
    if [ -n "$last_line" ]; then
        info "disk-check.log: $last_line"
    else
        warn "disk-check.log is empty — script ran but produced no output"
    fi
    return 0
}

# Forces the MEDIUM alert by lowering the threshold to 1% under a trap.
test_disk_check_email() {
    local key_set
    key_set=$(ssh_n8n "grep -c '^RESEND_API_KEY=.' /root/n8n/.backup_creds 2>/dev/null || true") || true
    if [ "${key_set:-0}" = "0" ]; then
        info "RESEND_API_KEY not configured in .backup_creds — skipping email delivery test"
        return 2
    fi

    local recipient
    recipient=$(ssh_n8n "grep '^DEVELOPER_EMAIL=' /root/n8n/.backup_creds 2>/dev/null | cut -d= -f2-") || true
    [ -z "$recipient" ] && recipient="(your DEVELOPER_EMAIL)"

    info "Sending a MEDIUM disk-space alert email to ${recipient} (threshold temporarily 1%, restored via trap)."
    local log_before
    log_before=$(ssh_n8n "wc -l < /root/n8n/disk-check.log 2>/dev/null || echo 0" | tr -d ' ')

    ssh_n8n bash -s <<'REMOTE_EOF' || { err "Remote trigger script failed (exit $?)"; return 1; }
set -e
# Force secure perms on every new tmp so a mid-test crash never leaves a
# world-readable .backup_creds — the file holds API tokens.
umask 077
CREDS="/root/n8n/.backup_creds"
BACKUP=$(mktemp)
cp "$CREDS" "$BACKUP"
trap "cp '$BACKUP' '$CREDS'; chmod 600 '$CREDS'; rm -f '$BACKUP'" EXIT
grep -v '^ALERT_DISK_THRESHOLD_MEDIUM=\|^ALERT_DISK_THRESHOLD_HIGH=' "$CREDS" > "$CREDS.tmp"
chmod 600 "$CREDS.tmp"
mv "$CREDS.tmp" "$CREDS"
printf 'ALERT_DISK_THRESHOLD_MEDIUM=1\nALERT_DISK_THRESHOLD_HIGH=101\n' >> "$CREDS"
bash /root/n8n/scripts/disk-space-check.sh
REMOTE_EOF

    local new_log
    new_log=$(ssh_n8n "tail -n +$((log_before + 1)) /root/n8n/disk-check.log 2>/dev/null") || true
    if [ -n "$new_log" ]; then
        info "New disk-check.log entries:"
        printf '%s\n' "$new_log" | sed 's/^/    /'
    else
        err "Cannot verify email delivery: no new lines in disk-check.log after the run"
        return 1
    fi
    if ! printf '%s\n' "$new_log" | grep -q 'MEDIUM alert email sent to '; then
        err "Disk alert email delivery failed — see disk-check.log entries above."
        return 1
    fi

    confirm_dev "Check your inbox for the disk space alert email.
    Recipient: ${C_BOLD}${recipient}${C_RESET}

  (Check Spam if not in Inbox — first send from a new Resend sender may land there.
   Mark as 'Not Spam' once, and future alerts should arrive normally.)

  Did you receive the alert email?

  • [y]es — email arrived correctly (test PASSES)
  • [n]o  — no email received (test FAILS — check /root/n8n/disk-check.log on VPS)
  • [s]kip — cannot check right now" || return $?
}

# ─── 6. Error monitoring ──────────────────────────────────────────────────

test_error_handler_workflow_active() {
    local wf_count
    _count_workflows() {
        wf_count=$(ssh_n8n bash -s <<'REMOTE_EOF' 2>/dev/null
set -e
[ -f /root/n8n/.backup_creds ] || exit 0
set -a; source /root/n8n/.backup_creds; set +a
DBN=$(docker exec n8n_postgres printenv POSTGRES_DB 2>/dev/null) || exit 0
docker exec n8n_postgres psql -U "$DB_USER" -d "$DBN" -tAc \
    'SELECT COUNT(*) FROM workflow_entity' 2>/dev/null
REMOTE_EOF
        )
        wf_count=$(echo "$wf_count" | tr -d ' \n\r')
    }
    _count_workflows
    if [ "${wf_count:-0}" = "0" ]; then
        prompt_dev "n8n DB has 0 workflows — push workflows to n8n first:

  git push

  GitHub Actions will deploy and sync workflows to the VPS.
  Once the deploy finishes, press [Enter] to continue." || return $?
        _count_workflows
        if [ "${wf_count:-0}" = "0" ]; then
            err "Still 0 workflows after deploy — check GitHub Actions logs"
            return 1
        fi
    fi

    local result
    _check_active() {
        result=$(ssh_n8n bash -s <<'REMOTE_EOF' 2>/dev/null
set -a; source /root/n8n/.backup_creds; set +a
curl -s "${N8N_LOCAL_API_URL}/workflows" \
  -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
  | jq -r '.data[] | select(.name == "Global Error Handler") | "found active=\(.active)"' 2>/dev/null | head -1
REMOTE_EOF
        ) || true
    }
    _check_active
    if echo "$result" | grep -q "active=true"; then
        info "✓ Global Error Handler workflow is active"
        return 0
    elif echo "$result" | grep -q "active=false"; then
        prompt_dev "Global Error Handler exists but is NOT active.

  1. Open n8n UI → Workflows → 'Global Error Handler' → toggle Active ON
  2. Settings → n8n Settings → Error Workflow → select 'Global Error Handler'" || return $?
        _check_active
        if echo "$result" | grep -q "active=true"; then
            info "✓ Global Error Handler workflow is active"
            return 0
        fi
        err "Global Error Handler still not active"
        return 1
    fi
    prompt_dev "Global Error Handler workflow not found in n8n.

  To enable this test:
    1. Push it: git push (deploy.yml syncs JSON → n8n).
    2. n8n UI → Workflows → 'Global Error Handler' → toggle Active ON.
    3. Settings → n8n Settings → Error Workflow → select 'Global Error Handler'." || return $?
    _check_active
    if echo "$result" | grep -q "active=true"; then
        info "✓ Global Error Handler workflow is active"
        return 0
    fi
    err "Global Error Handler still not found or not active"
    return 1
}

test_error_handler_env_vars() {
    local env_vars
    env_vars=$(ssh_n8n "docker inspect n8n_app --format '{{range .Config.Env}}{{println .}}{{end}}'" 2>/dev/null) \
        || { err "docker inspect n8n_app failed"; return 1; }
    local ok=1 val
    if echo "$env_vars" | grep -qE '^PROJECT_NAME=.+'; then
        val=$(echo "$env_vars" | grep '^PROJECT_NAME=' | head -1 | cut -d= -f2-)
        info "✓ PROJECT_NAME=$val in n8n container env"
    else
        err "PROJECT_NAME not in n8n container env — run a full deploy"
        ok=0
    fi
    if echo "$env_vars" | grep -qE '^DEVELOPER_EMAIL=.+'; then
        val=$(echo "$env_vars" | grep '^DEVELOPER_EMAIL=' | head -1 | cut -d= -f2-)
        info "✓ DEVELOPER_EMAIL=$val in n8n container env"
    else
        err "DEVELOPER_EMAIL not in n8n container env — run a full deploy"
        ok=0
    fi
    if echo "$env_vars" | grep -qE '^N8N_METRICS=false$'; then
        info "✓ N8N_METRICS=false in n8n container env (metrics endpoint disabled)"
    else
        err "N8N_METRICS not set to false in n8n container env — check docker-compose.yml"
        ok=0
    fi
    [ "$ok" -eq 1 ] && return 0 || return 1
}

test_error_handler_fail_workflow_active() {
    local wf_count
    wf_count=$(ssh_n8n bash -s <<'REMOTE_EOF' 2>/dev/null
set -e
[ -f /root/n8n/.backup_creds ] || exit 0
set -a; source /root/n8n/.backup_creds; set +a
DBN=$(docker exec n8n_postgres printenv POSTGRES_DB 2>/dev/null) || exit 0
docker exec n8n_postgres psql -U "$DB_USER" -d "$DBN" -tAc \
    'SELECT COUNT(*) FROM workflow_entity' 2>/dev/null
REMOTE_EOF
    )
    wf_count=$(echo "$wf_count" | tr -d ' \n\r')
    if [ "${wf_count:-0}" = "0" ]; then
        err "n8n DB has 0 workflows — push workflows first: git push → deploy"
        return 1
    fi

    local result
    _check_fp_active() {
        result=$(ssh_n8n bash -s <<'REMOTE_EOF' 2>/dev/null
set -a; source /root/n8n/.backup_creds; set +a
curl -s "${N8N_LOCAL_API_URL}/workflows" \
  -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
  | jq -r '.data[] | select(.name == "Fail on Purpose") | "found active=\(.active)"' 2>/dev/null | head -1
REMOTE_EOF
        ) || true
    }
    _check_fp_active
    if echo "$result" | grep -q "active=true"; then
        info "✓ 'Fail on Purpose' workflow is active"
        return 0
    elif echo "$result" | grep -q "active=false"; then
        prompt_dev "'Fail on Purpose' workflow exists but is NOT active.

  n8n UI → Workflows → 'Fail on Purpose' → toggle Active ON." || return $?
    else
        prompt_dev "'Fail on Purpose' workflow not found in n8n.

  To enable this test:
    1. Push it: git push (deploy.yml syncs JSON → n8n).
    2. n8n UI → Workflows → 'Fail on Purpose' → toggle Active ON." || return $?
    fi
    _check_fp_active
    if echo "$result" | grep -q "active=true"; then
        info "✓ 'Fail on Purpose' workflow is active"
        return 0
    fi
    err "'Fail on Purpose' still not found or not active"
    return 1
}

# Clears the 15-min rate limiter (staticData + restart) before triggering the webhook.
test_error_handler_email() {
    local wf_count
    wf_count=$(ssh_n8n bash -s <<'REMOTE_EOF' 2>/dev/null
set -e
[ -f /root/n8n/.backup_creds ] || exit 0
set -a; source /root/n8n/.backup_creds; set +a
DBN=$(docker exec n8n_postgres printenv POSTGRES_DB 2>/dev/null) || exit 0
docker exec n8n_postgres psql -U "$DB_USER" -d "$DBN" -tAc \
    'SELECT COUNT(*) FROM workflow_entity' 2>/dev/null
REMOTE_EOF
    )
    wf_count=$(echo "$wf_count" | tr -d ' \n\r')
    if [ "${wf_count:-0}" = "0" ]; then
        err "n8n DB has 0 workflows — push workflows first: git push → deploy"
        return 1
    fi

    local key_set
    key_set=$(ssh_n8n "grep -c '^RESEND_API_KEY=.' /root/n8n/.backup_creds 2>/dev/null || true") || true
    if [ "${key_set:-0}" = "0" ]; then
        info "RESEND_API_KEY not configured in .backup_creds — skipping error handler email test"
        return 2
    fi

    local active
    _check_geh_active() {
        active=$(ssh_n8n bash -s <<'REMOTE_EOF' 2>/dev/null
set -a; source /root/n8n/.backup_creds; set +a
curl -s "${N8N_LOCAL_API_URL}/workflows" \
  -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
  | jq -r '.data[] | select(.name == "Global Error Handler") | .active' 2>/dev/null | head -1
REMOTE_EOF
        ) || true
    }
    _check_geh_active
    if [ "$active" != "true" ]; then
        prompt_dev "Global Error Handler is not active in n8n.

  n8n UI → Workflows → 'Global Error Handler' → toggle Active ON,
  then Settings → n8n Settings → Error Workflow → select it." || return $?
        _check_geh_active
        if [ "$active" != "true" ]; then
            err "Global Error Handler still not active"
            return 1
        fi
    fi

    local fp_info fp_wf_id fp_active
    _check_fp_info() {
        fp_info=$(ssh_n8n bash -s <<'REMOTE_EOF' 2>/dev/null
set -a; source /root/n8n/.backup_creds; set +a
curl -s "${N8N_LOCAL_API_URL}/workflows" \
  -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
  | jq -r '.data[] | select(.name == "Fail on Purpose") | "\(.id)|\(.active)"' 2>/dev/null | head -1
REMOTE_EOF
        ) || true
        fp_wf_id=$(echo "$fp_info" | cut -d'|' -f1)
        fp_active=$(echo "$fp_info" | cut -d'|' -f2)
    }
    _check_fp_info
    if [ -z "$fp_wf_id" ]; then
        prompt_dev "'Fail on Purpose' workflow not found in n8n.

  Push it (git push) and activate in n8n UI → Workflows → 'Fail on Purpose'." || return $?
        _check_fp_info
        if [ -z "$fp_wf_id" ]; then
            err "'Fail on Purpose' still not found"
            return 1
        fi
    fi
    if [ "$fp_active" != "true" ]; then
        prompt_dev "'Fail on Purpose' exists but is not active.

  n8n UI → Workflows → 'Fail on Purpose' → toggle Active ON." || return $?
        _check_fp_info
        if [ "$fp_active" != "true" ]; then
            err "'Fail on Purpose' still not active"
            return 1
        fi
    fi

    local webhook_base recipient client_name
    webhook_base=$(ssh_n8n "docker inspect n8n_app --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -E '^WEBHOOK_URL=' | head -1 | cut -d= -f2-")
    recipient=$(ssh_n8n "grep '^DEVELOPER_EMAIL=' /root/n8n/.backup_creds 2>/dev/null | cut -d= -f2-") || true
    client_name=$(ssh_n8n "grep '^PROJECT_NAME=' /root/n8n/.backup_creds 2>/dev/null | cut -d= -f2-") || true
    local fail_url="${webhook_base}/webhook/fail-on-purpose"

    local expected_to
    if echo "$recipient" | grep -q '@'; then
        expected_to="${recipient%%@*}+n8n-${client_name}@${recipient#*@}"
    else
        expected_to="(DEVELOPER_EMAIL missing from .backup_creds)"
    fi

    # Code node uses $getWorkflowStaticData('global') — n8n nests that under
    # staticData.global, so the path is staticData->'global'->>'lastErrorEmailSent',
    # NOT staticData->>'lastErrorEmailSent' directly.
    local last_sent_ms rate_note=""
    _last_error_email_sent() {
        ssh_n8n bash -s <<'REMOTE_EOF' 2>/dev/null
set -a; source /root/n8n/.backup_creds; set +a
DBNAME=$(docker exec n8n_postgres printenv POSTGRES_DB 2>/dev/null)
[ -z "$DBNAME" ] && DBNAME="$DB_USER"
docker exec n8n_postgres psql -U "$DB_USER" -d "$DBNAME" -At \
  -c "SELECT COALESCE(\"staticData\"->'global'->>'lastErrorEmailSent','0') FROM workflow_entity WHERE name = 'Global Error Handler';" \
  2>/dev/null | head -1
REMOTE_EOF
    }
    last_sent_ms=$(_last_error_email_sent) || true
    last_sent_ms="${last_sent_ms:-0}"

    local now_s elapsed_s remaining_s
    now_s=$(ssh_n8n "date +%s" 2>/dev/null || echo "0")
    if [ "$last_sent_ms" != "0" ] && [ "$now_s" != "0" ]; then
        elapsed_s=$(( now_s - last_sent_ms / 1000 ))
        remaining_s=$(( 900 - elapsed_s ))
        if [ "$remaining_s" -gt 0 ]; then
            rate_note="
  ${C_YELLOW}⚠ Rate limiter active (${elapsed_s}s since last email, resets in ${remaining_s}s).
    n8n_app will be restarted to clear it before triggering.${C_RESET}"
        fi
    fi

    printf '  Test webhook: '
    print_link "$fail_url"
    info "Sending a workflow error alert email to ${expected_to}: ❌ [n8n][${client_name}] Fail on Purpose failed."

    if [ -n "$rate_note" ]; then
        info "Clearing rate limiter (reset staticData in Postgres + restart n8n_app)..."
        ssh_n8n bash -s <<'REMOTE_EOF' || { err "Failed to clear rate limiter or restart n8n_app"; return 1; }
set -a; source /root/n8n/.backup_creds; set +a
DBNAME=$(docker exec n8n_postgres printenv POSTGRES_DB 2>/dev/null)
[ -z "$DBNAME" ] && DBNAME="$DB_USER"
docker exec n8n_postgres psql -U "$DB_USER" -d "$DBNAME" -c \
  "UPDATE workflow_entity SET \"staticData\" = NULL WHERE name = 'Global Error Handler';" 2>/dev/null
docker restart n8n_app >/dev/null 2>&1
REMOTE_EOF
        info "Waiting for n8n_app to restart (up to 60s)..."
        local healthy=0 i
        for i in $(seq 1 12); do
            local code
            code=$(ssh_n8n "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:5678/healthz 2>/dev/null || echo 000")
            [ "$code" = "200" ] && healthy=1 && break
            sleep 5
        done
        if [ "$healthy" -eq 1 ]; then
            info "✓ n8n_app restarted and healthy"
        else
            warn "n8n_app did not respond within 60s — proceeding anyway"
        fi
    fi

    info "Triggering POST:"
    print_link "$fail_url"
    local http_code curl_rc=0
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
        -X POST "$fail_url" \
        -H "Content-Type: application/json" \
        -d '{"test":true}' 2>/dev/null) || curl_rc=$?
    info "Webhook response: HTTP ${http_code:-000} (curl exit $curl_rc)"
    if [ "$curl_rc" -ne 0 ] || [[ "$http_code" != 2[0-9][0-9] ]]; then
        err "Error alert trigger failed — HTTP ${http_code:-000} (curl exit $curl_rc); check the tunnel, Cloudflare Access, and active webhook."
        return 1
    fi

    # shortcut: the asynchronous timestamp covers all alerts; correlate executions if errors overlap.
    info "Waiting for successful Resend delivery to be recorded (up to 75s)..."
    local sent_after delivered=0 attempt
    for attempt in $(seq 1 15); do
        sent_after=$(_last_error_email_sent) || sent_after=""
        if [[ "$sent_after" =~ ^[0-9]+$ ]] && [ "$sent_after" -gt "$last_sent_ms" ]; then
            delivered=1
            break
        fi
        sleep 5
    done
    if [ "$delivered" -ne 1 ]; then
        err "Global Error Handler did not record successful email delivery within 75s — inspect its 'Send Error Email' execution in n8n for the Resend error; check the sender, API key, and developer email."
        return 1
    fi

    confirm_dev "Webhook triggered. Email usually arrives within seconds.

  Check: ${C_BOLD}${expected_to}${C_RESET}
  Subject: ❌ [n8n][${client_name}] Fail on Purpose failed

  (First delivery may land in Spam — mark as 'Not Spam' to train Gmail.)

  Did you receive the error alert email?

  • [y]es — email arrived correctly (test PASSES)
  • [n]o  — email not received (test FAILS — check /root/n8n/poll-publish.log on VPS)
  • [s]kip — cannot check right now" || return $?
}

# ─── 10. n8n MCP endpoint (.mcp.json + JSON-RPC initialize probe) ───────────

test_n8n_mcp_endpoint() {
    local mcp_file="$ROOT_DIR/.mcp.json"
    if [ ! -f "$mcp_file" ]; then
        if confirm_dev "  .mcp.json is missing from the project root.

  This file lets Claude Code (and other coding agents) reach n8n's
  instance-level MCP server. It's created by 'npm run initialize' after
  enabling MCP at \${WEBHOOK_URL}/settings/mcp.

  Confirm: is MCP access intentionally NOT needed for this project?"; then
            info "MCP intentionally not configured — acknowledged by developer."
            return 0
        else
            local rc=$?
            [ "$rc" = "2" ] && return 2
            err "MCP expected but .mcp.json missing — re-run 'npm run initialize'."
            return 1
        fi
    fi

    local url auth cf_id cf_secret
    url=$(jq -r '.mcpServers."n8n-mcp".url // ""' "$mcp_file" 2>/dev/null)
    auth=$(jq -r '.mcpServers."n8n-mcp".headers.Authorization // ""' "$mcp_file" 2>/dev/null)
    cf_id=$(jq -r '.mcpServers."n8n-mcp".headers."CF-Access-Client-Id" // ""' "$mcp_file" 2>/dev/null)
    cf_secret=$(jq -r '.mcpServers."n8n-mcp".headers."CF-Access-Client-Secret" // ""' "$mcp_file" 2>/dev/null)

    if [ -z "$url" ] || [ -z "$auth" ] || [ -z "$cf_id" ] || [ -z "$cf_secret" ]; then
        err ".mcp.json missing required fields (url / Authorization / CF-Access-Client-Id / -Secret)."
        return 1
    fi

    local body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"n8n-core-setup-test","version":"1.0"}}}'
    local http
    http=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
        -X POST "$url" \
        -H "Authorization: $auth" \
        -H "CF-Access-Client-Id: $cf_id" \
        -H "CF-Access-Client-Secret: $cf_secret" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        --data "$body" 2>/dev/null || echo 000)

    case "$http" in
        2*) info "JSON-RPC initialize → HTTP $http (CF Access + n8n MCP both accepted)"; return 0 ;;
        401) err "HTTP 401 — n8n MCP rejected the Bearer token. Regenerate at \${WEBHOOK_URL}/settings/mcp and re-run 'npm run initialize'."; return 1 ;;
        403) err "HTTP 403 — Cloudflare Access blocked the request. CF service token may have been rotated; re-run 'npm run init-cloudflare' then 'npm run initialize'."; return 1 ;;
        000) err "No response — check Cloudflare Tunnel + DNS:"
             print_link "$url"; return 1 ;;
        *)   err "Unexpected HTTP $http — inspect manually:"
             print_link "$url"; return 1 ;;
    esac
}

cat <<EOF
${C_BOLD}═══════════════════════════════════════════════════════════════════════${C_RESET}
${C_BOLD}  n8n-core-setup environment test  —  project: ${PROJECT_NAME:-(unset)}${C_RESET}
${C_BOLD}═══════════════════════════════════════════════════════════════════════${C_RESET}
This script runs a comprehensive end-to-end test of the stack. It will NOT
abort on failure — every test is independent and the summary is printed at
the end.

Interactive tests (sections 6–11) require developer input. The script
will ${C_BOLD}beep${C_RESET} and explain what it expects. ${C_DIM}Type 'skip' at any prompt to skip.${C_RESET}
EOF

step "1/10  Local environment"
run_test "Local: .env.config present"                    test_env_config_present
run_test "Local: required keys in .env.config"           test_env_config_required_keys
run_test "Local: node_modules installed"                 test_node_modules
run_test "Local: required CLI tools (npm/git/ssh/rsync/curl)" test_required_cli_tools
run_test "Local: .env.sops.yaml decrypts with age key"        test_env_sops_decryptable
run_test "Local: N8N_VPS_HOST_FINGERPRINT matches live VPS (reads .env or .env.sops.yaml)" test_env_fingerprint

step "2/10  SSH connectivity"
run_test "SSH: reach n8n VPS" test_ssh_n8n

step "3/10  n8n VPS stack health"
run_test "n8n: docker containers (app/postgres/cloudflared)" test_n8n_containers
run_test "n8n: Postgres pg_isready"                                    test_n8n_postgres_ready
run_test "n8n: local API /healthz on :5678"                            test_n8n_local_api
run_test "n8n: public Cloudflare tunnel reachable (WEBHOOK_URL)"       test_n8n_public_url
run_test "n8n: cron jobs (nightly backup + per-minute publish poll)"   test_n8n_cron_jobs
run_test "n8n: /root/n8n/.backup_creds present (mode 600, GitHub keys)" test_n8n_backup_creds
run_test "n8n: poll-publish.log clean (no schema/commit failures)"     test_poll_publish_log_healthy
run_test "n8n: GitHub auto-commit prereqs (script, token, repo)"       test_github_commit_prereqs
run_test "n8n: scan-workflow-secrets.sh present and executable"        test_scan_workflow_secrets_present
run_test "n8n: health ping URL configured in .backup_creds (optional)" test_health_ping_configured
run_test "n8n: Health Ping workflow active in n8n (if configured)"     test_health_ping_workflow_active
run_test "n8n: healthchecks.io ping URL reachable from VPS (optional)" test_health_ping_reachable

step "4/10  End-to-end features (automated)"
run_test "Backup: local restic repository accessible"              test_backup_local_repo
run_test "Backup: Backblaze restic repository accessible (if configured)" test_backup_backblaze_repo
run_test "Backup: end-to-end (pg_dumpall → restic snapshot)"      test_backup_end_to_end
run_test "Workflows: 'npm run pull' fetches workflows from n8n API" test_npm_pull

step "5/10  Disk space monitoring"
run_test "Disk: hourly cron installed on VPS"                          test_disk_check_cron
run_test "Disk: disk-space-check.sh present and executable"            test_disk_check_script
run_test "Disk: Resend HTTP API config (RESEND_API_KEY/_FROM_EMAIL, send-email.sh)" test_disk_check_resend_config
run_test "Disk: script dry-run exits cleanly (shows current free %)"   test_disk_check_dry_run
run_test "Disk: email alert delivery — force threshold=101%, confirm receipt" test_disk_check_email

step "6/10  Error monitoring"
run_test "Error handler: 'Global Error Handler' workflow active in n8n"      test_error_handler_workflow_active
run_test "Error handler: PROJECT_NAME + DEVELOPER_EMAIL in n8n container env" test_error_handler_env_vars
run_test "Error handler: 'Fail on Purpose' simulator workflow active"        test_error_handler_fail_workflow_active
run_test "Error handler: email delivery — trigger failure, confirm receipt"  test_error_handler_email

step "7/10  Interactive: GitHub auto-commit on publish"
run_test "Publish chain: workflow Publish → GitHub commit (≤90s)" test_publish_chain_github

step "8/10  Interactive: local edit → git push → deploy → n8n"
run_test "Deploy chain: local JSON edit → git push → deploy.yml → n8n updated" test_deploy_chain

step "9/10  Interactive: backup / restore"
run_test "Restore round-trip: LOCAL restic (modify → restore latest → verify state)"          test_restore_local
run_test "Restore round-trip: BACKBLAZE B2 (modify → restore latest → verify, if configured)" test_restore_backblaze

step "10/10 Interactive: local MCP config"
run_test "MCP: .mcp.json endpoint reachable (or intentionally absent)" test_n8n_mcp_endpoint


echo
echo "${C_BOLD}═══════════════════════════════════════════════════════════════════════${C_RESET}"
echo "${C_BOLD}  Test results${C_RESET}"
echo "${C_BOLD}═══════════════════════════════════════════════════════════════════════${C_RESET}"
for line in "${RESULTS[@]}"; do
    echo "  $line"
done
echo
echo "  ${C_GREEN}Passed: $PASS${C_RESET}    ${C_RED}Failed: $FAIL${C_RESET}    ${C_YELLOW}Skipped: $SKIP${C_RESET}"
echo

_beep
if [ "$FAIL" -eq 0 ]; then
    echo "${C_GREEN}${C_BOLD}🎉 All checked features are working.${C_RESET}"
    exit 0
fi
echo "${C_YELLOW}${C_BOLD}⚠ $FAIL test(s) failed — see results above.${C_RESET}"
exit 1
