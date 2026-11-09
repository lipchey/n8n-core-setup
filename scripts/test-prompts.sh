#!/bin/bash
# shellcheck disable=SC2034
# Stubs the tty paths, sleep, curl, ssh and PATH tools: must never reach the network, real env files or the clipboard.
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-prompts.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
mktemp() { command mktemp "$TMP/tmp.XXXXXX"; }
export HOME="$TMP/home"
mkdir -p "$HOME"
ENV_FILE="$TMP/.env"
ENV_CONFIG="$TMP/.env.config"
ENV_LOCAL="$TMP/.env.local"
TTY="$TMP/tty"
_PV_TTY_IN=/dev/fd/3
_PV_TTY_OUT="$TTY"
: > "$TTY"

# shellcheck source=lib/prompts.sh
source "$ROOT_DIR/scripts/lib/prompts.sh"

sleep() { printf '%s\n' "$1" >> "$TMP/sleeps"; }

checks=0
fails=0
_fail() { fails=$((fails + 1)); printf '  FAIL %s\n' "$1" >&2; shift; printf '       %s\n' "$@" >&2; }
eq() {
  checks=$((checks + 1))
  [ "$2" = "$3" ] || _fail "$1" "expected: [$2]" "got:      [$3]"
}
has() {
  checks=$((checks + 1))
  case "$3" in *"$2"*) ;; *) _fail "$1" "missing: [$2]" "in: [$3]" ;; esac
}
hasnt() {
  checks=$((checks + 1))
  case "$3" in *"$2"*) _fail "$1" "unexpected: [$2]" "in: [$3]" ;; esac
}

# Answers go through a pipe so successive reads consume them in order and EOF ends a stuck prompt.
pv() {
  local _answers="$1"; shift
  : > "$TTY"
  prompt_value "$@" 3< <(printf '%b' "$_answers")
}
tty_text() { cat "$TTY"; }

reset_snapshot() { _PV_KEYS_SNAPSHOT_DONE=""; _PV_SAVED_KEYS=""; }

for answer in '123\nn\n' ' \nn\n'; do
  got=$(ask_yn 'Create? [Y/n]: ' y 3< <(printf '%b' "$answer"))
  eq 'default yes: invalid input retries instead of accepting the default' n "$got"
done

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ALLOW_PROTOCOL=file GIT_CEILING_DIRECTORIES="$TMP"
unset GITHUB_REPO
guard_root="$TMP/guard-repo"
new_guard_repo() {
  rm -rf "$guard_root"
  git init -q "$guard_root" || exit 1
  git -C "$guard_root" symbolic-ref HEAD refs/heads/main
}
probe_guard() {
  initialize_repo_guard "$guard_root" "$@" || return
  printf '%s|%s' "$GITHUB_PUSH_REMOTE" "$GITHUB_PUSH_REPO"
}
template_repo=lipchey/n8n-core-setup
for repo in "$template_repo" acme/project; do
  for url in "git@github.com:$repo.git" "git@github.com:$repo" \
    "https://github.com/$repo" "https://github.com/$repo.git" \
    "https://github.com/$repo/" "https://github.com/$repo.git/" \
    "ssh://git@github.com/$repo.git" "ssh://git@ssh.github.com:443/$repo.git" \
    "https://github.com:443/$repo.git" "ssh://git@github.com:22/$repo.git" \
    "https://guard-user:guard-password@github.com:443/$repo.git" \
    "https://guard-user:guard-password@github.com/$repo.git"; do
    new_guard_repo
    git -C "$guard_root" remote add origin "$url"
    err=$(probe_guard 2>&1); rc=$?
    if [ "$repo" = "$template_repo" ]; then
      eq "remote guard: template URL is refused" "1" "$rc"
      has "remote guard: explains template creation" "Use this template" "$err"
      has "remote guard: explains cloning" "clone your own" "$err"
    else
      eq "remote guard: own repository URL is allowed" "0" "$rc"
      eq "remote guard: normalizes own repository" "origin|acme/project" "$err"
    fi
    hasnt "remote guard: never prints URL credentials" "guard-password" "$err"
    hasnt "remote guard: never prints URL username" "guard-user" "$err"
  done
done

new_guard_repo
err=$(probe_guard 2>&1); rc=$?
eq "remote guard: no remote allows creation" "0" "$rc"
eq "remote guard: no remote clears destination" "|" "$err"
err=$(_initialize_hard_reset=true probe_guard 2>&1); rc=$?
eq "remote guard: hard reset without remote stops" "1" "$rc"
has "remote guard: hard reset explains remote requirement" "--hard-reset" "$err"
rm -rf "$guard_root/.git"
eq "remote guard: no git allows creation" "|" "$(probe_guard)"
err=$(_initialize_hard_reset=true probe_guard 2>&1); rc=$?
eq "remote guard: hard reset without git stops" "1" "$rc"
new_guard_repo
git -C "$guard_root" remote add upstream https://github.com/acme/project.git
err=$(probe_guard 2>&1); rc=$?
eq "remote guard: another remote without origin stops" "1" "$rc"
has "remote guard: missing selected remote explains fix" "remote" "$err"
new_guard_repo
mkdir -p "$guard_root/child"
err=$(initialize_repo_guard "$guard_root/child" 2>&1); rc=$?
eq "remote guard: nested directory stops" "1" "$rc"
has "remote guard: nested directory explains parent repository" "inside another Git repository" "$err"
ln -s "$guard_root" "$TMP/guard-link"
eq "remote guard: physical root accepts symlink" "|" "$(initialize_repo_guard "$TMP/guard-link" && printf '%s|%s' "$GITHUB_PUSH_REMOTE" "$GITHUB_PUSH_REPO")"
git -C "$guard_root" remote add origin https://example.com/acme/project.git
err=$(probe_guard 2>&1); rc=$?
eq "remote guard: non-GitHub stops" "1" "$rc"
has "remote guard: non-GitHub explains Actions requirement" "GitHub Actions" "$err"
git -C "$guard_root" remote set-url origin git@github-work:me/proj.git
err=$(probe_guard 2>&1); rc=$?
eq "remote guard: unverifiable SSH alias stops" "1" "$rc"
has "remote guard: alias refusal shows accepted SSH form" "git@github.com:owner/repo.git" "$err"
has "remote guard: alias refusal shows accepted HTTPS form" "https://github.com/owner/repo.git" "$err"
for url in https://github.com.evil.invalid/acme/project.git \
  https://github.com.evil.com/acme/project.git https://github.com:444/acme/project.git \
  https://github.com@evil.com/acme/project.git ssh://git@github.com:23/acme/project.git \
  https://evil.invalid/path@github.com/acme/project.git /tmp/acme/project acme/project; do
  git -C "$guard_root" remote set-url origin "$url"
  probe_guard >/dev/null 2>&1; eq "remote guard: rejects lookalike or local URL" "1" "$?"
done

