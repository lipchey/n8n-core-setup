#!/bin/bash
# Callers must set ENV_CONFIG / ENV_FILE / ENV_LOCAL before using the upsert_* fns.

# Overridable so tests can drive prompts without a controlling terminal.
_PV_TTY_IN="${_PV_TTY_IN:-/dev/tty}"
_PV_TTY_OUT="${_PV_TTY_OUT:-/dev/tty}"

# shellcheck disable=SC2034
CURL_TIMEOUTS=(--connect-timeout 10 --max-time 60)

_GITHUB_TEMPLATE_REPO=lipchey/n8n-core-setup
_GITHUB_REPO_PATTERN='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'

section_header() {
  local title length left right left_dashes right_dashes
  title=$(printf '%s' "$1" | LC_ALL=C tr '[:lower:]' '[:upper:]')
  # Removing UTF-8 continuation bytes counts characters even under the wizard's C locale.
  length=$(printf '%s' "$title" | LC_ALL=C tr -d '\200-\277' | wc -c)
  left=$(((72 - 4 - length) / 2))
  right=$((72 - 4 - length - left))
  printf -v left_dashes '%*s' "$left" ''
  printf -v right_dashes '%*s' "$right" ''
  printf '  %s %s %s\n' "${left_dashes// /─}" "$title" "${right_dashes// /─}"
}

print_link() {
  if [ -t 1 ]; then
    printf '\033]8;;%s\033\\%s\033]8;;\033\\%s\n' "$1" "$1" "${2:-}"
  else
    printf '%s%s\n' "$1" "${2:-}"
  fi
}

_github_repo_from_url() {
  local url authority
  url=$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  case "$url" in
    https://*)
      url="${url#https://}"
      authority="${url%%/*}"
      case "${authority##*@}" in github.com|github.com:443) ;; *) return 1 ;; esac
      url="${url#*/}"
      ;;
    git@github.com:*) url="${url#git@github.com:}" ;;
    ssh://git@github.com/*) url="${url#ssh://git@github.com/}" ;;
    ssh://git@github.com:22/*) url="${url#ssh://git@github.com:22/}" ;;
    ssh://git@ssh.github.com:443/*) url="${url#ssh://git@ssh.github.com:443/}" ;;
    *) return 1 ;;
  esac
  url="${url%/}"
  url="${url%.git}"
  [[ "$url" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ ]] || return 1
  printf '%s' "$url"
}

