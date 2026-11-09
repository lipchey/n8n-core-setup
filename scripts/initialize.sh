#!/bin/bash
# shellcheck disable=SC1090
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/check-prerequisites.sh" || exit 1

set -eo pipefail
# Close the create→chmod race for files written without explicit modes.
umask 077

# Byte-oriented tools can otherwise abort on non-UTF-8 bytes from SSH or APIs.
export LC_ALL=C
export LANG=C

ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_CONFIG="$ROOT_DIR/.env.config"
ENV_FILE="$ROOT_DIR/.env"
ENV_LOCAL="$ROOT_DIR/.env.local"
ENV_DEVELOPER="$ROOT_DIR/.env.developer"

# Helpers

# shellcheck source=lib/prompts.sh
source "$SCRIPT_DIR/lib/prompts.sh"
_initialize_hard_reset=false
[ "${1:-}" != "--hard-reset" ] || _initialize_hard_reset=true
readonly _initialize_hard_reset
HARD_RESET="$_initialize_hard_reset"
initialize_repo_guard "$ROOT_DIR" "$ENV_CONFIG" "$ENV_DEVELOPER" "$ENV_FILE" "$ENV_LOCAL" || exit 1

write_env_config() {
  local _backup=""
  if [ -f "$ENV_CONFIG" ]; then
    _backup=$(mktemp); cp "$ENV_CONFIG" "$_backup"
  fi
  local backblaze="" domain=""
  if [ -n "${BACKBLAZE_BUCKET:-}" ]; then
    backblaze=$'\n\n'"BACKBLAZE_BUCKET=$BACKBLAZE_BUCKET"
  fi
  if [ -n "${N8N_COMMON_DOMAIN:-}" ]; then
    domain="N8N_COMMON_DOMAIN=$N8N_COMMON_DOMAIN"
  elif [ -n "${N8N_PROJECTS_DOMAIN:-}" ]; then
    domain="N8N_PROJECTS_DOMAIN=$N8N_PROJECTS_DOMAIN"
  fi

  cat > "$ENV_CONFIG" <<EOF
# Non-sensitive operational config — committed.
# Per-project identity consumed by every npm script and by deploy.yml.

DEVELOPER_EMAIL=$DEVELOPER_EMAIL

PROJECT_NAME=$PROJECT_NAME
# Workflow schedules and server jobs use this zone; storage stays UTC.
DISPLAY_TZ=$DISPLAY_TZ

# Docker memory limits — accepts 512m, 1g, 2g.
POSTGRES_MEM_LIMIT=$POSTGRES_MEM_LIMIT
N8N_MEM_LIMIT=$N8N_MEM_LIMIT
CLOUDFLARED_MEM_LIMIT=$CLOUDFLARED_MEM_LIMIT

# Execution history: 1440h = 60 days; oldest pruned first.
EXECUTIONS_MAX_AGE=${EXECUTIONS_MAX_AGE:-1440}
EXECUTIONS_MAX_COUNT=${EXECUTIONS_MAX_COUNT:-35000}${backblaze}

# Disk-usage % thresholds.
ALERT_DISK_THRESHOLD_MEDIUM=${ALERT_DISK_THRESHOLD_MEDIUM:-85}
ALERT_DISK_THRESHOLD_HIGH=${ALERT_DISK_THRESHOLD_HIGH:-95}

GITHUB_REPO=$GITHUB_REPO
GITHUB_BRANCH=$GITHUB_BRANCH

$domain
EOF
  if [ -n "$_backup" ]; then
    _preserve_unknown_env_keys "$ENV_CONFIG" "$_backup"
    rm -f "$_backup"
  fi
}

write_env_file() {
  local _backup_env=""
  if [ -f "$ENV_FILE" ]; then
    _backup_env=$(mktemp); cp "$ENV_FILE" "$_backup_env"
  fi
  # Provider and tunnel setup may have updated .env since it was loaded.
  local tunnel_tok fingerprint
  tunnel_tok=$(file_var "$ENV_FILE" "TUNNEL_TOKEN")
  fingerprint=$(file_var "$ENV_FILE" "N8N_VPS_HOST_FINGERPRINT")
  fingerprint="${fingerprint:-SHA256:paste_fingerprint_here}"

  local tunnel_block=""
  if [ -n "$tunnel_tok" ]; then
    tunnel_block="

# Written by init-cloudflare.sh — do not edit manually.
TUNNEL_TOKEN=$tunnel_tok"
  fi

  cat > "$ENV_FILE" <<EOF
# SENSITIVE — encrypted to .env.sops.yaml for git. CI decrypts via SOPS_AGE_KEY.
# Provider and Cloudflare tokens are encrypted too; CI loads only deployment-required keys.

N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY

N8N_API_KEY=${N8N_API_KEY:-}
# WEBHOOK_URL is derived from the domain in deploy.yml — do not set here.
N8N_LOCAL_API_URL=${N8N_LOCAL_API_URL:-http://localhost:5678/api/v1}

DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
DB_NAME=$DB_NAME

BACKUP_PASSWORD=$BACKUP_PASSWORD

BACKBLAZE_KEY_ID=${BACKBLAZE_KEY_ID:-}
BACKBLAZE_APPLICATION_KEY=${BACKBLAZE_APPLICATION_KEY:-}

# Resend — disk-space + secret alerts.
RESEND_API_KEY=${RESEND_API_KEY:-}
RESEND_FROM_EMAIL=${RESEND_FROM_EMAIL:-}

# Dead-man's switch — Health Ping workflow pings this URL every 5min.
HEALTH_PING_URL=${HEALTH_PING_URL:-}


# Fine-grained PAT needs Contents: Read+write and Actions: Read.
GITHUB_PERSONAL_ACCESS_TOKEN=$GITHUB_PERSONAL_ACCESS_TOKEN

N8N_VPS_USER=$N8N_VPS_USER
N8N_VPS_IP=$N8N_VPS_IP

N8N_VPS_HOST_FINGERPRINT=$fingerprint

# Token consumed only by init-cloudflare.sh; required scopes are in the onboarding checklist.
CLOUDFLARE_API_TOKEN=$CLOUDFLARE_API_TOKEN${tunnel_block}
EOF

  if [ -n "$_backup_env" ]; then
    _preserve_unknown_env_keys "$ENV_FILE" "$_backup_env"
    rm -f "$_backup_env"
  fi
  chmod 600 "$ENV_FILE"
}

# Pre-onboarding checklist
cat >/dev/tty <<'EOF'

╔══════════════════════════════════════════════════════════════════╗
║      n8n VPS Onboarding — What you need before starting         ║
╚══════════════════════════════════════════════════════════════════╝

  ✅ Things to have BEFORE proceeding:

  1. VPS provider account + API key (one of):
EOF
printf '       DigitalOcean — ' >/dev/tty
print_link "https://cloud.digitalocean.com/account/api/tokens" >/dev/tty
printf '       Hetzner Cloud — ' >/dev/tty
print_link "https://console.hetzner.com" >/dev/tty
cat >/dev/tty <<'EOF'
         → project → Security → API Tokens
  2. Domain on Cloudflare DNS (existing or new)
EOF
printf '  3. Cloudflare API token — ' >/dev/tty
print_link "https://dash.cloudflare.com/profile/api-tokens" >/dev/tty
cat >/dev/tty <<'EOF'
       Account → Cloudflare Tunnel           → Edit
       Account → Access: Apps and Policies   → Edit
       Account → Access: Service Tokens      → Edit
       Account → Account Settings            → Read
       Zone    → DNS                         → Edit
       Zone    → Firewall Services           → Edit
       Zone    → WAF                         → Edit
       Zone    → Transform Rules             → Edit
       User    → User Details                → Read
  4. GitHub — gh login with repo and workflow scopes (checked before this checklist)
       Run gh auth login and choose GitHub.com; for an existing login:
       gh auth refresh -s repo,workflow
       Use your private repo as the push remote
       With no remotes, submitting the repository name creates a private repository
EOF
printf '  5. GitHub fine-grained PAT — ' >/dev/tty
print_link "https://github.com/settings/personal-access-tokens" >/dev/tty
cat >/dev/tty <<'EOF'
       If the wizard creates the repository, create its PAT once it exists,
       at the destination token prompt, before VPS creation.
       Permissions on this repository:
         Contents → Read and write   (auto-commit of workflow JSON from VPS)
         Actions  → Read             (initialize.sh polls the deploy run via API)
  6. A readable SSH private key without a passphrase for VPS access and Actions
EOF
printf '  Press Enter to begin setup, or Ctrl+C to abort: ' >/dev/tty
read -r _ </dev/tty

_is_rerun=false
{ [ -f "$ENV_CONFIG" ] || [ -f "$ENV_FILE" ] || [ -f "$ROOT_DIR/.env.sops.yaml" ]; } && _is_rerun=true

echo ""
section_header "Docker image pins"
cat <<'EOF'
  ℹ️  All Docker images in n8n/docker-compose.yml
     are pinned by digest. 'npm run refresh-images' queries Docker Hub
     and bumps each pin to the latest
     tag in the same major series.

EOF
_image_choice=$(ask_yn "  → Run 'npm run refresh-images' now to check for updates? [Y/n]: " "y")
if [ "$_image_choice" = "y" ]; then
    echo ""
    _image_args=()
    [ "$_is_rerun" = true ] || _image_args=(--first-run)
    bash "$SCRIPT_DIR/refresh-image-pins.sh" "${_image_args[@]}" || echo "  ⚠️  Some image lookups failed (see above); the pins for those images are unchanged."
    echo ""
    _image_proceed=$(ask_yn "  → Continue with initialization? [Y/n]: " "y")
    if [ "$_image_proceed" != "y" ]; then
        echo "  Aborted — re-run npm run initialize when ready."
        exit 0
    fi
else
    echo "  ℹ️  Skipped — assuming pins are current."
fi

_failures=()
_print_failures() {
  echo "❌ Finished with failures:"
  printf '   • %s\n' "${_failures[@]}"
}

_env_from_sops=false
_env_decrypted_sum=""
_cleanup_on_exit() {
  [ -n "${TMPENV:-}" ] && rm -f "$TMPENV"
  rm -f "${ENV_FILE}.tmp"
  # A first-run .env is the only copy of its generated secrets, so only a session-decrypted one is removed.
  [ "$_env_from_sops" = "true" ] && [ -f "$ENV_FILE" ] || return 0
  # Values set this session (pasted API key, tunnel token) exist only in .env: encrypt before removing.
  if [ -n "$_env_decrypted_sum" ] && [ "$(cksum < "$ENV_FILE")" != "$_env_decrypted_sum" ]; then
    if sops --config "${ROOT_DIR}/.sops.yaml" --input-type dotenv --output-type dotenv -e "$ENV_FILE" > "${ROOT_DIR}/.env.sops.yaml.tmp" \
        && mv "${ROOT_DIR}/.env.sops.yaml.tmp" "${ROOT_DIR}/.env.sops.yaml"; then
      echo "  ℹ️  This session's .env changes were re-encrypted to .env.sops.yaml (not committed)." >&2
    else
      rm -f "${ROOT_DIR}/.env.sops.yaml.tmp"
      echo "  ⚠️  Could not re-encrypt .env, so it stays in plaintext to keep this session's changes. Run: npm run encrypt-env" >&2
      return 0
    fi
  fi
  rm -f "$ENV_FILE"
}
trap _cleanup_on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# On re-run after first success .env is absent (encrypted to .env.sops.yaml). Restore it.
if [ ! -f "$ENV_FILE" ] && [ -f "${ROOT_DIR}/.env.sops.yaml" ]; then
    echo "  ℹ️  Re-run: .env not found — decrypting .env.sops.yaml for this session..." >/dev/tty
    _env_from_sops=true
    bash "$ROOT_DIR/scripts/sops-env.sh" --decrypt
    _env_decrypted_sum=$(cksum < "$ENV_FILE")
fi

if [ -f "$ENV_LOCAL" ] && [ -f "$ENV_FILE" ]; then
  while IFS= read -r _k; do
    _vl=$(file_var "$ENV_LOCAL" "$_k"); _ve=$(file_var "$ENV_FILE" "$_k")
    if [ -n "$_vl" ] && [ -n "$_ve" ] && [ "$_vl" != "$_ve" ]; then
      echo "  ⚠️  $_k differs between .env.local and .env — .env.local wins on this machine." >/dev/tty
    fi
  done < <(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ {print $1}' "$ENV_LOCAL")
fi

env_keys_snapshot "$ENV_CONFIG" "$ENV_FILE" "$ENV_LOCAL"
env_files_check_alphabet "$ENV_CONFIG" "$ENV_FILE" "$ENV_LOCAL"

set -a
[ -f "$ENV_CONFIG" ]    && load_env_file "$ENV_CONFIG"
if [ -f "$ENV_DEVELOPER" ]; then
  chmod 600 "$ENV_DEVELOPER"
  load_env_file "$ENV_DEVELOPER"
fi
[ -f "$ENV_FILE" ]      && load_env_file "$ENV_FILE"
[ -f "$ENV_LOCAL" ]     && load_env_file "$ENV_LOCAL"
set +a
HARD_RESET="$_initialize_hard_reset"

# deploy.yml only deploys main, and a commit made on any other branch would never reach it.
if [ -n "${GITHUB_BRANCH:-}" ] && [ "$GITHUB_BRANCH" != "main" ]; then
  echo "❌ GITHUB_BRANCH=${GITHUB_BRANCH} is not supported: deploys run from main only. Set GITHUB_BRANCH=main in .env.config, then re-run." >&2
  exit 1
fi
GITHUB_BRANCH=main

# Timezone and project name must equal deploy.yml's validators, or CI rejects what the wizard accepted.
_project_name_re='^[a-z0-9][a-z0-9-]{0,30}$'
_tz_re='^[A-Za-z_]+(/[A-Za-z0-9_+-]+){0,2}$'
_email_re='^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
_host_re='^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$'
_domain_re='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'
_mem_re='^[1-9][0-9]*(\.[0-9]+)?[mMgG]$'
_positive_int_re='^[1-9][0-9]*$'

# Phase 1: .env.config (non-sensitive, committed)
echo ""
section_header "Phase 1/2 — Non-sensitive config  (.env.config, committed)"
echo ""

echo "  💡 Tip: avoid 'n8n' in the project name — it becomes the public subdomain"
echo "     in Option A below, and the 'n8n' keyword trips Chrome Safe Browsing"
echo "     phishing heuristics on fresh subdomains. Use e.g. 'acme-corp', not 'acme-n8n'."
PROJECT_NAME=$(prompt_value \
  "Project/project name (e.g. acme-corp; used in hostnames & paths)" \
  "${PROJECT_NAME:-$(basename "$ROOT_DIR")}" \
  "false" "false" "$_project_name_re" "PROJECT_NAME")
upsert_env_config "PROJECT_NAME" "$PROJECT_NAME"

echo ""
section_header "GitHub"
echo "  ℹ️  The VPS commits workflow JSON to this repo on every publish event."
echo "     Format: owner/repo-name  (e.g. acme/n8n-workflows)"
echo ""

ensure_local_repo_ready "$ROOT_DIR" || exit 1
if [ -z "$GITHUB_PUSH_REMOTE" ]; then
  create_private_github_repo || exit 1
else
  GITHUB_REPO=$(prompt_value "GitHub repository (owner/repo)" "$GITHUB_PUSH_REPO" \
    "false" "false" "$_GITHUB_REPO_PATTERN" "GITHUB_REPO")
  initialize_repo_guard "$ROOT_DIR" || exit 1
  require_private_github_repo "$GITHUB_PUSH_REPO" || exit 1
fi
if ! git -C "$ROOT_DIR" push --dry-run --no-verify -- "$GITHUB_PUSH_REMOTE" HEAD:refs/heads/main >/dev/null 2>&1; then
  echo '❌ Cannot push to the GitHub remote. Check credentials (SSH keys or the credential helper) and whether remote main has diverged; reconcile it, then re-run.' >&2
  exit 1
fi
upsert_env_config "GITHUB_REPO" "$GITHUB_REPO"
upsert_env_config "GITHUB_BRANCH" "$GITHUB_BRANCH"

echo ""
section_header "GitHub Personal Access Token"
printf '  ℹ️  Fine-grained PAT — '
print_link "https://github.com/settings/personal-access-tokens"
echo "     Permissions on repository ${GITHUB_REPO}:"
echo "       Contents → Read and write   (auto-commit of workflow JSON from VPS)"
echo "       Actions  → Read             (initialize.sh polls the deploy run via API)"
echo "     Contents write is confirmed by the first workflow publish from the VPS."
echo ""
echo ""

_validate_github_token() {
  local user repo
  local auth
  auth=$(printf 'header = "Authorization: Bearer %s"\n' "$1")
  local headers=(-H "User-Agent: n8n-core-setup-initialize/1.0")
  if ! user=$(printf '%s\n' "$auth" | curl -K - -sf --max-time 10 "${headers[@]}" "https://api.github.com/user" 2>/dev/null); then
    printf '❌ GitHub token authentication failed; check the token.\n' >&2
    return 1
  fi
  if ! repo=$(printf '%s\n' "$auth" | curl -K - -sf --max-time 10 "${headers[@]}" "https://api.github.com/repos/${GITHUB_REPO}" 2>/dev/null) \
     || ! printf '%s' "$repo" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf '❌ GitHub token needs access to %s.\n' "$GITHUB_REPO" >&2
    return 1
  fi
  if ! printf '%s\n' "$auth" | curl -K - -sf --max-time 10 "${headers[@]}" "https://api.github.com/repos/${GITHUB_REPO}/actions/runs?per_page=1" >/dev/null 2>&1; then
    printf '❌ GitHub token needs Actions: Read on %s.\n' "$GITHUB_REPO" >&2
    return 1
  fi
  printf '%s' "$user"
}

_gh_token_valid=false
_gh_result=""
if [ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then
  printf '  🔑 Validating existing GitHub token...\n'
  if _gh_result=$(_validate_github_token "$GITHUB_PERSONAL_ACCESS_TOKEN"); then
    _gh_login=$(printf '%s' "$_gh_result" | jq -r '.login // empty' || true)
    printf '  ✅ Token valid (github.com/%s) — press Enter to keep.\n' "$_gh_login"
    _gh_token_valid=true
  else
    printf '  ⚠️  Existing token is invalid — enter a new one.\n'
    GITHUB_PERSONAL_ACCESS_TOKEN=""
  fi
fi

while true; do
  if [ "$_gh_token_valid" = "true" ]; then
    printf '  → GitHub Personal Access Token \033[90m[***]\033[0m: ' >/dev/tty
  else
    printf '  → GitHub Personal Access Token: ' >/dev/tty
  fi
  read_secret _input_token || exit 1
  if [ -z "$_input_token" ] && [ "$_gh_token_valid" = "true" ]; then
    break
  elif [ -z "$_input_token" ]; then
    printf '  ⚠️  Token cannot be empty.\n' >/dev/tty; continue
  elif ! env_value_ok "$_input_token"; then
    env_alphabet_hint >/dev/tty; continue
  fi
  printf '  🔑 Validating...\n'
  if _gh_result=$(_validate_github_token "$_input_token"); then
    GITHUB_PERSONAL_ACCESS_TOKEN="$_input_token"
    _gh_login=$(printf '%s' "$_gh_result" | jq -r '.login // empty' || true)
    printf '  ✅ Authenticated as: github.com/%s\n' "$_gh_login"
    break
  else
    printf '  ❌ Invalid token — check permissions and try again.\n' >/dev/tty
  fi
done
upsert_env "GITHUB_PERSONAL_ACCESS_TOKEN" "$GITHUB_PERSONAL_ACCESS_TOKEN"

DISPLAY_TZ=$(prompt_timezone "$_tz_re") || exit 1
upsert_env_config "DISPLAY_TZ" "$DISPLAY_TZ"

DEVELOPER_EMAIL=$(prompt_value \
  "Developer email (for notifications & Cloudflare)" \
  "${DEVELOPER_EMAIL:-}" "false" "false" "$_email_re" "DEVELOPER_EMAIL")
upsert_env_config "DEVELOPER_EMAIL" "$DEVELOPER_EMAIL"

echo ""
section_header "SSH"
echo "  ℹ️  Your local SSH private key — used for connecting to VPS hosts."
echo "     CI uses the SSH_PRIVATE_KEY GitHub secret (key contents) instead."

SSH_PRIVATE_KEY=$(prompt_value \
  "Local SSH private key path" \
  "${SSH_PRIVATE_KEY:-$HOME/.ssh/id_ed25519}" "false" "false" "" "SSH_PRIVATE_KEY")
validate_ssh_private_key "$SSH_PRIVATE_KEY" || exit 1
upsert_env_local "SSH_PRIVATE_KEY" "$SSH_PRIVATE_KEY"

if [ -f "$ROOT_DIR/n8n/custom-nodes/package.json" ]; then
  echo "▶  Building custom-nodes locally (matches deploy.yml, so dev dependencies are not uploaded) ..."
  # --ignore-scripts: skip transitive native builds (isolated-vm) — unused by tsc, pruned anyway, break on Node 26.
  ( cd "$ROOT_DIR/n8n/custom-nodes" && umask 022 && \
      if [ -f package-lock.json ]; then npm ci --no-audit --no-fund --ignore-scripts; else npm install --no-audit --no-fund --ignore-scripts; fi && \
      npm run build && \
      npm prune --omit=dev ) || {
    echo "❌ custom-nodes build failed — aborting." >&2; exit 1; }
  echo "✅ custom-nodes built."
fi

# One run only: a re-run after a lost response could create a second billed server.
_run_provider() {
  local _label="$1" _script="$2" _rc=0
  bash "$_script" || _rc=$?
  case "$_rc" in
    0) ;;
    10)
      echo "  ℹ️  ${_label}: no server created. Re-run initialization when ready to provision."
      exit 10
      ;;
    11)
      echo "❌ ${_label}: outcome unknown — a server may exist and be billing. Not retrying; follow the steps above." >&2
      exit 11
      ;;
    *)
      echo "❌ ${_label} provisioning failed (exit ${_rc}). Not retrying. Check the provider dashboard, then re-run: a saved server is resumed, not recreated." >&2
      exit "$_rc"
      ;;
  esac
}