git -C "$guard_root" remote set-url origin "https://github.com/$template_repo.git"
git -C "$guard_root" remote set-url --push origin https://github.com/acme/project.git
err=$(probe_guard 2>&1); rc=$?
eq "remote guard: template fetch with own push stops" "1" "$rc"
has "remote guard: fetch mismatch explains the fix" "Fetch and push URLs must resolve to the same GitHub repository" "$err"
git -C "$guard_root" remote set-url origin https://guard-user:guard-password@github.com/other/project.git
err=$(probe_guard 2>&1); rc=$?
eq "remote guard: different fetch repository stops" "1" "$rc"
hasnt "remote guard: fetch credentials stay private" "guard-password" "$err"
hasnt "remote guard: fetch username stays private" "guard-user" "$err"
git -C "$guard_root" remote set-url origin https://example.com/acme/project.git
probe_guard >/dev/null 2>&1; eq "remote guard: non-GitHub fetch with own push stops" "1" "$?"
git -C "$guard_root" remote set-url --push --delete origin '.*'
git -C "$guard_root" remote set-url origin https://github.com/Acme/Project.git
GITHUB_REPO=ACME/PROJECT probe_guard >/dev/null 2>&1
eq "remote guard: configured comparison ignores case" "0" "$?"
err=$(GITHUB_REPO=other/project probe_guard 2>&1); rc=$?
eq "remote guard: configured mismatch stops" "1" "$rc"
has "remote guard: mismatch names configured repo" "other/project" "$err"
has "remote guard: mismatch names push repo" "acme/project" "$err"
err=$(GITHUB_REPO=https://guard-user:guard-password@github.com/other/project.git probe_guard 2>&1)
hasnt "remote guard: configured URL credentials stay private" "guard-password" "$err"
has "remote guard: configured URL mismatch is normalized" "other/project" "$err"
printf 'GITHUB_REPO=other/saved\n' > "$TMP/guard.config"
err=$(probe_guard "$TMP/guard.config" 2>&1); rc=$?
eq "remote guard: saved mismatch stops before sourcing" "1" "$rc"
has "remote guard: saved mismatch names configured repo" "other/saved" "$err"
printf 'GITHUB_REPO=Acme/Project\n' > "$TMP/guard.local"
probe_guard "$TMP/guard.config" "$TMP/guard.local" >/dev/null 2>&1
eq "remote guard: last sourced file wins" "0" "$?"
printf 'GITHUB_REPO="Acme/Project"\n' > "$TMP/guard.local"
probe_guard "$TMP/guard.local" >/dev/null 2>&1
eq "remote guard: quoted developer default works" "0" "$?"

git -C "$guard_root" remote add upstream "https://github.com/$template_repo.git"
git -C "$guard_root" config branch.main.remote upstream
probe_guard >/dev/null 2>&1; eq "remote guard: branch remote is checked" "1" "$?"
git -C "$guard_root" config remote.pushDefault origin
eq "remote guard: pushDefault overrides branch remote" "origin|acme/project" "$(probe_guard)"
git -C "$guard_root" config branch.main.pushRemote upstream
probe_guard >/dev/null 2>&1; eq "remote guard: branch pushRemote overrides pushDefault" "1" "$?"
git -C "$guard_root" config branch.main.pushRemote origin
eq "remote guard: branch pushRemote is allowed" "origin|acme/project" "$(probe_guard)"
git -C "$guard_root" remote set-url --push origin https://github.com/acme/project.git
git -C "$guard_root" remote set-url --add --push origin "https://github.com/$template_repo.git"
err=$(probe_guard 2>&1); rc=$?
eq "remote guard: any template push URL stops" "1" "$rc"
has "remote guard: second push URL explains template creation" "Use this template" "$err"
git -C "$guard_root" remote set-url --push --delete origin '.*'
git -C "$guard_root" remote set-url --push origin https://github.com/acme/project.git
git -C "$guard_root" remote set-url --add --push origin git@github.com:Acme/Project.git
eq "remote guard: equivalent push URLs are allowed" "origin|acme/project" "$(probe_guard)"
git -C "$guard_root" remote set-url --add --push origin https://github.com/other/project.git
probe_guard >/dev/null 2>&1; eq "remote guard: different push repositories stop" "1" "$?"
git -C "$guard_root" remote set-url --push --delete origin '.*'
git -C "$guard_root" remote set-url --push origin https://example.com/acme/project.git
git -C "$guard_root" remote set-url --add --push origin "https://github.com/$template_repo.git"
err=$(probe_guard 2>&1)
has "remote guard: template is found after a non-GitHub URL" "Use this template" "$err"
git -C "$guard_root" remote set-url --push --delete origin '.*'
git -C "$guard_root" remote set-url --push origin "https://github.com/$(printf '%s' "$template_repo" | tr '[:lower:]' '[:upper:]').git/"
probe_guard >/dev/null 2>&1; eq "remote guard: template comparison ignores case" "1" "$?"

new_guard_repo
git -C "$guard_root" remote add origin "https://github.com/$template_repo.git"
git -C "$guard_root" remote add own git@github.com:acme/project.git
git -C "$guard_root" config branch.main.remote own
eq "remote guard: branch remote selects own repository over template origin" "own|acme/project" "$(probe_guard)"

mkdir -p "$TMP/privacy-bin"
cat > "$TMP/privacy-bin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" > "$PRIVACY_ARGS"
printf '%s' "$PRIVACY_OUTPUT"
exit "$PRIVACY_RC"
EOF
chmod +x "$TMP/privacy-bin/gh"
for privacy_output in true false unknown ''; do
  err=$(PATH="$TMP/privacy-bin:$PATH" PRIVACY_ARGS="$TMP/privacy.args" \
    PRIVACY_OUTPUT="$privacy_output" PRIVACY_RC=0 require_private_github_repo acme/project 2>&1); rc=$?
  if [ "$privacy_output" = true ]; then
    eq "private repository: true continues" "0" "$rc"
  else
    eq "private repository: [$privacy_output] stops" "1" "$rc"
    if [ "$privacy_output" = false ]; then
      has "private repository: public refusal names repository" "acme/project" "$err"
      has "private repository: public refusal explains settings" "Settings" "$err"
      has "private repository: public refusal explains replacement" "new private repo" "$err"
    else
      has "private repository: unknown privacy is explicit" "privacy could not be confirmed" "$err"
      has "private repository: unknown privacy explains gh access" "gh auth login" "$err"
    fi
  fi
done
err=$(PATH="$TMP/privacy-bin:$PATH" PRIVACY_ARGS="$TMP/privacy.args" \
  PRIVACY_OUTPUT=true PRIVACY_RC=1 require_private_github_repo acme/project 2>&1); rc=$?
eq "private repository: API failure stops even with true output" "1" "$rc"
has "private repository: API failure explains gh access" "gh auth login" "$err"
eq "private repository: queries the normalized destination" "api repos/acme/project --jq .private" "$(cat "$TMP/privacy.args" 2>/dev/null)"
has "private repository: wizard checks immediately after guard" \
  $'initialize_repo_guard "$ROOT_DIR" || exit 1\nrequire_private_github_repo "$GITHUB_PUSH_REPO" || exit 1' \
  "$(sed 's/^  //' "$ROOT_DIR/scripts/initialize.sh")"

create_root="$TMP/create project"
mkdir -p "$TMP/create-bin"
cat > "$TMP/create-bin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CREATE_CALLS"
case "$1 $2" in
  'api user') printf 'fixture-owner\n' ;;
  'api -i') printf '%s\n' "${CREATE_SCOPES:-X-OAuth-Scopes: repo, workflow}" ;;
  'config get') printf '%s\n' "${CREATE_PROTOCOL:-https}" ;;
  'api repos/'*) printf '%s\n' "${CREATE_PRIVATE:-true}" ;;
  'repo create')
    if [ "${CREATE_RC:-0}" != 0 ]; then
      printf 'Repository name already exists\n' >&2
      exit "$CREATE_RC"
    fi
    repo="$3"; source_dir=""
    for arg in "$@"; do
      case "$arg" in --source=*) source_dir="${arg#--source=}" ;; esac
    done
    [ "$source_dir" = "$CREATE_ROOT" ] || exit 98
    git -C "$source_dir" remote add origin "https://github.com/$repo.git"
    ;;
  *) exit 99 ;;
esac
EOF
chmod +x "$TMP/create-bin/gh"
new_create_tree() {
  rm -rf "$create_root"
  mkdir -p "$create_root/.github/workflows" "$create_root/.githooks"
  cp "$ROOT_DIR/.github/workflows/deploy.yml" "$create_root/.github/workflows/"
  cp "$ROOT_DIR/.githooks/pre-commit" "$create_root/.githooks/"
  cat > "$create_root/.gitignore" <<'EOF'
.env
.env.*
!.env.config
!.env.example
!.env.developer.example
!.env.sops.yaml
EOF
  printf 'template\n' > "$create_root/README.md"
  printf 'ignored fixture\n' > "$create_root/.env"
  printf 'ignored fixture\n' > "$create_root/.env.local"
  printf '[user]\nname = Fixture\nemail = fixture@example.invalid\n[core]\nhooksPath = /dev/null\n' > "$TMP/create.gitconfig"
  : > "$TMP/create.calls"
  : > "$TTY"
}
probe_create() (
  ROOT_DIR="$create_root"; PROJECT_NAME=project
  GITHUB_REPO="${CREATE_SAVED_REPO:-}"; GITHUB_PUSH_REMOTE="${CREATE_PUSH_REMOTE:-}"
  _is_rerun="${CREATE_RERUN:-false}"; _PV_SAVED_KEYS=" GITHUB_REPO "
  unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL EMAIL
  export GIT_CONFIG_GLOBAL="$TMP/create.gitconfig"
  export PATH="$TMP/create-bin:$PATH" CREATE_ROOT="$create_root" CREATE_CALLS="$TMP/create.calls"
  if [ "${CREATE_PREPARE:-true}" = true ]; then
    initialize_repo_guard "$ROOT_DIR" || return
    ensure_local_repo_ready "$ROOT_DIR" || return
  fi
  create_private_github_repo || return
  printf '%s|%s|%s' "$GITHUB_REPO" "$GITHUB_PUSH_REMOTE" "$GITHUB_PUSH_REPO"
)
create_commit_count() { git -C "$create_root" rev-list --count HEAD 2>/dev/null || true; }
init_create_repo() { git init -q -b "${1:-main}" "$create_root"; }
commit_create_repo() {
  git -C "$create_root" add -A
  git -C "$create_root" -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c core.hooksPath=/dev/null commit -qm fixture
}

