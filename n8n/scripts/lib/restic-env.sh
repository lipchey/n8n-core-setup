#!/bin/bash
# Restic/B2 environment setup. Requires common.sh sourced + load_backup_creds run.

# Validates PROJECT_NAME (interpolated into restic --host/--tag) and exports RESTIC_PASSWORD.
setup_restic_local() {
  [[ "$PROJECT_NAME" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] \
    || die "PROJECT_NAME '$PROJECT_NAME' invalid — must match ^[a-z0-9][a-z0-9-]{0,30}\$"
  require_cmds restic
  export RESTIC_PASSWORD="$BACKUP_PASSWORD"
}

# rc 0 = B2 fully configured (exports RCLONE_CONFIG_B2_*); rc 1 = B2 not configured.
# Partial config dies — a typo'd var must not silently disable offsite copies.
setup_restic_b2() {
  local _set=0 _v
  for _v in BACKBLAZE_KEY_ID BACKBLAZE_APPLICATION_KEY RESTIC_REPOSITORY_BACKBLAZE; do
    [ -n "${!_v:-}" ] && _set=$((_set + 1))
  done
  [ "$_set" -eq 0 ] && return 1
  [ "$_set" -eq 3 ] || die "Backblaze partially configured — need all of BACKBLAZE_KEY_ID, BACKBLAZE_APPLICATION_KEY, RESTIC_REPOSITORY_BACKBLAZE (check .backup_creds / .env.sops.yaml)"
  # Remote configured via env so we never touch ~/.config/rclone/rclone.conf.
  export RCLONE_CONFIG_B2_TYPE=b2 \
         RCLONE_CONFIG_B2_ACCOUNT="$BACKBLAZE_KEY_ID" \
         RCLONE_CONFIG_B2_KEY="$BACKBLAZE_APPLICATION_KEY" \
         RCLONE_CONFIG_B2_HARD_DELETE=true
}
