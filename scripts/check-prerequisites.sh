#!/bin/bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/prompts.sh
source "$ROOT_DIR/scripts/lib/prompts.sh"

TOOLS=(
    'git|git|git|2.28.0|required|repository setup and synchronization'
    'gh|gh|gh|2.40.0|required|GitHub repository privacy and setup'
    'curl|curl|curl|7.76.0|required|provider and service API requests'
    'jq|jq|jq||required|JSON processing'
    'openssl|openssl|openssl||required|secret generation'
    'rsync|rsync|rsync||required|workflow downloads'
    'sops|sops|||required|secret encryption and decryption'
    'ssh|openssh|openssh-client||required|VPS commands'
    'scp|openssh|openssh-client||required|VPS file uploads'
    'ssh-keygen|openssh|openssh-client||required|SSH key generation and fingerprints'
    'ssh-keyscan|openssh|openssh-client||required|VPS host verification'
    'node|node|nodejs|14.17.0|required|custom-node build runtime'
    'npm|node|npm|7.0.0|required|custom-node dependency installation and build'
    'age-keygen|age|age||required|encryption key generation'
    'pbcopy,xclip,xsel||||optional|clipboard copying unavailable; copy manually'
    'afplay,osascript||||optional|sound notifications use the terminal bell'
    'open||||optional|deploy watcher runs without a Terminal window'
)

version_at_least() {
    local found="$1" minimum="$2" found_part minimum_part
    while [ -n "$found$minimum" ]; do
        found_part="${found%%.*}"
        minimum_part="${minimum%%.*}"
        if [ "$((10#${found_part:-0}))" -gt "$((10#${minimum_part:-0}))" ]; then return 0; fi
        if [ "$((10#${found_part:-0}))" -lt "$((10#${minimum_part:-0}))" ]; then return 1; fi
        case "$found" in *.*) found="${found#*.}" ;; *) found="" ;; esac
        case "$minimum" in *.*) minimum="${minimum#*.}" ;; *) minimum="" ;; esac
    done
    return 0
}

platform=$(uname -s 2>/dev/null) || platform=unknown
if [ "$platform" = Darwin ]; then
    if ! command -v brew >/dev/null 2>&1; then
        printf 'Homebrew is absent; install it for the commands below from ' >&2
        print_link "https://brew.sh" >&2
    fi
else
    printf 'Platform %s is outside the supported boundary: the developer machine must run macOS.\n' "$platform" >&2
fi