for initial_state in no-git unborn committed; do
  new_create_tree
  if [ "$initial_state" != no-git ]; then init_create_repo; fi
  before_head=""
  if [ "$initial_state" = committed ]; then
    commit_create_repo
    before_head=$(git -C "$create_root" rev-parse HEAD)
    printf 'work in progress\n' > "$create_root/untracked.txt"
  fi
  err=$(probe_create 3< <(printf '\ny\n') 2>&1); rc=$?
  eq "repo creation: $initial_state succeeds" "0" "$rc"
  has "repo creation: $initial_state resolves destination" "fixture-owner/project|origin|fixture-owner/project" "$err"
  eq "repo creation: $initial_state has one commit" "1" "$(create_commit_count)"
  eq "repo creation: $initial_state uses main" "main" "$(git -C "$create_root" branch --show-current 2>/dev/null)"
  if [ "$initial_state" = committed ]; then
    eq "repo creation: existing HEAD is unchanged" "$before_head" "$(git -C "$create_root" rev-parse HEAD)"
    hasnt "repo creation: existing WIP stays untracked" "untracked.txt" "$(git -C "$create_root" ls-files)"
  else
    eq "repo creation: root commit message" "Initial commit from n8n-core-setup" "$(git -C "$create_root" log -1 --format=%s 2>/dev/null)"
    eq "repo creation: whole non-ignored tree is committed" $'.githooks/pre-commit\n.github/workflows/deploy.yml\n.gitignore\nREADME.md' "$(git -C "$create_root" ls-tree -r --name-only HEAD 2>/dev/null)"
  fi
  has "repo creation: $initial_state uses account default" '[fixture-owner/project]' "$(tty_text)"
  has "repo creation: $initial_state output names private repo" 'private GitHub repository fixture-owner/project' "$err"
  has "repo creation: $initial_state passes private and source flags" "repo create fixture-owner/project --private --source=$create_root --remote=origin" "$(cat "$TMP/create.calls")"
  hasnt "repo creation: $initial_state does not push" '--push' "$(cat "$TMP/create.calls")"
  has "repo creation: $initial_state confirms privacy" 'api repos/fixture-owner/project --jq .private' "$(cat "$TMP/create.calls")"
done

new_create_tree
err=$(CREATE_SAVED_REPO=Saved/Project CREATE_RERUN=true probe_create 3< <(printf '\ny\n') 2>&1); rc=$?
eq "repo creation: saved default succeeds on rerun" "0" "$rc"
has "repo creation: saved default is used" 'repo create Saved/Project --private' "$(cat "$TMP/create.calls")"
hasnt "repo creation: saved default needs no account lookup" 'api user' "$(cat "$TMP/create.calls")"
has "repo creation: saved default names private repo" 'private GitHub repository Saved/Project' "$err"

new_create_tree
err=$(probe_create 3< <(printf 'invalid\nother/renamed\ny\n') 2>&1); rc=$?
eq "repo creation: custom owner and repo succeed" "0" "$rc"
has "repo creation: validator retries invalid name" 'Invalid format' "$(tty_text)"
has "repo creation: custom owner and repo are created" 'repo create other/renamed --private' "$(cat "$TMP/create.calls")"

for forbidden_repo in lipchey/n8n-core-setup LIPCHEY/N8N-CORE-SETUP Lipchey/N8n-Core-Setup; do
  new_create_tree
  err=$(CREATE_PREPARE=false probe_create 3< <(printf '%s\ny\n' "$forbidden_repo") 2>&1); rc=$?
  eq "repo creation: template $forbidden_repo stops" "1" "$rc"
  has "repo creation: template refusal explains destination" 'public template' "$err"
  eq "repo creation: template refusal leaves no git" "absent" "$([ -e "$create_root/.git" ] && echo present || echo absent)"
  hasnt "repo creation: template refusal never creates" 'repo create' "$(cat "$TMP/create.calls")"
done

for terminal_state in eof closed; do
  new_create_tree
  if [ "$terminal_state" = eof ]; then
    err=$(probe_create 3< /dev/null 2>&1); rc=$?
  else
    err=$( (_PV_TTY_IN=/dev/fd/4; probe_create 4<&-) 2>&1); rc=$?
  fi
  eq "repo creation: name prompt $terminal_state stops" 1 "$rc"
  hasnt "repo creation: name prompt $terminal_state never creates" 'repo create' "$(cat "$TMP/create.calls")"
done

new_create_tree
err=$(CREATE_RC=1 probe_create 3< <(printf '\ny\n') 2>&1); rc=$?
eq "repo creation: gh failure stops" "1" "$rc"
has "repo creation: gh failure retains reason" 'Repository name already exists' "$err"
has "repo creation: gh failure gives recovery" 'git remote add origin' "$err"
eq "repo creation: gh failure leaves no remote" "" "$(git -C "$create_root" remote 2>/dev/null)"

for unsafe_state in other-remote nested non-main detached no-name no-email; do
  new_create_tree
  case "$unsafe_state" in
    other-remote)
      init_create_repo
      git -C "$create_root" remote add upstream https://github.com/acme/project.git ;;
    nested)
      init_create_repo
      mkdir -p "$create_root/child"
      create_root="$create_root/child" ;;
    non-main) init_create_repo feature; commit_create_repo ;;
    detached) init_create_repo; commit_create_repo; git -C "$create_root" checkout -q --detach ;;
    no-name) printf '[user]\nemail = fixture@example.invalid\n' > "$TMP/create.gitconfig" ;;
    no-email) printf '[user]\nname = Fixture\n' > "$TMP/create.gitconfig" ;;
  esac
  err=$(probe_create 3< <(printf '\ny\n') 2>&1); rc=$?
  eq "repo creation: $unsafe_state stops" "1" "$rc"
  hasnt "repo creation: $unsafe_state never creates" 'repo create' "$(cat "$TMP/create.calls")"
  case "$unsafe_state" in
    nested)
      has "repo creation: nested fix" 'inside another Git repository' "$err"
      create_root="${create_root%/child}" ;;
    non-main|detached) has "repo creation: $unsafe_state fix" 'git switch main' "$err" ;;
    no-name|no-email)
      has "repo creation: $unsafe_state fix" "git config --global user.${unsafe_state#no-}" "$err"
      eq "repo creation: $unsafe_state stops before git init" "absent" "$([ -e "$create_root/.git" ] && echo present || echo absent)" ;;
  esac
done

new_create_tree
init_create_repo
commit_create_repo
git -C "$create_root" remote add origin https://github.com/acme/project.git
err=$(CREATE_PUSH_REMOTE=origin probe_create 3</dev/null 2>&1); rc=$?
eq "repo creation: clone path is unchanged" "0" "$rc"
eq "repo creation: clone path never calls gh" "" "$(cat "$TMP/create.calls")"
eq "repo creation: clone path never prompts" "" "$(tty_text)"
err=$(probe_create 3</dev/null 2>&1); rc=$?
eq "repo creation: rerun discovers existing remote" "0" "$rc"
eq "repo creation: rerun never creates again" "" "$(cat "$TMP/create.calls")"

new_create_tree
err=$(CREATE_PRIVATE=false probe_create 3< <(printf '\ny\n') 2>&1); rc=$?
eq "repo creation: privacy recheck refuses public result" "1" "$rc"
has "repo creation: privacy recheck explains refusal" 'is public' "$err"

new_create_tree
printf 'GITHUB_REPO=stale/project\n' > "$create_root/.env.local"
err=$(probe_create 3< <(printf '\ny\n') 2>&1); rc=$?
eq "repo creation: conflicting reload default stops" "1" "$rc"
has "repo creation: conflicting reload default explains mismatch" 'differs from push remote' "$err"
hasnt "repo creation: env conflict never creates a repository" 'repo create' "$(cat "$TMP/create.calls")"

probe_local() (
  export GIT_CONFIG_GLOBAL="$TMP/create.gitconfig"
  unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL EMAIL
  ensure_local_repo_ready "$create_root"
)

for local_remote in absent present; do
  for local_state in unborn detached feature incomplete no-name no-email; do
    new_create_tree
    init_create_repo feature
    case "$local_state" in
      detached|feature|no-name|no-email) commit_create_repo ;;
      incomplete) rm -rf "$create_root/.github" ;;
    esac
    case "$local_state" in
      detached) git -C "$create_root" checkout -q --detach ;;
      no-name|no-email)
        git -C "$create_root" branch -M main
        if [ "$local_state" = no-name ]; then
          printf '[user]\nemail = fixture@example.invalid\n' > "$TMP/create.gitconfig"
        else
          printf '[user]\nname = Fixture\n' > "$TMP/create.gitconfig"
        fi ;;
    esac
    if [ "$local_remote" = present ]; then
      git -C "$create_root" remote add origin https://github.com/acme/project.git
    fi
    err=$(probe_local 2>&1); rc=$?
    if [ "$local_state" = unborn ]; then
      eq "local readiness: $local_remote unborn succeeds" 0 "$rc"
      eq "local readiness: $local_remote unborn becomes main" main "$(git -C "$create_root" branch --show-current)"
      eq "local readiness: $local_remote unborn has a root commit" 1 "$(create_commit_count)"
    else
      eq "local readiness: $local_remote $local_state stops" 1 "$rc"
      case "$local_state" in
        detached|feature) has "local readiness: $local_remote $local_state recovery" 'git switch main' "$err" ;;
        incomplete) has "local readiness: $local_remote incomplete explains missing dotfiles" 'tree is incomplete' "$err" ;;
        no-name|no-email) has "local readiness: $local_remote committed identity fix" "git config --global user.${local_state#no-}" "$err" ;;
      esac
    fi
  done