echo ""
section_header "VPS creation"
if [ -z "${N8N_VPS_IP:-}" ]; then
  # A saved server ID goes straight to its own provider, so a menu pick cannot create a second one.
  if [ -n "${DIGITALOCEAN_DROPLET_ID:-}" ]; then
    _provider_choice=1
  elif [ -n "${HETZNER_SERVER_ID:-}" ]; then
    _provider_choice=2
  else
    echo "  → Select VPS provider:"
    echo "     1)  DigitalOcean"
    echo "     2)  Hetzner"
    printf '  [1/2, default 2]: ' >/dev/tty
    read -r _provider_choice </dev/tty
  fi
  case "${_provider_choice:-2}" in
    1) _run_provider "DigitalOcean" "$SCRIPT_DIR/init-digitalocean.sh" ;;
    2) _run_provider "Hetzner"      "$SCRIPT_DIR/init-hetzner.sh" ;;
    *) echo "❌ Choose DigitalOcean (1) or Hetzner (2), then re-run initialization." >&2; exit 1 ;;
  esac
  set -a
  load_env_file "$ENV_CONFIG"
  [ -f "$ENV_FILE"  ] && load_env_file "$ENV_FILE"
  [ -f "$ENV_LOCAL" ] && load_env_file "$ENV_LOCAL"
  set +a
  HARD_RESET="$_initialize_hard_reset"
  echo "✅ VPS created — memory limits in .env.config, VPS IP in .env.local."
else
  echo "  ℹ️  N8N_VPS_IP already set (${N8N_VPS_IP}) — skipping creation."
fi

echo ""
section_header "Docker memory limits (recommended per VPS tier)"
printf '  %-8s  %-12s  %-10s  %-13s\n' "VPS RAM" "postgres" "n8n" "cloudflared"
echo "  ───────────────────────────────────────────────────────────"
printf '  %-8s  %-12s  %-10s  %-13s\n' "1 GB"  "256m"  "512m"  "64m"
printf '  %-8s  %-12s  %-10s  %-13s\n' "2 GB"  "512m"  "1g"    "128m"
printf '  %-8s  %-12s  %-10s  %-13s\n' "4 GB"  "1g"    "2g"    "128m"
printf '  %-8s  %-12s  %-10s  %-13s\n' "8 GB+" "2g"    "4g"    "128m"

# Skip the tier picker if provider script already wrote limits.
if [ -z "${POSTGRES_MEM_LIMIT:-}" ] && [ -z "${N8N_MEM_LIMIT:-}" ]; then
    echo ""
    printf '  Quick-pick VPS tier [1/2/4/8, Enter to set manually]: ' >/dev/tty
    read -r _tier_pick </dev/tty
    case "${_tier_pick:-}" in
        1) POSTGRES_MEM_LIMIT=256m; N8N_MEM_LIMIT=512m; CLOUDFLARED_MEM_LIMIT=64m ;;
        2) POSTGRES_MEM_LIMIT=512m; N8N_MEM_LIMIT=1g;   CLOUDFLARED_MEM_LIMIT=128m ;;
        4) POSTGRES_MEM_LIMIT=1g;   N8N_MEM_LIMIT=2g;   CLOUDFLARED_MEM_LIMIT=128m ;;
        8) POSTGRES_MEM_LIMIT=2g;   N8N_MEM_LIMIT=4g;   CLOUDFLARED_MEM_LIMIT=128m ;;
    esac
fi

echo ""
echo "  ℹ️  Accepts Docker memory strings: 512m, 1g, 2g, etc. Fine-tune below."

_beep
POSTGRES_MEM_LIMIT=$(prompt_value \
  "PostgreSQL memory limit" \
  "${POSTGRES_MEM_LIMIT:-512m}" "false" "false" "$_mem_re" "POSTGRES_MEM_LIMIT")
upsert_env_config "POSTGRES_MEM_LIMIT" "$POSTGRES_MEM_LIMIT"

N8N_MEM_LIMIT=$(prompt_value \
  "n8n memory limit" \
  "${N8N_MEM_LIMIT:-1g}" "false" "false" "$_mem_re" "N8N_MEM_LIMIT")
upsert_env_config "N8N_MEM_LIMIT" "$N8N_MEM_LIMIT"

CLOUDFLARED_MEM_LIMIT=$(prompt_value \
  "cloudflared memory limit" \
  "${CLOUDFLARED_MEM_LIMIT:-128m}" "false" "false" "$_mem_re" "CLOUDFLARED_MEM_LIMIT")
upsert_env_config "CLOUDFLARED_MEM_LIMIT" "$CLOUDFLARED_MEM_LIMIT"


echo ""
section_header "n8n execution history retention"
echo "  ℹ️  n8n stores execution logs in Postgres for debugging and audit."
echo "     Longer retention means more disk and DB space consumed."
echo "     Projects with access to the n8n UI can browse these logs."

EXECUTIONS_MAX_AGE=$(prompt_value \
  "Max age of execution logs (hours, 1440 = 60 days)" \
  "${EXECUTIONS_MAX_AGE:-1440}" "false" "false" "$_positive_int_re" "EXECUTIONS_MAX_AGE")
