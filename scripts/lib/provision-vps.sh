#!/bin/bash
# shellcheck disable=SC2034
# Bash 3.2 callers must source prompts.sh and set PV_LABEL, PV_API, PV_ID_KEY and PV_TOKEN.

# Exit codes a caller must tell apart: operator declined the create / create outcome unknown.
PV_EXIT_ABORTED=10
PV_EXIT_UNCERTAIN=11

# printf %.2f breaks under comma-decimal locales when run standalone.
export LC_ALL=C

pv_require_tools() {
  local _c
  for _c in jq curl ssh-keygen; do
    command -v "$_c" >/dev/null || { echo "❌ $_c is required (brew install $_c)" >&2; exit 1; }
  done
}

pv_api_get() {
  local path="$1"
  printf 'header = "Authorization: Bearer %s"\n' "$PV_TOKEN" | curl -K - -sS "${CURL_TIMEOUTS[@]}" --fail-with-body \
    "${PV_API}${path}" || { echo "❌ ${PV_LABEL} API error: GET $path" >&2; exit 1; }
}

# Non-fatal variant for poll loops — one transient API hiccup must not kill the
# script after the server was already created but before env writeback.
pv_api_try_get() {
  local path="$1"
  printf 'header = "Authorization: Bearer %s"\n' "$PV_TOKEN" | curl -K - -sS --fail-with-body --connect-timeout 10 --max-time 20 \
    "${PV_API}${path}" 2>/dev/null
}

pv_api_post() {
  local path="$1" body="$2"
  printf '%s' "$body" | curl -sS "${CURL_TIMEOUTS[@]}" --fail-with-body -X POST \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "$PV_TOKEN") \
    -H "Content-Type: application/json" \
    --data @- \
    "${PV_API}${path}" || { echo "❌ ${PV_LABEL} API error: POST $path" >&2; exit 1; }
}

# Call unconditionally to preserve errexit on state writes; a lost response may still be billing.
pv_create_server() {
  local _path="$1" _body="$2" _jq_id="$3" _jq_ip="$4" _out _rc=0 _code _resp _ip
  PV_SERVER_ID=""
  PV_CREATE_REJECTED=false
  _out=$(printf '%s' "$_body" | curl -sS "${CURL_TIMEOUTS[@]}" -X POST \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "$PV_TOKEN") \
    -H "Content-Type: application/json" \
    --data @- -w '\n%{http_code}' \
    "${PV_API}${_path}") || _rc=$?
  _code="${_out##*$'\n'}"
  _resp="${_out%$'\n'*}"

  if [ "$_rc" -eq 0 ]; then
    case "$_code" in
      2??) PV_SERVER_ID=$(printf '%s' "$_resp" | jq -r "$_jq_id // empty" 2>/dev/null || true) ;;
      408) ;;
      4??)
        echo "  ❌ ${PV_LABEL} rejected the request (HTTP ${_code}) — no server was created." >&2
        printf '%s' "$_resp" | jq -r '.error.message // .message // empty' >&2 2>/dev/null || true
        PV_CREATE_REJECTED=true
        return 0
        ;;
    esac
  fi

  # An out-of-alphabet path would stop the next run's env check.
  if [ -f "${_matched_privkey:-}" ] && env_value_ok "$_matched_privkey"; then
    upsert_env_local "SSH_PRIVATE_KEY" "$_matched_privkey"
  fi

  if [ -z "$PV_SERVER_ID" ]; then
    # A server that does exist was given this host key, so resuming it needs the fingerprint kept.
    upsert_env "N8N_VPS_HOST_FINGERPRINT" "$_HOST_FINGERPRINT"
    cat >&2 <<EOF

  ❌ ${PV_LABEL} create call: outcome unknown (curl exit ${_rc}, HTTP ${_code}). A server may exist and be billing.
     Not retrying. Check the ${PV_LABEL} dashboard, then:
       - if the server exists: add ${PV_ID_KEY}=<its id> to .env.local and re-run to resume it
       - if it does not: re-run to create it