missing=0
packages=""
if command -v git >/dev/null 2>&1 && git -C "$ROOT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    for state in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply sequencer index.lock; do
        state_path=$(git -C "$ROOT_DIR" rev-parse --git-path "$state")
        case "$state_path" in /*) ;; *) state_path="$ROOT_DIR/$state_path" ;; esac
        if [ -e "$state_path" ]; then
            missing=1
            printf '%s: unfinished Git work; inspect git status and finish or abort the operation; if another Git process is running, wait. Never delete a lock.\n' "$state_path" >&2
        fi
    done
    if [ -n "$(git -C "$ROOT_DIR" ls-files --unmerged)" ]; then
        missing=1
        printf '%s: unmerged paths; inspect git status and finish or abort the operation.\n' "$ROOT_DIR" >&2
    fi
fi

for directory in "$ROOT_DIR" "${TMPDIR:-/tmp}"; do
    if probe=$(mktemp "$directory/.prerequisite.XXXXXX" 2>/dev/null); then
        rm -f "$probe"
    else
        missing=1
        printf '%s: cannot create an empty file; grant write access to this directory or choose a writable path.\n' "$directory" >&2
    fi
done
for name in .env .env.config .env.local .sops.yaml .env.sops.yaml; do
    path="$ROOT_DIR/$name"
    if { [ -e "$path" ] || [ -L "$path" ]; } && { [ ! -f "$path" ] || [ ! -r "$path" ]; }; then
        missing=1
        printf '%s: must be a readable file; correct the path or its read permission.\n' "$path" >&2
    fi
done
if [ -e "$ROOT_DIR/.sops.yaml" ] && [ ! -w "$ROOT_DIR/.sops.yaml" ]; then
    missing=1
    printf '%s: must be writable; grant write access to this file.\n' "$ROOT_DIR/.sops.yaml" >&2
fi
age_target="$HOME/.config/sops/age"
age_project=$(file_var "$ROOT_DIR/.env.config" PROJECT_NAME)
ancestor="$age_target"
while [ ! -e "$ancestor" ] && [ ! -L "$ancestor" ]; do ancestor="${ancestor%/*}"; done
if [ ! -d "$ancestor" ]; then
    missing=1
    printf '%s: ancestor %s must be a directory; correct this path.\n' "$age_target" "$ancestor" >&2
elif [ ! -w "$ancestor" ] && { [ "$ancestor" != "$age_target" ] \
    || [ -z "$age_project" ] || [ ! -f "$age_target/$age_project.txt" ] || [ ! -f "$age_target/keys.txt" ]; }; then
    missing=1
    printf '%s: cannot create it under %s; grant write access to that directory.\n' "$age_target" "$ancestor" >&2
fi
if [ -e "$age_target/keys.txt" ] && [ ! -w "$age_target/keys.txt" ]; then
    missing=1
    printf '%s: must be writable; grant write access to this keystore.\n' "$age_target/keys.txt" >&2
fi

# Tests override the device because CI has no controlling terminal.
tty_path="${PREREQUISITES_TTY:-/dev/tty}"
if [ ! -e "$tty_path" ] || ! ( : <"$tty_path" >"$tty_path" ) 2>/dev/null; then
    missing=1
    printf '%s: no usable terminal; run from an interactive terminal.\n' "$tty_path" >&2
fi

for spec in "${TOOLS[@]}"; do
    IFS='|' read -r tools brew_package apt_package minimum requirement purpose <<< "$spec"
    IFS=',' read -r -a alternatives <<< "$tools"
    present=false
    for tool in "${alternatives[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then present=true; break; fi
    done
    if [ "$requirement" = optional ]; then
        if [ "$present" = false ]; then printf 'Optional %s: %s.\n' "$tools" "$purpose" >&2; fi
        continue
    fi

    version_note=""
    action=install
    if [ "$present" = true ] && [ -n "$minimum" ]; then
        version_text=$("$tool" --version 2>/dev/null) || version_text=""
        found=unknown
        if [[ "$version_text" =~ ([0-9]+([.][0-9]+)+) ]]; then found="${BASH_REMATCH[1]}"; fi
        if [ "$found" = unknown ] || ! version_at_least "$found" "$minimum"; then
            present=false
            action=upgrade
            version_note=" (requires >=$minimum; found $found)"
        fi
    fi
    [ "$present" = false ] || continue
    missing=1
    if [ "$platform" = Darwin ]; then
        advice="$action: brew $action $brew_package"
        case " $packages " in
            *" $brew_package "*) ;;
            *) packages="${packages:+$packages }$brew_package" ;;
        esac
    elif [ -n "$apt_package" ]; then
        if [ "$action" = upgrade ]; then
            advice="upgrade: apt-get install --only-upgrade $apt_package"
        else
            advice="install: apt-get install $apt_package"
        fi
    else
        advice="install $tool from its upstream releases (no known apt-get package)"
    fi
    printf '%s: %s%s; %s\n' "$tools" "$purpose" "$version_note" "$advice" >&2
done

if command -v gh >/dev/null 2>&1; then
    if ! auth_output=$(gh auth status --active 2>&1); then
        missing=1
        [ -z "$auth_output" ] || printf '%s\n' "$auth_output" >&2
        printf '%s\n' 'You are not logged in to GitHub, or the check could not reach it.' \
            'Run gh auth login, choose GitHub.com; repo and workflow scopes are needed.' \
            'For an existing login, run: gh auth refresh -s repo,workflow' >&2
    fi
fi

if [ "$missing" -ne 0 ]; then
    if [ -n "$packages" ]; then printf 'Install missing packages: brew install %s\n' "$packages" >&2; fi
    printf 'Resolve the problems above, then re-run npm run initialize.\n' >&2
    exit 1
fi
printf 'All prerequisites are available.\n'