upsert_env_config "EXECUTIONS_MAX_AGE" "$EXECUTIONS_MAX_AGE"

EXECUTIONS_MAX_COUNT=$(prompt_value \
  "Max number of execution records to keep" \
  "${EXECUTIONS_MAX_COUNT:-35000}" "false" "false" "$_positive_int_re" "EXECUTIONS_MAX_COUNT")
upsert_env_config "EXECUTIONS_MAX_COUNT" "$EXECUTIONS_MAX_COUNT"

echo ""
section_header "n8n VPS"

# Step 1 and deploy.yml use apt and /root/n8n, so a non-root user only fails later, after a restart.
N8N_VPS_USER=$(prompt_value \
  "n8n VPS SSH user (must be root)" \
  "${N8N_VPS_USER:-root}" "false" "false" '^root$' "N8N_VPS_USER")
upsert_env_local "N8N_VPS_USER" "$N8N_VPS_USER"

N8N_VPS_IP=$(prompt_value \
  "n8n VPS IP address or hostname" \
  "${N8N_VPS_IP:-}" "false" "false" "$_host_re")
upsert_env_local "N8N_VPS_IP" "$N8N_VPS_IP"


echo ""
section_header "Public n8n hostname"
echo "  Option A) Common domain — hostname = PROJECT_NAME.your-domain.com"
echo "            Use when YOU manage n8n for multiple projects on your domain."
echo "  Option B) Project domain — hostname used as-is (e.g. project.com or ops.project.com)"
echo "            Use when the PROJECT owns their domain. No subdomain prefix added."
echo "            ⚠ Avoid 'n8n' in the subdomain — Chrome Safe Browsing flags it. Prefer 'ops', 'studio', 'flow'."
echo ""

if [ -n "${N8N_PROJECTS_DOMAIN:-}" ]; then
  _domain_label="current: B — ${N8N_PROJECTS_DOMAIN}"
  _default_domain_choice="B"
elif [ -n "${N8N_COMMON_DOMAIN:-}" ]; then
  _domain_label="current: A — ${N8N_COMMON_DOMAIN}"
  _default_domain_choice="A"
else
  _domain_label="not set"
  _default_domain_choice="A"
fi

if [ "$_is_rerun" = "true" ] && [ "$_default_domain_choice" != "" ] && { [ -n "${N8N_PROJECTS_DOMAIN:-}" ] || [ -n "${N8N_COMMON_DOMAIN:-}" ]; }; then
  echo "  ✓ Domain mode: ${_domain_label} [existing]"
  _domain_choice="$_default_domain_choice"
else
  printf '  → Domain mode [A/B] \033[90m(%s)\033[0m: ' "$_domain_label" >/dev/tty
  read -r _domain_choice </dev/tty
  [ -z "$_domain_choice" ] && _domain_choice="$_default_domain_choice"
fi

if [ "$_domain_choice" = "b" ] || [ "$_domain_choice" = "B" ]; then
  N8N_PROJECTS_DOMAIN=$(prompt_value \
    "Project domain, used as-is (e.g. project.com or ops.project.com — avoid 'n8n' in subdomain)" \
    "${N8N_PROJECTS_DOMAIN:-}" "false" "false" "$_domain_re")
  N8N_COMMON_DOMAIN=""
  upsert_env_config "N8N_PROJECTS_DOMAIN" "$N8N_PROJECTS_DOMAIN"
  upsert_env_config "N8N_COMMON_DOMAIN"  ""
else
  N8N_COMMON_DOMAIN=$(prompt_value \
    "Your domain (e.g. your-agency.com)" \
    "${N8N_COMMON_DOMAIN:-}" "false" "false" "$_domain_re")
  N8N_PROJECTS_DOMAIN=""
  upsert_env_config "N8N_COMMON_DOMAIN"  "$N8N_COMMON_DOMAIN"
  upsert_env_config "N8N_PROJECTS_DOMAIN" ""
fi

write_env_config
echo ""
echo "✅ .env.config written."


# Phase 2: .env (sensitive secrets)
echo ""
section_header "Phase 2/2 — Sensitive secrets  (.env, never committed)"
echo ""

if [ "$_is_rerun" = "true" ]; then
  echo "  ✅ Existing .env or .env.config found — saved values accepted automatically."
  echo "     To change a value: edit .env or .env.config directly, then re-run."
  echo ""
fi


echo ""
section_header "n8n"

# Never regenerate — changing N8N_ENCRYPTION_KEY invalidates all credentials.
if [ -n "${N8N_ENCRYPTION_KEY:-}" ]; then
  echo "  ℹ️  N8N_ENCRYPTION_KEY already set — keeping existing value (changing it breaks n8n credentials)."
else
  N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
  echo "  ✅ N8N_ENCRYPTION_KEY generated and saved to .env."
fi
upsert_env "N8N_ENCRYPTION_KEY" "$N8N_ENCRYPTION_KEY"

N8N_LOCAL_API_URL="${N8N_LOCAL_API_URL:-http://localhost:5678/api/v1}"
upsert_env "N8N_LOCAL_API_URL" "$N8N_LOCAL_API_URL"

DB_USER="${DB_USER:-n8n_db_user}"
DB_NAME="${DB_NAME:-n8n_database}"
if [ -z "${DB_PASSWORD:-}" ]; then
  DB_PASSWORD=$(openssl rand -hex 16)
fi
upsert_env "DB_USER" "$DB_USER"
upsert_env "DB_PASSWORD" "$DB_PASSWORD"
upsert_env "DB_NAME" "$DB_NAME"

echo ""
section_header "Encrypted DB backup"

# Never regenerate — changing BACKUP_PASSWORD breaks existing restic backups.
if [ -n "${BACKUP_PASSWORD:-}" ]; then
  echo "  ℹ️  BACKUP_PASSWORD already set — keeping existing value (changing it breaks existing backups)."
else
  BACKUP_PASSWORD=$(openssl rand -base64 36 | tr -dc 'A-Za-z0-9')
  upsert_env "BACKUP_PASSWORD" "$BACKUP_PASSWORD"
  echo "  ✅ BACKUP_PASSWORD generated and saved to .env."
fi

echo ""
section_header "Backblaze offsite backup (optional)"
echo "  ℹ️  Adds a second restic layer to Backblaze alongside local VPS backups."
printf '     Create an Application Key at: '
print_link "https://secure.backblaze.com/app_keys.htm"
echo "     Skip if you only want local backups."
echo ""

_b2_preconfigured=n
[ -n "${BACKBLAZE_KEY_ID:-}" ] && [ -n "${BACKBLAZE_APPLICATION_KEY:-}" ] && _b2_preconfigured=y

if [ "$_b2_preconfigured" = "y" ]; then
  echo "  ✅ Backblaze already configured (keyID: ${BACKBLAZE_KEY_ID:0:8}…) — keeping credentials."
  _want_backblaze=y
else
  _want_backblaze=$(ask_yn "  → Enable Backblaze offsite backup? [y/N]: ")
fi

if [ "$_want_backblaze" = "y" ]; then
  if [ "$_b2_preconfigured" = "n" ]; then
    BACKBLAZE_KEY_ID=$(prompt_value "keyID" "${BACKBLAZE_KEY_ID:-}")
    upsert_env "BACKBLAZE_KEY_ID" "$BACKBLAZE_KEY_ID"

    BACKBLAZE_APPLICATION_KEY=$(prompt_value "applicationKey" "${BACKBLAZE_APPLICATION_KEY:-}" "true")
    upsert_env "BACKBLAZE_APPLICATION_KEY" "$BACKBLAZE_APPLICATION_KEY"
  fi

  BACKBLAZE_BUCKET="${BACKBLAZE_BUCKET:-${PROJECT_NAME}-backups}"
  echo "  ℹ️  B2 bucket '${BACKBLAZE_BUCKET}' will be saved after creation or reuse succeeds."
else
  BACKBLAZE_KEY_ID=""; BACKBLAZE_APPLICATION_KEY=""
fi


echo ""
section_header "Cloudflare API token"
printf '  ℹ️  '
print_link "https://dash.cloudflare.com/profile/api-tokens"
echo "     API token should have the following permissions:"
echo "       • Account → Cloudflare Tunnel       → Edit"
echo "       • Account → Access: Service Tokens  → Edit"
echo "       • Account → Account Settings        → Read"
echo "       • Account → Access: Apps and Policies → Edit"
echo "       • User    → User Details            → Read"
echo "       • Zone    → Zone WAF                → Edit"
echo "       • Zone    → Firewall Services       → Edit"
echo "       • Zone    → DNS                     → Edit"
echo "       • Zone    → Transform Rules         → Edit"
echo ""

_validate_cf_token() {
  local _resp _rc
  _resp=$(printf 'header = "Authorization: Bearer %s"\n' "$1" | curl -K - -s --max-time 10 \
    "https://api.cloudflare.com/client/v4/user/tokens/verify" 2>/dev/null)
  _rc=$?
  [ "$_rc" -ne 0 ] && return 2
  printf '%s' "$_resp" | grep -q '"success":true' || return 1
  printf '%s' "$_resp"
}

_cf_token_valid=false
_cf_result=""
if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
  printf '  🔑 Validating existing Cloudflare token...\n'
  # `|| _cf_rc=$?` — a bare assignment would trip set -e and skip the branches below.
  _cf_rc=0; _cf_result=$(_validate_cf_token "$CLOUDFLARE_API_TOKEN") || _cf_rc=$?
  if [ "$_cf_rc" -eq 0 ]; then
    printf '  ✅ Token valid — press Enter to keep.\n'
    _cf_token_valid=true
  elif [ "$_cf_rc" -eq 2 ]; then
    printf '  ⚠️  Could not reach Cloudflare API — keeping existing token unverified.\n'
    _cf_token_valid=true
  else
    printf '  ⚠️  Existing token is invalid — enter a new one.\n'
    CLOUDFLARE_API_TOKEN=""
  fi
fi

while true; do
  if [ "$_cf_token_valid" = "true" ]; then
    printf '  → Cloudflare API token \033[90m[***]\033[0m: ' >/dev/tty
  else
    printf '  → Cloudflare API token: ' >/dev/tty
  fi
  read_secret _input_token || exit 1
  if [ -z "$_input_token" ] && [ "$_cf_token_valid" = "true" ]; then
    break
  elif [ -z "$_input_token" ]; then
    printf '  ⚠️  Token cannot be empty.\n' >/dev/tty; continue
  elif ! env_value_ok "$_input_token"; then
    env_alphabet_hint >/dev/tty; continue
  fi
  printf '  🔑 Validating...\n'
  _cf_rc=0; _cf_result=$(_validate_cf_token "$_input_token") || _cf_rc=$?
  if [ "$_cf_rc" -eq 0 ]; then
    CLOUDFLARE_API_TOKEN="$_input_token"
    printf '  ✅ Cloudflare token valid.\n'
    break
  elif [ "$_cf_rc" -eq 2 ]; then
    printf '  ⚠️  Could not reach Cloudflare API (network/DNS).\n' >/dev/tty
    printf '     [r]etry / [s]kip validation and accept token / [a]bort? ' >/dev/tty
    read -r _cf_choice </dev/tty || _cf_choice=a
    case "${_cf_choice:-r}" in
      s|S) CLOUDFLARE_API_TOKEN="$_input_token"; printf '  ⚠️  Token accepted without validation.\n'; break ;;
      a|A) exit 1 ;;
      *)   continue ;;
    esac
  else
    printf '  ❌ Invalid token — check permissions and try again.\n' >/dev/tty
  fi
done
upsert_env "CLOUDFLARE_API_TOKEN" "$CLOUDFLARE_API_TOKEN"

echo ""
section_header "Disk space monitoring (optional)"
echo "  ℹ️  An hourly cron checks root disk free space and emails you when it"
echo "     drops below the threshold. Uses Resend HTTP API to send."
echo ""
if [ -n "${RESEND_API_KEY:-}" ]; then
  echo "  ✅ Disk alerts already configured (Resend) — keeping existing settings."
  _want_disk_alerts=y
else
  _want_disk_alerts=$(ask_yn "  → Enable disk space email alerts? [Y/n]: " "y")
fi
if [ "$_want_disk_alerts" = "y" ]; then
  echo "  ℹ️  Two severity levels based on % of disk USED (e.g. 85 = alert when 85% full)."
  echo "     MEDIUM fires first; HIGH fires when the situation is more critical."
  echo ""
  ALERT_DISK_THRESHOLD_MEDIUM="${ALERT_DISK_THRESHOLD_MEDIUM:-85}"
  ALERT_DISK_THRESHOLD_HIGH="${ALERT_DISK_THRESHOLD_HIGH:-95}"
  upsert_env_config "ALERT_DISK_THRESHOLD_MEDIUM" "$ALERT_DISK_THRESHOLD_MEDIUM"
  upsert_env_config "ALERT_DISK_THRESHOLD_HIGH" "$ALERT_DISK_THRESHOLD_HIGH"

  echo ""
  section_header "Resend (email API) settings"
  echo "  Alerts are sent via Resend's HTTP API — SMTP ports are blocked by"
  echo "  DigitalOcean by default, so we can't use Gmail/SendGrid SMTP directly."
  echo ""
  echo "  Setup (one-time per project domain):"
  printf '    1. Sign up at '
  print_link "https://resend.com"
  echo "       Free tier: 3000 emails/month."
  printf '    2. Visit '
  print_link "https://resend.com/domains/add"
  echo "       and enter your domain"
  echo "    3. Click 'Auto configure' and sign in to Cloudflare: Resend adds the DNS records itself."
  echo "    4. Wait until the domain shows as verified, usually a few minutes."
  printf '    5. Visit '
  print_link "https://resend.com/api-keys"
  echo "       and create a key: any name, Permission 'Sending access', Domain = your domain, then click Add."
  echo "    6. Copy the re_... key: it is shown only once."
  echo ""
  _beep

  RESEND_API_KEY=$(prompt_value \
    "Resend API key" \
    "${RESEND_API_KEY:-}" "true")
  upsert_env "RESEND_API_KEY" "$RESEND_API_KEY"

  _resend_domain="${N8N_COMMON_DOMAIN:-}"
  if [ -z "$_resend_domain" ] && [ -n "${N8N_PROJECTS_DOMAIN:-}" ]; then
    _resend_domain="${N8N_PROJECTS_DOMAIN#*.}"
    [[ "$_resend_domain" == *.* ]] || _resend_domain="$N8N_PROJECTS_DOMAIN"
  fi
  _resend_from_default="${RESEND_FROM_EMAIL:-}"
  if [ -z "$_resend_from_default" ] && [ -n "$_resend_domain" ]; then
    _resend_from_default="alerts@${_resend_domain}"
  fi
  RESEND_FROM_EMAIL=$(prompt_value \
    "From address (must be on a verified Resend domain)" \
    "$_resend_from_default" "false" "false" "$_email_re" "RESEND_FROM_EMAIL")
  upsert_env "RESEND_FROM_EMAIL" "$RESEND_FROM_EMAIL"

  echo "  ✅ Disk space alerts configured — MEDIUM ≥${ALERT_DISK_THRESHOLD_MEDIUM}% / HIGH ≥${ALERT_DISK_THRESHOLD_HIGH}% used, alerts → ${DEVELOPER_EMAIL} (via Resend)."