done

for secret_case in marker forced-env nodes; do
  new_create_tree
  init_create_repo
  case "$secret_case" in
    marker) printf 'AGE-%s\n' 'SECRET-KEY-1-fixture' > "$create_root/leaked.txt" ;;
    forced-env) git -C "$create_root" add -f .env ;;
    nodes)
      mkdir -p "$create_root/n8n/custom-nodes"
      printf 'fixture\n' > "$create_root/n8n/custom-nodes/source.ts" ;;
  esac
  err=$(probe_local 2>&1); rc=$?
  if [ "$secret_case" = nodes ]; then
    eq "root hook: missing node_modules skips only nodes gate" 0 "$rc"
  else
    eq "root hook: $secret_case stops" 1 "$rc"
    has "root hook: $secret_case preserves hook message" 'Refusing commit' "$err"
    eq "root hook: $secret_case leaves no HEAD" '' "$(create_commit_count)"
    eq "root hook: $secret_case unstages the whole root commit" '' "$(git -C "$create_root" ls-files)"
  fi
done

for env_name in .env.bak .env.prod .env.config .env.example .env.developer.example .env.sops.yaml; do
  ignored=$(git -C "$create_root" check-ignore --no-index -- "$env_name" 2>/dev/null); rc=$?
  case "$env_name" in
    .env.bak|.env.prod) eq "ignore fixture: $env_name is ignored" 0 "$rc" ;;
    *) eq "ignore fixture: $env_name can be tracked" 1 "$rc" ;;
  esac
done

new_create_tree
err=$(CREATE_SAVED_REPO=Saved/Taken CREATE_RERUN=true probe_create 3< <(printf 'other/available\ny\n') 2>&1); rc=$?
eq "repo creation: saved name can be changed on rerun" 0 "$rc"
has "repo creation: changed saved name is created" 'repo create other/available --private' "$(cat "$TMP/create.calls")"

for auth_case in missing-workflow ssh fine-grained with-workflow; do
  new_create_tree
  scopes='X-OAuth-Scopes: repo'; protocol=https
  case "$auth_case" in
    ssh) protocol=ssh ;;
    fine-grained) scopes='HTTP/2 200' ;;
    with-workflow) scopes='x-oauth-scopes: repo, workflow' ;;
  esac
  err=$(CREATE_SCOPES="$scopes" CREATE_PROTOCOL="$protocol" probe_create 3< <(printf '\ny\n') 2>&1); rc=$?
  if [ "$auth_case" = missing-workflow ]; then
    eq "repo creation: HTTPS classic token needs workflow scope" 1 "$rc"
    has "repo creation: workflow scope recovery" 'gh auth refresh -s workflow' "$err"
    hasnt "repo creation: missing scope stops before creation" 'repo create' "$(cat "$TMP/create.calls")"
  else
    eq "repo creation: $auth_case credentials allow creation" 0 "$rc"
  fi
done

destination_block=$(sed -n '/^if \[ -z "$GITHUB_PUSH_REMOTE" \]; then/,/^upsert_env_config "GITHUB_BRANCH"/p' "$ROOT_DIR/scripts/initialize.sh")
for destination_path in created existing; do
  err=$( (
    ROOT_DIR="$create_root"; GITHUB_PUSH_REMOTE=''; GITHUB_PUSH_REPO=acme/project; GITHUB_REPO=acme/project; GITHUB_BRANCH=main
    [ "$destination_path" != existing ] || GITHUB_PUSH_REMOTE=origin
    create_private_github_repo() { GITHUB_PUSH_REMOTE=origin; }
    initialize_repo_guard() { :; }
    require_private_github_repo() { :; }
    upsert_env_config() { :; }
    git() { printf '%s\n' "$*" >> "$TMP/destination.git"; return 1; }
    : > "$TMP/destination.git"
    eval "$destination_block" 3< <(printf '\n')
  ) 2>&1); rc=$?
  eq "destination access: $destination_path inaccessible remote stops" 1 "$rc"
  has "destination access: $destination_path explains credentials" 'SSH keys or the credential helper' "$err"
  has "destination access: $destination_path probes selected remote" 'push --dry-run --no-verify -- origin HEAD:refs/heads/main' "$(cat "$TMP/destination.git")"
done

post_push_block=$(sed -n '/^_git_push() /,/^# Wait for GitHub Actions deploy/p' "$ROOT_DIR/scripts/initialize.sh")
for push_rc in 0 1; do
  err=$( (
    ROOT_DIR="$create_root"; GITHUB_PUSH_REMOTE=origin; GITHUB_BRANCH=main
    GITHUB_REPO=acme/project; _failures=()
    git() { return "$push_rc"; }
    retry_or_skip() { shift; "$@"; }
    _check_gh_state() { printf ready; }
    _print_failures() { :; }
    eval "$post_push_block"
  ) 2>&1); rc=$?
  if [ "$push_rc" = 0 ]; then
    eq "initialization push: success continues" 0 "$rc"
  else
    eq "initialization push: skipped push stops" 1 "$rc"
  fi
done

flag_prelude=$(sed -n '/^_initialize_hard_reset=false/,/^initialize_repo_guard /p' "$ROOT_DIR/scripts/initialize.sh")
flag_restore=$(sed -n '/^set +a$/ {n; /HARD_RESET=/p;}' "$ROOT_DIR/scripts/initialize.sh")
for cli_flag in '' --hard-reset; do
  for saved_flag in true false; do
    got=$( (
      set -- "$cli_flag"
      ENV_DEVELOPER="$TMP/unused.developer"
      initialize_repo_guard() { :; }
      eval "$flag_prelude"
      HARD_RESET="$saved_flag"
      eval "$flag_restore"
      printf '%s' "$HARD_RESET"
    ))
    expected=false; [ "$cli_flag" != --hard-reset ] || expected=true
    eq "hard reset: CLI [$cli_flag] overrides sourced [$saved_flag]" "$expected" "$got"
  done
done

rerun_message=$(sed -n '/^if \[ "$_is_rerun" = "true" \]; then/,/^fi$/p' "$ROOT_DIR/scripts/initialize.sh" | head -n 5)
got=$( (_is_rerun=true; eval "$rerun_message") )
hasnt "rerun message: config alone does not claim an env file" 'Existing .env found' "$got"
hasnt "GitHub destination: no interactive login" 'Running '\''gh auth login'\''' "$(cat "$ROOT_DIR/scripts/initialize.sh")"
got=$( (gh() { return 1; }; _check_gh_state) )
eq "later GitHub logout: state is unauthenticated" unauthenticated "$got"
err=$( (
  gh() { [ "$1" = auth ] && return 1; printf 'SECRET_UPLOAD_CALLED'; }
  GITHUB_REPO=acme/project
  _push_github_secret TEST_SECRET
) 2>&1); rc=$?
eq "later GitHub logout: secret upload fails closed" 1 "$rc"
hasnt "later GitHub logout: no secret upload" SECRET_UPLOAD_CALLED "$err"
has "PAT checklist: creation can precede token selection" 'If the wizard creates the repository, create its PAT once it exists' "$(cat "$ROOT_DIR/scripts/initialize.sh")"
has "PAT prompt: identifies the selected repository" 'Permissions on repository ${GITHUB_REPO}:' "$(cat "$ROOT_DIR/scripts/initialize.sh")"

eq "GitHub destination: privacy and creation precede provider dispatch" "1" \
  "$(sed '/^[[:space:]]*#/d' "$ROOT_DIR/scripts/initialize.sh" | awk '/^PROJECT_NAME=\$\(prompt_value/ {project=NR} /create_private_github_repo/ {creation=NR} /require_private_github_repo / {privacy=NR} /ensure_local_repo_ready / {local_ready=NR} /git -C .*push --dry-run/ {access=NR} /1\) _run_provider / {print (project && local_ready > project && creation > local_ready && privacy > project && access > privacy && creation < NR && privacy < NR && access < NR)+0; exit}')"
eq "remote guard: hard reset is set before first guard" "1" \
  "$(awk '/_initialize_hard_reset=true/ {seen=1} /^initialize_repo_guard / {print seen+0; exit}' "$ROOT_DIR/scripts/initialize.sh")"