EOF
    exit "$PV_EXIT_UNCERTAIN"
  fi

  upsert_env_local "$PV_ID_KEY" "$PV_SERVER_ID"
  _ip=$(printf '%s' "$_resp" | jq -r "$_jq_ip" 2>/dev/null | head -n1 || true)
  if [ -n "$_ip" ]; then
    pv_write_vps_env "$_ip" "$_HOST_FINGERPRINT"
  else
    upsert_env "N8N_VPS_HOST_FINGERPRINT" "$_HOST_FINGERPRINT"
  fi
}

pv_hetzner_available() {
  jq '
    .server_types |= map(
      select(.architecture == "x86" and .memory >= 1)
      | [.locations[]? | select(.available == true and .deprecation == null) | .name] as $locations
      | .prices |= map(select(.location as $location | $locations | index($location)))
      | select(.prices | length > 0)
    )'
}

pv_hetzner_types() {
  pv_hetzner_available | jq -r '
    [.server_types[] | . + {lowest: ([.prices[].price_monthly.gross | tonumber] | min)}]
    | sort_by(.lowest)[]
    | [.prices[].price_monthly.gross | tonumber] as $prices
    | [.name, .cores, .memory, .disk, .cpu_type, .lowest, .architecture,
       (.prices | length), (($prices | min) != ($prices | max))] | join("|")'
}

pv_hetzner_locations() {
  pv_hetzner_available | jq -r --arg type "$1" '
    .server_types[] | select(.name == $type)
    | .prices | sort_by(.price_monthly.gross | tonumber)[]
    | [.location, (.price_monthly.gross | tonumber)] | join("|")'
}