else
  RESEND_API_KEY="${RESEND_API_KEY:-}"
  RESEND_FROM_EMAIL="${RESEND_FROM_EMAIL:-}"
fi

section_header "Workflow health ping (optional)"
echo "  ℹ️  Dead man's switch: n8n workflow pings a healthchecks.io URL every 5 min."
echo "     If pings stop (n8n down, workflow deactivated, VPS crashed) you get an email."
printf '     Free tier (20 checks, no credit card): '
print_link "https://healthchecks.io"
echo ""

configure_health_ping() {
  [ -z "${HEALTH_PING_URL:-}" ] || return 0
  local _hc_api_key="${HEALTHCHECKS_API_KEY:-}" _hc_name _hc_body _hc_resp
  local _hc_status _hc_error _hc_ping _hc_rc
  export -n _hc_api_key
  if [ -n "${N8N_PROJECTS_DOMAIN:-}" ]; then
    _hc_name="$N8N_PROJECTS_DOMAIN"
  elif [ -n "${N8N_COMMON_DOMAIN:-}" ]; then
    _hc_name="${PROJECT_NAME}.${N8N_COMMON_DOMAIN}"
  else
    _hc_name="$PROJECT_NAME"
  fi
  _hc_body=$(jq -nc --arg name "$_hc_name" \
    '{"name":$name,"timeout":600,"grace":1800,"channels":"*","unique":["name"]}')
  while :; do
    if [ -z "$_hc_api_key" ]; then
      printf '  Open '
      print_link "https://healthchecks.io"
      echo "  Project Settings → API Access → create a read-write API key."
      _hc_api_key=$(prompt_value \
        "healthchecks.io API key (leave blank to skip)" \
        "" "true" "true") || return 1
      [ -n "$_hc_api_key" ] || { HEALTH_PING_URL=""; return 0; }
    fi
    echo "  ▶  Creating healthchecks.io check '${_hc_name}' via API ..."
    _hc_rc=0
    _hc_resp=$(printf 'header = "X-Api-Key: %s"\n' "$_hc_api_key" | curl -K - -s --max-time 10 -X POST \
      -H "Content-Type: application/json" \
      -d "$_hc_body" -w '\n%{http_code}' \
      "https://healthchecks.io/api/v3/checks/" 2>/dev/null) || _hc_rc=$?
    _hc_status=${_hc_resp##*$'\n'}
    _hc_resp=${_hc_resp%$'\n'*}
    if [ "$_hc_rc" -eq 0 ] && [[ "$_hc_status" =~ ^2[0-9][0-9]$ ]] && \
        _hc_ping=$(printf '%s' "$_hc_resp" | jq -er '.ping_url | select(type == "string" and length > 0)' 2>/dev/null); then
      HEALTH_PING_URL="$_hc_ping"
      echo "  ✅ Check created — ping URL saved to .env."
      return 0
    fi
    _hc_error=$(printf '%s' "$_hc_resp" | jq -r '.error // .message // . | if type == "string" then . else tojson end' 2>/dev/null) || _hc_error="$_hc_resp"
    _hc_error=${_hc_error//"$_hc_api_key"/***}
    printf '  ⚠️  healthchecks.io HTTP %s (curl exit %s): %s\n' \
      "${_hc_status:-000}" "$_hc_rc" "${_hc_error:-No response body}" >&2
    _hc_api_key=""
  done
}
configure_health_ping
upsert_env "HEALTH_PING_URL" "$HEALTH_PING_URL"

echo ""

write_env_file
if [ "$_is_rerun" = "true" ]; then
  echo "✅ .env updated."
else
  echo "✅ .env written."
fi
echo ""

# .env.developer values can reach write_env_file without passing a prompt.
env_files_check_alphabet "$ENV_CONFIG" "$ENV_FILE" "$ENV_LOCAL"

set -a
load_env_file "$ENV_CONFIG"
[ -f "$ENV_DEVELOPER" ] && load_env_file "$ENV_DEVELOPER"
load_env_file "$ENV_FILE"
[ -f "$ENV_LOCAL" ]     && load_env_file "$ENV_LOCAL"
set +a
HARD_RESET="$_initialize_hard_reset"

if [ "$HARD_RESET" = true ]; then
  echo ""
  echo "⚠️  --hard-reset: this DESTROYS the n8n stack volumes (database and application files)."
  printf "Type exactly  wipe-all-data  to confirm: "
  read -r CONFIRM
  if [ "$CONFIRM" != "wipe-all-data" ]; then
    echo "❌ Confirmation string wrong. Aborting."
    exit 1
  fi
  echo "✅ Hard reset confirmed."
fi

# Step 0: Cloudflare bootstrap (before main validation)
if [ -n "${TUNNEL_TOKEN:-}" ]; then
  echo "✅ Step 0: Cloudflare already configured — skipping."
elif [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
  echo "▶  Step 0: Bootstrapping Cloudflare tunnel + DNS + Access ..."
  if retry_or_skip "Cloudflare bootstrap" bash "$ROOT_DIR/scripts/cloudflare/init-cloudflare.sh"; then
    set -a
    [ -f "$ENV_CONFIG" ]    && load_env_file "$ENV_CONFIG"
    [ -f "$ENV_DEVELOPER" ] && load_env_file "$ENV_DEVELOPER"
    [ -f "$ENV_FILE" ]      && load_env_file "$ENV_FILE"
    [ -f "$ENV_LOCAL" ]     && load_env_file "$ENV_LOCAL"
    set +a
    HARD_RESET="$_initialize_hard_reset"
    echo "✅ Step 0: Cloudflare configured."
  else
    cat >&2 <<'MSG'

⚠️  Step 0: Cloudflare bootstrap was SKIPPED — tunnel / DNS / Access / WAF / Transform Rule
   were not (re)applied. The most common cause is a missing API-token permission
   (see the hint printed above the [r]etry/[s]kip/[a]bort prompt).

   Fix the underlying issue and either:
     • re-run  npm run initialize     (this step is idempotent), or
     • run     npm run init-cloudflare  standalone, then re-run npm run initialize.

   Aborting now — downstream steps need TUNNEL_TOKEN and would fail anyway.
MSG
    exit 1
  fi
else
  cat >&2 <<'MSG'
❌ Cloudflare is not yet configured and CLOUDFLARE_API_TOKEN is missing.

   Option A (automatic): add CLOUDFLARE_API_TOKEN to your .env — initialize
                         will bootstrap Cloudflare automatically as Step 0.

   Option B (manual):    run  npm run init-cloudflare  first, then re-run
                         npm run initialize.
MSG
  exit 1
fi

missing=()
_required_vars=(PROJECT_NAME N8N_VPS_IP N8N_VPS_USER N8N_ENCRYPTION_KEY \
                DB_USER DB_PASSWORD DB_NAME BACKUP_PASSWORD TUNNEL_TOKEN)
for v in "${_required_vars[@]}"; do
  [ -z "${!v}" ] && missing+=("$v")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "❌ Missing required values: ${missing[*]}"
  echo "   Check .env.config (non-sensitive) and .env (sensitive)."
  exit 1
fi

if [ "$N8N_VPS_USER" != "root" ]; then
  echo "❌ N8N_VPS_USER must be root (got '${N8N_VPS_USER}'). Set it in .env.local, then re-run."
  exit 1
fi

# Exactly one domain mode required.
if [ -n "${N8N_COMMON_DOMAIN:-}" ] && [ -n "${N8N_PROJECTS_DOMAIN:-}" ]; then
  echo "❌ Set only one of N8N_COMMON_DOMAIN or N8N_PROJECTS_DOMAIN in .env.config, not both."
  exit 1
elif [ -n "${N8N_COMMON_DOMAIN:-}" ]; then
  WEBHOOK_URL="https://${PROJECT_NAME}.${N8N_COMMON_DOMAIN}"
elif [ -n "${N8N_PROJECTS_DOMAIN:-}" ]; then
  WEBHOOK_URL="https://${N8N_PROJECTS_DOMAIN}"
else
  echo "❌ Set either N8N_COMMON_DOMAIN or N8N_PROJECTS_DOMAIN in .env.config."
  exit 1
fi

echo "✅ All required env vars present."

trust_vps_host_key() {
  local raw_key="" pinned="${N8N_VPS_HOST_FINGERPRINT:-}" attempt
  local known_hosts="$HOME/.ssh/known_hosts"
  for attempt in 1 2 3 4 5; do
    if raw_key=$(ssh-keyscan -T 5 -t ed25519 "$N8N_VPS_IP" 2>/dev/null) && [ -n "$raw_key" ]; then
      break
    fi
    raw_key=""
    [ "$attempt" -eq 5 ] || sleep 2
  done
  if [ -z "$raw_key" ]; then
    echo "❌ Could not scan the ed25519 host key for $N8N_VPS_IP; check server boot and SSH access, then re-run." >&2
    return 1
  fi
  _FINGERPRINT=$(printf '%s\n' "$raw_key" | ssh-keygen -lf - | awk '{ print $2 }') || return 1
  if [ -n "$pinned" ] && [ "$pinned" != "SHA256:paste_fingerprint_here" ]; then
    if [ "$pinned" != "$_FINGERPRINT" ]; then
      printf '❌ SSH host fingerprint MISMATCH for %s.\n   Saved: %s\n   Scanned: %s\n' \
        "$N8N_VPS_IP" "$pinned" "$_FINGERPRINT" >&2
      echo "   Check the IP and host key in the provider console before changing the saved fingerprint; a rebuild or impersonation may have changed it." >&2
      return 1
    fi
    echo "✅ VPS ed25519 host key matches the saved fingerprint ($_FINGERPRINT)."
  else
    echo "⚠️  No saved VPS fingerprint: $_FINGERPRINT; cross-check it in the provider console."
  fi
  mkdir -p "$HOME/.ssh" || return 1
  chmod 700 "$HOME/.ssh" || return 1
  touch "$known_hosts" || return 1
  chmod 600 "$known_hosts" || return 1
  ssh-keygen -R "$N8N_VPS_IP" -f "$known_hosts" >/dev/null 2>&1 || return 1
  printf '%s\n' "$raw_key" >> "$known_hosts" || return 1
  N8N_SSH_OPTS+=(-o StrictHostKeyChecking=yes)
  N8N_SSH_OPTS+=(-o "UserKnownHostsFile=$known_hosts" -o HostKeyAlgorithms=ssh-ed25519)
}

# ConnectTimeout keeps the retry loop responsive when sshd briefly bounces
# (needrestart, unattended-upgrades).
N8N_SSH_OPTS=("-o" "ConnectTimeout=10")
[ -n "${SSH_PRIVATE_KEY:-}" ] && [ -f "${SSH_PRIVATE_KEY/#\~/$HOME}" ] && \
  N8N_SSH_OPTS+=("-i" "${SSH_PRIVATE_KEY/#\~/$HOME}")

# Retries only on exit 255 (SSH transport) — remote command errors propagate.
_n8n_ssh_retry() {
    local attempt=1 max=4 rc sleep_for
    while :; do
        # `|| rc=$?` keeps set -e from aborting before the retry logic runs.
        rc=0
        "$@" || rc=$?
        if [ "$rc" -eq 0 ] || [ "$rc" -ne 255 ] || [ "$attempt" -ge "$max" ]; then
            return "$rc"
        fi
        sleep_for=$((attempt * 3))
        echo "  ⚠ SSH transport failure (exit $rc) — retrying in ${sleep_for}s (attempt $attempt/$max)..." >&2
        sleep "$sleep_for"
        attempt=$((attempt + 1))
    done
}

ssh_n8n() { _n8n_ssh_retry ssh "${N8N_SSH_OPTS[@]}" "${N8N_VPS_USER}@${N8N_VPS_IP}" "$@"; }
ssh_n8n_stdin() { retry_ssh_buffered ssh "${N8N_SSH_OPTS[@]}" "${N8N_VPS_USER}@${N8N_VPS_IP}" "$@"; }
scp_n8n() { _n8n_ssh_retry scp "${N8N_SSH_OPTS[@]}" "$@"; }

# Wait for sshd to settle after Step 1's apt upgrade. ≥6s between probes keeps
# us under ufw's `limit 22/tcp` rate-limit even without a dev-IP ALLOW rule.
wait_for_sshd() {
    local consecutive=0 attempt=0 max_attempts=20 needed=3 interval=6
    echo "  ⏳ Waiting for sshd to settle (need ${needed} consecutive successes)..."
    while [ "$consecutive" -lt "$needed" ] && [ "$attempt" -lt "$max_attempts" ]; do
        if ssh "${N8N_SSH_OPTS[@]}" -o BatchMode=yes \
                "${N8N_VPS_USER}@${N8N_VPS_IP}" 'true' 2>/dev/null; then
            consecutive=$((consecutive + 1))
        else
            consecutive=0
        fi
        attempt=$((attempt + 1))
        sleep "$interval"
    done
    if [ "$consecutive" -lt "$needed" ]; then
        echo "  ❌ sshd did not settle after ${max_attempts} probes" >&2
        return 1
    fi
    echo "  ✓ sshd is stable (${consecutive} consecutive successful probes)."
}

echo ""
section_header "Initializing VPS"
echo "  Project:       ${PROJECT_NAME}"
echo "  n8n VPS:       ${N8N_VPS_IP}"
echo "  Backup:        local (on n8n VPS)"
echo ""

# .env.sops.yaml means this project was deployed before, so the next steps can hit production.
if [ -f "${ROOT_DIR}/.env.sops.yaml" ] && [ "$HARD_RESET" != "true" ]; then
  echo "  ⚠️  .env.sops.yaml exists: this looks like a deployed project."
  echo "     Continuing runs apt-get upgrade and docker compose down/up on ${N8N_VPS_IP} (downtime)."
  if [ "$(ask_yn '  → Continue? [y/N]: ')" != "y" ]; then
    echo "  Stopped before touching the VPS."
    exit 0
  fi
fi

# Operational shell time is UTC (storage/logs); display zone is applied at edges.
trust_vps_host_key || exit 1
echo "▶  Step 1/4: OS setup (apt, Docker, UFW, swap, restic, crons) ..."
ssh_n8n_stdin bash << INIT_EOF
set -e
export TZ="UTC"
export DEBIAN_FRONTEND=noninteractive
# Stop needrestart auto-bouncing sshd mid-script (Ubuntu 22.04+).
export NEEDRESTART_MODE=l
export NEEDRESTART_SUSPEND=1

# Fresh cloud images run unattended-upgrades at boot, which holds the apt lock.
apt-get -o DPkg::Lock::Timeout=300 update
apt-get -o DPkg::Lock::Timeout=300 upgrade -y
apt-get -o DPkg::Lock::Timeout=300 install -y apt-transport-https ca-certificates curl gnupg lsb-release jq rsync ufw logrotate restic python3 locales

if [ ! -f /swapfile ]; then
    # swap = clamp(RAM * 2, 2 GB .. 4 GB). Past 4 GB swap is wasted disk on a typical 25 GB droplet.
    _ram_mb=\$(awk '/MemTotal:/ {print int(\$2/1024)}' /proc/meminfo)
    _swap_mb=\$(( _ram_mb * 2 ))
    [ "\$_swap_mb" -gt 4096 ] && _swap_mb=4096
    [ "\$_swap_mb" -lt 2048 ] && _swap_mb=2048
    fallocate -l \${_swap_mb}M /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
    echo "  ✓ swap: \${_swap_mb} MB (RAM detected: \${_ram_mb} MB)"
fi

# Install Docker via official apt repo (GPG-verified) — never get.docker.com|sh.
if ! command -v docker >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings
    . /etc/os-release
    case "\$ID" in
        debian|ubuntu)
            _docker_distro="\$ID"
            _docker_codename="\$VERSION_CODENAME"
            ;;
        *)
            # Ubuntu/Debian derivative (Pop!_OS, Mint, elementary, …): map via
            # ID_LIKE and prefer the upstream codename — derivatives set
            # VERSION_CODENAME to their own name, UBUNTU_CODENAME to the base.
            case " \$ID_LIKE " in
                *" ubuntu "*)
                    _docker_distro="ubuntu"
                    _docker_codename="\${UBUNTU_CODENAME:-\$VERSION_CODENAME}"
                    ;;
                *" debian "*)
                    _docker_distro="debian"
                    _docker_codename="\$VERSION_CODENAME"
                    ;;
                *)
                    echo "❌ Unsupported OS for Docker apt repo: \$ID (ID_LIKE=\$ID_LIKE)" >&2
                    exit 1
                    ;;
            esac
            ;;
    esac
    curl -fsSL "https://download.docker.com/linux/\${_docker_distro}/gpg" \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    # Fingerprint per docs.docker.com/engine/install/ubuntu/.
    _DOCKER_EXPECTED_FP="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
    _DOCKER_GOT_FP=\$(gpg --show-keys --with-colons \
        /etc/apt/keyrings/docker.asc 2>/dev/null \
        | awk -F: '/^fpr:/{print \$10; exit}')
    if [ "\$_DOCKER_GOT_FP" != "\$_DOCKER_EXPECTED_FP" ]; then
        echo "❌ Docker GPG key fingerprint mismatch — aborting to prevent installing packages from an untrusted source." >&2
        echo "   Expected: \$_DOCKER_EXPECTED_FP" >&2
        echo "   Got:      \$_DOCKER_GOT_FP" >&2
        rm -f /etc/apt/keyrings/docker.asc
        exit 1
    fi
    echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/\${_docker_distro} \${_docker_codename} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get -o DPkg::Lock::Timeout=300 update
    apt-get -o DPkg::Lock::Timeout=300 install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# UFW — no rate-limit on 22 (GitHub Actions tripped the 6-conn/30s threshold).
