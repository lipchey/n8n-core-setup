#!/bin/bash
# Cloudflare bootstrap: tunnel + ingress + DNS CNAME + Zero Trust Access app
# + Access policy. Idempotent. Writes TUNNEL_TOKEN to .env.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"

# shellcheck source=../lib/prompts.sh
source "$ROOT_DIR/scripts/lib/prompts.sh"

if [ ! -f "$ROOT_DIR/.env.config" ]; then
  echo "❌ .env.config not found at $ROOT_DIR/.env.config" >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
load_env_file "$ROOT_DIR/.env.config"
if [ -f "$ROOT_DIR/.env" ]; then
  # shellcheck disable=SC1091
  load_env_file "$ROOT_DIR/.env"
fi
set +a

: "${CLOUDFLARE_API_TOKEN:?Missing CLOUDFLARE_API_TOKEN — add it to .env}"
: "${PROJECT_NAME:?Missing PROJECT_NAME in .env.config}"
: "${DEVELOPER_EMAIL:?Missing DEVELOPER_EMAIL in .env.config}"

command -v jq   >/dev/null || { echo "❌ jq is required (brew install jq)";   exit 1; }
command -v curl >/dev/null || { echo "❌ curl is required";                    exit 1; }

# Exactly one of N8N_COMMON_DOMAIN / N8N_PROJECTS_DOMAIN.
if [ -n "${N8N_COMMON_DOMAIN:-}" ] && [ -n "${N8N_PROJECTS_DOMAIN:-}" ]; then
  echo "❌ Set only one of N8N_COMMON_DOMAIN or N8N_PROJECTS_DOMAIN in .env.config, not both." >&2
  exit 1
elif [ -n "${N8N_COMMON_DOMAIN:-}" ]; then
  HOSTNAME="${PROJECT_NAME}.${N8N_COMMON_DOMAIN}"
  ZONE_NAME="${N8N_COMMON_DOMAIN}"
  ZONE_CANDIDATES=("${N8N_COMMON_DOMAIN}")
elif [ -n "${N8N_PROJECTS_DOMAIN:-}" ]; then
  HOSTNAME="${N8N_PROJECTS_DOMAIN}"
  # Try suffixes longest→shortest; only the API can say which is registered.
  ZONE_CANDIDATES=()
  _remaining="$N8N_PROJECTS_DOMAIN"
  while [[ "$_remaining" == *.* ]]; do
    ZONE_CANDIDATES+=("$_remaining")
    _remaining="${_remaining#*.}"
  done
  # Fallback for bare single-label (e.g. `localhost`) so we surface a real error.
  [ "${#ZONE_CANDIDATES[@]}" -eq 0 ] && ZONE_CANDIDATES=("$N8N_PROJECTS_DOMAIN")
  ZONE_NAME="${ZONE_CANDIDATES[0]}"
  unset _remaining
else
  echo "❌ Set either N8N_COMMON_DOMAIN or N8N_PROJECTS_DOMAIN in .env.config." >&2
  exit 1
fi

API="https://api.cloudflare.com/client/v4"
# CLOUDFLARE_RESOURCE_SUFFIX isolates DR/test copies from prod (e.g. "-dr").
# Empty by default — leaves prod tunnel/MCP token names untouched.
RES_SUFFIX="${CLOUDFLARE_RESOURCE_SUFFIX:-}"
if [ -n "$RES_SUFFIX" ]; then
  echo "⚠️  CLOUDFLARE_RESOURCE_SUFFIX='${RES_SUFFIX}' — using ISOLATED resource names (NOT prod's tunnel/MCP token)." >&2
fi
TUNNEL_NAME="${PROJECT_NAME}-n8n${RES_SUFFIX}"
APP_NAME="${PROJECT_NAME} n8n${RES_SUFFIX}"