_is_rerun=false
GITHUB_PUSH_REPO=acme/project
github_prompt=$(sed -n '/^[[:space:]]*GITHUB_REPO=$(prompt_value/,/"GITHUB_REPO")/p' "$ROOT_DIR/scripts/initialize.sh")
has "GitHub prompt: exists on first run and re-run" 'GITHUB_REPO=$(prompt_value' "$github_prompt"
: > "$TTY"
got=$(eval "$github_prompt" 3< <(printf '\n'); printf '%s' "${GITHUB_REPO:-}")
eq "GitHub prompt: Enter accepts the push repository" "acme/project" "$got"
has "GitHub prompt: displays push repository default" "[acme/project]" "$(tty_text)"
_is_rerun=true
_PV_SAVED_KEYS=" GITHUB_REPO "
: > "$TTY"
got=$(eval "$github_prompt" 3</dev/null; printf '%s' "${GITHUB_REPO:-}")
eq "GitHub prompt: saved repository survives re-run" "acme/project" "$got"
has "GitHub prompt: saved repository is silent" "[existing]" "$(tty_text)"
reset_snapshot

git_push_function=$(sed -n '/^_git_push() /p' "$ROOT_DIR/scripts/initialize.sh")
got=$( (
  GITHUB_PUSH_REMOTE=upstream; GITHUB_BRANCH=main
  git() { printf '%s' "$*"; }
  eval "$git_push_function"
  _git_push
))
has "Git push: uses the checked push remote and sets upstream" 'push -u -- upstream main' "$got"

new_create_tree
rm -rf "$create_root"
mkdir -p "$create_root"
while IFS= read -r tracked_path; do
  mkdir -p "$create_root/$(dirname "$tracked_path")"
  [ ! -f "$ROOT_DIR/$tracked_path" ] || cp "$ROOT_DIR/$tracked_path" "$create_root/$tracked_path"
done < <(git -C "$ROOT_DIR" ls-files)
printf 'ignored fixture\n' > "$create_root/.env"
printf 'ignored fixture\n' > "$create_root/.env.local"
err=$(probe_local 2>&1); rc=$?
eq "local bare integration: copied tree root commit succeeds" 0 "$rc"
bare_target="$TMP/local-bare.git"
git init -q --bare "$bare_target"
git -C "$create_root" remote add origin "$bare_target"
got=$( (
  ROOT_DIR="$create_root"; GITHUB_PUSH_REMOTE=origin; GITHUB_BRANCH=main
  eval "$git_push_function"
  _git_push
) 2>&1); rc=$?
eq "local bare integration: real push succeeds" 0 "$rc"
for tracked_path in .github/workflows/deploy.yml .env.example; do
  git --git-dir="$bare_target" cat-file -e "main:$tracked_path" 2>/dev/null
  eq "local bare integration: includes $tracked_path" 0 "$?"
done
for secret_path in .env .env.local; do
  git --git-dir="$bare_target" cat-file -e "main:$secret_path" 2>/dev/null
  eq "local bare integration: excludes $secret_path" 128 "$?"
done
eq "local bare integration: upstream is configured" origin/main "$(git -C "$create_root" rev-parse --abbrev-ref 'main@{upstream}' 2>/dev/null)"
git -C "$create_root" ls-remote origin >/dev/null 2>&1
eq "local bare integration: remote is readable" 0 "$?"

normalize_block=$(sed -n '/^# Normalize workflow JSON/,/^# n8n MCP/p' "$ROOT_DIR/scripts/initialize.sh")
for first_push_rc in 0 1; do
  (
    GITHUB_PUSH_REMOTE=own; GITHUB_BRANCH=main; _run_ok=true; _failures=(); pushes=0
    git() {
      shift 2
      printf '%s\n' "$*" >> "$TMP/normalize.git"
      case "$1" in
        diff) return 1 ;;
        push) pushes=$((pushes + 1)); [ "$pushes" -gt 1 ] || return "$first_push_rc" ;;
      esac
      return 0
    }
    bash() { :; }
    : > "$TMP/normalize.git"
    eval "$normalize_block" >/dev/null
  )
  got=$(cat "$TMP/normalize.git")
  has "workflow normalization: fetch uses checked remote" 'pull --rebase --autostash -- own main' "$got"
  has "workflow normalization: push uses checked remote" 'push -- own main' "$got"
  hasnt "workflow normalization: never uses origin" 'origin' "$got"
  if [ "$first_push_rc" = 1 ]; then
    eq "workflow normalization: retries fetch on checked remote" "2" "$(grep -c '^pull --rebase --autostash -- own main$' "$TMP/normalize.git")"
    eq "workflow normalization: retries push on checked remote" "2" "$(grep -c '^push -- own main$' "$TMP/normalize.git")"
  fi
done

identity_root="$TMP/identity"
mkdir -p "$identity_root"
printf 'creation_rules:\n  - age: fixture-recipient\n' > "$identity_root/.sops.yaml"
age_key_writer=$(sed -n '/^_ensure_age_key() {/,/^}/p' "$ROOT_DIR/scripts/initialize.sh")
(
  ROOT_DIR="$identity_root"; PROJECT_NAME=acme
  age_pub=age1testfixturenotarealrecipient
  age-keygen() { if [ "$1" = -y ]; then printf '%s\n' "$age_pub"; else printf 'fixture\n' > "$2"; fi; }
  eval "$age_key_writer"
  _ensure_age_key >/dev/null
)
has "SOPS: placeholder becomes the generated public key" 'age: age1' "$(cat "$identity_root/.sops.yaml")"
hasnt "SOPS: placeholder is removed" PUBLIC_AGE_KEY_HERE "$(cat "$identity_root/.sops.yaml")"
rm -f "$HOME/.config/sops/age/acme.txt" "$HOME/.config/sops/age/keys.txt"
eq "remote guard: call precedes the first prompt" "1" "$(awk '/^initialize_repo_guard / {seen=1} /^cat >\/dev\/tty/ {print seen+0; exit}' "$ROOT_DIR/scripts/initialize.sh")"

_is_rerun=false
eq "validator: first valid answer" "123" "$(pv '123\n' d "" false false '^[0-9]+$')"
got=$(pv 'abc\n123\n' d "" false false '^[0-9]+$')
eq "validator: mismatch re-prompts" "123" "$got"
has "validator: mismatch says so" "Invalid format" "$(tty_text)"
eq "validator: applies to the default on Enter" "42" "$(pv '\n42\n' d "bad" false false '^[0-9]+$')"
eq "validator: an allowed empty answer skips it" "" "$(pv '\n' d "" false true '^[0-9]+$')"

snap="$TMP/snap.env"
printf '# COMMENTED=1\nSAVED_KEY=x\nOTHER_KEY_LONG=y\n' > "$snap"
reset_snapshot
env_keys_snapshot "$snap" "$TMP/missing.env"
_is_rerun=true

eq "re-run: no key_name keeps silent accept" "def" "$(pv '' d "def")"
has "re-run: no key_name reports existing" "[existing]" "$(tty_text)"

eq "re-run: saved key is silent" "def" "$(pv '' d "def" false false "" SAVED_KEY)"
has "re-run: saved key reports existing" "[existing]" "$(tty_text)"

eq "re-run: unsaved key takes default on Enter" "def" "$(pv '\n' d "def" false false "" NEW_KEY)"
has "re-run: unsaved key prompts" "→" "$(tty_text)"
has "re-run: unsaved key pre-fills default" "[def]" "$(tty_text)"
hasnt "re-run: unsaved key is not silent" "[existing]" "$(tty_text)"
eq "re-run: unsaved key takes typed answer" "typed" "$(pv 'typed\n' d "def" false false "" NEW_KEY)"
eq "re-run: key match is whole-word" "typed" "$(pv 'typed\n' d "def" false false "" OTHER_KEY)"
eq "re-run: commented key is not saved" "typed" "$(pv 'typed\n' d "def" false false "" COMMENTED)"
eq "re-run: saved key failing validator prompts" "7" "$(pv '7\n' d "def" false false '^[0-9]+$' SAVED_KEY)"

printf 'LATE_KEY=1\n' > "$TMP/late.env"
env_keys_snapshot "$TMP/late.env"
eq "re-run: snapshot is built only once" "typed" "$(pv 'typed\n' d "def" false false "" LATE_KEY)"

eq "re-run: secret saved key is silent" "s3cret" "$(pv '' d "s3cret" true false "" SAVED_KEY)"
hasnt "re-run: secret value never shown" "s3cret" "$(tty_text)"

_is_rerun=false
eq "first run: saved key still prompts" "typed" "$(pv 'typed\n' d "def" false false "" SAVED_KEY)"