_check_github_repo_config() {
  local push_repo="$1" configured="${GITHUB_REPO:-}" file value
  shift
  # Env files must not execute before destination validation.
  for file in "$@"; do
    [ -f "$file" ] || continue
    if value=$(awk -F= '$1 == "GITHUB_REPO" { sub(/^[^=]*=/, ""); value=$0; found=1 } END { if (!found) exit 1; print value }' "$file"); then
      configured="$value"
    fi
  done
  case "$configured" in
    \"*\") configured="${configured#\"}"; configured="${configured%\"}" ;;
    \'*\') configured="${configured#\'}"; configured="${configured%\'}" ;;
  esac
  if env_value_is_placeholder "$configured"; then configured=""; fi
  if [ -n "$configured" ]; then
    if [[ "$configured" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
      configured=$(printf '%s' "$configured" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    elif ! configured=$(_github_repo_from_url "$configured"); then
      echo '❌ GITHUB_REPO must be a GitHub owner/repo matching the push remote. Correct the configured value, then re-run.' >&2
      return 1
    fi
    if [ "$configured" != "$push_repo" ]; then
      printf '❌ GITHUB_REPO=%s differs from push remote repository %s. Correct GITHUB_REPO or the push remote, then re-run.\n' "$configured" "$push_repo" >&2
      return 1
    fi
  fi
}

initialize_repo_guard() {
  local root="$1" repo_root remotes branch remote urls url repo push_repo="" invalid=false different=false
  shift
  GITHUB_PUSH_REMOTE="" GITHUB_PUSH_REPO=""
  root=$(cd "$root" && pwd -P) || return 1
  repo_root=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$repo_root" ] && [ "$(cd "$repo_root" && pwd -P)" != "$root" ]; then
    echo '❌ This directory is inside another Git repository. Copy the tree outside that repository, then re-run npm run initialize.' >&2
    return 1
  fi
  remotes=$(git -C "$root" remote 2>/dev/null || true)
  if [ -z "$remotes" ]; then
    if [ "${_initialize_hard_reset:-false}" = true ]; then
      echo '❌ --hard-reset requires an existing GitHub push remote. Configure your private repository remote, then re-run.' >&2
      return 1
    fi
    return 0
  fi
  branch=$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  remote=""
  [ -z "$branch" ] || remote=$(git -C "$root" config --get "branch.$branch.pushRemote" 2>/dev/null || true)
  [ -n "$remote" ] || remote=$(git -C "$root" config --get remote.pushDefault 2>/dev/null || true)
  if [ -z "$remote" ] && [ -n "$branch" ]; then
    remote=$(git -C "$root" config --get "branch.$branch.remote" 2>/dev/null || true)
  fi
  remote="${remote:-origin}"
  if ! urls=$(git -C "$root" remote get-url --push --all -- "$remote" 2>/dev/null) || [ -z "$urls" ]; then
    echo '❌ The selected push remote is missing. Correct your configured remotes before re-running; initialization will not create a repository alongside them.' >&2
    return 1
  fi
  while IFS= read -r url; do
    if ! repo=$(_github_repo_from_url "$url"); then
      invalid=true
      continue
    fi
    if [ "$repo" = "$_GITHUB_TEMPLATE_REPO" ]; then
      echo '❌ The push remote is the public template. Use this template on GitHub, then clone your own repository before initializing.' >&2
      return 1
    fi
    [ -z "$push_repo" ] || [ "$push_repo" = "$repo" ] || different=true
    push_repo="$repo"
  done <<< "$urls"
  if [ "$invalid" = true ]; then
    echo '❌ Every push URL must point to a GitHub repository: deployment requires GitHub Actions. Use git@github.com:owner/repo.git or the HTTPS form below, then re-run.' >&2
    print_link "https://github.com/owner/repo.git" >&2
    return 1
  fi
  if [ "$different" = true ]; then
    echo '❌ Push URLs target different GitHub repositories. Configure one repository for initialization, then re-run.' >&2
    return 1
  fi
  if ! url=$(git -C "$root" remote get-url -- "$remote" 2>/dev/null) \
     || ! repo=$(_github_repo_from_url "$url") || [ "$repo" != "$push_repo" ]; then
    echo '❌ Fetch and push URLs must resolve to the same GitHub repository. Correct the selected remote URLs, then re-run.' >&2
    return 1
  fi
  _check_github_repo_config "$push_repo" "$@" || return 1
  # shellcheck disable=SC2034
  GITHUB_PUSH_REMOTE="$remote" GITHUB_PUSH_REPO="$push_repo"
}

require_private_github_repo() {
  local repo="$1" private
  if private=$(gh api "repos/$repo" --jq .private 2>/dev/null); then
    case "$private" in
      true) return 0 ;;
      false)
        printf '❌ Repository %s is public. Make it private in Settings, or create a new private repo, then re-run.\n' "$repo" >&2
        return 1
        ;;
    esac
  fi
  printf "❌ Repository %s privacy could not be confirmed. Install gh, run 'gh auth login', and ensure your account has access to this repository, then re-run.\n" "$repo" >&2
  return 1
}

ensure_local_repo_ready() {
  local root="$1" branch key has_head=false
  git -C "$root" rev-parse --verify HEAD >/dev/null 2>&1 && has_head=true
  if [ "$has_head" = true ]; then
    branch=$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    if [ "$branch" != main ]; then
      echo '❌ Initialization requires main. Run git switch main (or git branch -M main to rename the current branch), then re-run.' >&2
      return 1
    fi
  fi
  for key in name email; do
    if [ -z "$(git -C "$root" config --get "user.$key" 2>/dev/null)" ]; then
      if [ "$key" = name ]; then
        echo '❌ Initialization needs your Git identity. Run: git config --global user.name "Your Name", then re-run.' >&2
      else
        echo '❌ Initialization needs your Git identity. Run: git config --global user.email "you@example.com", then re-run.' >&2
      fi
      return 1
    fi
  done
  if [ ! -e "$root/.git" ]; then
    git -C "$root" init -b main || return 1
  fi
  if [ "$has_head" = false ]; then
    git -C "$root" symbolic-ref HEAD refs/heads/main || return 1
    git -C "$root" add -A || return 1
    if ! N8N_SKIP_CUSTOM_NODES_GATE=true git -C "$root" -c core.hooksPath=.githooks \
      commit -m "Initial commit from n8n-core-setup"; then
      git -C "$root" rm -r --cached --ignore-unmatch . >/dev/null || return 1
      return 1
    fi
  fi
  if ! git -C "$root" cat-file -e HEAD:.github/workflows/deploy.yml 2>/dev/null; then
    echo '❌ The repository tree is incomplete: .github/workflows/deploy.yml is missing. Copy the template including dotfiles, then re-run.' >&2
    return 1
  fi
}

create_private_github_repo() {
  [ -z "${GITHUB_PUSH_REMOTE:-}" ] || return 0
  initialize_repo_guard "$ROOT_DIR" || return 1
  [ -z "$GITHUB_PUSH_REMOTE" ] || return 0
  local default_repo="${GITHUB_REPO:-}" login
  if [ -z "$default_repo" ]; then
    if ! login=$(gh api user --jq .login); then
      echo "❌ Cannot identify your GitHub account. Run 'gh auth login' with repo and workflow scopes, then re-run npm run initialize." >&2
      return 1
    fi
    default_repo="$login/$PROJECT_NAME"
  fi
  GITHUB_REPO=$(_is_rerun=false prompt_value "GitHub repository (owner/repo)" "$default_repo" \
    "false" "false" "$_GITHUB_REPO_PATTERN") || return 1
  if [ "$(printf '%s' "$GITHUB_REPO" | LC_ALL=C tr '[:upper:]' '[:lower:]')" = "$_GITHUB_TEMPLATE_REPO" ]; then
    echo '❌ The public template cannot be your destination. Choose your own private repository, then re-run.' >&2
    return 1
  fi
  _check_github_repo_config "$(printf '%s' "$GITHUB_REPO" | LC_ALL=C tr '[:upper:]' '[:lower:]')" \
    "$ROOT_DIR/.env.config" "$ROOT_DIR/.env.developer" "$ROOT_DIR/.env" "$ROOT_DIR/.env.local" || return 1
  local auth_headers oauth_scopes
  if ! auth_headers=$(gh api -i user); then
    echo "❌ Cannot check GitHub authentication. Run 'gh auth login' with repo and workflow scopes, then re-run." >&2
    return 1
  fi
  oauth_scopes=$(printf '%s\n' "$auth_headers" | LC_ALL=C awk '
    tolower($0) ~ /^x-oauth-scopes:/ { sub(/^[^:]*:[ \t]*/, ""); gsub(/\r/, ""); print; exit }')
  if printf '%s\n' "$auth_headers" | grep -qi '^x-oauth-scopes:' \
     && ! printf '%s\n' "$oauth_scopes" | tr ',' '\n' | grep -qE '^[[:space:]]*workflow[[:space:]]*$' \
     && [ "$(gh config get git_protocol)" != ssh ]; then
    echo '❌ HTTPS pushes of GitHub Actions need workflow scope. Run: gh auth refresh -s workflow, then re-run.' >&2
    return 1
  fi
  printf '  Creating private GitHub repository %s.\n' "$GITHUB_REPO"
  if ! gh repo create "$GITHUB_REPO" --private --source="$ROOT_DIR" --remote=origin; then
    printf "❌ GitHub repository creation failed (see error above). Check the name, network and gh repo and workflow scopes, or create a private repo yourself, run: git remote add origin git@github.com:%s.git, then re-run npm run initialize.\n" "$GITHUB_REPO" >&2
    return 1
  fi
  initialize_repo_guard "$ROOT_DIR" || return 1
  require_private_github_repo "$GITHUB_PUSH_REPO"
}

# Characters a value in a sourced env file may contain: deploy.yml's .env.config allowlist plus comma.
ENV_VALUE_FORBIDDEN_ERE='[^A-Za-z0-9@._:/+=,-]'

# Pinned to C so a locale cannot widen the A-Z ranges beyond what deploy.yml accepts.
env_value_ok() {
  local LC_ALL=C
  [[ ! "$1" =~ $ENV_VALUE_FORBIDDEN_ERE ]]
}

env_alphabet_hint() {
  cat <<'EOF'
  Allowed in values: letters, digits and @ . _ : / + = , -
  Fix: change the value to use only those, then re-run. Nothing is rewritten for you.
  This means no spaces (a bare sender address a@b.com, not "Name <a@b.com>"), no ? or & in URLs,
  no quotes, ~, $ or Windows line endings (write paths out in full).
EOF
}

# Prints keys and "line N", never values or line content: either may be a secret.
# Sourcing executes every line, so anything but a blank, a comment or KEY=value is reported.
_env_bad_keys() {
  LC_ALL=C awk -F= -v bad="$ENV_VALUE_FORBIDDEN_ERE" '
    /^[ \t]*$/ || /^[ \t]*#/ { next }
    /^[A-Za-z_][A-Za-z0-9_]*=/ { v = $0; sub(/^[^=]*=/, "", v); if (v ~ bad) print $1; next }
    { print "line " FNR }
  ' "$@"
}

# Call before sourcing: stops the run if any existing file is not safe to source.
env_files_check_alphabet() {
  local _f _bad _found=false
  for _f in "$@"; do
    [ -f "$_f" ] || continue
    _bad=$(_env_bad_keys "$_f")
    [ -n "$_bad" ] || continue
    _found=true
    printf '❌ %s: value outside the allowed characters, or a line that is not blank, a comment or KEY=value: %s\n' \
      "$_f" "$(printf '%s' "$_bad" | tr '\n' ' ')" >&2
  done
  [ "$_found" = "true" ] || return 0
  env_alphabet_hint >&2
  exit 1
}

env_value_is_placeholder() {
  case "$1" in auto_generated|paste_*_here) return 0 ;; esac
  return 1
}

load_env_file() {
  [ -f "$1" ] || return 0
  # shellcheck source=/dev/null
  source "$1"
  local _env_key
  while IFS= read -r _env_key; do
    if env_value_is_placeholder "${!_env_key:-}"; then
      unset "$_env_key"
    fi
  done < <(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$1")
}

# Call once, before sourcing, so prompt_value can tell saved keys from values the script defaulted.
env_keys_snapshot() {
  [ -z "${_PV_KEYS_SNAPSHOT_DONE:-}" ] || return 0
  _PV_KEYS_SNAPSHOT_DONE=1
  local _f
  _PV_SAVED_KEYS=""
  for _f in "$@"; do
    [ -f "$_f" ] || continue
    _PV_SAVED_KEYS="$_PV_SAVED_KEYS $(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$_f" | tr '\n' ' ')"
  done
}

# Replays stdin on every attempt: a retried ssh would otherwise read a drained pipe, run an empty
# script and exit 0.
retry_ssh_buffered() {
  local _buf _attempt=1 _max=4 _rc _sleep_for
  # The sentinel keeps trailing newlines that $(...) would strip.
  _buf=$(cat; printf x)
  _buf="${_buf%x}"
  while :; do
    _rc=0
    "$@" < <(printf '%s' "$_buf") || _rc=$?
    if [ "$_rc" -ne 255 ] || [ "$_attempt" -ge "$_max" ]; then
      return "$_rc"
    fi
    _sleep_for=$((_attempt * 3))
    echo "  ⚠ SSH transport failure (exit $_rc) — retrying in ${_sleep_for}s (attempt $_attempt/$_max)..." >&2
    sleep "$_sleep_for"
    _attempt=$((_attempt + 1))
  done
}

# Run a fallible command with bounded auto-retry, then prompt retry/skip/abort.
# Returns 0 on success, the command's exit status on user-skip. Exits the script on user-abort.
retry_or_skip() {
  local _desc="$1"; shift
  local _max=3 _try=1 _rc _ans
  while :; do
    "$@" && return 0
    _rc=$?
    echo "  ⚠️  ${_desc}: failed (exit ${_rc}, attempt ${_try}/${_max})" >&2
    if [ "$_try" -lt "$_max" ]; then
      _try=$((_try + 1))
      sleep 2
      continue
    fi
    while :; do
      printf '  [r]etry / [s]kip / [a]bort? ' >>"$_PV_TTY_OUT"
      read -r _ans <"$_PV_TTY_IN" || _ans=a
      case "${_ans:-r}" in
        r|R|"") _try=1; break ;;
        s|S)    echo "  ⏭   Skipped: ${_desc}" >&2; return "$_rc" ;;
        a|A)    echo "  ✋  Aborted: ${_desc}" >&2; exit 1 ;;
      esac
    done
  done
}

