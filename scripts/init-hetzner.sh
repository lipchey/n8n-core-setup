#!/bin/bash
# shellcheck disable=SC1090,SC2034
set -euo pipefail
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

PV_LABEL="Hetzner"
PV_API="https://api.hetzner.cloud/v1"
# shellcheck disable=SC2034
PV_ID_KEY="HETZNER_SERVER_ID"
_JQ_STATE='.server.status'
_JQ_IP='.server.public_net.ipv4.ip // empty'
pv_require_tools

# ─── Header ──────────────────────────────────────────────────────────────────

echo
section_header "Hetzner Cloud VPS Provisioning"
echo
echo "  Creates a server (location + type + OS your choice) and writes its"
echo "  IP to .env.local so npm run initialize can proceed immediately."
echo

# ─── 1. API token ─────────────────────────────────────────────────────────────

_validate_token() {
  printf 'header = "Authorization: Bearer %s"\n' "$1" | curl -K - -sf --max-time 10 \
    "${PV_API}/locations" 2>/dev/null
}

PV_TOKEN=""

if [ -n "${HETZNER_API_TOKEN:-}" ]; then
  printf '  🔑 Validating HETZNER_API_TOKEN from .env...\n'
  if _validate_token "$HETZNER_API_TOKEN" >/dev/null; then
    PV_TOKEN="$HETZNER_API_TOKEN"
    printf '  ✅ Token valid.\n'
  else
    printf '  ⚠️  Token from .env is invalid — enter a new one below.\n'
  fi
fi

while [ -z "$PV_TOKEN" ]; do
  printf '  ℹ️  Get a token at: ' >/dev/tty
  print_link "https://console.hetzner.com" >/dev/tty
  printf '     → project → Security → API Tokens\n' >/dev/tty
  printf '  → Hetzner API token: ' >/dev/tty
  read_secret _input_token || exit 1
  if [ -z "$_input_token" ]; then
    printf '  ⚠️  Token cannot be empty.\n' >/dev/tty
    continue
  fi
  printf '  🔑 Validating...\n'
  if _validate_token "$_input_token" >/dev/null; then
    PV_TOKEN="$_input_token"
    printf '  ✅ Token valid.\n'
  else
    printf '  ❌ Invalid token — check permissions and try again.\n' >/dev/tty
  fi
done

upsert_env "HETZNER_API_TOKEN" "$PV_TOKEN"

pv_resume_saved_server "/servers" "$_JQ_STATE" "$_JQ_IP" "running"
trap 'exit "$PV_EXIT_ABORTED"' EXIT

# ─── Interactive server config (retry loop covers steps 2–7) ─────────────────
while true; do

echo
echo "  ⚙️  Available x86 server types (≥ 1 GB RAM):"
echo "  ℹ️  Recommended for n8n + Postgres: ≥ 2 GB RAM  (marked ✓)"
echo
printf '  %4s  %-14s  %5s  %6s  %7s  %10s  %-18s  %s\n' \
  "#" "Type" "vCPU" "RAM" "Disk" "CPU" "Price/mo" "Locations"

_types_json=$(pv_api_get "/server_types?per_page=100")
_types_file=$(mktemp)
printf '%s' "$_types_json" | pv_hetzner_types > "$_types_file"
_types_count=$(wc -l < "$_types_file" | tr -d ' ')
if [ "$_types_count" -eq 0 ]; then
  echo "  ❌ Hetzner currently has no capacity for these x86 types; try later or use DigitalOcean." >&2
  rm -f "$_types_file"
  exit 1
fi
_i=0
while IFS='|' read -r name cores mem disk cpu_type price arch locations varies; do
  _i=$((_i + 1))
  marker=""; [ "$(awk "BEGIN{print ($mem >= 2)}")" -eq 1 ] && marker=" ✓"
  _from=""; [ "$varies" != true ] || _from="from "
  printf '  %4d  %-14s  %5d  %5.0f GB  %5d GB  %10s  %s€%.2f%s  %s locations\n' \
    "$_i" "$name" "$cores" "$mem" "$disk" "$cpu_type" "$_from" "$price" "$marker" "$locations"
done < "$_types_file"
_type_idx=$(pick_number "  Select type [1-${_types_count}]: " "$_types_count")
SERVER_TYPE=$(sed -n "${_type_idx}p" "$_types_file" | cut -d'|' -f1)
_type_ram=$(sed -n "${_type_idx}p" "$_types_file" | cut -d'|' -f3)
_type_arch=$(sed -n "${_type_idx}p" "$_types_file" | cut -d'|' -f7)

echo
echo "  📍 Available locations for ${SERVER_TYPE}:"
_locs_file=$(mktemp)
printf '%s' "$_types_json" | pv_hetzner_locations "$SERVER_TYPE" > "$_locs_file"
pv_pick_location "$_locs_file" "€"
LOCATION="$PV_LOCATION"
_type_price="$PV_LOCATION_PRICE"
echo "       → $SERVER_TYPE in $LOCATION (€$(printf '%.2f' "$_type_price")/mo)"
rm -f "$_types_file" "$_locs_file"

# Memory-limit presets by server RAM.
_size_ram_mb=$(awk "BEGIN{printf \"%d\", $_type_ram * 1024}")
pv_mem_presets "${_size_ram_mb:-0}"

# ─── 4. OS image ─────────────────────────────────────────────────────────────

echo
echo "  🖥️  Available OS images:"
echo "  ℹ️  Debian recommended for servers — lighter than Ubuntu, no GUI overhead."
echo

