#!/bin/bash
# shellcheck disable=SC1090,SC2034
set -euo pipefail
# Tighten umask so generated host keys / scratch files aren't briefly world-readable.
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_CONFIG="$ROOT_DIR/.env.config"
ENV_FILE="$ROOT_DIR/.env"
ENV_LOCAL="$ROOT_DIR/.env.local"

# shellcheck source=lib/prompts.sh
source "$SCRIPT_DIR/lib/prompts.sh"
set -a
load_env_file "$ENV_FILE"
set +a
# shellcheck source=lib/provision-vps.sh
source "$SCRIPT_DIR/lib/provision-vps.sh"

PV_LABEL="DigitalOcean"
PV_API="https://api.digitalocean.com/v2"
# shellcheck disable=SC2034
PV_ID_KEY="DIGITALOCEAN_DROPLET_ID"
_JQ_STATE='.droplet.status'
_JQ_IP='.droplet.networks.v4[] | select(.type=="public") | .ip_address'
pv_require_tools

# ─── Header ──────────────────────────────────────────────────────────────────

echo
section_header "DigitalOcean VPS Provisioning"
echo
echo "  Creates a droplet (region + size + OS your choice) and writes its IP to"
echo "  .env.local so npm run initialize can proceed immediately."
echo

# ─── 1. API token ─────────────────────────────────────────────────────────────

_validate_token() {
  printf 'header = "Authorization: Bearer %s"\n' "$1" | curl -K - -sf --max-time 10 \
    "${PV_API}/account" 2>/dev/null
}

PV_TOKEN=""
_account=""

if [ -n "${DIGITAL_OCEAN_API_TOKEN:-}" ]; then
  printf '  🔑 Validating DIGITAL_OCEAN_API_TOKEN from .env...\n'
  if _account=$(_validate_token "$DIGITAL_OCEAN_API_TOKEN"); then
    PV_TOKEN="$DIGITAL_OCEAN_API_TOKEN"
  else
    printf '  ⚠️  Token from .env is invalid — enter a new one below.\n'
  fi
fi

while [ -z "$PV_TOKEN" ]; do
  printf '  ℹ️  Get a token at: ' >/dev/tty
  print_link "https://cloud.digitalocean.com/account/api/tokens" >/dev/tty
  printf '  → DigitalOcean API token: ' >/dev/tty
  read_secret _input_token || exit 1
  if [ -z "$_input_token" ]; then
    printf '  ⚠️  Token cannot be empty.\n' >/dev/tty
    continue
  fi
  printf '  🔑 Validating...\n'
  if _account=$(_validate_token "$_input_token"); then
    PV_TOKEN="$_input_token"
  else
    printf '  ❌ Invalid token — check permissions and try again.\n' >/dev/tty
  fi
done

_do_email=$(printf '%s' "$_account" | jq -r '.account.email')
printf '  ✅ Authenticated as: %s\n' "$_do_email"
upsert_env "DIGITAL_OCEAN_API_TOKEN" "$PV_TOKEN"

pv_resume_saved_server "/droplets" "$_JQ_STATE" "$_JQ_IP" "active"
trap 'exit "$PV_EXIT_ABORTED"' EXIT

while true; do

echo
echo "  ⚙️  Available x86 droplet sizes (≥ 1 GB RAM, ≤ \$96/mo):"
echo "  ℹ️  Recommended for n8n + Postgres: ≥ 2 GB RAM  (marked ✓)"
echo
printf '  %4s  %-24s  %5s  %7s  %7s  %9s  %s\n' \
  "#" "Slug" "vCPU" "RAM" "Disk" "Transfer" "Price/mo"
_sizes_file=$(mktemp)
pv_api_get "/sizes?per_page=200" | pv_digitalocean_sizes > "$_sizes_file"
_sizes_count=$(wc -l < "$_sizes_file" | tr -d ' ')
if [ "$_sizes_count" -eq 0 ]; then
  echo "  ❌ DigitalOcean currently has no capacity for these sizes; try later or use Hetzner." >&2
  rm -f "$_sizes_file"
  exit 1
fi
_i=0
while IFS='|' read -r slug vcpus mem disk transfer price regions; do
  _i=$((_i + 1))
  ram_gb=$(( mem / 1024 ))
  marker=""; [ "$ram_gb" -ge 2 ] && marker=" ✓"
  printf '  %4d  %-24s  %5s  %5d GB  %5d GB  %7s TB  $%.0f%s\n' \
    "$_i" "$slug" "$vcpus" "$ram_gb" "$disk" "$transfer" "$price" "$marker"
done < "$_sizes_file"
_size_idx=$(pick_number "  Select size [1-${_sizes_count}]: " "$_sizes_count")
SIZE=$(sed -n "${_size_idx}p" "$_sizes_file" | cut -d'|' -f1)
_size_price=$(sed -n "${_size_idx}p" "$_sizes_file" | cut -d'|' -f6)
_size_ram_mb=$(sed -n "${_size_idx}p" "$_sizes_file" | cut -d'|' -f3)
_size_regions=$(sed -n "${_size_idx}p" "$_sizes_file" | cut -d'|' -f7)