# Cloudflare Tunnel needs no public HTTP ports.
ufw allow 22/tcp comment 'SSH (key-auth)'
ufw --force enable

if [ ! -s /root/.ssh/authorized_keys ]; then
    echo "❌ /root/.ssh/authorized_keys is empty: disabling password login would lock you out. Add your key and re-run." >&2
    exit 1
fi

# sshd keeps the first value it reads, so the name must sort before 50-cloud-init.conf.
rm -f /etc/ssh/sshd_config.d/99-n8n-core-setup.conf
cat > /etc/ssh/sshd_config.d/00-n8n-core-setup.conf <<'SSHCFG'
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
MaxAuthTries 3
LoginGraceTime 20
PermitEmptyPasswords no
SSHCFG
chmod 644 /etc/ssh/sshd_config.d/00-n8n-core-setup.conf
# Validate before reload — no lockouts.
if sshd -t; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    # sshd -t passes even when another file overrides ours; sshd -T prints what actually applies.
    _sshd_effective=\$(sshd -T)
    if ! printf '%s\n' "\$_sshd_effective" | grep -qx 'passwordauthentication no' \
       || ! printf '%s\n' "\$_sshd_effective" | grep -qx 'kbdinteractiveauthentication no' \
       || ! printf '%s\n' "\$_sshd_effective" | grep -qxE 'permitrootlogin (prohibit-password|without-password)'; then
        echo "❌ sshd hardening did not take effect (check sshd -T and /etc/ssh/sshd_config)" >&2
        exit 1
    fi
else
    echo "❌ sshd config invalid — leaving previous config in place" >&2
    rm -f /etc/ssh/sshd_config.d/00-n8n-core-setup.conf
fi

mkdir -p /root/n8n

sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
locale-gen
for v in LC_ALL LANG LANGUAGE; do
    grep -q "export \$v=en_US.UTF-8" ~/.bashrc || echo "export \$v=en_US.UTF-8" >> ~/.bashrc
done

# Crons are installed by install-crons.sh after Step 2's SCP.

cat > /etc/logrotate.d/n8n << 'LOGROTATE'
/root/n8n/poll-publish.log /root/n8n/backup.log /root/n8n/disk-check.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    dateext
    create 0600 root root
}
LOGROTATE
echo "✅ Logrotate config written to /etc/logrotate.d/n8n."
INIT_EOF
echo "✅ OS setup complete."
upsert_env "N8N_VPS_HOST_FINGERPRINT" "$_FINGERPRINT"
N8N_VPS_HOST_FINGERPRINT="$_FINGERPRINT"

wait_for_sshd


echo "▶  Step 2/4: Uploading n8n project files ..."
ssh_n8n "mkdir -p ~/n8n"
scp_n8n -r "$ROOT_DIR/n8n" "${N8N_VPS_USER}@${N8N_VPS_IP}:~/"
# macOS npm ci sets node_modules/.bin to 0700; container runs UID 1000 and crashes on EACCES.
ssh_n8n "[ -d /root/n8n/custom-nodes ] && chmod -R a+rX /root/n8n/custom-nodes || true"
echo "✅ Files uploaded."

echo "▶  Installing VPS cron jobs ..."
ssh_n8n "DISPLAY_TZ='${DISPLAY_TZ:-UTC}' bash /root/n8n/scripts/install-crons.sh"
echo "✅ Cron jobs installed."

echo "▶  Step 3/4: Booting n8n Docker stack ..."

RESTIC_REPOSITORY="/root/db-backups/${PROJECT_NAME}"

# printf-based — unquoted heredocs would execute $(…)/backticks in secret values.
TMPENV=$(mktemp)
chmod 600 "$TMPENV"
{
    printf 'PROJECT_NAME=%s\n'        "${PROJECT_NAME}"
    printf 'DISPLAY_TZ=%s\n'         "${DISPLAY_TZ:-UTC}"
    printf 'N8N_ENCRYPTION_KEY=%s\n' "${N8N_ENCRYPTION_KEY}"
    printf 'N8N_API_KEY=%s\n'        "${N8N_API_KEY:-}"
    printf 'WEBHOOK_URL=%s\n'        "${WEBHOOK_URL}"
    printf 'N8N_LOCAL_API_URL=%s\n'  "${N8N_LOCAL_API_URL:-}"
    printf 'DB_USER=%s\n'            "${DB_USER}"
    printf 'DB_PASSWORD=%s\n'        "${DB_PASSWORD}"
    printf 'DB_NAME=%s\n'            "${DB_NAME}"
    printf 'BACKUP_PASSWORD=%s\n'    "${BACKUP_PASSWORD}"
    printf 'TUNNEL_TOKEN=%s\n'       "${TUNNEL_TOKEN}"
    printf 'GITHUB_PERSONAL_ACCESS_TOKEN=%s\n'   "${GITHUB_PERSONAL_ACCESS_TOKEN:-}"
    printf 'GITHUB_REPO=%s\n'        "${GITHUB_REPO:-}"
    printf 'GITHUB_BRANCH=%s\n'      "${GITHUB_BRANCH:-}"
    printf 'BACKBLAZE_KEY_ID=%s\n'   "${BACKBLAZE_KEY_ID:-}"
    printf 'BACKBLAZE_APPLICATION_KEY=%s\n'  "${BACKBLAZE_APPLICATION_KEY:-}"
    printf 'RESEND_API_KEY=%s\n'     "${RESEND_API_KEY:-}"
    printf 'RESEND_FROM_EMAIL=%s\n'  "${RESEND_FROM_EMAIL:-}"
    printf 'HEALTH_PING_URL=%s\n'    "${HEALTH_PING_URL:-}"
    printf 'DEVELOPER_EMAIL=%s\n'     "${DEVELOPER_EMAIL:-}"
    printf 'RESTIC_REPOSITORY=%s\n'   "${RESTIC_REPOSITORY}"
    printf 'ALERT_DISK_THRESHOLD_MEDIUM=%s\n' "${ALERT_DISK_THRESHOLD_MEDIUM:-85}"
    printf 'ALERT_DISK_THRESHOLD_HIGH=%s\n'   "${ALERT_DISK_THRESHOLD_HIGH:-95}"
    if [ -n "${BACKBLAZE_BUCKET:-}" ] && [ -n "${BACKBLAZE_KEY_ID:-}" ]; then
        # rclone:b2: (not native b2:) because Backblaze deprecated API v1 — restic 0.18
        # via blazer fails b2_authorize_account on v2-only application keys.
        printf 'RESTIC_REPOSITORY_BACKBLAZE=rclone:b2:%s\n' "${BACKBLAZE_BUCKET}"
    fi
} > "$TMPENV"
scp_n8n "$TMPENV" "${N8N_VPS_USER}@${N8N_VPS_IP}:~/n8n/.env"
rm -f "$TMPENV"

# Only ${HARD_RESET} expands locally (always "true"/"false"). All other values
# pass via .env (printf-written above) and the grep below — no heredoc injection.
ssh_n8n_stdin << EOF
set -e
umask 077
cd ~/n8n
chmod 600 .env
trap 'rm -f .env' EXIT
find scripts -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true

_COMPOSE_ARGS=\$(bash scripts/lib/compose-args.sh)
# Pull BEFORE down — a failed pull must not leave the stack stopped.
docker compose \$_COMPOSE_ARGS pull 2>&1
if [ "${HARD_RESET}" = "true" ]; then
  echo "⚠️  HARD_RESET=true — wiping n8n stack volumes (destroys DB and application files)"
  docker compose \$_COMPOSE_ARGS down -v 2>&1 || true
else
  docker compose \$_COMPOSE_ARGS down 2>&1 || true
fi
docker compose \$_COMPOSE_ARGS up -d --remove-orphans 2>&1

grep -E "^(DB_USER|DB_NAME|BACKUP_PASSWORD|PROJECT_NAME|DISPLAY_TZ|N8N_API_KEY|N8N_LOCAL_API_URL|GITHUB_PERSONAL_ACCESS_TOKEN|GITHUB_REPO|GITHUB_BRANCH|TUNNEL_TOKEN|BACKBLAZE_KEY_ID|BACKBLAZE_APPLICATION_KEY|HEALTH_PING_URL|DEVELOPER_EMAIL|RESTIC_REPOSITORY|RESTIC_REPOSITORY_BACKBLAZE|ALERT_DISK_THRESHOLD_MEDIUM|ALERT_DISK_THRESHOLD_HIGH|RESEND_API_KEY|RESEND_FROM_EMAIL)=" .env > .backup_creds || true
chmod 600 .backup_creds || true
rm -f .env
echo "✅ Stack is up. .backup_creds written."
EOF
echo "✅ n8n stack booted."