_images_file=$(mktemp)
pv_api_get "/images?type=system&architecture=${_type_arch:-x86}&per_page=100" \
  | jq -r '
      .images[]
      | select(
          .status == "available"
          and (.os_flavor | test("debian|ubuntu"; "i"))
        )
      | "\(.name)|\(.os_flavor)|\(.description)"
    ' \
  | sort -t'|' -k2,2 -k3,3V \
  > "$_images_file"

_images_count=$(wc -l < "$_images_file" | tr -d ' ')
if [ "$_images_count" -eq 0 ]; then
  echo "  ❌ No OS images found for architecture ${_type_arch:-x86}." >&2
  exit 1
fi
_i=0
_default_idx=1
_default_name="debian-13"
while IFS='|' read -r name flavor desc; do
  _i=$((_i + 1))
  marker=""
  if [ "$name" = "debian-13" ]; then
    marker="  ← default"
    _default_idx="$_i"
    _default_name="$desc"
  fi
  printf '  %4d)  %-10s  %-32s  %s\n' "$_i" "$flavor" "$desc" "$marker"
done < "$_images_file"

echo
_image_idx=$(pick_number "  Select OS [1-${_images_count}, \033[90mEnter for → ${_default_name}\033[0m]: " "$_images_count" "$_default_idx")
IMAGE_NAME=$(sed -n "${_image_idx}p" "$_images_file" | cut -d'|' -f1)
IMAGE_LABEL=$(sed -n "${_image_idx}p" "$_images_file" | cut -d'|' -f2-3 | tr '|' ' ')
echo "       → $IMAGE_LABEL ($IMAGE_NAME)"

# ─── 5. SSH key ──────────────────────────────────────────────────────────────

while true; do
pv_select_ssh_key "/ssh_keys?per_page=100" "/ssh_keys"
pv_match_local_privkey "$PV_KEY_FP" && break
[ -n "${SSH_PRIVATE_KEY:-$(file_var "$ENV_LOCAL" SSH_PRIVATE_KEY)}" ] || exit "$PV_EXIT_ABORTED"
done
validate_ssh_private_key "${_matched_privkey:-}" || exit "$PV_EXIT_ABORTED"

# ─── 5b. Hetzner managed backups ─────────────────────────────────────────────

_backups_label="disabled"
_backups_enabled=false

echo
_want_backups=$(ask_yn "  Enable Hetzner managed backups? (+~20% server cost) [y/N]: ")
if [ "$_want_backups" = "y" ]; then
  _backups_enabled=true
  _backups_label="enabled"
fi

# ─── 6. Server name + confirm ────────────────────────────────────────────────

echo
_project_name=$(file_var "$ENV_CONFIG" "PROJECT_NAME")
pv_prompt_server_name "${_project_name:-n8n}"
SERVER_NAME="$PV_SERVER_NAME"

if ! pv_confirm_create \
    "Name:|$SERVER_NAME" \
    "Type:|$SERVER_TYPE  (€$(printf '%.2f' "$_type_price")/mo)" \
    "Location:|$LOCATION" \
    "Image:|$IMAGE_LABEL" \
    "SSH key:|$SSH_KEY_NAME" \
    "Backups:|$_backups_label"; then
  rm -f "$_images_file"
  continue
fi

echo
echo "  🚀 Creating server..."

pv_gen_host_keys "$SERVER_NAME"

_server_body=$(jq -n \
  --arg     name        "$SERVER_NAME" \
  --arg     server_type "$SERVER_TYPE" \
  --arg     location    "$LOCATION" \
  --arg     image       "$IMAGE_NAME" \
  --rawfile user_data   <(printf '%s' "$_USER_DATA") \
  --argjson key_id      "$SSH_KEY_ID" \
  --argjson backups     "$_backups_enabled" \
  '{
    name:        $name,
    server_type: $server_type,
    location:    $location,
    image:       $image,
    ssh_keys:    [$key_id],
    backups:     $backups,
    user_data:   $user_data
  }')

trap - EXIT
pv_create_server "/servers" "$_server_body" '.server.id' "$_JQ_IP"
if [ "$PV_CREATE_REJECTED" = true ]; then
  trap 'exit "$PV_EXIT_ABORTED"' EXIT
  rm -f "$_images_file"
  echo "  ↻ Refreshing availability — choose a server type again."
  continue
fi
break
done
SERVER_ID="$PV_SERVER_ID"
echo "     Server ID: $SERVER_ID"
echo "     Waiting for running status..."

# ─── 7. Poll until running, wait for cloud-init ──────────────────────────────

pv_wait_active "/servers/$SERVER_ID" "$_JQ_STATE" "$_JQ_IP" "running"

pv_wait_cloud_init "$N8N_VPS_IP"

# ─── 8. Write to env files ────────────────────────────────────────────────────

pv_write_vps_env "$N8N_VPS_IP" "$_HOST_FINGERPRINT"

# ─── 9. Summary ─────────────────────────────────────────────────────────────

rm -f "$_images_file"

cat <<EOF

  ✅ Provisioning complete.

     n8n VPS:
       Name:     $SERVER_NAME  (id: $SERVER_ID)
       Type:     $SERVER_TYPE  (€$(printf '%.2f' "$_type_price")/mo)
       Location: $LOCATION
       Image:    $IMAGE_LABEL  ($IMAGE_NAME)
       Backups:  $_backups_label
       IP:       $N8N_VPS_IP

  Written to .env.local (gitignored) and .env (encrypted into .env.sops.yaml):
     N8N_VPS_USER = root
     N8N_VPS_IP   = $N8N_VPS_IP

  ${PV_SSH_NOTE} — next, unless npm run initialize launched this:
     npm run initialize
EOF
