#!/bin/bash
# shellcheck disable=SC1090
# Callers must export RCLONE_CONFIG_B2_*; no rclone config file is written.
set -euo pipefail

if [ -f ~/n8n/.backup_creds ]; then
  set -a; source ~/n8n/.backup_creds; set +a
fi

: "${BACKBLAZE_KEY_ID:=}"
: "${BACKBLAZE_APPLICATION_KEY:=}"

if [ -z "$BACKBLAZE_KEY_ID" ] || [ -z "$BACKBLAZE_APPLICATION_KEY" ]; then
  echo "ℹ️  ensure-rclone: BACKBLAZE_KEY_ID / BACKBLAZE_APPLICATION_KEY unset — skipping."
  exit 0
fi

if ! command -v rclone >/dev/null 2>&1; then
  echo "▶  Installing rclone (Debian's packaged version is too old for B2 v2 API)..."
  command -v unzip >/dev/null 2>&1 || apt-get install -y --no-install-recommends unzip >/dev/null

  # Pinned + checksum-verified — replaces `curl rclone.org/install.sh | bash`,
  # which was unverified arbitrary code as root. To bump: change RCLONE_VERSION
  # and refresh both sums from the release's SHA256SUMS.
  RCLONE_VERSION=1.74.2
  case "$(uname -m)" in
    x86_64)  RCLONE_ARCH=amd64; RCLONE_SHA256=72a806370072015ccbe4d81bcd348cc5eaf3beca6c65ba693fd43fb31fcca5b1 ;;
    aarch64) RCLONE_ARCH=arm64; RCLONE_SHA256=bc2b2eb8269b743ed7bcea869f3782cfb4931e41efa53fc8befc6dc8308b7a50 ;;
    *) echo "❌ ensure-rclone: unsupported architecture '$(uname -m)' — add its rclone SHA256 to install." >&2; exit 1 ;;
  esac

  RCLONE_DIR="rclone-v${RCLONE_VERSION}-linux-${RCLONE_ARCH}"
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL "https://github.com/rclone/rclone/releases/download/v${RCLONE_VERSION}/${RCLONE_DIR}.zip" -o "$TMP/${RCLONE_DIR}.zip"
  echo "${RCLONE_SHA256}  $TMP/${RCLONE_DIR}.zip" | sha256sum -c -
  unzip -q -o "$TMP/${RCLONE_DIR}.zip" -d "$TMP"
  install -m 755 "$TMP/${RCLONE_DIR}/rclone" /usr/local/bin/rclone
  rm -rf "$TMP"; trap - EXIT

  echo "✅ rclone installed: $(rclone version | head -1)"
else
  echo "✅ rclone present: $(rclone version | head -1)"
fi