pv_digitalocean_sizes() {
  jq -r '
    [.sizes[] | select(.available == true and .memory >= 1024 and .price_monthly <= 96
      and (.regions | length > 0)
      and ((.architecture // "x86") | IN("x86", "x86_64", "amd64")))]
    | sort_by(.price_monthly)[]
    | [.slug, .vcpus, .memory, .disk, .transfer, .price_monthly, (.regions | join(","))] | join("|")'
}

pv_pick_location() {
  local file="$1" currency="$2" count index name price
  count=$(wc -l < "$file" | tr -d ' ')
  index=0
  while IFS='|' read -r name price; do
    index=$((index + 1))
    printf '  %3d)  %-12s  %s%.2f/mo\n' "$index" "$name" "$currency" "$price" >>"$_PV_TTY_OUT"
  done < "$file"
  index=$(pick_number "  Select location [1-${count}, Enter for 1]: " "$count" 1 true) || return 1
  PV_LOCATION=$(sed -n "${index}p" "$file" | cut -d'|' -f1)
  PV_LOCATION_PRICE=$(sed -n "${index}p" "$file" | cut -d'|' -f2)
}

# pv_resume_saved_server PATH_PREFIX JQ_STATE JQ_IP WANT_STATE — with a saved ID, finishes that
# server and exits instead of letting the caller create a second paid one. No saved ID: returns.
pv_resume_saved_server() {
  local _prefix="$1" _jq_state="$2" _jq_ip="$3" _want="$4" _id _code _fingerprint
  _id=$(file_var "$ENV_LOCAL" "$PV_ID_KEY")
  [ -n "$_id" ] || return 0

  _fingerprint=$(file_var "$ENV_FILE" "N8N_VPS_HOST_FINGERPRINT")
  if [ -z "$_fingerprint" ] || [ "$_fingerprint" = "SHA256:paste_fingerprint_here" ]; then
    cat >&2 <<EOF
  ❌ ${PV_LABEL} server ${_id} is saved (${PV_ID_KEY} in .env.local), but .env has no N8N_VPS_HOST_FINGERPRINT.
     The fingerprint lives in the encrypted secrets (.env.sops.yaml). Either:
       - run npm run decrypt-env, then re-run to resume this server
       - remove ${PV_ID_KEY} from .env.local, then re-run to create a new server
EOF
    exit 1
  fi

  _matched_privkey=$(file_var "$ENV_LOCAL" "SSH_PRIVATE_KEY")
  _matched_privkey="${_matched_privkey/#\~/$HOME}"
  if [ -n "$_matched_privkey" ]; then validate_ssh_private_key "$_matched_privkey" || exit 1; fi

  echo "  ↻ Resuming ${PV_LABEL} server ${_id} (${PV_ID_KEY} in .env.local)..."
  _code=$(printf 'header = "Authorization: Bearer %s"\n' "$PV_TOKEN" | curl -K - -sS "${CURL_TIMEOUTS[@]}" -o /dev/null -w '%{http_code}' \
    "${PV_API}${_prefix}/${_id}") || _code="000"
  case "$_code" in
    2??) ;;
    404)
      echo "  ❌ ${PV_LABEL} server ${_id} no longer exists. Remove ${PV_ID_KEY} from .env.local to create a new one." >&2
      exit 1
      ;;
    *)
      echo "  ❌ Could not check ${PV_LABEL} server ${_id} (HTTP ${_code}). Not creating another; re-run to retry." >&2
      exit 1
      ;;
  esac

  pv_wait_active "${_prefix}/${_id}" "$_jq_state" "$_jq_ip" "$_want"
  pv_wait_cloud_init "$N8N_VPS_IP"
  pv_write_vps_env "$N8N_VPS_IP" "$_fingerprint"
  echo
  if [ "$PV_SSH_NOTE" = "SSH is ready" ]; then
    echo "  ✅ Resumed ${PV_LABEL} server ${_id}. IP: ${N8N_VPS_IP}"
  else
    echo "  ⚠️  ${PV_LABEL} server ${_id} is saved (IP: ${N8N_VPS_IP}), but cloud-init is not confirmed done."
    echo "     Check with: ssh${_matched_privkey:+ -i $_matched_privkey} root@${N8N_VPS_IP} 'cloud-init status'"
  fi
  cat <<EOF
     To create a new server instead, remove ${PV_ID_KEY} from .env.local.

  ${PV_SSH_NOTE} — next, unless npm run initialize launched this:
     npm run initialize
EOF
  exit 0
}

# pv_mem_presets RAM_MB — picks docker memory-limit tier, upserts .env.config.
pv_mem_presets() {
  local _ram_mb="${1:-0}" _pg_mem _n8n_mem _cf_mem _mem_tier
  if   [ "$_ram_mb" -ge 7680 ]; then
      _pg_mem=2g;   _n8n_mem=4g;   _cf_mem=128m; _mem_tier="8 GB"
  elif [ "$_ram_mb" -ge 3072 ]; then
      _pg_mem=1g;   _n8n_mem=2g;   _cf_mem=128m; _mem_tier="4 GB"
  elif [ "$_ram_mb" -ge 1536 ]; then
      _pg_mem=512m; _n8n_mem=1g;   _cf_mem=128m; _mem_tier="2 GB"
  else
      _pg_mem=256m; _n8n_mem=512m; _cf_mem=64m; _mem_tier="1 GB"
  fi
  echo "       → Memory preset for ${_mem_tier} tier: postgres=${_pg_mem}  n8n=${_n8n_mem}  cloudflared=${_cf_mem}"
  upsert_env_config "POSTGRES_MEM_LIMIT"    "$_pg_mem"
  upsert_env_config "N8N_MEM_LIMIT"         "$_n8n_mem"
  upsert_env_config "CLOUDFLARED_MEM_LIMIT" "$_cf_mem"
}

# pv_select_ssh_key LIST_PATH UPLOAD_PATH — lists account keys (uploading a local
# .pub when none exist), prompts a pick. Sets SSH_KEY_ID / SSH_KEY_NAME / PV_KEY_FP.
pv_select_ssh_key() {
  local _list_path="$1" _upload_path="$2"
  local _keys_file _keys_count _i

  echo
  echo "  🔑 SSH keys on your ${PV_LABEL} account:"
  echo

  _keys_file=$(mktemp)
  pv_api_get "$_list_path" \
    | jq -r '.ssh_keys[] | "\(.id)|\(.name)|\(.fingerprint)"' \
    > "$_keys_file"

  _keys_count=$(wc -l < "$_keys_file" | tr -d ' ')
  if [ "$_keys_count" -eq 0 ]; then
    echo "  ℹ️  No SSH keys found on your ${PV_LABEL} account."
    echo "     Let's upload one now."
    echo ""

    local _pub_files=() _f _pub_path="" _pub_idx
    while IFS= read -r -d '' _f; do
      _pub_files+=("$_f")
    done < <(find "$HOME/.ssh" -maxdepth 1 -name "*.pub" -print0 2>/dev/null | sort -z)

    if [ "${#_pub_files[@]}" -gt 0 ]; then
      echo "  Found public keys in ~/.ssh/:"
      echo ""
      _i=0
      for _f in "${_pub_files[@]}"; do
        _i=$((_i + 1))
        printf '  %4d)  %s\n' "$_i" "$_f"
      done
      echo ""
      _pub_idx=$(pick_number "  Select key [1-${#_pub_files[@]}]: " "${#_pub_files[@]}")
      _pub_path="${_pub_files[$((_pub_idx - 1))]}"
    else
      echo "  ℹ️  No .pub files found in ~/.ssh/ — enter the full path manually."
      echo ""
    fi

    while [ -z "$_pub_path" ] || [ ! -f "$_pub_path" ]; do
      printf '  → Path to public key (.pub): ' >/dev/tty
      read -r _pub_path </dev/tty
      [ -f "$_pub_path" ] || { printf '  ⚠️  File not found: %s\n' "$_pub_path" >/dev/tty; _pub_path=""; }
    done

    local _pub_content _default_key_name _key_name_input _key_name
    _pub_content=$(cat "$_pub_path")
    _default_key_name="$(hostname -s 2>/dev/null || basename "$_pub_path" .pub)"
    printf '  → Key name \033[90m[%s]\033[0m: ' "$_default_key_name" >/dev/tty
    read -r _key_name_input </dev/tty
    _key_name="${_key_name_input:-$_default_key_name}"

    echo "     Uploading..."
    local _upload_body _upload_resp _new_key_id _new_key_fp
    _upload_body=$(jq -n --arg name "$_key_name" --arg pub "$_pub_content" \
      '{name: $name, public_key: $pub}')
    _upload_resp=$(pv_api_post "$_upload_path" "$_upload_body")
    _new_key_id=$(printf '%s' "$_upload_resp" | jq -r '.ssh_key.id')
    _new_key_fp=$(printf '%s' "$_upload_resp" | jq -r '.ssh_key.fingerprint')

    if [ -z "$_new_key_id" ] || [ "$_new_key_id" = "null" ]; then
      echo "  ❌ Failed to upload SSH key. Response:" >&2
      printf '%s\n' "$_upload_resp" >&2
      exit 1
    fi

    printf '%s|%s|%s\n' "$_new_key_id" "$_key_name" "$_new_key_fp" > "$_keys_file"
    _keys_count=1
    echo "     ✅ Uploaded: $_key_name  ($_new_key_fp)"
    echo ""
  fi

  _i=0
  local id name fingerprint
  while IFS='|' read -r id name fingerprint; do
    _i=$((_i + 1))
    printf '  %4d)  %-30s  %s\n' "$_i" "$name" "$fingerprint"
  done < "$_keys_file"

  echo
  local _key_idx
  _key_idx=$(pick_number "  Select SSH key [1-${_keys_count}]: " "$_keys_count")
  SSH_KEY_ID=$(sed -n "${_key_idx}p" "$_keys_file" | cut -d'|' -f1)
  SSH_KEY_NAME=$(sed -n "${_key_idx}p" "$_keys_file" | cut -d'|' -f2)
  PV_KEY_FP=$(sed -n "${_key_idx}p" "$_keys_file" | cut -d'|' -f3)
  rm -f "$_keys_file"
  echo "       → $SSH_KEY_NAME"
}

pv_match_local_privkey() {
  local _want_fp="$1" _pub _local_fp _priv _selected
  _matched_privkey=""
  _selected="${SSH_PRIVATE_KEY:-$(file_var "${ENV_LOCAL:-}" SSH_PRIVATE_KEY)}"
  _selected="${_selected/#\~/$HOME}"
  if [ -n "$_selected" ]; then
    _local_fp=$(ssh-keygen -y -P '' -f "$_selected" 2>/dev/null \
      | ssh-keygen -E md5 -lf - 2>/dev/null | awk '{print $2}' | sed 's/^MD5://') || _local_fp=""
    if [ -n "$_local_fp" ] && [ "$_local_fp" = "$_want_fp" ]; then
      _matched_privkey="$_selected"
      echo "     ✅ Private key found: $_matched_privkey"
      return 0
    fi
    printf '     ⚠️  Provider SSH key does not match the selected private key %s; choose the matching provider key.\n' "$_selected" >&2
    return 1
  fi
  for _pub in "$HOME"/.ssh/*.pub; do
    [ -f "$_pub" ] || continue
    _local_fp=$(ssh-keygen -E md5 -lf "$_pub" 2>/dev/null | LC_ALL=C awk '{print $2}' | sed 's/^MD5://')
    if [ "$_local_fp" = "$_want_fp" ]; then
      _priv="${_pub%.pub}"
      [ ! -f "$_priv" ] || _matched_privkey="$_priv"
      break
    fi
  done

  if [ -n "$_matched_privkey" ]; then
    echo "     ✅ Private key found: $_matched_privkey"
  else
    printf '     ⚠️  No matching private key found in ~/.ssh/ for fingerprint %s\n' "$_want_fp"
    printf '        Make sure the private key is available before running npm run initialize.\n'
    return 1
  fi
}

# pv_prompt_server_name DEFAULT — validated name loop. Sets PV_SERVER_NAME.
pv_prompt_server_name() {
  local _default_name="$1"
  while true; do
    printf '  Server name \033[90m[%s]\033[0m: ' "$_default_name" >/dev/tty
    read -r PV_SERVER_NAME </dev/tty
    PV_SERVER_NAME="${PV_SERVER_NAME:-$_default_name}"
    PV_SERVER_NAME=$(printf '%s' "$PV_SERVER_NAME" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if printf '%s' "$PV_SERVER_NAME" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9.-]{0,253}[a-zA-Z0-9]$|^[a-zA-Z0-9]$'; then
      break
    fi
    echo "  ⚠️  Invalid name — use only letters, digits, hyphens, dots; no leading/trailing hyphens or spaces." >/dev/tty
  done
}

# EOF must abort even though Enter confirms a create.
pv_confirm_create() {
  local _row _label _value _confirm
  echo
  echo "  ┌─────────────────────────────────────────────┐"
  for _row in "$@"; do
    _label="${_row%%|*}"; _value="${_row#*|}"
    printf '  │  %-9s%-34s│\n' "$_label" "$_value"
  done
  echo "  └─────────────────────────────────────────────┘"
  echo
  _beep
  while true; do
    printf '  Create this server? [Y/n/r]: ' >>"$_PV_TTY_OUT"
    if ! IFS= read -r _confirm <"$_PV_TTY_IN"; then
      echo "  Aborted — no server created."
      exit "$PV_EXIT_ABORTED"
    fi
    case "$_confirm" in
      y|Y|yes|YES|'') return 0 ;;
      r|R|retry|RETRY)
        echo "  ↺ Restarting config — you'll be re-prompted from the top." >>"$_PV_TTY_OUT"
        echo "" >>"$_PV_TTY_OUT"
        return 1
        ;;
      n|N|no|NO) echo "  Aborted — no server created."; exit "$PV_EXIT_ABORTED" ;;
      *) echo "  Please enter y, n, or r." >>"$_PV_TTY_OUT" ;;
    esac
  done
}

# pv_gen_host_keys NAME — pre-generates the host key, injects it via cloud-init.
# ed25519-ONLY: drone-ssh (Go) prefers ECDSA>RSA>ed25519, so any extra key type makes it negotiate THAT and the pinned ed25519 fp mismatches.
pv_gen_host_keys() {
  local _name="$1" _hk_dir _ed_priv _ed_pub
  _hk_dir=$(mktemp -d)
  chmod 700 "$_hk_dir"
  ssh-keygen -q -t ed25519 -N '' -C "n8n-vps-${_name}" \
    -f "$_hk_dir/ssh_host_ed25519_key" >/dev/null

  _HOST_FINGERPRINT=$(ssh-keygen -lf "$_hk_dir/ssh_host_ed25519_key.pub" | LC_ALL=C awk '{print $2}')
  echo "       → Pre-generated host fingerprint: $_HOST_FINGERPRINT"

  _ed_priv=$(cat "$_hk_dir/ssh_host_ed25519_key")
  _ed_pub=$(cat  "$_hk_dir/ssh_host_ed25519_key.pub")

  _USER_DATA=$(cat <<CLOUDINIT
#cloud-config
ssh_genkeytypes: ['ed25519']
ssh_keys:
  ed25519_private: |
$(printf '%s\n' "$_ed_priv" | sed 's/^/    /')
  ed25519_public: $_ed_pub
runcmd:
  - [ systemctl, restart, ssh ]
CLOUDINIT
)
  # Wipe private host keys — public fingerprint is all we need.
  rm -rf "$_hk_dir"
}

# pv_wait_active ID_PATH JQ_STATE JQ_IP WANT_STATE — polls until the server
# reports WANT_STATE and has a public IP. Sets N8N_VPS_IP + PV_STATE.
pv_wait_active() {
  local _id_path="$1" _jq_state="$2" _jq_ip="$3" _want="$4"
  local _attempt _status
  N8N_VPS_IP=""
  PV_STATE=""
  for _attempt in $(seq 1 36); do
    sleep 10
    # Tolerate transient API failures mid-poll — server already exists.
    _status=$(pv_api_try_get "$_id_path") || { printf '     [%2d/36] API hiccup — retrying\n' "$_attempt"; continue; }
    PV_STATE=$(printf '%s' "$_status" | jq -r "$_jq_state" 2>/dev/null || echo "")
    N8N_VPS_IP=$(printf '%s' "$_status" | jq -r "$_jq_ip" 2>/dev/null | head -n1)
    printf '     [%2d/36] %-12s %s\n' "$_attempt" "${PV_STATE:-?}" "${N8N_VPS_IP:-—}"
    [ "$PV_STATE" = "$_want" ] && [ -n "$N8N_VPS_IP" ] && break
  done

  if [ -z "$N8N_VPS_IP" ] || [ "$PV_STATE" != "$_want" ]; then
    echo "" >&2
    echo "  ❌ Server did not become ${_want} within 6 minutes." >&2
    echo "     Check the ${PV_LABEL} dashboard, then re-run: it resumes the saved server." >&2
    exit 1
  fi
}

# pv_wait_cloud_init IP — "active/running" only means the VM booted; cloud-init's
# runcmd restarts sshd at the end of boot, so connecting earlier gets
# "Connection closed". Polls until cloud-init reports done.
pv_wait_cloud_init() {
  local _ip="$1" _attempt _ci_status
  PV_SSH_NOTE="cloud-init had not finished — wait a bit first"
  local _ssh_id_opt=()
  [ -f "${_matched_privkey:-}" ] && _ssh_id_opt=(-i "$_matched_privkey")
  echo "     Waiting for cloud-init to finish on the VPS..."
  for _attempt in $(seq 1 30); do
    sleep 10
    # ${arr[@]+...} — bash 3.2/4.3 raise "unbound variable" on empty arrays under set -u.
    # Exit 2 means done with recoverable errors, so the output counts whatever the exit status.
    _ci_status=$(ssh ${_ssh_id_opt[@]+"${_ssh_id_opt[@]}"} \
      -o BatchMode=yes -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@${_ip}" 'cloud-init status' 2>/dev/null) || true
    if printf '%s' "$_ci_status" | grep -qE 'status: (degraded )?done'; then
      printf '     [%2d/30] cloud-init done — SSH ready\n' "$_attempt"
      PV_SSH_NOTE="SSH is ready"
      break
    fi
    printf '     [%2d/30] %s\n' "$_attempt" "${_ci_status:-not reachable yet}"
  done

  if [ "$PV_SSH_NOTE" != "SSH is ready" ]; then
    echo "" >&2
    echo "  ⚠️  cloud-init did not report done within 5 minutes." >&2
    echo "     The server exists and stays saved: nothing new is created on a re-run." >&2
  fi
}

# pv_write_vps_env IP FP — .env.local for local use; .env so the encrypted
# .env.sops.yaml carries the values into deploy.yml.
pv_write_vps_env() {
  upsert_env_local "N8N_VPS_IP"   "$1"
  upsert_env_local "N8N_VPS_USER" "root"
  upsert_env       "N8N_VPS_IP"   "$1"
  upsert_env       "N8N_VPS_USER" "root"
  # Pre-generated fingerprint pinned so verification has no TOFU window.
  upsert_env "N8N_VPS_HOST_FINGERPRINT" "$2"
}