echo
echo "  📍 Available regions for ${SIZE}:"
_regions_file=$(mktemp)
printf '%s\n' "$_size_regions" | tr ',' '\n' | while IFS= read -r region; do
  printf '%s|%s\n' "$region" "$_size_price"
done > "$_regions_file"
pv_pick_location "$_regions_file" '$'
REGION="$PV_LOCATION"
echo "       → $SIZE in $REGION (\$$_size_price/mo)"
rm -f "$_sizes_file" "$_regions_file"

# Memory-limit presets by VPS RAM (initialize.sh shows as defaults).
pv_mem_presets "${_size_ram_mb:-0}"

# ─── 4. OS image ─────────────────────────────────────────────────────────────

echo
echo "  🖥️  Available OS images in ${REGION}:"
echo "  ℹ️  Debian recommended for servers — lighter than Ubuntu, no GUI overhead."
echo

_images_file=$(mktemp)
pv_api_get "/images?type=distribution&per_page=200" \
  | jq -r --arg region "$REGION" '
      .images[]
      | select(
          .public == true
          and .status == "available"
          and (.slug | endswith("-x64"))
          and (.regions | index($region) != null)
          and (.distribution | test("Debian|Ubuntu"; "i"))
        )
      | "\(.slug)|\(.distribution)|\(.name)"
    ' \
  | sort -t'|' -k2,2 -k3,3V \
  > "$_images_file"

_images_count=$(wc -l < "$_images_file" | tr -d ' ')
if [ "$_images_count" -eq 0 ]; then
  echo "  ❌ No OS images found in region $REGION." >&2
  exit 1
fi

_i=0
_debian_idx=1
_debian_name="Debian 13"
while IFS='|' read -r slug distro name; do
  _i=$((_i + 1))
  marker=""
  if printf '%s' "$slug" | grep -qi "^debian-13"; then
    marker="  ← default"
    _debian_idx="$_i"
    _debian_name="$name"
  fi
  printf '  %4d)  %-16s  %-30s  %s\n' "$_i" "$distro" "$name" "$marker"
done < "$_images_file"

echo
_image_idx=$(pick_number "  Select OS [1-${_images_count}, \033[90mEnter for → ${_debian_name}\033[0m]: " "$_images_count" "$_debian_idx")
IMAGE_SLUG=$(sed -n "${_image_idx}p" "$_images_file" | cut -d'|' -f1)
IMAGE_LABEL=$(sed -n "${_image_idx}p" "$_images_file" | cut -d'|' -f2-3 | tr '|' ' ')
echo "       → $IMAGE_LABEL ($IMAGE_SLUG)"

# ─── 5. SSH key ──────────────────────────────────────────────────────────────

while true; do
pv_select_ssh_key "/account/keys?per_page=200" "/account/keys"
pv_match_local_privkey "$PV_KEY_FP" && break
[ -n "${SSH_PRIVATE_KEY:-$(file_var "$ENV_LOCAL" SSH_PRIVATE_KEY)}" ] || exit "$PV_EXIT_ABORTED"
done
validate_ssh_private_key "${_matched_privkey:-}" || exit "$PV_EXIT_ABORTED"

# ─── 5b. DigitalOcean managed backups ────────────────────────────────────────

BACKUP_PLAN=""
BACKUP_WEEKDAY=""
BACKUP_HOUR=0
DO_BACKUPS_JSON=false
DO_BACKUP_POLICY_JSON=null
_backup_plan_label="disabled"

echo
_want_do_backups=$(ask_yn "  Enable DigitalOcean managed backups? [y/N]: ")