eq "allow_empty: Enter with no default is empty" "" "$(pv '\n' d "" false true)"
eq "allow_empty: Enter keeps a default" "def" "$(pv '\n' d "def" false true)"
eq "allow_empty: typed answer wins" "typed" "$(pv 'typed\n' d "def" false true)"
eq "required: empty re-prompts" "val" "$(pv '\nval\n' d "")"
has "required: says so" "Required" "$(tty_text)"
_is_rerun=true
eq "allow_empty: re-run with no default still prompts" "" "$(pv '\n' d "" false true)"
_is_rerun=false

eq "secret: returns the answer" "abc" "$(pv 'abc\n' d "" true)"
eq "secret: prompt line ends in a newline" "1" "$(tail -c1 "$TTY" | wc -l | tr -d ' ')"
eq "secret: masks the default" "def" "$(pv '\n' d "def" true)"
has "secret: default shown masked" "[***]" "$(tty_text)"
hasnt "secret: default not shown" "[def]" "$(tty_text)"

for v in 'a@b.co' 'https://x.y/z' 'a,b' 'Aa0@._:/+=,-' 'SHA256:abc+/=' ''; do
  checks=$((checks + 1))
  env_value_ok "$v" || _fail "alphabet: accepts [$v]" "rejected"
done
# shellcheck disable=SC2088
for v in 'a b' 'Name <a@b.co>' 'http://x?y=1' 'a&b' 'a"b' "a'b" 'a$(x)' 'a;b' '~/x' '#x' $'a\nb' $'a\r' 'é'; do
  checks=$((checks + 1))
  if env_value_ok "$v"; then _fail "alphabet: rejects [$v]" "accepted"; fi
done
checks=$((checks + 1))
if ( LC_ALL=en_US.UTF-8; env_value_ok 'é' ) 2>/dev/null; then _fail "alphabet: rejects é under a UTF-8 locale" "accepted"; fi

got=$(pv 'Name <a@b.co>\nhttp://x?y=1\na@b.co\n' d "")
eq "alphabet: prompt_value re-prompts" "a@b.co" "$got"
has "alphabet: prompt states no spaces" "no spaces" "$(tty_text)"
has "alphabet: prompt states bare sender" "bare sender address" "$(tty_text)"
has "alphabet: prompt states URL limit" "no ? or & in URLs" "$(tty_text)"
eq "alphabet: comma is allowed" "a,b" "$(pv 'a,b\n' d "")"
eq "alphabet: bad default is not accepted on Enter" "ok" "$(pv '\nok\n' d "a b")"
_is_rerun=true
eq "alphabet: bad default is not accepted silently" "ok" "$(pv 'ok\n' d "a b")"
_is_rerun=false

eq "alphabet: .env.example fits" "0" "$(env_files_check_alphabet "$ROOT_DIR/.env.example" >/dev/null 2>&1; echo $?)"
printf '# comment with spaces & ?\n  # indented comment\n\n \t\nGOOD=a@b.co\nEMPTY=\n' > "$TMP/good.env"
eq "alphabet: clean file and missing file pass" "0" "$(env_files_check_alphabet "$TMP/good.env" "$TMP/none.env" >/dev/null 2>&1; echo $?)"

printf 'GOOD=x\nBAD_ONE=hunter2 secret\nBAD_TWO=y?z\n' > "$TMP/bad.env"
cp "$TMP/bad.env" "$TMP/bad.orig"
err=$( (env_files_check_alphabet "$TMP/good.env" "$TMP/bad.env") 2>&1 >/dev/null ); rc=$?
eq "pre-source check: stops the run" "1" "$rc"
has "pre-source check: names the first key" "BAD_ONE" "$err"
has "pre-source check: names the second key" "BAD_TWO" "$err"
hasnt "pre-source check: does not name a good key" "GOOD" "$err"
hasnt "pre-source check: never prints the value" "hunter2" "$err"
has "pre-source check: gives the fix" "Fix:" "$err"
has "pre-source check: states the consequences" "no spaces" "$err"
eq "pre-source check: no silent rewrite" "$(cat "$TMP/bad.orig")" "$(cat "$TMP/bad.env")"

# shellcheck disable=SC2016
for line in 'export TOKEN=$(hunter2)' '  INDENTED=hunter2' 'hunter2 --flag' $'\r'; do
  printf 'GOOD=x\n%s\nALSO_GOOD=y\n' "$line" > "$TMP/shape.env"
  err=$( (env_files_check_alphabet "$TMP/shape.env") 2>&1 >/dev/null ); rc=$?
  eq "pre-source check [$line]: stops the run" "1" "$rc"
  has "pre-source check [$line]: names the line" "line 2" "$err"
  hasnt "pre-source check [$line]: never prints the line" "hunter2" "$err"
done

printf 'KNOWN=1\n' > "$TMP/cur.env"
printf 'KNOWN=2\nSTRIPE_KEY=abc\n' > "$TMP/prev.env"
_preserve_unknown_env_keys "$TMP/cur.env" "$TMP/prev.env"
has "preserve: carries a clean unknown key" "STRIPE_KEY=abc" "$(cat "$TMP/cur.env")"
hasnt "preserve: leaves a known key alone" "KNOWN=2" "$(cat "$TMP/cur.env")"

printf 'KNOWN=1\n' > "$TMP/cur.env"
chmod 600 "$TMP/cur.env"
printf 'KNOWN=2 ignored\nSTRIPE_KEY=hunter2 x\n' > "$TMP/prev.env"
cp "$TMP/prev.env" "$TMP/prev.orig"
err=$( (_preserve_unknown_env_keys "$TMP/cur.env" "$TMP/prev.env") 2>&1 >/dev/null ); rc=$?
eq "preserve: stops on a bad unknown key" "1" "$rc"
has "preserve: names the key" "STRIPE_KEY" "$err"
has "preserve: gives the fix" "Fix:" "$err"
hasnt "preserve: never prints the value" "hunter2" "$err"
hasnt "preserve: names no backup path" "$TMP/prev.env" "$err"
eq "preserve: original restored" "$(cat "$TMP/prev.orig")" "$(cat "$TMP/cur.env")"
eq "preserve: restore keeps the mode" "-rw-------" "$(ls -l "$TMP/cur.env" | cut -c1-10)"
eq "preserve: no plaintext backup left" "no" "$([ -e "$TMP/prev.env" ] && echo yes || echo no)"

rs() {
  local _answers="$1"; shift
  : > "$TTY"
  retry_or_skip "desc" "$@" 3< <(printf '%b' "$_answers")
}
fail_times() {
  local _n; _n=$(cat "$TMP/count" 2>/dev/null || echo 0)
  echo $((_n + 1)) > "$TMP/count"
  [ "$_n" -ge "$1" ]
}
fail_7() { return 7; }

rm -f "$TMP/count"; rs '' fail_times 0 2>/dev/null; eq "retry_or_skip: success is 0" "0" "$?"
rm -f "$TMP/count"; rs '' fail_times 2 2>/dev/null; rc=$?
eq "retry_or_skip: auto-retry recovers" "0" "$rc"
eq "retry_or_skip: tried three times" "3" "$(cat "$TMP/count")"
rm -f "$TMP/count"; rs 'r\n' fail_times 3 2>/dev/null; eq "retry_or_skip: r retries" "0" "$?"

err=$(rs 's\n' fail_7 2>&1 >/dev/null); rc=$?
eq "retry_or_skip: skip returns the real status" "7" "$rc"
has "retry_or_skip: reports the real status" "exit 7" "$err"
( rs 'a\n' fail_7 ) >/dev/null 2>&1; eq "retry_or_skip: abort exits 1" "1" "$?"
( rs '' fail_7 ) >/dev/null 2>&1; eq "retry_or_skip: closed tty aborts" "1" "$?"
rm -f "$TMP/count"
got=$( ( set -e; rs '' fail_times 1 2>/dev/null; echo alive ) )
eq "retry_or_skip: failed attempt survives set -e" "alive" "$got"

# PATH holds only stubs, so the real clipboard is out of reach
cat_bin=$(command -v cat)
clip_dir() {
  local _d="$TMP/clip-$1"; mkdir -p "$_d"; ln -sf "$cat_bin" "$_d/cat"
  if [ "$1" != "none" ]; then
    printf '#!/bin/sh\n%s > "%s/clip.out"\n' "$cat_bin" "$TMP" > "$_d/$1"
    chmod +x "$_d/$1"
  fi
  printf '%s' "$_d"
}
got=$( ( set -e; PATH=$(clip_dir none); out=$(printf 'pw' | _clipboard_copy); printf '%s' "$out" ) ); rc=$?
eq "clipboard: no tool survives set -e" "0" "$rc"
eq "clipboard: no tool reports none" "none" "$got"
for tool in pbcopy xclip xsel; do
  rm -f "$TMP/clip.out"
  eq "clipboard: $tool reported" "$tool" "$( ( PATH=$(clip_dir "$tool"); printf 'pw' | _clipboard_copy ) )"
  eq "clipboard: $tool receives the bytes" "pw" "$(cat "$TMP/clip.out")"
