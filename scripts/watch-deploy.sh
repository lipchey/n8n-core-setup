#!/bin/bash
set -u

GIT_DIR="$(git rev-parse --git-dir 2>/dev/null || echo .git)"
REQUEST="$GIT_DIR/watch-deploy.request"
PIDFILE="$GIT_DIR/watch-deploy.pid"
IDLE_TIMEOUT=1800

# shellcheck source=lib/prompts.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/prompts.sh"

_have_gh() {
  command -v gh >/dev/null 2>&1 || { echo "gh not installed — skip."; return 1; }
  gh auth status >/dev/null 2>&1 || { echo "gh not authenticated (gh auth login) — skip."; return 1; }
}

watch_one() { # sha (empty → latest run on main)
  local sha="$1" id="" url=""
  if [ -n "$sha" ]; then
    for _ in $(seq 1 30); do
      id=$(gh run list -w deploy.yml -b main -L 20 --json databaseId,headSha \
           -q "[.[] | select(.headSha==\"$sha\")][0].databaseId" 2>/dev/null)
      [ -n "$id" ] && break
      sleep 3
    done
  else
    id=$(gh run list -w deploy.yml -b main -L 1 --json databaseId -q '.[0].databaseId' 2>/dev/null)
  fi
  [ -n "$id" ] || { printf '%s — %s\n' "Deploy" "No Actions run found${sha:+ for ${sha:0:7}}"; return; }
  url=$(gh run view "$id" --json url -q .url 2>/dev/null)
  printf '🔭 Watching run %s — ' "$id"
  print_link "$url"
  if gh run watch "$id" --exit-status; then
    # Skip mode is a green run in which every deploy_mode-gated step was skipped.
    local validate
    validate=$(gh run view "$id" --json jobs \
      -q '.jobs[] | select(.name == "deploy") | .steps[] | select(.name == "Validate required config") | .conclusion' 2>/dev/null)
    if [ "$validate" = "skipped" ]; then
      printf '⏭️ Deploy skipped — %s nothing shipped ' "${sha:0:7}"
      print_link "$url"
    else
      printf '✅ Deploy succeeded — %s ' "${sha:0:7}"
      print_link "$url"
    fi
  else
    local job_url
    job_url=$(gh run view "$id" --json jobs \
      -q '.jobs[] | select(.conclusion == "failure") | .url' 2>/dev/null | head -1)
    printf '❌ Deploy failed — %s ' "${sha:0:7}"
    print_link "${job_url:-$url}"
  fi
}

case "${1:-}" in
  --loop)
    _have_gh || { echo "Press Enter to close."; read -r _ || true; exit 0; }
    echo $$ > "$PIDFILE"
    trap 'rm -f "$PIDFILE"' EXIT
    printf '\033]0;Deploy watcher\007'
    echo "🔭 Deploy watcher ready — follows each push to main in this window. Ctrl+C to stop."
    last=""; idle=0
    while true; do
      sha="$(cat "$REQUEST" 2>/dev/null || true)"
      if [ -n "$sha" ] && [ "$sha" != "$last" ]; then
        last="$sha"; idle=0
        echo; echo "── $(date '+%H:%M:%S')  push ${sha:0:7} ──"
        watch_one "$sha"
        echo "— idle; waiting for the next push —"
      else
        sleep 3; idle=$((idle + 3))
        [ "$idle" -ge "$IDLE_TIMEOUT" ] && { echo "Idle $((IDLE_TIMEOUT / 60)) min — closing watcher."; break; }
      fi
    done
    ;;
  --sha)
    _have_gh || exit 0
    watch_one "${2:-}"
    ;;
  *)
    _have_gh || exit 0
    watch_one ""
    ;;
esac