# Fresh install / --hard-reset wipes the DB, so any old N8N_API_KEY is invalid.
echo "▶  Checking n8n API key..."

_n8n_local_url="${N8N_LOCAL_API_URL:-http://localhost:5678/api/v1}"

_n8n_ready=0
for _i in $(seq 1 18); do
  _http=$(ssh_n8n "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:5678/healthz 2>/dev/null || true")
  if [ "$_http" = "200" ]; then _n8n_ready=1; break; fi
  echo "   Waiting for n8n... (attempt $_i/18, status: ${_http:-none})"
  sleep 5
done
[ "$_n8n_ready" = "1" ] || echo "⚠️  n8n did not respond within 90s — continuing anyway."

# Fire initial healthchecks.io ping so the check transitions "New" → "Up".
# Without at least one ping the check stays grey and never alerts on downtime.
if [ -n "${HEALTH_PING_URL:-}" ] && [ "$_n8n_ready" = "1" ]; then
  _hc_http=$(ssh_n8n "curl -s -o /dev/null -w '%{http_code}' --max-time 10 '${HEALTH_PING_URL}' 2>/dev/null || true")
  if [ "$_hc_http" = "200" ]; then
    echo "✅ healthchecks.io initial ping sent from VPS — check is now 'Up'."
  else
    echo "⚠️  healthchecks.io ping failed (HTTP ${_hc_http}) — check may stay in 'New' state."
  fi
fi