done

payload=$(printf 'line 1\nline 2\n\nx'; printf '\n\n'; printf y)
payload="${payload%y}"
printf '%s' "$payload" > "$TMP/payload"
mock_ssh() {
  local _n; _n=$(cat "$TMP/count" 2>/dev/null || echo 0); _n=$((_n + 1))
  echo "$_n" > "$TMP/count"
  cat > "$TMP/stdin.$_n"
  [ "$_n" -gt "$1" ] && return "$2"
  return 255
}
rm -f "$TMP/count" "$TMP"/stdin.* "$TMP/sleeps"
retry_ssh_buffered mock_ssh 1 0 < "$TMP/payload" 2>/dev/null; rc=$?
eq "ssh buffered: recovers after one 255" "0" "$rc"
eq "ssh buffered: two attempts" "2" "$(cat "$TMP/count")"
checks=$((checks + 1)); cmp -s "$TMP/payload" "$TMP/stdin.1" || _fail "ssh buffered: attempt 1 got the exact bytes" "differs"
checks=$((checks + 1)); cmp -s "$TMP/payload" "$TMP/stdin.2" || _fail "ssh buffered: attempt 2 got the exact bytes" "differs"
eq "ssh buffered: first back-off" "3" "$(cat "$TMP/sleeps")"

rm -f "$TMP/count"
retry_ssh_buffered mock_ssh 0 5 < "$TMP/payload" 2>/dev/null; rc=$?
eq "ssh buffered: remote failure is not retried" "5" "$rc"
eq "ssh buffered: one attempt on remote failure" "1" "$(cat "$TMP/count")"

rm -f "$TMP/count" "$TMP/sleeps"
retry_ssh_buffered mock_ssh 99 0 < "$TMP/payload" 2>/dev/null; rc=$?
eq "ssh buffered: gives up with 255" "255" "$rc"
eq "ssh buffered: four attempts" "4" "$(cat "$TMP/count")"
eq "ssh buffered: back-off schedule" "3 6 9" "$(tr '\n' ' ' < "$TMP/sleeps" | sed 's/ $//')"

# Each provisioning scenario runs in a subshell because the library exits and exports LC_ALL
pv_scenario() {
  rm -f "$ENV_FILE" "$ENV_LOCAL" "$TMP/curl.argv" "$TMP/curl.stdin" "$TMP/ssh.argv"
  (
    # shellcheck source=lib/provision-vps.sh
    source "$ROOT_DIR/scripts/lib/provision-vps.sh"
    PV_LABEL="Test"; PV_API="http://stub.invalid"; PV_TOKEN="tok"; PV_ID_KEY="TEST_SERVER_ID"
    _HOST_FINGERPRINT="SHA256:fp"
    _beep() { :; }
    curl() {
      printf '%s\n' "$*" >> "$TMP/curl.argv"
      case " $* " in
        *" -X POST "*) cat > "$TMP/curl.stdin"; printf '%s\n%s' "${STUB_BODY:-}" "${STUB_CODE:-000}" ;;
        *" -o /dev/null "*) printf '%s' "${STUB_CODE:-000}" ;;
        *) printf '%s' "${STUB_GET:-}" ;;
      esac
      return "${STUB_RC:-0}"
    }
    ssh() { printf '%s\n' "$*" >> "$TMP/ssh.argv"; echo "${STUB_SSH_OUT:-status: done}"; return 2; }
    "$@"
  )
}
create() { pv_create_server "/servers" '{"secret":"HOSTKEY"}' '.server.id' '.server.ip // empty'; echo "id=$PV_SERVER_ID"; }
create_with_key() { _matched_privkey="$1"; create; }
mkdir -p "$HOME/.ssh"
ssh-keygen -q -t ed25519 -N "" -f "$HOME/.ssh/id_saved"
: > "$HOME/.ssh/id with space"

out=$(STUB_BODY='{"server":{"id":77,"ip":"1.2.3.4"}}' STUB_CODE=201 pv_scenario create 2>&1); rc=$?
eq "create: success" "0" "$rc"
has "create: sets the ID" "id=77" "$out"
eq "create: ID saved" "77" "$(file_var "$ENV_LOCAL" TEST_SERVER_ID)"
eq "create: IP saved" "1.2.3.4" "$(file_var "$ENV_LOCAL" N8N_VPS_IP)"
eq "create: fingerprint saved" "SHA256:fp" "$(file_var "$ENV_FILE" N8N_VPS_HOST_FINGERPRINT)"
eq "create: body goes over stdin" '{"secret":"HOSTKEY"}' "$(cat "$TMP/curl.stdin")"
hasnt "create: body not in argv" "HOSTKEY" "$(cat "$TMP/curl.argv")"
has "create: curl has timeouts" "--max-time 60" "$(cat "$TMP/curl.argv")"

STUB_BODY='{"server":{"id":78}}' STUB_CODE=202 pv_scenario create >/dev/null 2>&1
eq "create: ID saved when the response has no IP" "78" "$(file_var "$ENV_LOCAL" TEST_SERVER_ID)"
eq "create: no IP invented" "" "$(file_var "$ENV_LOCAL" N8N_VPS_IP)"
eq "create: fingerprint saved without an IP" "SHA256:fp" "$(file_var "$ENV_FILE" N8N_VPS_HOST_FINGERPRINT)"

STUB_BODY='{"server":{"id":79}}' STUB_CODE=202 pv_scenario create_with_key "$HOME/.ssh/id_saved" >/dev/null 2>&1
eq "create: key path saved" "$HOME/.ssh/id_saved" "$(file_var "$ENV_LOCAL" SSH_PRIVATE_KEY)"
STUB_RC=28 pv_scenario create_with_key "$HOME/.ssh/id_saved" >/dev/null 2>&1
eq "create: key path saved when the outcome is unknown" "$HOME/.ssh/id_saved" "$(file_var "$ENV_LOCAL" SSH_PRIVATE_KEY)"
STUB_CODE=422 pv_scenario create_with_key "$HOME/.ssh/id_saved" >/dev/null 2>&1
eq "create: rejected create saves no key path" "" "$(file_var "$ENV_LOCAL" SSH_PRIVATE_KEY)"
STUB_BODY='{"server":{"id":79}}' STUB_CODE=202 pv_scenario create_with_key "x.pub (no private key file at x)" >/dev/null 2>&1
eq "create: diagnostic is not saved as a key path" "" "$(file_var "$ENV_LOCAL" SSH_PRIVATE_KEY)"
STUB_BODY='{"server":{"id":79}}' STUB_CODE=202 pv_scenario create_with_key "$HOME/.ssh/id with space" >/dev/null 2>&1
eq "create: out-of-alphabet path is not saved" "" "$(file_var "$ENV_LOCAL" SSH_PRIVATE_KEY)"

for scenario in "28|000|" "0|500|oops" "0|201|{}"; do
  IFS='|' read -r s_rc s_code s_body <<< "$scenario"
  err=$(STUB_RC="$s_rc" STUB_CODE="$s_code" STUB_BODY="$s_body" pv_scenario create 2>&1); rc=$?
  eq "create uncertain [$scenario]: distinct exit" "11" "$rc"
  has "create uncertain [$scenario]: reconciliation message" "outcome unknown" "$err"
  has "create uncertain [$scenario]: names the key to set" "TEST_SERVER_ID=<its id>" "$err"
  eq "create uncertain [$scenario]: no ID invented" "" "$(file_var "$ENV_LOCAL" TEST_SERVER_ID)"
  eq "create uncertain [$scenario]: fingerprint kept" "SHA256:fp" "$(file_var "$ENV_FILE" N8N_VPS_HOST_FINGERPRINT)"
  eq "create uncertain [$scenario]: one attempt" "1" "$(grep -c -- '-X POST' "$TMP/curl.argv")"
done

err=$(STUB_CODE=422 STUB_BODY='{"error":{"message":"bad type"}}' pv_scenario create 2>&1); rc=$?
eq "create rejected: returns for reselection" "0" "$rc"
has "create rejected: says nothing was created" "no server was created" "$err"
has "create rejected: API message shown" "bad type" "$err"
eq "create rejected: nothing saved" "" "$(file_var "$ENV_LOCAL" TEST_SERVER_ID)"

resume() { pv_resume_saved_server "/servers" '.state' '.ip // empty' "running"; echo "continued"; }
out=$(pv_scenario resume 2>&1); rc=$?
eq "resume: no saved ID continues" "0" "$rc"
has "resume: no saved ID reaches the caller" "continued" "$out"
eq "resume: no saved ID makes no API call" "no" "$([ -f "$TMP/curl.argv" ] && echo yes || echo no)"