# cf METHOD PATH [BODY] — returns .result, aborts on .success != true.
cf() {
  local method="$1" path="$2" body="${3-}"
  local resp
  if [ -n "$body" ]; then
    resp=$(printf 'header = "Authorization: Bearer %s"\n' "$CLOUDFLARE_API_TOKEN" | curl -K - -sS "${CURL_TIMEOUTS[@]}" --fail-with-body -X "$method" "${API}${path}" \
      -H "Content-Type: application/json" \
      --data "$body") || true
  else
    resp=$(printf 'header = "Authorization: Bearer %s"\n' "$CLOUDFLARE_API_TOKEN" | curl -K - -sS "${CURL_TIMEOUTS[@]}" --fail-with-body -X "$method" "${API}${path}") || true
  fi
  if [ -z "$resp" ]; then
    echo "❌ No response from Cloudflare API ($method $path) — check network and CLOUDFLARE_API_TOKEN" >&2
    exit 1
  fi
  local _success
  # jq's `.success // empty` collapses false→empty, mislabeling {"success":false} as non-JSON — test has() instead.
  _success=$(printf '%s' "$resp" | jq -r 'if has("success") then (.success|tostring) else empty end' 2>/dev/null || true)
  if [ -z "$_success" ]; then
    echo "❌ Cloudflare API returned non-JSON on $method $path (likely edge HTML 5xx):" >&2
    printf '%s\n' "$resp" | head -c 1024 >&2; echo >&2
    exit 1
  fi
  if [ "$_success" != "true" ]; then
    echo "❌ Cloudflare API error on $method $path:" >&2
    echo "$resp" | jq . >&2
    _cf_authz_hint "$resp" "the relevant Account/Zone scope (see 'npm run initialize' → Cloudflare API token section for the full list)"
    exit 1
  fi
  echo "$resp"
}

# Print a remediation hint when a CF response indicates the token lacks a permission.
# Caller passes the response JSON + the human-readable scope name (e.g. "Zone → Transform Rules → Edit").
_cf_authz_hint() {
  local _resp="$1" _scope="$2"
  local _msg
  _msg=$(printf '%s' "$_resp" | jq -r '.errors[]?.message // empty' 2>/dev/null | head -1)
  if printf '%s' "$_msg" | grep -qiE "not authorized|authentication|forbidden|insufficient"; then
    {
      echo ""
      echo "   👉  Cloudflare API token is missing: $_scope"
      echo "       Edit the token to add the permission at:"
      print_link "https://dash.cloudflare.com/profile/api-tokens"
      echo "       then retry (token value stays the same — permissions apply immediately)."
    } >&2
  fi
}

echo "🌩  Cloudflare init for project: $PROJECT_NAME"
echo "    Hostname: $HOSTNAME"
echo

ZONE_ID=""
while [ -z "$ZONE_ID" ]; do
  for _candidate in "${ZONE_CANDIDATES[@]}"; do
    echo "🔎 Looking up Cloudflare zone for $_candidate..."
    _zone_resp=$(cf GET "/zones?name=${_candidate}")
    ZONE_ID=$(printf '%s' "$_zone_resp" | jq -r '.result[0].id // empty')
    if [ -n "$ZONE_ID" ]; then
      ZONE_NAME="$_candidate"
      break
    fi
  done
  if [ -z "$ZONE_ID" ]; then
    echo "  ⚠️  None of the candidate zones (${ZONE_CANDIDATES[*]}) were found in your Cloudflare account." >&2
    echo "     Add the registered apex domain via Add a domain at:" >&2
    print_link "https://dash.cloudflare.com" >&2
    printf '  Press Enter to retry, or Ctrl+C to abort: ' >/dev/tty
    read -r _ </dev/tty
  fi
done
unset _candidate
echo "   Zone ID: $ZONE_ID  (zone: $ZONE_NAME)"