# Read value from stdin, push as a repo Actions secret. Needs GITHUB_REPO.
_push_github_secret() {
  local name="$1"
  command -v gh >/dev/null 2>&1 || return 1
  gh auth status >/dev/null 2>&1 || return 1
  [ -n "${GITHUB_REPO:-}" ] || return 1
  gh secret set "$name" --repo "$GITHUB_REPO" >/dev/null 2>&1
}

# Prints: not_installed | unauthenticated | ready.
_check_gh_state() {
  command -v gh >/dev/null 2>&1 || { printf 'not_installed'; return; }
  if gh auth status >/dev/null 2>&1; then
    printf 'ready'
  else
    printf 'unauthenticated'
  fi
}

# On failure, prints the GitHub API message to stderr so callers don't have to guess.
_gh_warn_from_output() {
  local out="$1" msg
  msg=$(printf '%s' "$out" | jq -r '.message // empty' 2>/dev/null)
  [ -z "$msg" ] && msg=$(printf '%s' "$out" | grep -oE 'message: .*' | head -1)
  [ -z "$msg" ] && msg=$(printf '%s' "$out" | head -1)
  printf '  GitHub API: %s\n' "$msg" >&2
}

# Idempotent. Personal-Free private repos return 422; org repos without GHAS return 403.
_enable_github_push_protection() {
  local repo="$1" out
  [ -n "$repo" ] || return 1
  if ! out=$(gh api -X PATCH "/repos/${repo}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -f 'security_and_analysis[secret_scanning][status]=enabled' \
      -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled' 2>&1); then
    _gh_warn_from_output "$out"
    return 1
  fi
}

_clipboard_copy() {
  if command -v pbcopy >/dev/null 2>&1; then
    pbcopy; echo "pbcopy"; return 0
  elif command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard; echo "xclip"; return 0
  elif command -v xsel >/dev/null 2>&1; then
    xsel --clipboard --input; echo "xsel"; return 0
  else
    cat > /dev/null; echo "none"; return 0
  fi
}

# Crash-safe upsert: writes immediately so prior progress isn't lost on Ctrl+C.
# awk -F= with literal $1==k avoids regex-metachar bugs if a future caller passes a key with `.`/`*`.
upsert_env_config() {
  local key="$1" value="$2"
  [ -f "$ENV_CONFIG" ] || touch "$ENV_CONFIG"
  local tmp; tmp=$(mktemp)
  awk -F= -v k="$key" '$1 != k' "$ENV_CONFIG" > "$tmp"
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$ENV_CONFIG"
}

upsert_env() {
  local key="$1" value="$2"
  [ -f "$ENV_FILE" ] || touch "$ENV_FILE"
  local tmp; tmp=$(mktemp)
  awk -F= -v k="$key" '$1 != k' "$ENV_FILE" > "$tmp"
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$ENV_FILE"
}

upsert_env_local() {
  local key="$1" value="$2"
  [ -f "$ENV_LOCAL" ] || touch "$ENV_LOCAL"
  local tmp; tmp=$(mktemp)
  awk -F= -v k="$key" '$1 != k' "$ENV_LOCAL" > "$tmp"
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$ENV_LOCAL"
}

# Re-appends KEY=value lines from $backup not already in $file. Used by initialize.sh
# after rewriting .env / .env.config from a boilerplate template — preserves
# project-added keys (e.g. STRIPE_*, integration API tokens) on re-run.
_preserve_unknown_env_keys() {
  local file="$1" backup="$2"
  [ -f "$file" ]   || return 0
  [ -f "$backup" ] || return 0
  local preserved
  preserved=$(awk -F= -v cur="$file" '
    BEGIN {
      while ((getline line < cur) > 0) {
        if (line ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
          eq = index(line, "=")
          known[substr(line, 1, eq-1)] = 1
        }
      }
      close(cur)
    }
    /^(ALERTS_TELEGRAM_BOT_TOKEN|ALERTS_TELEGRAM_CHAT_ID|N8N_LOGIN_EMAIL|N8N_LOGIN_PASSWORD)=/ { next }
    /^[A-Za-z_][A-Za-z0-9_]*=/ && !($1 in known) { print }
  ' "$backup")
  local _bad
  _bad=$(printf '%s\n' "$preserved" | _env_bad_keys)
  if [ -n "$_bad" ]; then
    # Written through so the file keeps its mode; the backup is a plaintext copy of secrets.
    cat "$backup" > "$file" || {
      printf '❌ %s: could not restore it; the previous content is still at %s\n' "$file" "$backup" >&2
      exit 1
    }
    rm -f "$backup"
    printf '❌ %s: restored as it was, value outside the allowed characters for: %s\n' \
      "$file" "$(printf '%s' "$_bad" | tr '\n' ' ')" >&2
    env_alphabet_hint >&2
    exit 1
  fi
  if [ -n "$preserved" ]; then
    {
      printf '\n# ─── Preserved from previous file (keys not in template) ─────\n'
      printf '%s\n' "$preserved"
    } >> "$file"
  fi
}

file_var() {
  local file="$1" key="$2" value
  # awk -v with strict $1==key sidesteps regex-metachar bugs in $key.
  [ -f "$file" ] || return 0
  value=$(awk -F= -v k="$key" '$1==k { sub(/^[^=]*=/, ""); val=$0; found=1 } END { if (found) print val }' "$file") || return 1
  env_value_is_placeholder "$value" || printf '%s' "$value"
}

validate_ssh_private_key() {
  local key="$1" project="${PROJECT_NAME:-}"
  key="${key/#\~/$HOME}"
  if [ -f "$key" ] && [ -r "$key" ] && ssh-keygen -y -P '' -f "$key" >/dev/null 2>&1; then
    return 0
  fi
  if [ -z "$project" ] && [ -n "${ENV_CONFIG:-}" ]; then project=$(file_var "$ENV_CONFIG" PROJECT_NAME); fi
  printf '❌ SSH private key %s is missing, unreadable or requires a passphrase; GitHub Actions needs a key usable without a passphrase.\n' "${key:-for the selected public key}" >&2
  printf 'Create a dedicated key: ssh-keygen -t ed25519 -f ~/.ssh/%s_deploy -N ""\n' "${project:-n8n}" >&2
  return 1
}

resolve_timezone() {
  local answer="$1" zones="${ZONEINFO_DIR:-/usr/share/zoneinfo}" city path zone
  local matches=()
  local zone_re='^[A-Za-z_]+(/[A-Za-z0-9_+-]+){0,2}$'
  if [[ "$answer" =~ $zone_re ]] && env_value_ok "$answer"; then
    case "$answer" in
      posix/*|right/*) ;;
      *) if [ -f "$zones/$answer" ]; then printf '%s' "$answer"; return 0; fi ;;
    esac
  fi
  city="${answer// /_}"
  if [[ "$city" =~ ^[A-Za-z0-9_+-]+$ ]]; then
    while IFS= read -r path; do
      zone="${path#"$zones"/}"
      if [[ "$zone" =~ $zone_re ]] && env_value_ok "$zone"; then matches+=("$zone"); fi
    done < <(find -L "$zones" -type d \( -path "$zones/posix" -o -path "$zones/right" \) -prune -o -type f -iname "$city" -print | LC_ALL=C sort)
  fi
  if [ "${#matches[@]}" -eq 1 ]; then
    printf '→ Using timezone: %s\n' "${matches[0]}" >>"$_PV_TTY_OUT"
    printf '%s' "${matches[0]}"
    return 0
  elif [ "${#matches[@]}" -gt 1 ]; then
    printf 'Several timezones match; enter one of these Region/City names:\n' >>"$_PV_TTY_OUT"
    printf '  %s\n' "${matches[@]}" >>"$_PV_TTY_OUT"
  else
    printf 'No matching timezone; try the nearest large city or a Region/City name.\n' >>"$_PV_TTY_OUT"
  fi
  return 1
}

prompt_timezone() {
  local default="${DISPLAY_TZ:-}" answer resolved validator="$1"
  if [ "${_is_rerun:-false}" = true ] && _pv_key_saved DISPLAY_TZ \
     && [[ "$default" =~ $validator ]] && env_value_ok "$default"; then
    printf '  ✓ City or timezone: %s [existing]\n' "$default" >>"$_PV_TTY_OUT"
    printf '%s' "$default"
    return 0
  fi
  if [ -z "$default" ]; then
    default=$(readlink /etc/localtime 2>/dev/null) || default=""
    case "$default" in *zoneinfo/*) default="${default#*zoneinfo/}" ;; *) default=UTC ;; esac
    if ! [[ "$default" =~ $validator ]] || ! env_value_ok "$default"; then default=UTC; fi
  fi
  printf 'Your timezone sets when scheduled workflows and server jobs run.\n' >>"$_PV_TTY_OUT"
  while true; do
    printf '  → City or timezone (e.g. Berlin, New York, Europe/Berlin) [%s]: ' "$default" >>"$_PV_TTY_OUT"
    IFS= read -r answer <"$_PV_TTY_IN" || return 1
    if resolved=$(resolve_timezone "${answer:-$default}"); then printf '%s' "$resolved"; return 0; fi
  done
}

# Returns y or n; empty defaults to n.
ask_yn() {
  local _prompt="$1" _default="${2:-n}" _ans
  while true; do
    printf '%s' "$_prompt" >>"$_PV_TTY_OUT"
    if ! IFS= read -r _ans <"$_PV_TTY_IN"; then
      return 1
    fi
    [ -z "$_ans" ] && _ans="$_default"
    _ans=$(printf '%s' "$_ans" | LC_ALL=C tr -cd 'a-zA-Z' | cut -c1 | LC_ALL=C tr 'A-Z' 'a-z')
    case "$_ans" in
      y) printf 'y'; return ;;
      n) printf 'n'; return ;;
      *) printf '  ⚠️  Please enter y or n.\n' >>"$_PV_TTY_OUT" ;;
    esac
  done
}

_pv_key_saved() {
  case " ${_PV_SAVED_KEYS:-} " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

_read_secret_chars() {
  local _secret_char
  while true; do
    _secret_char=""
    if ! IFS= read -r -n 1 _secret_char <&8; then return 1; fi
    case "$_secret_char" in
      ''|$'\r') return 0 ;;
      $'\004') return 1 ;;
      $'\003') return 130 ;;
      $'\177'|$'\010')
        if [ -n "$_secret_value" ]; then
          _secret_value="${_secret_value%?}"
          printf '\b \b' >>"$_PV_TTY_OUT"
        fi
        ;;
      *) _secret_value="$_secret_value$_secret_char"; printf '*' >>"$_PV_TTY_OUT" ;;
    esac
  done
}

read_secret() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  local _secret_result _secret_status=0 _secret_traps
  _secret_traps=$(trap -p INT TERM HUP)
  trap '_secret_status=130' INT
  trap '_secret_status=143' TERM
  trap '_secret_status=129' HUP
  _secret_result=$(
    exec 8<"$_PV_TTY_IN" || exit 1
    _secret_value=""
    _secret_state=$(stty -g <&8 2>/dev/null) || _secret_state=""
    # A subshell keeps caller traps intact and restores after Bash unwinds its read state.
    trap '[ -z "$_secret_state" ] || stty "$_secret_state" <&8; printf "\n" >>"$_PV_TTY_OUT"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    if [ -n "$_secret_state" ]; then stty -echo -icanon min 1 time 0 <&8 || exit 1; fi
    _secret_status=0
    _read_secret_chars || _secret_status=$?
    printf '%s' "$_secret_value"
    exit "$_secret_status"
  ) || _secret_status=$?
  trap - INT TERM HUP
  eval "$_secret_traps"
  printf -v "$1" '%s' "$_secret_result"
  return "$_secret_status"
}

# Usage: val=$(prompt_value "Description" "$default" [is_secret=false] [allow_empty=false] [validator_ere] [key_name])
# validator_ere: an answer must match it, otherwise re-prompt; an allowed empty answer skips it.
# key_name: a re-run accepts the default silently only if env_keys_snapshot saw this key.
prompt_value() {
  local desc="$1" default="$2" is_secret="${3:-false}" allow_empty="${4:-false}" validator="${5:-}" key_name="${6:-}"
  local display_default="" _pv_input _pv_value
  [ -n "$default" ] && { [ "$is_secret" = "true" ] && display_default="***" || display_default="$default"; }

  # Re-run: existing value accepted without prompting.
  if [ "${_is_rerun:-false}" = "true" ] && [ -n "$default" ] \
     && { [ -z "$key_name" ] || _pv_key_saved "$key_name"; } \
     && env_value_ok "$default" \
     && { [ -z "$validator" ] || [[ "$default" =~ $validator ]]; }; then
    if [ "$is_secret" = "true" ]; then
      printf '  ✓ %s [existing]\n' "$desc" >>"$_PV_TTY_OUT"
    else
      printf '  ✓ %s: %s [existing]\n' "$desc" "$default" >>"$_PV_TTY_OUT"
    fi
    printf '%s' "$default"
    return 0
  fi

  while true; do
    if [ -n "$display_default" ]; then
      printf '  → %s \033[90m[%s]\033[0m: ' "$desc" "$display_default" >>"$_PV_TTY_OUT"
    else
      printf '  → %s: ' "$desc" >>"$_PV_TTY_OUT"
    fi
    # Without this guard, a closed /dev/tty (no controlling terminal) silently
    # produces empty input and a required-value prompt loops forever.
    if [ "$is_secret" = "true" ]; then
      if ! read_secret _pv_input; then
        echo "❌ prompt_value: /dev/tty unavailable — cannot read '${desc}' interactively" >&2
        exit 1
      fi
    elif ! IFS= read -r _pv_input <"$_PV_TTY_IN"; then
      echo "❌ prompt_value: /dev/tty unavailable — cannot read '${desc}' interactively" >&2
      exit 1
    fi

    _pv_value="${_pv_input:-$default}"
    if [ -z "$_pv_value" ]; then
      if [ "$allow_empty" = "true" ]; then
        printf ''
        return 0
      fi
      printf '  ⚠️  Required — please enter a value.\n' >>"$_PV_TTY_OUT"
    elif ! env_value_ok "$_pv_value"; then
      env_alphabet_hint >>"$_PV_TTY_OUT"
    elif [ -n "$validator" ] && ! [[ "$_pv_value" =~ $validator ]]; then
      printf '  ⚠️  Invalid format — must match: %s\n' "$validator" >>"$_PV_TTY_OUT"
    else
      printf '%s' "$_pv_value"
      return 0
    fi
  done
}

# Audible cue before a prompt. afplay → osascript → \a. Backgrounded.
_beep() {
  local _snd="/System/Library/Sounds/Glass.aiff"
  if command -v afplay >/dev/null 2>&1; then
    ( afplay "$_snd" >/dev/null 2>&1 & ) || true
  elif command -v osascript >/dev/null 2>&1; then
    osascript -e 'beep' 2>/dev/null &
  else
    printf '\a' >/dev/tty 2>/dev/null || true
  fi
}

# Usage: pick_number "prompt" count [default]
pick_number() {
  local prompt="$1" count="$2" default="${3:-}" choice
  # An empty list would make the range check unsatisfiable → infinite prompt loop.
  if [ "$count" -lt 1 ]; then
    echo "❌ pick_number: empty list (API returned no options) — aborting" >&2
    exit 1
  fi
  if [ "$count" -eq 1 ] && [ "${4:-false}" != true ]; then
    printf '1'
    return
  fi
  while true; do
    printf '%b' "$prompt" >>"$_PV_TTY_OUT"
    if ! read -r choice <"$_PV_TTY_IN"; then
      echo "❌ pick_number: /dev/tty unavailable — cannot pick interactively" >&2
      exit 1
    fi
    [ -z "$choice" ] && [ -n "$default" ] && { printf '%s' "$default"; return; }
    case "$choice" in
      ''|*[!0-9]*) ;;
      *) [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ] && { printf '%s' "$choice"; return; } ;;
    esac
    printf '  ⚠️  Enter a number between 1 and %d\n' "$count" >>"$_PV_TTY_OUT"
  done
}