seed() { printf 'TEST_SERVER_ID=77\n' > "$ENV_LOCAL"; printf 'N8N_VPS_HOST_FINGERPRINT=SHA256:saved\n' > "$ENV_FILE"; }
resume_seeded() { seed; resume; }
out=$(STUB_CODE=200 STUB_GET='{"state":"running","ip":"5.6.7.8"}' pv_scenario resume_seeded 2>&1); rc=$?
eq "resume: finishes the saved server" "0" "$rc"
hasnt "resume: does not fall through to create" "continued" "$out"
has "resume: cloud-init exit 2 still counts as done" "SSH is ready" "$out"
has "resume: confirmed cloud-init prints success" "✅ Resumed" "$out"
eq "resume: IP written" "5.6.7.8" "$(file_var "$ENV_LOCAL" N8N_VPS_IP)"
eq "resume: fingerprint kept" "SHA256:saved" "$(file_var "$ENV_FILE" N8N_VPS_HOST_FINGERPRINT)"
hasnt "resume: never POSTs" "-X POST" "$(cat "$TMP/curl.argv")"
hasnt "resume: no saved key passes no identity" "-i " "$(cat "$TMP/ssh.argv")"

resume_with_key() { seed; printf 'SSH_PRIVATE_KEY=%s\n' "$1" >> "$ENV_LOCAL"; resume; }
STUB_CODE=200 STUB_GET='{"state":"running","ip":"5.6.7.8"}' pv_scenario resume_with_key "$HOME/.ssh/id_saved" >/dev/null 2>&1
has "resume: saved key reaches ssh" "-i $HOME/.ssh/id_saved " "$(cat "$TMP/ssh.argv")"
# shellcheck disable=SC2088
STUB_CODE=200 STUB_GET='{"state":"running","ip":"5.6.7.8"}' pv_scenario resume_with_key '~/.ssh/id_saved' >/dev/null 2>&1
has "resume: saved ~ path is expanded" "-i $HOME/.ssh/id_saved " "$(cat "$TMP/ssh.argv")"

out=$(STUB_SSH_OUT='status: running' STUB_CODE=200 STUB_GET='{"state":"running","ip":"5.6.7.8"}' pv_scenario resume_with_key "$HOME/.ssh/id_saved" 2>&1); rc=$?
eq "resume: unconfirmed cloud-init still exits 0" "0" "$rc"
hasnt "resume: unconfirmed cloud-init prints no success" "✅" "$out"
has "resume: unconfirmed cloud-init warns" "not confirmed" "$out"
has "resume: unconfirmed cloud-init says how to check" "ssh -i $HOME/.ssh/id_saved root@5.6.7.8 'cloud-init status'" "$out"

resume_no_env() { printf 'TEST_SERVER_ID=77\n' > "$ENV_LOCAL"; resume; }
resume_no_pin() { printf 'TEST_SERVER_ID=77\n' > "$ENV_LOCAL"; printf 'OTHER=1\nN8N_VPS_HOST_FINGERPRINT=\n' > "$ENV_FILE"; resume; }
# The stubbed server is live so that a missing guard would reach the write.
err=$(STUB_CODE=200 STUB_GET='{"state":"running","ip":"5.6.7.8"}' pv_scenario resume_no_env 2>&1); rc=$?
eq "resume no fingerprint: stops" "1" "$rc"
has "resume no fingerprint: names the server" "server 77" "$err"
has "resume no fingerprint: names the encrypted secrets" ".env.sops.yaml" "$err"
has "resume no fingerprint: way forward to resume" "npm run decrypt-env" "$err"
has "resume no fingerprint: way forward to create" "remove TEST_SERVER_ID from .env.local" "$err"
hasnt "resume no fingerprint: does not fall through" "continued" "$err"
eq "resume no fingerprint: no API call" "no" "$([ -f "$TMP/curl.argv" ] && echo yes || echo no)"
eq "resume no fingerprint: writes no .env" "no" "$([ -e "$ENV_FILE" ] && echo yes || echo no)"
eq "resume no fingerprint: writes no IP" "" "$(file_var "$ENV_LOCAL" N8N_VPS_IP)"
STUB_CODE=200 STUB_GET='{"state":"running","ip":"5.6.7.8"}' pv_scenario resume_no_pin >/dev/null 2>&1; rc=$?
eq "resume empty fingerprint: stops" "1" "$rc"
eq "resume empty fingerprint: file not rewritten" "OTHER=1 N8N_VPS_HOST_FINGERPRINT=" "$(tr '\n' ' ' < "$ENV_FILE" | sed 's/ $//')"
resume_placeholder_pin() { printf 'TEST_SERVER_ID=77\n' > "$ENV_LOCAL"; printf 'N8N_VPS_HOST_FINGERPRINT=SHA256:paste_fingerprint_here\n' > "$ENV_FILE"; resume; }
STUB_CODE=200 STUB_GET='{"state":"running","ip":"5.6.7.8"}' pv_scenario resume_placeholder_pin >/dev/null 2>&1; rc=$?
eq "resume placeholder fingerprint: stops" "1" "$rc"

err=$(STUB_CODE=404 pv_scenario resume_seeded 2>&1); rc=$?
eq "resume: gone server stops" "1" "$rc"
has "resume: gone server says how to recreate" "Remove TEST_SERVER_ID" "$err"
hasnt "resume: gone server does not fall through" "continued" "$err"

err=$(STUB_RC=28 pv_scenario resume_seeded 2>&1); rc=$?
eq "resume: API failure stops" "1" "$rc"
hasnt "resume: API failure does not fall through" "continued" "$err"

confirm() { pv_confirm_create "Name:|x" 3< <(printf '%b' "$1"); }
out=$(pv_scenario confirm 'n\n' 2>&1); rc=$?
eq "confirm: n is a distinct exit" "10" "$rc"
hasnt "confirm: n prints no success" "✅" "$out"
pv_scenario confirm '\n' >/dev/null 2>&1; eq "confirm: Enter creates" "0" "$?"
pv_scenario confirm 'y\n' >/dev/null 2>&1; eq "confirm: y creates" "0" "$?"
pv_scenario confirm 'r\n' >/dev/null 2>&1; eq "confirm: r restarts" "1" "$?"

# sops-env.sh runs from a copy so ROOT_DIR, and every file it touches, stays inside $TMP
sops_root="$TMP/sops-root"
mkdir -p "$sops_root/scripts" "$TMP/sops-bin" "$HOME/.config/sops/age"
cp "$ROOT_DIR/scripts/sops-env.sh" "$sops_root/scripts/"
cat > "$TMP/sops-bin/sops" <<EOF
#!/bin/sh
printf '%s' "\$SOPS_AGE_KEY_FILE" > "$TMP/sops.keyfile"
printf 'blob'
exit \${STUB_SOPS_RC:-0}
EOF
chmod +x "$TMP/sops-bin/sops"
sops_env() { ( PATH="$TMP/sops-bin:$PATH"; bash "$sops_root/scripts/sops-env.sh" "$@" ); }
printf 'PROJECT_NAME=proj\n' > "$sops_root/.env.config"

err=$(sops_env --check-only 2>&1); rc=$?
eq "sops-env: no key stops" "1" "$rc"
has "sops-env: no key names the project path" "age/proj.txt" "$err"

touch "$HOME/.config/sops/age/keys.txt"
sops_env --check-only >/dev/null 2>&1
eq "sops-env: keys.txt found" "$HOME/.config/sops/age/keys.txt" "$(cat "$TMP/sops.keyfile")"
touch "$HOME/.config/sops/age/proj.txt"
sops_env --check-only >/dev/null 2>&1
eq "sops-env: project key found first" "$HOME/.config/sops/age/proj.txt" "$(cat "$TMP/sops.keyfile")"

printf 'A=1\n' > "$sops_root/.env"
STUB_SOPS_RC=3 sops_env --encrypt >/dev/null 2>&1; rc=$?
eq "sops-env: encrypt failure is non-zero" "3" "$rc"
eq "sops-env: encrypt failure leaves no tmp" "no" "$([ -e "$sops_root/.env.sops.yaml.tmp" ] && echo yes || echo no)"
eq "sops-env: encrypt failure writes no blob" "no" "$([ -e "$sops_root/.env.sops.yaml" ] && echo yes || echo no)"
eq "sops-env: encrypt failure keeps .env" "A=1" "$(cat "$sops_root/.env")"
sops_env --encrypt >/dev/null 2>&1; rc=$?
eq "sops-env: encrypt success" "0" "$rc"
eq "sops-env: encrypt success writes the blob" "blob" "$(cat "$sops_root/.env.sops.yaml")"
eq "sops-env: encrypt success removes .env" "no" "$([ -e "$sops_root/.env" ] && echo yes || echo no)"

if [ "$fails" -ne 0 ]; then
  echo "test-prompts: $fails of $checks checks failed" >&2
  exit 1
fi
echo "test-prompts: $checks checks passed"