# The zone names its owning account; the first entry of /accounts is arbitrary on a multi-account token.
if [ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
  CLOUDFLARE_ACCOUNT_ID=$(printf '%s' "$_zone_resp" | jq -r '.result[0].account.id // empty')
  if [ -z "$CLOUDFLARE_ACCOUNT_ID" ]; then
    echo "❌ Zone $ZONE_NAME did not report its Cloudflare account." >&2
    echo "   Add CLOUDFLARE_ACCOUNT_ID=<your-account-id> to .env.config as a manual override." >&2
    echo "   (Find it in the Cloudflare dashboard → right sidebar on any domain page.)" >&2
    exit 1
  fi
  echo "   Account ID: $CLOUDFLARE_ACCOUNT_ID"
fi

# 2. Find or create the tunnel
echo "🚇 Finding or creating tunnel '$TUNNEL_NAME'..."
TUNNEL_ID=$(cf GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel?name=${TUNNEL_NAME}&is_deleted=false" \
  | jq -r '.result[0].id // empty')

if [ -z "$TUNNEL_ID" ]; then
  TUNNEL_SECRET=$(openssl rand -base64 32)
  body=$(jq -n --arg name "$TUNNEL_NAME" --arg secret "$TUNNEL_SECRET" \
    '{name:$name, tunnel_secret:$secret, config_src:"cloudflare"}')
  TUNNEL_ID=$(cf POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel" "$body" \
    | jq -r '.result.id')
  echo "   Created new tunnel: $TUNNEL_ID"
else
  echo "   Reusing existing tunnel: $TUNNEL_ID"
fi

echo "🔑 Fetching tunnel token..."
TUNNEL_TOKEN=$(cf GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token" \
  | jq -r '.result')
# Defensive — null/empty would land in .env and surface as an opaque cloudflared error.
if [ -z "$TUNNEL_TOKEN" ] || [ "$TUNNEL_TOKEN" = "null" ]; then
  echo "❌ Cloudflare /cfd_tunnel/${TUNNEL_ID}/token returned empty/null .result — refusing to write a bogus TUNNEL_TOKEN" >&2
  exit 1
fi

# Final catch-all rule is required by Cloudflare. Hostname → n8n:5678 by Compose service name.
printf '🛣️  Setting tunnel ingress: %s → ' "$HOSTNAME"
print_link "http://n8n:5678"
ingress_body=$(jq -n --arg host "$HOSTNAME" '{
  config: {
    ingress: [
      { hostname: $host, service: "http://n8n:5678" },
      { service: "http_status:404" }
    ]
  }
}')
cf PUT "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" "$ingress_body" >/dev/null

# 5. Upsert proxied CNAME
echo "🌐 Upserting CNAME $HOSTNAME → ${TUNNEL_ID}.cfargotunnel.com"
DNS_TARGET="${TUNNEL_ID}.cfargotunnel.com"
_dns_resp=$(cf GET "/zones/${ZONE_ID}/dns_records?type=CNAME&name=${HOSTNAME}")
EXISTING_DNS=$(printf '%s' "$_dns_resp" | jq -r '.result[0].id // empty')
EXISTING_DNS_TARGET=$(printf '%s' "$_dns_resp" | jq -r '.result[0].content // empty')
dns_body=$(jq -n --arg name "$HOSTNAME" --arg content "$DNS_TARGET" \
  '{type:"CNAME", name:$name, content:$content, proxied:true, ttl:1, comment:"n8n-core-setup: n8n tunnel"}')

if [ -n "$EXISTING_DNS" ]; then
  case "$EXISTING_DNS_TARGET" in
    *.cfargotunnel.com) ;;
    *)
      echo "⚠️  $HOSTNAME is a CNAME to $EXISTING_DNS_TARGET, not a Cloudflare tunnel." >&2
      echo "   Repointing it sends that hostname's traffic to n8n." >&2
      if [ "$(ask_yn "  Repoint it to this tunnel? [y/N]: ")" != "y" ]; then
        echo "❌ Left $HOSTNAME unchanged. Choose another hostname or remove the record, then re-run." >&2
        exit 1
      fi
      ;;
  esac
  cf PUT  "/zones/${ZONE_ID}/dns_records/${EXISTING_DNS}" "$dns_body" >/dev/null
  echo "   Updated existing record ($EXISTING_DNS)"
else
  cf POST "/zones/${ZONE_ID}/dns_records" "$dns_body" >/dev/null
  echo "   Created new record"
fi

# 6. Cloudflare Access (Zero Trust) Application
echo "🔐 Configuring Zero Trust Access for $HOSTNAME..."
EXISTING_APP=$(cf GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps?per_page=200" \
  | jq -r --arg domain "$HOSTNAME" '.result[] | select(.domain==$domain) | .id' | head -n1)

app_body=$(jq -n --arg name "$APP_NAME" --arg domain "$HOSTNAME" '{
  name: $name,
  domain: $domain,
  type: "self_hosted",
  session_duration: "24h",
  app_launcher_visible: true
}')

if [ -n "$EXISTING_APP" ]; then
  APP_ID="$EXISTING_APP"
  cf PUT "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps/${APP_ID}" "$app_body" >/dev/null
  echo "   Updated existing Access app ($APP_ID)"
else
  APP_ID=$(cf POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps" "$app_body" \
    | jq -r '.result.id')
  echo "   Created new Access app: $APP_ID"
fi

# 7. Access policy: allow developer + CF account owner
# Fetch the CF account owner's email so the client (not just the boilerplate
# maintainer) can log in. Token needs 'User → User Details → Read'.
OWNER_EMAIL=""
while :; do
  _user_resp=$(printf 'header = "Authorization: Bearer %s"\n' "$CLOUDFLARE_API_TOKEN" | curl -K - -sS "${CURL_TIMEOUTS[@]}" "${API}/user" 2>/dev/null || true)
  if [ "$(printf '%s' "$_user_resp" | jq -r '.success // false' 2>/dev/null)" = "true" ]; then
    OWNER_EMAIL=$(printf '%s' "$_user_resp" | jq -r '.result.email // empty')
  fi
  [ -n "$OWNER_EMAIL" ] && break
  echo "⚠️  Could not fetch Cloudflare account owner email." >&2
  echo "   The token likely lacks 'User → User Details → Read' permission." >&2
  echo "   Without it, only $DEVELOPER_EMAIL will be allowed through the Access gate —" >&2
  echo "   the account owner won't be able to log in to n8n unless added manually later." >&2
  _retry=$(ask_yn "  Retry after adding the scope to the token? [Y/n]: " "y")
  [ "$_retry" = "n" ] && break
done

_include_emails=("$DEVELOPER_EMAIL")
if [ -n "$OWNER_EMAIL" ] && [ "$OWNER_EMAIL" != "$DEVELOPER_EMAIL" ]; then
  _include_emails+=("$OWNER_EMAIL")
fi

# Cloudflare requires a unique precedence per app: keep the policy's own, else take the next free slot.
_policy_precedence() {
  printf '%s' "$1" | jq --arg name "$2" \
    '[.result[]? | select(.name==$name) | .precedence][0] // (([.result[]?.precedence] | max // 0) + 1)'
}

POLICY_NAME="Allow developer access"
# Matched by name: any other allow policy on the app was added by hand and must survive a re-run.
_policies=$(cf GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps/${APP_ID}/policies?per_page=200")
EXISTING_POLICY=$(printf '%s' "$_policies" \
  | jq -r --arg name "$POLICY_NAME" '.result[]? | select(.name==$name and .decision=="allow") | .id' | head -n1)
_other_allow=$(printf '%s' "$_policies" \
  | jq -r --arg name "$POLICY_NAME" '.result[]? | select(.name!=$name and .decision=="allow") | .name')
[ -z "$_other_allow" ] || printf '   ℹ️  Leaving other allow policies untouched: %s\n' "$(printf '%s' "$_other_allow" | tr '\n' ',')"

_emails_json=$(printf '%s\n' "${_include_emails[@]}" | jq -R . | jq -s .)
policy_body=$(jq -n --arg name "$POLICY_NAME" --argjson emails "$_emails_json" \
  --argjson precedence "$(_policy_precedence "$_policies" "$POLICY_NAME")" '{
  name: $name,
  decision: "allow",
  precedence: $precedence,
  include: ($emails | map({email: {email: .}}))
}')

if [ -n "$EXISTING_POLICY" ]; then
  cf PUT "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps/${APP_ID}/policies/${EXISTING_POLICY}" "$policy_body" >/dev/null
  echo "   Updated Access policy ($EXISTING_POLICY) → allow ${_include_emails[*]}"
else
  cf POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps/${APP_ID}/policies" "$policy_body" >/dev/null
  echo "   Created Access policy → allow ${_include_emails[*]}"
fi

# 7b. Service Token + MCP policy
# Lets Claude Code (and other coding-agent MCP clients) pass Cloudflare Access
# non-interactively via CF-Access-Client-Id/Secret headers. Required because
# MCP clients can't complete the email-OTP flow used by humans.
SERVICE_TOKEN_NAME="${PROJECT_NAME}-n8n-mcp${RES_SUFFIX}"
echo "🔑 Configuring Cloudflare Access service token '$SERVICE_TOKEN_NAME' for MCP..."

_existing_tokens=$(cf GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/service_tokens?per_page=200")
SERVICE_TOKEN_ID=$(printf '%s' "$_existing_tokens" \
  | jq -r --arg name "$SERVICE_TOKEN_NAME" '.result[]? | select(.name==$name) | .id' | head -n1)
SERVICE_TOKEN_CLIENT_ID=$(printf '%s' "$_existing_tokens" \
  | jq -r --arg name "$SERVICE_TOKEN_NAME" '.result[]? | select(.name==$name) | .client_id // empty' | head -n1)

# CF returns the client_secret ONLY at create or rotate — never on subsequent GETs.
# So: reuse only if BOTH the saved CF_ACCESS_CLIENT_ID matches the live one AND
# CF_ACCESS_CLIENT_SECRET is already in .env. Otherwise rotate or create.
_env_client_id=$(file_var "$ENV_FILE" "CF_ACCESS_CLIENT_ID")
_env_client_secret=$(file_var "$ENV_FILE" "CF_ACCESS_CLIENT_SECRET")

CF_ACCESS_CLIENT_ID=""
CF_ACCESS_CLIENT_SECRET=""
_token_kept=false

if [ -n "$SERVICE_TOKEN_ID" ] \
   && [ -n "$_env_client_id" ] && [ "$_env_client_id" = "$SERVICE_TOKEN_CLIENT_ID" ] \
   && [ -n "$_env_client_secret" ]; then
  CF_ACCESS_CLIENT_ID="$_env_client_id"
  CF_ACCESS_CLIENT_SECRET="$_env_client_secret"
  echo "   Reusing existing service token ($SERVICE_TOKEN_ID)"
elif [ -n "$SERVICE_TOKEN_ID" ]; then
  echo "   Service token $SERVICE_TOKEN_ID exists, but .env has no matching secret." >&2
  echo "   Rotating gets a new secret and breaks anything still using the current one." >&2
  if [ "$(ask_yn "  Rotate the service token now? [y/N]: ")" = "y" ]; then
    _rotated=$(cf POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/service_tokens/${SERVICE_TOKEN_ID}/rotate" "{}")
    CF_ACCESS_CLIENT_ID=$(printf '%s' "$_rotated" | jq -r '.result.client_id // empty')
    CF_ACCESS_CLIENT_SECRET=$(printf '%s' "$_rotated" | jq -r '.result.client_secret // empty')
    echo "   Rotated service token ($SERVICE_TOKEN_ID) — new secret captured"
  else
    _token_kept=true
    echo "   Keeping the token." >&2
    if [ -n "$_env_client_id" ] && [ -n "$SERVICE_TOKEN_CLIENT_ID" ] && [ "$_env_client_id" != "$SERVICE_TOKEN_CLIENT_ID" ]; then
      # Otherwise initialize.sh would build .mcp.json from credentials Access rejects.
      upsert_env CF_ACCESS_CLIENT_ID ""
      upsert_env CF_ACCESS_CLIENT_SECRET ""
      echo "   ⚠️  .env held credentials of another token, so they were cleared. MCP setup is skipped until you rotate; the live token is untouched." >&2
    elif [ -z "$_env_client_id" ] || [ -z "$_env_client_secret" ]; then
      echo "   n8n MCP setup stays skipped until CF_ACCESS_CLIENT_ID and CF_ACCESS_CLIENT_SECRET are in .env." >&2
    fi
  fi
else
  _create_body=$(jq -n --arg name "$SERVICE_TOKEN_NAME" '{name:$name, duration:"8760h"}')
  _created=$(cf POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/service_tokens" "$_create_body")
  SERVICE_TOKEN_ID=$(printf '%s' "$_created" | jq -r '.result.id // empty')
  CF_ACCESS_CLIENT_ID=$(printf '%s' "$_created" | jq -r '.result.client_id // empty')
  CF_ACCESS_CLIENT_SECRET=$(printf '%s' "$_created" | jq -r '.result.client_secret // empty')
  echo "   Created new service token: $SERVICE_TOKEN_ID"
fi

if [ "$_token_kept" = "false" ]; then
  if [ -z "$CF_ACCESS_CLIENT_ID" ] || [ -z "$CF_ACCESS_CLIENT_SECRET" ] || [ -z "$SERVICE_TOKEN_ID" ]; then
    echo "❌ Failed to obtain Cloudflare Access service-token credentials — aborting." >&2
    exit 1
  fi
  upsert_env CF_ACCESS_CLIENT_ID     "$CF_ACCESS_CLIENT_ID"
  upsert_env CF_ACCESS_CLIENT_SECRET "$CF_ACCESS_CLIENT_SECRET"
fi

# Separate policy so the identity-based "Allow developer" policy stays clean.
MCP_POLICY_NAME="Allow MCP service token"
_existing_policies=$(cf GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps/${APP_ID}/policies?per_page=200")
EXISTING_MCP_POLICY=$(printf '%s' "$_existing_policies" \
  | jq -r --arg name "$MCP_POLICY_NAME" '.result[]? | select(.name==$name) | .id' | head -n1)
# What token does the current policy point to? When PROJECT_NAME changed between
# runs, the policy still allowlists the previous run's token — left behind, that
# token is an orphan AND breaks MCP if .mcp.json holds the freshly-created one.
_old_mcp_token_id=$(printf '%s' "$_existing_policies" \
  | jq -r --arg name "$MCP_POLICY_NAME" '.result[]? | select(.name==$name) | .include[]?.service_token?.token_id // empty' | head -n1)

mcp_policy_body=$(jq -n --arg name "$MCP_POLICY_NAME" --arg tid "$SERVICE_TOKEN_ID" \
  --argjson precedence "$(_policy_precedence "$_existing_policies" "$MCP_POLICY_NAME")" '{
  name: $name,
  decision: "non_identity",
  precedence: $precedence,
  include: [ { service_token: { token_id: $tid } } ]
}')

if [ -n "$EXISTING_MCP_POLICY" ]; then
  cf PUT "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps/${APP_ID}/policies/${EXISTING_MCP_POLICY}" "$mcp_policy_body" >/dev/null
  echo "   Updated MCP policy ($EXISTING_MCP_POLICY)"
else
  cf POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps/${APP_ID}/policies" "$mcp_policy_body" >/dev/null
  echo "   Created MCP policy → allow service token"
fi

# Clean up any orphan service token left from a previous run that used a
# different PROJECT_NAME (the current naming scheme would never find it again).
if [ -n "$_old_mcp_token_id" ] && [ "$_old_mcp_token_id" != "$SERVICE_TOKEN_ID" ]; then
  # Subshell: cf exits on failure, which would end this script with its output discarded.
  ( cf DELETE "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/service_tokens/${_old_mcp_token_id}" ) >/dev/null 2>&1 \
    && echo "   Deleted orphan service token ${_old_mcp_token_id} (previously in policy)" \
    || echo "   ⚠️  Could not delete orphan service token ${_old_mcp_token_id} — clean up manually"
fi

# Bypass /webhook/* and /webhook-test/* — Access auth would block them otherwise.
_upsert_bypass_app() {
  local path="$1" app_label="$2"
  local bypass_domain="${HOSTNAME}/${path}"
  local bypass_app_name="${PROJECT_NAME} n8n ${app_label}${RES_SUFFIX}"
  local bypass_policy_name="Bypass ${path}"

  echo "🔓 Configuring bypass for /${path}..."

  local existing_bypass_app
  existing_bypass_app=$(cf GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps?per_page=200" \
    | jq -r --arg d "$bypass_domain" '.result[] | select(.domain==$d) | .id' | head -n1)

  local bypass_app_body
  bypass_app_body=$(jq -n --arg name "$bypass_app_name" --arg domain "$bypass_domain" '{
    name: $name,
    domain: $domain,
    type: "self_hosted",
    app_launcher_visible: false
  }')

  local bypass_app_id
  if [ -n "$existing_bypass_app" ]; then
    bypass_app_id="$existing_bypass_app"
    cf PUT "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps/${bypass_app_id}" "$bypass_app_body" >/dev/null
    echo "   Updated bypass app ($bypass_app_id)"
  else
    bypass_app_id=$(cf POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps" "$bypass_app_body" \
      | jq -r '.result.id')
    echo "   Created bypass app: $bypass_app_id"
  fi

  local existing_bypass_policy
  existing_bypass_policy=$(cf GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps/${bypass_app_id}/policies" \
    | jq -r --arg name "$bypass_policy_name" '.result[] | select(.name==$name) | .id' | head -n1)

  local bypass_policy_body
  bypass_policy_body=$(jq -n --arg name "$bypass_policy_name" '{
    name: $name,
    decision: "bypass",
    precedence: 1,
    include: [ { everyone: {} } ]
  }')

  if [ -n "$existing_bypass_policy" ]; then
    cf PUT "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps/${bypass_app_id}/policies/${existing_bypass_policy}" \
      "$bypass_policy_body" >/dev/null
    echo "   Updated bypass policy ($existing_bypass_policy)"
  else
    cf POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps/${bypass_app_id}/policies" \
      "$bypass_policy_body" >/dev/null
    echo "   Created bypass policy → everyone"
  fi
}

_upsert_bypass_app "webhook"      "Webhooks"
_upsert_bypass_app "webhook-test" "Webhook Tests"

# ASN-allowlist skip (32934=Meta 36459=GitHub 62041=Telegram); Stripe relies on in-workflow HMAC not ASN; per-host expr+desc so a shared zone does not leak the skip to siblings.
WAF_RULE_DESC="Allow n8n Webhooks (Telegram, Meta, GitHub) — ${HOSTNAME}"
WAF_RULE_EXPR="(http.host eq \"${HOSTNAME}\") and (ip.geoip.asnum in {32934 36459 62041}) and (http.request.uri.path contains \"/webhook\" or http.request.uri.path contains \"/webhook-test\")"

echo "🛡️  Configuring WAF custom rule for webhook services..."

# If no entrypoint ruleset exists yet, GET returns 10003 → seed via PUT.
_waf_entrypoint=$(printf 'header = "Authorization: Bearer %s"\n' "$CLOUDFLARE_API_TOKEN" | curl -K - -sS --max-time 10 \
  "${API}/zones/${ZONE_ID}/rulesets/phases/http_request_firewall_custom/entrypoint" || true)

_waf_success=$(printf '%s' "$_waf_entrypoint" | jq -r '.success // false' 2>/dev/null || echo false)
_waf_err_code=$(printf '%s' "$_waf_entrypoint" | jq -r '.errors[0].code // empty' 2>/dev/null || echo "")

_existing_waf_rule_id=""
_existing_waf_ruleset_id=""
if [ "$_waf_success" = "true" ]; then
  _existing_waf_ruleset_id=$(printf '%s' "$_waf_entrypoint" | jq -r '.result.id // empty')
  _existing_waf_rule_id=$(printf '%s' "$_waf_entrypoint" \
    | jq -r --arg desc "$WAF_RULE_DESC" \
      '.result.rules[]? | select(.description==$desc) | .id' | head -n1)
  _legacy_waf_desc="Allow n8n Webhooks (Telegram, Meta, GitHub)"
  _legacy_waf_rule_id=$(printf '%s' "$_waf_entrypoint" \
    | jq -r --arg desc "$_legacy_waf_desc" '.result.rules[]? | select(.description==$desc) | .id' | head -n1)
  if [ -n "$_legacy_waf_rule_id" ]; then
    echo "   ⚠️  Legacy WAF skip rule $_legacy_waf_rule_id applies to every host in zone $ZONE_NAME, not just $HOSTNAME." >&2
    echo "      Remove it: Cloudflare dashboard → $ZONE_NAME → Security → WAF → Custom rules → delete \"$_legacy_waf_desc\"." >&2
  fi
elif [ "$_waf_err_code" != "10003" ]; then
  echo "❌ Unexpected response inspecting WAF entrypoint:" >&2
  printf '%s' "$_waf_entrypoint" | jq . >&2 || printf '%s\n' "$_waf_entrypoint" >&2
  _cf_authz_hint "$_waf_entrypoint" "Zone → Firewall Services → Edit (and Zone → Zone WAF → Edit)"
  exit 1
fi

_waf_rule_body=$(jq -n --arg desc "$WAF_RULE_DESC" --arg expr "$WAF_RULE_EXPR" '{
  description: $desc,
  expression:  $expr,
  action:      "skip",
  action_parameters: {
    phases:   ["http_request_firewall_managed", "http_request_sbfm"],
    products: ["waf", "bic", "securityLevel"]
  },
  logging: { enabled: true },
  enabled: true
}')

if [ "$_waf_success" != "true" ]; then
  _waf_seed_body=$(jq -n --argjson rule "$_waf_rule_body" '{rules: [$rule]}')
  cf PUT "/zones/${ZONE_ID}/rulesets/phases/http_request_firewall_custom/entrypoint" \
    "$_waf_seed_body" >/dev/null
  echo "   Seeded entrypoint ruleset + WAF rule → Skip for Telegram / Meta / GitHub on /webhook*"
elif [ -n "$_existing_waf_rule_id" ]; then
  cf PATCH "/zones/${ZONE_ID}/rulesets/${_existing_waf_ruleset_id}/rules/${_existing_waf_rule_id}" \
    "$_waf_rule_body" >/dev/null
  echo "   Updated WAF rule ($_existing_waf_rule_id)"
else
  cf POST "/zones/${ZONE_ID}/rulesets/${_existing_waf_ruleset_id}/rules" \
    "$_waf_rule_body" >/dev/null
  echo "   Created WAF rule → Skip for Telegram / Meta / GitHub on /webhook*"
fi

# Tells Google/Bing not to index — fresh subdomain with a login form trips
# Safe Browsing / Enhanced Safe Browsing heuristics and Chrome flags it "Dangerous".
ROBOTS_RULE_DESC="n8n: X-Robots-Tag noindex (Safe Browsing trust signal) — ${HOSTNAME}"
ROBOTS_RULE_EXPR="(http.host eq \"${HOSTNAME}\")"

echo "🤖 Configuring Transform Rule: X-Robots-Tag noindex on $HOSTNAME..."

_robots_entrypoint=$(printf 'header = "Authorization: Bearer %s"\n' "$CLOUDFLARE_API_TOKEN" | curl -K - -sS --max-time 10 \
  "${API}/zones/${ZONE_ID}/rulesets/phases/http_response_headers_transform/entrypoint" || true)

_robots_success=$(printf '%s' "$_robots_entrypoint" | jq -r '.success // false' 2>/dev/null || echo false)
_robots_err_code=$(printf '%s' "$_robots_entrypoint" | jq -r '.errors[0].code // empty' 2>/dev/null || echo "")

_existing_robots_rule_id=""
_existing_robots_ruleset_id=""
if [ "$_robots_success" = "true" ]; then
  _existing_robots_ruleset_id=$(printf '%s' "$_robots_entrypoint" | jq -r '.result.id // empty')
  _existing_robots_rule_id=$(printf '%s' "$_robots_entrypoint" \
    | jq -r --arg desc "$ROBOTS_RULE_DESC" \
      '.result.rules[]? | select(.description==$desc) | .id' | head -n1)
elif [ "$_robots_err_code" != "10003" ]; then
  echo "❌ Unexpected response inspecting response-headers entrypoint:" >&2
  printf '%s' "$_robots_entrypoint" | jq . >&2 || printf '%s\n' "$_robots_entrypoint" >&2
  _cf_authz_hint "$_robots_entrypoint" "Zone → Transform Rules → Edit"
  exit 1
fi

_robots_rule_body=$(jq -n --arg desc "$ROBOTS_RULE_DESC" --arg expr "$ROBOTS_RULE_EXPR" '{
  description: $desc,
  expression:  $expr,
  action:      "rewrite",
  action_parameters: {
    headers: {
      "X-Robots-Tag": { operation: "set", value: "noindex, nofollow" }
    }
  },
  enabled: true
}')

if [ "$_robots_success" != "true" ]; then
  _robots_seed_body=$(jq -n --argjson rule "$_robots_rule_body" '{rules: [$rule]}')
  cf PUT "/zones/${ZONE_ID}/rulesets/phases/http_response_headers_transform/entrypoint" \
    "$_robots_seed_body" >/dev/null
  echo "   Seeded entrypoint ruleset + Transform Rule → X-Robots-Tag noindex on $HOSTNAME"
elif [ -n "$_existing_robots_rule_id" ]; then
  cf PATCH "/zones/${ZONE_ID}/rulesets/${_existing_robots_ruleset_id}/rules/${_existing_robots_rule_id}" \
    "$_robots_rule_body" >/dev/null
  echo "   Updated Transform Rule ($_existing_robots_rule_id)"
else
  cf POST "/zones/${ZONE_ID}/rulesets/${_existing_robots_ruleset_id}/rules" \
    "$_robots_rule_body" >/dev/null
  echo "   Created Transform Rule → X-Robots-Tag noindex on $HOSTNAME"
fi

# WEBHOOK_URL is derived everywhere; only TUNNEL_TOKEN persists.
WEBHOOK_URL="https://${HOSTNAME}"
upsert_env TUNNEL_TOKEN "$TUNNEL_TOKEN"

cat <<EOF

✅ Cloudflare setup complete.

   Tunnel:        $TUNNEL_NAME ($TUNNEL_ID)
   Hostname:      $HOSTNAME (proxied CNAME → ${TUNNEL_ID}.cfargotunnel.com)
   Access app:    $APP_NAME ($APP_ID)
   Access policy: allow ${_include_emails[*]} (one-time PIN by email)
   MCP policy:    allow service token '$SERVICE_TOKEN_NAME' (non-identity)
   Bypass apps:   /${HOSTNAME}/webhook  +  /${HOSTNAME}/webhook-test (everyone, no auth)
   WAF rule:      Skip WAF/Bot/SecurityLevel for Telegram, Meta, GitHub on /webhook*
                  (Stripe verification is delegated to per-workflow Stripe-Signature checks)
   Headers rule:  X-Robots-Tag: noindex, nofollow on $HOSTNAME (Safe Browsing trust)
EOF
printf '   WEBHOOK_URL:   '
print_link "$WEBHOOK_URL"
cat <<EOF
                  (derived automatically — no .env.sops.yaml entry needed)

   Written automatically:
     .env  ← TUNNEL_TOKEN, CF_ACCESS_CLIENT_ID, CF_ACCESS_CLIENT_SECRET (sensitive — do not commit)

   TUNNEL_TOKEN is read by \`npm run initialize\` and persisted to
   /root/n8n/.backup_creds on the VPS — do NOT add it to .env.sops.yaml.
   Run \`npm run initialize\` to bring up n8n.
EOF