# Test the current API key (skip test if key is empty). Pipe the key into ssh
# stdin and use `curl -K -` (config from stdin) so it never appears in argv of
# the remote curl process — `ps aux` on the VPS would otherwise expose it for
# the duration of the request.
_api_valid=false
if [ -n "${N8N_API_KEY:-}" ] && [ "${HARD_RESET}" != "true" ]; then
  _api_status=$(printf 'header = "X-N8N-API-KEY: %s"\n' "${N8N_API_KEY}" \
    | ssh_n8n_stdin "curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
      -K - '${_n8n_local_url}/workflows' 2>/dev/null || true")
  [ "$_api_status" = "200" ] && _api_valid=true
fi

if [ "$_api_valid" = "false" ]; then
  _beep
  echo ""
  section_header "ACTION REQUIRED — Set up n8n owner account"
  echo ""
  printf '  n8n is running at: '
  print_link "$WEBHOOK_URL"
  echo ""
  echo "  1. Open the URL above and create the owner account:"
  echo "     use your own email and a strong password, and save them in your password manager"
  printf '  2. Go to: '
  print_link "${WEBHOOK_URL}/settings/api" " → click 'Create API key'"
  echo "  3. Come back here"
  echo ""
  printf '  Press [Enter] when done: ' >/dev/tty
  IFS= read -r _ </dev/tty || exit 1
  echo ""
  while :; do
    printf '  Paste N8N_API_KEY: ' >"$_PV_TTY_OUT"
    read_secret _new_key || exit 1
    if [ -z "$_new_key" ]; then
      printf '  ⚠️  Required — please enter a value.\n' >"$_PV_TTY_OUT"
    elif env_value_ok "$_new_key"; then
      _api_status=$(printf 'header = "X-N8N-API-KEY: %s"\n' "$_new_key" \
        | ssh_n8n_stdin "curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
          -K - '${_n8n_local_url}/workflows' 2>/dev/null || true") || _api_status=000
      if [ "$_api_status" = 200 ]; then break; fi
      printf '  ⚠️  N8N_API_KEY rejected or unreachable (HTTP %s); try again.\n' "${_api_status:-000}" >"$_PV_TTY_OUT"
    else
      env_alphabet_hint >"$_PV_TTY_OUT"
    fi
  done
  N8N_API_KEY="$_new_key"
  upsert_env "N8N_API_KEY" "$N8N_API_KEY"
  # SSH argv would expose the key to other processes.
  printf '%s\n' "${N8N_API_KEY}" | ssh_n8n_stdin "
NEW_KEY=\$(cat)
_tmp=\$(mktemp)
grep -v '^N8N_API_KEY=' ~/n8n/.backup_creds 2>/dev/null > \"\$_tmp\" || true
printf 'N8N_API_KEY=%s\n' \"\$NEW_KEY\" >> \"\$_tmp\"
mv \"\$_tmp\" ~/n8n/.backup_creds
chmod 600 ~/n8n/.backup_creds"
  echo "✅ N8N_API_KEY saved to .env and patched in VPS .backup_creds."
else
  echo "✅ N8N_API_KEY valid."
fi

# n8n MCP setup moved below — runs only after the first deploy succeeds,
# because the per-user MCP token lives on the n8n instance (must be up).

# Generate (or reuse) the per-project age key, register it in the default
# keystore, and (re)write .sops.yaml. Sets _age_keyfile + _age_pubkey.
_ensure_age_key() {
  local _age_dir="${HOME}/.config/sops/age"
  local _age_default="${_age_dir}/keys.txt"
  _age_keyfile="${_age_dir}/${PROJECT_NAME}.txt"
  if [ ! -f "$_age_keyfile" ]; then
    mkdir -p "$_age_dir"
    age-keygen -o "$_age_keyfile" 2>/dev/null
    chmod 600 "$_age_keyfile"
    echo "  ✅ New age key generated: ${_age_keyfile}"
  else
    echo "  ℹ️  Age key already exists at ${_age_keyfile} — reusing."
  fi
  if ! _age_pubkey=$(age-keygen -y "$_age_keyfile" 2>/dev/null) || [ -z "$_age_pubkey" ]; then
    printf '❌ Cannot derive the age recipient from %s; check that it is a readable age key.\n' "$_age_keyfile" >&2
    exit 1
  fi
  # `sops` finds keys via the default keystore.
  if ! grep -qF "$_age_pubkey" "$_age_default" 2>/dev/null; then
    printf '\n# %s\n' "$PROJECT_NAME" >> "$_age_default"
    cat "$_age_keyfile" >> "$_age_default"
  fi
  printf 'creation_rules:\n  - path_regex: \\.env(\\.sops\\.yaml)?$\n    age: %s\n' \
    "$_age_pubkey" > "${ROOT_DIR}/.sops.yaml"
}

# Age key must exist before the SOPS_AGE_KEY GitHub-secret prompt.
[ -f "$ENV_FILE" ] && _ensure_age_key

echo ""
section_header "ACTION REQUIRED — Save TWO secrets to GitHub before first deploy"
echo ""


section_header "Secret 1/2: SSH_PRIVATE_KEY"
echo "  Used by GitHub Actions (appleboy/ssh-action) to SSH into the VPS."
echo ""
_ssh_key_path="${SSH_PRIVATE_KEY/#\~/$HOME}"
if [ ! -f "$_ssh_key_path" ]; then
  echo "  ⚠️  SSH private key not found at: ${_ssh_key_path}"
  echo "     Add SSH_PRIVATE_KEY to GitHub Secrets manually (key contents, not path)."
  _beep
  printf "  Press Enter once SSH_PRIVATE_KEY is saved manually ..." >/dev/tty
  read -r _ </dev/tty
elif _push_github_secret SSH_PRIVATE_KEY < "$_ssh_key_path"; then
  echo "  ✅ SSH_PRIVATE_KEY pushed to ${GITHUB_REPO} via gh CLI."
else
  echo "❌ Could not save SSH_PRIVATE_KEY via gh CLI; check repository secret permissions and connectivity, then re-run." >&2
  exit 1
fi
echo "✅ SSH_PRIVATE_KEY saved."

echo ""
section_header "Secret 2/2: SOPS_AGE_KEY"
echo "  CI decrypts secrets via your per-project age private key."
echo ""
_age_key_path="${HOME}/.config/sops/age/${PROJECT_NAME}.txt"
if [ ! -f "$_age_key_path" ]; then
  echo "  ⚠️  Age key not found at ${_age_key_path} — see SOPS setup in README."
  _beep
  printf "  Press Enter once SOPS_AGE_KEY is saved manually ..." >/dev/tty
  read -r _ </dev/tty
elif _push_github_secret SOPS_AGE_KEY < "$_age_key_path"; then
  echo "  ✅ SOPS_AGE_KEY pushed to ${GITHUB_REPO} via gh CLI."
else
  echo "❌ Could not save SOPS_AGE_KEY via gh CLI; check repository secret permissions and connectivity, then re-run." >&2
  exit 1
fi
echo "✅ SOPS_AGE_KEY saved."
echo ""

section_header "GitHub Push Protection"
echo "  Server-side scanner: blocks AWS / Stripe / OpenAI / GitHub PATs / etc."
echo "  before they hit git history. Availability depends on the repository/account and plan."
echo ""
_pp_enabled=0
if _enable_github_push_protection "$GITHUB_REPO"; then
  echo "  ✅ Push Protection + Secret Scanning enabled on ${GITHUB_REPO}."
  _pp_enabled=1
else
  printf '  ⚠️  Enable manually: '
  print_link "https://github.com/${GITHUB_REPO}/settings/security_analysis"
fi
if [ "$_pp_enabled" -eq 0 ]; then
  echo ""
  echo "  ⚠️  Push Protection NOT enabled — only local pre-flight checks"
  echo "     protect auto-commits. Enable in GitHub UI when convenient:"
  printf '     → '
  print_link "https://github.com/${GITHUB_REPO}/settings/security_analysis"
  echo "     → Enable 'Secret scanning' and 'Push protection'."
fi
echo ""

echo "▶  Step 4/4: Setting up backup repository ..."
ssh_n8n "mkdir -p /root/db-backups"
echo "   n8n VPS: /root/db-backups created."

echo "   Initializing restic repository: ${RESTIC_REPOSITORY} ..."
_local_restic_init() {
  ssh_n8n "set -a; source ~/n8n/.backup_creds; set +a
    export RESTIC_PASSWORD=\"\$BACKUP_PASSWORD\"
    restic -r '${RESTIC_REPOSITORY}' snapshots > /dev/null 2>&1 \
      || restic -r '${RESTIC_REPOSITORY}' init"
}
if retry_or_skip "Local restic init" _local_restic_init; then
  echo "✅ Backup repository setup complete."
else
  _failures+=("Local restic repository not initialized: no local backups until it is")
fi

_b2_create_bucket() {
  local attempt=1 response code name bucket_id listing lock_state suffix
  local file_lock=false
  [ "$_b2_use_lock" != y ] || file_lock=true
  while [ "$attempt" -le 4 ]; do
    echo "   Creating bucket '${BACKBLAZE_BUCKET}'..."
    if ! response=$(printf 'header = "Authorization: %s"\n' "$_b2_auth_token" | curl -K - -s --max-time 15 \
      -d "{\"accountId\":\"${_b2_real_account_id}\",\"bucketName\":\"${BACKBLAZE_BUCKET}\",\"bucketType\":\"allPrivate\",\"fileLockEnabled\":${file_lock}}" \
      "${_b2_api_url}/b2api/v2/b2_create_bucket"); then
      echo "   ❌ B2 bucket creation failed; check connectivity before re-running." >&2
      return 1
    fi
    code=$(printf '%s' "$response" | jq -r '.code // empty') || return 1
    name=$(printf '%s' "$response" | jq -r '.bucketName // empty') || return 1
    bucket_id=$(printf '%s' "$response" | jq -r '.bucketId // empty') || return 1
    if [ -z "$code" ] && [ "$name" = "$BACKBLAZE_BUCKET" ] && [ -n "$bucket_id" ]; then
      _b2_bucket_id="$bucket_id"
      upsert_env_config "BACKBLAZE_BUCKET" "$BACKBLAZE_BUCKET" || return 1
      echo "   ✅ B2 bucket '${BACKBLAZE_BUCKET}' created (Object Lock: ${file_lock})."
      return 0
    fi
    if [ "$code" != duplicate_bucket_name ]; then
      printf '   ❌ B2 bucket creation failed: %s\n' "$response" >&2
      return 1
    fi
    if ! listing=$(printf 'header = "Authorization: %s"\n' "$_b2_auth_token" | curl -K - -s --max-time 15 \
      -d "{\"accountId\":\"${_b2_real_account_id}\",\"bucketName\":\"${BACKBLAZE_BUCKET}\"}" \
      "${_b2_api_url}/b2api/v2/b2_list_buckets"); then
      echo "   ❌ Could not check whether the existing B2 bucket belongs to your account." >&2
      return 1
    fi
    if ! printf '%s' "$listing" | jq -e '.buckets | type == "array"' >/dev/null; then
      printf '   ❌ B2 bucket lookup failed: %s\n' "$listing" >&2
      return 1
    fi
    bucket_id=$(printf '%s' "$listing" | jq -r --arg name "$BACKBLAZE_BUCKET" \
      '.buckets[] | select(.bucketName == $name) | .bucketId // empty') || return 1
    if [ -n "$bucket_id" ]; then
      _b2_bucket_id="$bucket_id"
      lock_state=$(printf '%s' "$listing" | jq -r --arg name "$BACKBLAZE_BUCKET" \
        '.buckets[] | select(.bucketName == $name) | .fileLockConfiguration.value.isFileLockEnabled // false') || return 1
      if [ "$file_lock" = true ] && [ "$lock_state" != true ]; then
        echo "   ❌ Existing bucket '${BACKBLAZE_BUCKET}' has Object Lock disabled; B2 cannot enable it retroactively." >&2
        return 1
      fi
      upsert_env_config "BACKBLAZE_BUCKET" "$BACKBLAZE_BUCKET" || return 1
      echo "   ✅ Reusing existing B2 bucket '${BACKBLAZE_BUCKET}'."
      return 0
    fi
    if _pv_key_saved BACKBLAZE_BUCKET || [ "$attempt" -eq 4 ]; then
      echo "   ❌ B2 bucket name '${BACKBLAZE_BUCKET}' is taken; keeping the saved configuration." >&2
      return 1
    fi
    suffix=$(openssl rand -hex 3) || return 1
    BACKBLAZE_BUCKET="${PROJECT_NAME}-backups-${suffix}"
    attempt=$((attempt + 1))
  done
}

if [ -n "${BACKBLAZE_KEY_ID:-}" ] && [ -n "${BACKBLAZE_APPLICATION_KEY:-}" ] && [ -n "${BACKBLAZE_BUCKET:-}" ]; then
  echo "▶  Step 4b: Creating Backblaze B2 bucket and initializing restic repo ..."

  echo ""
  echo "   Object Lock protects backups from deletion (e.g. ransomware) for 30 days."
  echo "   Trade-off: deleting a locked bucket requires the master key + b2 CLI."
  _b2_use_lock=$(ask_yn "   → Enable Object Lock on the bucket? [Y/n]: " "y")

  # Create bucket via B2 API (from developer's machine)
  echo "   Authorizing with Backblaze B2..."
  _b2_authorize() {
    _b2_auth=$(printf 'user = "%s:%s"\n' "$BACKBLAZE_KEY_ID" "$BACKBLAZE_APPLICATION_KEY" | curl -K - -sf --max-time 15 \
      "https://api.backblazeb2.com/b2api/v2/b2_authorize_account") || return 1
    [ -n "$_b2_auth" ]
  }
  _b2_ok=false
  if retry_or_skip "B2 authorization" _b2_authorize; then
    _b2_ok=true
  else
    _failures+=("Backblaze authorization skipped: no bucket or offsite repository set up")
  fi
fi

if [ "${_b2_ok:-false}" = "true" ]; then
  _b2_api_url=$(printf '%s' "$_b2_auth" | jq -r '.apiUrl')
  _b2_auth_token=$(printf '%s' "$_b2_auth" | jq -r '.authorizationToken')
  _b2_real_account_id=$(printf '%s' "$_b2_auth" | jq -r '.accountId')

  if ! _b2_create_bucket; then
    _failures+=("Backblaze bucket not ready: no offsite backups until it is")
    _b2_skip=true
  fi

  if [ "${_b2_skip:-false}" = "true" ]; then
    echo "   ℹ️  Backblaze post-creation steps skipped."
  else

  # Collision retries can change the destination after credentials were uploaded.
  ssh_n8n "_tmp=\$(mktemp)
    grep -v '^RESTIC_REPOSITORY_BACKBLAZE=' ~/n8n/.backup_creds 2>/dev/null > \"\$_tmp\" || true
    printf 'RESTIC_REPOSITORY_BACKBLAZE=rclone:b2:%s\n' '${BACKBLAZE_BUCKET}' >> \"\$_tmp\"
    mv \"\$_tmp\" ~/n8n/.backup_creds
    chmod 600 ~/n8n/.backup_creds"

  # Install rclone; the 'b2' remote is configured via RCLONE_CONFIG_B2_* env at call time, not rclone.conf.
  ssh_n8n "bash /root/n8n/scripts/database/ensure-rclone.sh"

  # 30-day governance: only keys with bypassGovernance can override, which the
  # VPS-side write key lacks — a compromised VPS can't expire snapshots early.
  if [ "$_b2_use_lock" = "y" ] && [ -n "$_b2_bucket_id" ]; then
    echo "   Applying 30-day governance retention to bucket..."
    _b2_lock_resp=$(printf 'header = "Authorization: %s"\n' "$_b2_auth_token" | curl -K - -sf --max-time 15 \
      -d "{\"accountId\":\"${_b2_real_account_id}\",\"bucketId\":\"${_b2_bucket_id}\",\"defaultRetention\":{\"mode\":\"governance\",\"period\":{\"duration\":30,\"unit\":\"days\"}}}" \
      "${_b2_api_url}/b2api/v2/b2_update_bucket" 2>/dev/null || true)
    if [ -n "$_b2_lock_resp" ] && [ "$(printf '%s' "$_b2_lock_resp" | jq -r '.code // empty' 2>/dev/null)" = "" ]; then
      echo "   ✅ Default retention: governance, 30 days."
    else
      echo "   ⚠️  Could not apply default retention (will still work without lock):"
      echo "      ${_b2_lock_resp}"
      _failures+=("Backblaze default retention not applied: snapshots lack the 30-day lock you asked for")
    fi
  fi

  echo "   Initializing Backblaze restic repository: rclone:b2:${BACKBLAZE_BUCKET} ..."
  _b2_restic_init() {
    ssh_n8n "set -a; source ~/n8n/.backup_creds; set +a
      export RESTIC_PASSWORD=\"\$BACKUP_PASSWORD\"
      # Define rclone's 'b2' remote via env — must match setup_restic_b2() in lib/restic-env.sh (the backup cron's path).
      export RCLONE_CONFIG_B2_TYPE=b2 \
             RCLONE_CONFIG_B2_ACCOUNT=\"\$BACKBLAZE_KEY_ID\" \
             RCLONE_CONFIG_B2_KEY=\"\$BACKBLAZE_APPLICATION_KEY\" \
             RCLONE_CONFIG_B2_HARD_DELETE=true
      restic -r 'rclone:b2:${BACKBLAZE_BUCKET}' snapshots > /dev/null 2>&1 \
        || restic -r 'rclone:b2:${BACKBLAZE_BUCKET}' init \
        || restic -r 'rclone:b2:${BACKBLAZE_BUCKET}' snapshots > /dev/null 2>&1"
  }
  if retry_or_skip "Backblaze restic init" _b2_restic_init; then
    echo "✅ Backblaze restic repository ready."
  else
    echo "   ⏭   Backblaze restic init skipped — run manually later."
    _failures+=("Backblaze restic repository not initialized: no offsite backups until it is")
  fi
  fi
fi

# Generate age key + encrypt .env → .env.sops.yaml
echo ""
if [ -f "$ENV_FILE" ]; then
  section_header "SOPS+age secrets encryption"

  _ensure_age_key
  echo "  ✅ .sops.yaml written (age public key: ${_age_pubkey})"

  # Capture CF Access creds before encryption deletes .env — MCP block (below)
  # needs them and can't decrypt mid-flow.
  _mcp_cf_id=$(file_var "$ENV_FILE" "CF_ACCESS_CLIENT_ID")
  _mcp_cf_secret=$(file_var "$ENV_FILE" "CF_ACCESS_CLIENT_SECRET")

  echo "▶  Encrypting .env → .env.sops.yaml ..."
  # Write via tmp + mv: a sops failure must not leave a truncated .env.sops.yaml
  # that a later `git add -A` would commit.
  sops --config "${ROOT_DIR}/.sops.yaml" --input-type dotenv --output-type dotenv -e "$ENV_FILE" > "${ROOT_DIR}/.env.sops.yaml.tmp" \
    && mv "${ROOT_DIR}/.env.sops.yaml.tmp" "${ROOT_DIR}/.env.sops.yaml" \
    || { rm -f "${ROOT_DIR}/.env.sops.yaml.tmp"; echo "❌ sops encryption failed — .env left in place" >&2; exit 1; }
  chmod 600 "${ROOT_DIR}/.env.sops.yaml"
  echo "✅ .env encrypted to .env.sops.yaml"
  rm -f "$ENV_FILE"
  echo "✅ .env deleted."

  echo ""
  echo "  ⚠️  Back up your age private key — it is the ONLY way to decrypt secrets."
  echo "     Key file: ${_age_keyfile}"
  echo "     Save this file as an attachment in your password manager NOW."
  echo ""
  _beep
  printf "  Press Enter once the age key is backed up: " >/dev/tty
  read -r _ </dev/tty

  git -C "$ROOT_DIR" config core.hooksPath .githooks 2>/dev/null || true
  echo "  ✅ Git pre-commit hook wired (.githooks/)."
else
  echo "ℹ️  No .env file found — skipping encryption."
fi

# Commit & push → trigger GitHub Actions deploy
echo ""
echo "▶  Committing initialization files and pushing to trigger CI deploy..."
# Path-limited add AND commit — a pathless commit would take the whole index, so
# any pre-staged/unstaged/untracked WIP would ride this deploy-triggering commit.
_init_files=()
for _f in .env.config .sops.yaml .env.sops.yaml; do
  [ -f "$ROOT_DIR/$_f" ] && _init_files+=("$_f")
done
# The VPS already runs whatever compose files were uploaded; uncommitted pins would make CI roll them back.
while IFS= read -r _f; do
  _init_files+=("$_f")
done < <(git -C "$ROOT_DIR" diff --name-only HEAD -- 'n8n/*docker-compose*.yml')
if [ "${#_init_files[@]}" -eq 0 ]; then
  echo "  ⚠️  No init files found to commit — skipping."
else
  git -C "$ROOT_DIR" add -- "${_init_files[@]}"
  if git -C "$ROOT_DIR" diff --cached --quiet -- "${_init_files[@]}"; then
    echo "  ℹ️  Nothing new to commit — skipping git commit."
  else
    git -C "$ROOT_DIR" commit -m "chore: init ${PROJECT_NAME}" -- "${_init_files[@]}"
    echo "  ✅ Committed."
  fi
fi
_git_push() { git -C "$ROOT_DIR" push -u -- "$GITHUB_PUSH_REMOTE" "${GITHUB_BRANCH:-main}"; }
retry_or_skip "git push ${GITHUB_PUSH_REMOTE} ${GITHUB_BRANCH:-main}" _git_push || {
  echo "  ⚠️  Push skipped — CI deploy will not trigger. Re-run 'npm run initialize' after manual push."
  _failures+=("git push skipped: no CI deploy was triggered")
  _print_failures
  exit 1
}
echo "  ✅ Pushed → GitHub Actions deploy triggered."

# Wait for GitHub Actions deploy to succeed
_github_deploy_get() {
  local response http rc=0
  response=$(printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_PERSONAL_ACCESS_TOKEN" | curl -K - -s "${CURL_TIMEOUTS[@]}" -w '\n%{http_code}' \
    -H "Accept: application/vnd.github+json" "$1" 2>/dev/null) || rc=$?
  http="${response##*$'\n'}"
  if [ "$rc" -ne 0 ] || [ "$http" != 200 ]; then
    printf '  ⚠️  GitHub deploy API request failed (HTTP %s; curl exit %s).\n' "${http:-000}" "$rc" >&2
    case "$http" in
      401|403|404)
        echo "     Check the token and repository permissions, including Actions: Read." >&2
        ;;
    esac
    return 1
  fi
  printf '%s' "${response%$'\n'*}"
}

echo ""
echo "▶  Waiting for GitHub Actions deploy to complete..."
_GH_DEPLOY_TIMEOUT=600
_GH_POLL_INTERVAL=15
_gh_skip_run_id=""  # tracks the last failed/timed-out run so retry skips it
_run_ok=false      # defaults to false in case the outer loop breaks before any run is polled
_gh_dispatched=false
_gh_api_ok=true

while true; do
  # Find the latest run of this exact commit (skip previously-failed run)
  _elapsed=0
  _run_id=""
  _head_sha=$(git -C "$ROOT_DIR" rev-parse HEAD)
  sleep 8  # give GitHub a moment to register the push
  while [ "$_elapsed" -lt 120 ]; do
    if ! _run_json=$(_github_deploy_get \
      "https://api.github.com/repos/${GITHUB_REPO}/actions/workflows/deploy.yml/runs?branch=${GITHUB_BRANCH:-main}&head_sha=${_head_sha}&per_page=1"); then
      _gh_api_ok=false
      break
    fi
    _candidate=$(printf '%s' "$_run_json" | jq -r '.workflow_runs[0].id // empty')
    if [ -n "$_candidate" ] && [ "$_candidate" != "$_gh_skip_run_id" ]; then
      _run_id="$_candidate"; break
    fi
    sleep "$_GH_POLL_INTERVAL"
    _elapsed=$((_elapsed + _GH_POLL_INTERVAL))
  done
  [ "$_gh_api_ok" = true ] || break

  if [ -z "$_run_id" ]; then
    echo "  ⚠️  No new deploy run found for commit ${_head_sha} after 120s."
    echo "     The API answered normally; the push may have contained no changes or [skip ci]."
    printf '     Check '
    print_link "https://github.com/${GITHUB_REPO}/actions"
    if [ "$_gh_dispatched" = "false" ] && [ "$(_check_gh_state)" = "ready" ]; then
      _gh_dispatched=true
      echo "  Triggering deploy automatically..."
      if gh workflow run deploy.yml --repo "$GITHUB_REPO" --ref "${GITHUB_BRANCH:-main}"; then
        continue
      fi
    fi
    break
  fi

  # Poll until the run completes
  echo "  Found run #${_run_id} — polling for completion..."
  _elapsed=0
  _run_ok=false
  _run_concluded=false
  while [ "$_elapsed" -lt "$_GH_DEPLOY_TIMEOUT" ]; do
    if ! _run_json=$(_github_deploy_get "https://api.github.com/repos/${GITHUB_REPO}/actions/runs/${_run_id}"); then
      _gh_api_ok=false
      break
    fi
    _status=$(printf '%s' "$_run_json" \
      | grep -o '"status": *"[^"]*"' | head -1 \
      | grep -o '"[^"]*"$' | tr -d '"') || true
    _conclusion=$(printf '%s' "$_run_json" \
      | grep -o '"conclusion": *"[^"]*"' | head -1 \
      | grep -o '"[^"]*"$' | tr -d '"') || true
    if [ "$_status" = "completed" ]; then
      _run_concluded=true
      if [ "$_conclusion" = "success" ]; then
        echo "  ✅ GitHub Actions deploy succeeded."
        _run_ok=true
      else
        echo ""
        echo "  ❌ Deploy failed (${_conclusion:-unknown}) — run #${_run_id}:"
        printf '     '
        print_link "https://github.com/${GITHUB_REPO}/actions/runs/${_run_id}"
      fi
      break
    fi
    printf "  ... status: %-12s (%ds elapsed)\r" "${_status:-pending}" "$_elapsed"
    sleep "$_GH_POLL_INTERVAL"
    _elapsed=$((_elapsed + _GH_POLL_INTERVAL))
  done
  [ "$_gh_api_ok" = true ] || break

  [ "$_run_ok" = true ] && break

  if [ "$_run_concluded" = false ]; then
    echo ""
    echo "  ⚠️  Timeout (${_GH_DEPLOY_TIMEOUT}s) — run #${_run_id} still running:"
    printf '     '
    print_link "https://github.com/${GITHUB_REPO}/actions/runs/${_run_id}"
  fi

  _gh_skip_run_id="$_run_id"
  printf '\n  Fix the issue, push a commit, then press Enter to retry (Ctrl+C to abort): ' >/dev/tty
  read -r _ </dev/tty
  echo ""
  echo "  Waiting for new GitHub Actions run..."
done
[ "$_run_ok" = true ] || _failures+=("Deploy not confirmed for commit ${_head_sha}")

# Normalize workflow JSON to n8n-assigned IDs (one-time after first push)
# n8n reassigns IDs on fresh init; push upserts by name but pull names files <slug>_<id>.json — sync once to lock real IDs so later pulls don't show rename diffs.
if [ "$_run_ok" = true ]; then
  echo ""
  echo "▶  Normalizing local workflow JSON to n8n-assigned IDs..."
  # The VPS publish poller may have pushed already, so rebase to keep our push a fast-forward.
  git -C "$ROOT_DIR" pull --rebase --autostash -- "$GITHUB_PUSH_REMOTE" "${GITHUB_BRANCH:-main}" >/dev/null 2>&1 || true
  if ! bash "$ROOT_DIR/n8n/scripts/sync-workflows.sh" --pull >/dev/null 2>&1; then
    echo "  ⚠️  Workflow normalize failed. Run 'npm run pull' to see why."
    _failures+=("Workflow JSON not synced to n8n-assigned IDs: run 'npm run pull'")
  elif ! git -C "$ROOT_DIR" diff --quiet -- n8n/workflows/ \
       || [ -n "$(git -C "$ROOT_DIR" ls-files --others --exclude-standard -- n8n/workflows/)" ]; then
    git -C "$ROOT_DIR" add n8n/workflows/
    git -C "$ROOT_DIR" commit -m "Workflows: sync to n8n-assigned IDs [skip ci]" -- n8n/workflows/ >/dev/null
    if git -C "$ROOT_DIR" push -- "$GITHUB_PUSH_REMOTE" "${GITHUB_BRANCH:-main}" >/dev/null 2>&1; then
      echo "  ✅ Renamed workflows committed + pushed ([skip ci] suppresses redeploy)."
    elif git -C "$ROOT_DIR" pull --rebase --autostash -- "$GITHUB_PUSH_REMOTE" "${GITHUB_BRANCH:-main}" >/dev/null 2>&1 \
         && git -C "$ROOT_DIR" push -- "$GITHUB_PUSH_REMOTE" "${GITHUB_BRANCH:-main}" >/dev/null 2>&1; then
      echo "  ✅ Renamed workflows committed + pushed after rebase ([skip ci] suppresses redeploy)."
    else
      echo "  ⚠️  Commit OK but push failed — run 'git pull --rebase && git push' manually."
      _failures+=("Workflow ID commit not pushed: run 'git pull --rebase && git push'")
    fi
  else
    echo "  ℹ️  No workflow rename needed."
  fi
fi

# n8n MCP — capture per-user token + write project-local .mcp.json
# n8n MCP access token is per-user, shown ONCE with no fetch API — paste manually; only after deploy (n8n must be reachable).
if [ "$_run_ok" = true ]; then
  echo ""
  _mcp_url="${WEBHOOK_URL%/}/mcp-server/http"
  _mcp_file="$ROOT_DIR/.mcp.json"
  # CF creds captured pre-encryption (.env is gone by now).
  _cf_id="${_mcp_cf_id:-}"
  _cf_secret="${_mcp_cf_secret:-}"

  if [ -z "$_cf_id" ] || [ -z "$_cf_secret" ]; then
    echo "⚠️  CF_ACCESS_CLIENT_ID/SECRET missing — skipping n8n MCP setup."
    echo "    Run 'npm run init-cloudflare' first if you want Claude Code MCP access."
  else
    _mcp_existing_bearer=""
    _mcp_existing_id=""
    if [ -f "$_mcp_file" ]; then
      _raw_auth=$(jq -r '.mcpServers."n8n-mcp".headers.Authorization // ""' "$_mcp_file" 2>/dev/null || true)
      _mcp_existing_bearer="${_raw_auth#Bearer }"
      _mcp_existing_id=$(jq -r '.mcpServers."n8n-mcp".headers."CF-Access-Client-Id" // ""' "$_mcp_file" 2>/dev/null || true)
    fi

    _need_paste=true
    if [ -n "$_mcp_existing_bearer" ] && [ "${_mcp_existing_id:-}" = "$_cf_id" ]; then
      echo "✅ .mcp.json already configured for this instance — keeping existing n8n token."
      _need_paste=false
    fi

    _n8n_bearer=""
    if [ "$_need_paste" = "true" ]; then
      echo ""
      section_header "ACTION REQUIRED — Generate n8n MCP Access Token"
      echo ""
      printf '  1. Open: '
      print_link "${WEBHOOK_URL}/settings/mcp"
      echo "  2. Toggle 'Enable MCP access' (instance owner / admin required)"
      echo "  3. Click 'Connection details' → 'Access Token' tab"
      echo "  4. Copy the JSON snippet (mcpServers.n8n-mcp.headers.Authorization is the token)"
      echo ""
      echo "  Paste the JSON below. Finish with an empty line:"
      echo ""
      _mcp_paste=""
      _mcp_started=false
      while IFS= read -r _line </dev/tty; do
        if [ "$_mcp_started" = "false" ]; then
          [ -z "$_line" ] && continue  # skip leading blank lines before JSON starts
          _mcp_started=true
        else
          [ -z "$_line" ] && break
        fi
        _mcp_paste+="$_line"$'\n'
      done

      if [ -z "$_mcp_paste" ]; then
        echo "⚠️  Skipped — no JSON pasted. Re-run 'npm run initialize' when ready."
      else
        _raw_auth=$(printf '%s' "$_mcp_paste" \
          | jq -r '.mcpServers."n8n-mcp".headers.Authorization // ""' 2>/dev/null || true)
        _n8n_bearer="${_raw_auth#Bearer }"
        if [ -z "$_n8n_bearer" ]; then
          echo "❌ Could not extract Bearer token from pasted JSON — expected"
          echo "   .mcpServers.\"n8n-mcp\".headers.Authorization. Skipping."
        fi
      fi
    fi

    # Merge: pasted bearer (or kept existing) + current CF service-token headers.
    _final_bearer="${_n8n_bearer:-$_mcp_existing_bearer}"
    if [ -n "$_final_bearer" ]; then
      jq -n --arg url "$_mcp_url" \
            --arg auth "Bearer $_final_bearer" \
            --arg cfid "$_cf_id" \
            --arg cfsec "$_cf_secret" '{
        mcpServers: {
          "n8n-mcp": {
            type: "http",
            url: $url,
            headers: {
              Authorization: $auth,
              "CF-Access-Client-Id": $cfid,
              "CF-Access-Client-Secret": $cfsec
            }
          }
        }
      }' > "$_mcp_file"
      chmod 600 "$_mcp_file"
      echo "✅ Wrote ${_mcp_file#"$ROOT_DIR/"} (gitignored)."

      # Codex has no project-local .mcp.json equivalent — mirror the n8n MCP
      # server into a per-repo .codex/config.toml (native HTTP) for CODEX_HOME.
      _codex_file="$ROOT_DIR/.codex/config.toml"
      mkdir -p "$ROOT_DIR/.codex"
      cat > "$_codex_file" <<CODEX_TOML
# Auto-generated by initialize.sh — Codex MCP parity with .mcp.json.
# Launch: CODEX_HOME="\$PWD/.codex" codex   (gitignored)

[mcp_servers.n8n-mcp]
url = "$_mcp_url"

[mcp_servers.n8n-mcp.http_headers]
Authorization = "Bearer $_final_bearer"
CF-Access-Client-Id = "$_cf_id"
CF-Access-Client-Secret = "$_cf_secret"
CODEX_TOML
      chmod 600 "$_codex_file"
      echo "✅ Wrote ${_codex_file#"$ROOT_DIR/"} (gitignored) — Codex MCP parity."

      # Sanity probe — JSON-RPC initialize handshake. 2xx = both CF Access and
      # n8n MCP accepted the request. 403 = CF blocked; 401 = n8n rejected token.
      echo "▶  Probing MCP endpoint ..."
      _probe_body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"n8n-core-setup-init","version":"1.0"}}}'
      while :; do
        _probe_http=$(printf 'header = "%s"\n' \
          "Authorization: Bearer $_final_bearer" \
          "CF-Access-Client-Id: $_cf_id" \
          "CF-Access-Client-Secret: $_cf_secret" \
          | curl -K - -s -o /dev/null -w '%{http_code}' --max-time 15 \
          -X POST "$_mcp_url" \
          -H "Content-Type: application/json" \
          -H "Accept: application/json, text/event-stream" \
          --data "$_probe_body" 2>/dev/null || true)
        case "$_probe_http" in
          2*)  echo "✅ MCP probe OK (HTTP $_probe_http) — Claude Code can connect via .mcp.json."
               break ;;
          401) echo "❌ MCP probe failed (HTTP 401) — n8n Bearer token rejected."
               printf '     Regenerate at '
               print_link "${WEBHOOK_URL}/settings/mcp" ;;
          403) echo "❌ MCP probe failed (HTTP 403) — Cloudflare Access blocked."
               echo "     Common causes: CF service token not in Access policy, or re-run 'npm run init-cloudflare'." ;;
          000) echo "⚠️  MCP probe — no response; check tunnel + DNS:"
               print_link "$_mcp_url" ;;
          *)   echo "⚠️  MCP probe returned HTTP $_probe_http — inspect manually." ;;
        esac
        while :; do
          printf '  [r]etry probe / [s]kip / [a]bort? ' >/dev/tty
          IFS= read -r _mcp_ans </dev/tty || _mcp_ans=""
          _mcp_ans=$(printf '%s' "$_mcp_ans" | LC_ALL=C tr -cd '[:print:]' | LC_ALL=C tr 'A-Z' 'a-z' | cut -c1)
          case "$_mcp_ans" in
            r) continue 2 ;;
            a) echo "  ✋  Aborted MCP probe." >&2; exit 1 ;;
            s) echo "  ⏭   Skipping MCP probe — .mcp.json was still written."; break 2 ;;
            *) printf "  ⚠️  Expected r / s / a.\n" >/dev/tty ;;
          esac
        done
      done
    fi
  fi