case "$_want_do_backups" in
  y)
    DO_BACKUPS_JSON=true

    # https://docs.digitalocean.com/products/droplets/details/pricing/#backups
    _backup_pct_daily=0.20
    _backup_pct_weekly=0.05
    _price_daily=$(awk  "BEGIN {printf \"%.2f\", ${_size_price} * ${_backup_pct_daily}}")
    _price_weekly=$(awk "BEGIN {printf \"%.2f\", ${_size_price} * ${_backup_pct_weekly}}")
    echo ""
    echo "  📅 Backup plan:"
    echo "     1)  daily   — every day       (\$$_price_daily/mo)"
    echo "     2)  weekly  — once a week     (\$$_price_weekly/mo)"
    echo ""
    _plan_idx=$(pick_number "  Select plan [1-2, \033[90mEnter for 2\033[0m]: " "2" "2")
    [ "$_plan_idx" -eq 1 ] && BACKUP_PLAN="daily" || BACKUP_PLAN="weekly"

    if [ "$BACKUP_PLAN" = "weekly" ]; then
      echo ""
      echo "  📅 Day of week:"
      _do_days="SUN MON TUE WED THU FRI SAT"
      _j=0
      for _day in $_do_days; do
        _j=$((_j + 1))
        printf '  %4d)  %s\n' "$_j" "$_day"
      done
      echo ""
      _day_idx=$(pick_number "  Select day [1-7, \033[90mEnter for 2 (MON)\033[0m]: " "7" "2")
      BACKUP_WEEKDAY=$(printf '%s\n' $_do_days | sed -n "${_day_idx}p")
    fi

    echo ""
    echo "  🕐 Backup hour (UTC):"
    _do_hours="0 4 8 12 16 20"
    _j=0
    for _h in $_do_hours; do
      _j=$((_j + 1))
      printf '  %4d)  %02d:00 UTC\n' "$_j" "$_h"
    done
    echo ""
    _hour_idx=$(pick_number "  Select hour [1-6, \033[90mEnter for 1 (00:00 UTC)\033[0m]: " "6" "1")
    BACKUP_HOUR=$(printf '%s\n' $_do_hours | sed -n "${_hour_idx}p")

    if [ "$BACKUP_PLAN" = "weekly" ]; then
      DO_BACKUP_POLICY_JSON=$(jq -n \
        --arg     plan    "$BACKUP_PLAN" \
        --arg     weekday "$BACKUP_WEEKDAY" \
        --argjson hour    "$BACKUP_HOUR" \
        '{plan: $plan, weekday: $weekday, hour: $hour}')
      _backup_plan_label="$BACKUP_PLAN, $BACKUP_WEEKDAY, $(printf '%02d' "$BACKUP_HOUR"):00 UTC"
    else
      DO_BACKUP_POLICY_JSON=$(jq -n \
        --arg     plan "$BACKUP_PLAN" \
        --argjson hour "$BACKUP_HOUR" \
        '{plan: $plan, hour: $hour}')
      _backup_plan_label="$BACKUP_PLAN, $(printf '%02d' "$BACKUP_HOUR"):00 UTC"
    fi
    echo "       → $_backup_plan_label"
    ;;
esac

# ─── 6. Droplet name + confirm ───────────────────────────────────────────────

echo
_project_name=$(file_var "$ENV_CONFIG" "PROJECT_NAME")
pv_prompt_server_name "${_project_name:-n8n}"
DROPLET_NAME="$PV_SERVER_NAME"

if ! pv_confirm_create \
    "Name:|$DROPLET_NAME" \
    "Size:|$SIZE  (\$$_size_price/mo)" \
    "Region:|$REGION" \
    "Image:|$IMAGE_LABEL" \
    "SSH key:|$SSH_KEY_NAME" \
    "Backups:|$_backup_plan_label"; then
  rm -f "$_images_file"
  continue
fi

echo
echo "  🚀 Creating droplet..."

pv_gen_host_keys "$DROPLET_NAME"

_droplet_body=$(jq -n \
  --arg     name          "$DROPLET_NAME" \
  --arg     region        "$REGION" \
  --arg     size          "$SIZE" \
  --arg     image         "$IMAGE_SLUG" \
  --rawfile user_data     <(printf '%s' "$_USER_DATA") \
  --argjson key_id        "$SSH_KEY_ID" \
  --argjson backups       "$DO_BACKUPS_JSON" \
  --argjson backup_policy "$DO_BACKUP_POLICY_JSON" \
  '{
    name:       $name,
    region:     $region,
    size:       $size,
    image:      $image,
    ssh_keys:   [$key_id],
    backups:    $backups,
    ipv6:       false,
    monitoring: true,
    user_data:  $user_data,
    tags:       ["n8n", "n8n-core-setup"]
  } + (if $backup_policy != null then {backup_policy: $backup_policy} else {} end)')

trap - EXIT
pv_create_server "/droplets" "$_droplet_body" '.droplet.id' "$_JQ_IP"
if [ "$PV_CREATE_REJECTED" = true ]; then
  trap 'exit "$PV_EXIT_ABORTED"' EXIT
  rm -f "$_images_file"
  echo "  ↻ Refreshing availability — choose a size again."
  continue
fi
break
done
DROPLET_ID="$PV_SERVER_ID"
echo "     Droplet ID: $DROPLET_ID"
echo "     Waiting for active status..."

# ─── 7. Poll until active, wait for cloud-init ───────────────────────────────

pv_wait_active "/droplets/$DROPLET_ID" "$_JQ_STATE" "$_JQ_IP" "active"

pv_wait_cloud_init "$N8N_VPS_IP"

# ─── 8. Write n8n VPS to .env.local + host fingerprint to .env ─────────────

pv_write_vps_env "$N8N_VPS_IP" "$_HOST_FINGERPRINT"

# ─── 9. Summary ───────────────────────────────────────────────────────────────

rm -f "$_images_file"

cat <<EOF

  ✅ Provisioning complete.

     n8n VPS:
       Name:    $DROPLET_NAME  (id: $DROPLET_ID)
       Size:    $SIZE  (\$$_size_price/mo)
       Region:  $REGION
       Image:   $IMAGE_LABEL  ($IMAGE_SLUG)
       Backups: $_backup_plan_label
       IP:      $N8N_VPS_IP

  Written to .env.local (gitignored) and .env (encrypted into .env.sops.yaml):
     N8N_VPS_USER = root
     N8N_VPS_IP   = $N8N_VPS_IP

  ${PV_SSH_NOTE} — next, unless npm run initialize launched this:
     npm run initialize
EOF