else
  echo "ℹ️  Skipping n8n MCP setup — deploy did not succeed. Re-run 'npm run initialize' after a successful deploy."
fi

# Run tests (against CI-deployed state on VPS)
echo ""
echo "▶  Running environment tests..."
echo ""
TEST_RC=0
bash "${SCRIPT_DIR}/test-environment.sh" || TEST_RC=$?
if [ "$TEST_RC" -ne 0 ]; then
  echo ""
  echo "⚠  Environment tests reported failures (exit ${TEST_RC})."
  echo "   Review the results above — run 'npm test' again after fixes."
  _failures+=("Environment tests reported failures (exit ${TEST_RC}): run 'npm test' after fixes")
fi

echo ""
section_header "Initialization result"
if [ "${#_failures[@]}" -eq 0 ]; then
  echo "✅  Initialization complete!"
else
  _print_failures
fi
echo ""
echo "  Restic repository (local): ${RESTIC_REPOSITORY}"
if [ -n "${BACKBLAZE_BUCKET:-}" ]; then
  echo "  Restic repository (B2):    rclone:b2:${BACKBLAZE_BUCKET}"
fi
echo "  (Backup runs nightly at 02:00, log: /root/n8n/backup.log)"
if [ -n "${RESEND_API_KEY:-}" ]; then
  echo "  Disk space alerts: every hour → ${DEVELOPER_EMAIL} (via Resend)"
  echo "    MEDIUM: ≥${ALERT_DISK_THRESHOLD_MEDIUM:-85}% used   HIGH: ≥${ALERT_DISK_THRESHOLD_HIGH:-95}% used"
  echo "  (Disk check log: /root/n8n/disk-check.log)"
else
  echo "  Disk space alerts: not configured (re-run initialize to enable)"
fi
echo ""
if [ -f "$ROOT_DIR/.mcp.json" ]; then
  echo "  Claude Code MCP:   .mcp.json present — opens this project to enable n8n MCP access"
fi
if [ -f "$ROOT_DIR/.codex/config.toml" ]; then
  echo "  Codex MCP:         .codex/config.toml present — run: CODEX_HOME=\"\$PWD/.codex\" codex"
fi
[ "${#_failures[@]}" -eq 0 ] || exit 1
