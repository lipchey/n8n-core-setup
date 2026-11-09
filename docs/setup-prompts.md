# Initialization steps and prompts

Generated from [the initializer](../scripts/initialize.sh); do not edit this page by hand.
Regenerate with `python3 scripts/generate-setup-docs.py` from the repository root.

Headings and helper calls appear in source order, including conditional branches; this is not a runtime trace.
Defaults are shell expressions, shown without evaluating them or reading local secrets.
Blank allowed means the helper accepts an empty value; it does not mean the resulting deployment will work.
The repository-name dialog inside `create_private_github_repo` is not extracted; submitting it creates a private repository.
For a recommended first run and conditional inputs, see [setup](setup.md).

## Phase and action headings

| Source line | Heading |
| --- | --- |
| 198 | Docker image pins |
| 302 | Phase 1/2 — Non-sensitive config  (.env.config, committed) |
| 315 | GitHub |
| 337 | GitHub Personal Access Token |
| 417 | SSH |
| 428 | ▶  Building custom-nodes locally (matches deploy.yml, so dev dependencies are not uploaded) ... |
| 460 | VPS creation |
| 491 | Docker memory limits (recommended per VPS tier) |
| 533 | n8n execution history retention |
| 549 | n8n VPS |
| 564 | Public n8n hostname |
| 615 | Phase 2/2 — Sensitive secrets  (.env, never committed) |
| 626 | n8n |
| 650 | Encrypted DB backup |
| 662 | Backblaze offsite backup (optional) |
| 696 | Cloudflare API token |
| 775 | Disk space monitoring (optional) |
| 795 | Resend (email API) settings |
| 840 | Workflow health ping (optional) |
| 932 | ▶  Step 0: Bootstrapping Cloudflare tunnel + DNS + Access ... |
| 1088 | Initializing VPS |
| 1106 | ▶  Step 1/4: OS setup (apt, Docker, UFW, swap, restic, crons) ... |
| 1252 | ▶  Step 2/4: Uploading n8n project files ... |
| 1259 | ▶  Installing VPS cron jobs ... |
| 1263 | ▶  Step 3/4: Booting n8n Docker stack ... |
| 1332 | ▶  Checking n8n API key... |
| 1371 | ACTION REQUIRED — Set up n8n owner account |
| 1449 | ACTION REQUIRED — Save TWO secrets to GitHub before first deploy |
| 1453 | Secret 1/2: SSH_PRIVATE_KEY |
| 1472 | Secret 2/2: SOPS_AGE_KEY |
| 1490 | GitHub Push Protection |
| 1512 | ▶  Step 4/4: Setting up backup repository ... |
| 1589 | ▶  Step 4b: Creating Backblaze B2 bucket and initializing restic repo ... |
| 1676 | SOPS+age secrets encryption |
| 1686 | ▶  Encrypting .env → .env.sops.yaml ... |
| 1714 | ▶  Committing initialization files and pushing to trigger CI deploy... |
| 1764 | ▶  Waiting for GitHub Actions deploy to complete... |
| 1864 | ▶  Normalizing local workflow JSON to n8n-assigned IDs... |
| 1919 | ACTION REQUIRED — Generate n8n MCP Access Token |
| 1997 | ▶  Probing MCP endpoint ... |
| 2041 | ▶  Running environment tests... |
| 2053 | Initialization result |

## Helper prompts

On reruns, valid saved defaults may be accepted without a prompt.

| Source line | Prompt | Default expression | Hidden | Blank allowed |
| --- | --- | --- | --- | --- |
| 206 |   → Run 'npm run refresh-images' now to check for updates? [Y/n]:  | `y` | no | no |
| 213 |   → Continue with initialization? [Y/n]:  | `y` | no | no |
| 308 | Project/project name (e.g. acme-corp; used in hostnames & paths) | `${PROJECT_NAME:-$(basename $ROOT_DIR)}` | no | no |
| 324 | GitHub repository (owner/repo) | `$GITHUB_PUSH_REPO` | no | no |
| 408 | City or timezone (e.g. Berlin, New York, Europe/Berlin) | `saved DISPLAY_TZ or machine timezone, otherwise UTC` | no | no |
| 411 | Developer email (for notifications & Cloudflare) | `${DEVELOPER_EMAIL:-}` | no | no |
| 421 | Local SSH private key path | `${SSH_PRIVATE_KEY:-$HOME/.ssh/id_ed25519}` | no | no |
| 516 | PostgreSQL memory limit | `${POSTGRES_MEM_LIMIT:-512m}` | no | no |
| 521 | n8n memory limit | `${N8N_MEM_LIMIT:-1g}` | no | no |
| 526 | cloudflared memory limit | `${CLOUDFLARED_MEM_LIMIT:-128m}` | no | no |
| 538 | Max age of execution logs (hours, 1440 = 60 days) | `${EXECUTIONS_MAX_AGE:-1440}` | no | no |
| 543 | Max number of execution records to keep | `${EXECUTIONS_MAX_COUNT:-35000}` | no | no |
| 552 | n8n VPS SSH user (must be root) | `${N8N_VPS_USER:-root}` | no | no |
| 557 | n8n VPS IP address or hostname | `${N8N_VPS_IP:-}` | no | no |
| 593 | Project domain, used as-is (e.g. project.com or ops.project.com — avoid 'n8n' in subdomain) | `${N8N_PROJECTS_DOMAIN:-}` | no | no |
| 600 | Your domain (e.g. your-agency.com) | `${N8N_COMMON_DOMAIN:-}` | no | no |
| 676 |   → Enable Backblaze offsite backup? [y/N]:  | `n` | no | no |
| 681 | keyID | `${BACKBLAZE_KEY_ID:-}` | no | no |
| 684 | applicationKey | `${BACKBLAZE_APPLICATION_KEY:-}` | yes | no |
| 783 |   → Enable disk space email alerts? [Y/n]:  | `y` | no | no |
| 815 | Resend API key | `${RESEND_API_KEY:-}` | yes | no |
| 829 | From address (must be on a verified Resend domain) | `$_resend_from_default` | no | no |
| 866 | healthchecks.io API key (leave blank to skip) | — | yes | yes |
| 1098 |   → Continue? [y/N]:  | `n` | no | no |
| 1594 |    → Enable Object Lock on the bucket? [Y/n]:  | `y` | no | no |

## Direct input inventory

These reads bypass the helpers. Only their statements and order are checked; prompt wording,
defaults and conditional meaning require manual review. Provider, Cloudflare, image-refresh,
retry-helper and environment-test dialogs are outside this table.

| Source line | Read statement |
| --- | --- |
| 192 | `read -r _ &lt;/dev/tty` |
| 388 | `read_secret _input_token &#124;&#124; exit 1` |
| 472 | `read -r _provider_choice &lt;/dev/tty` |
| 503 | `read -r _tier_pick &lt;/dev/tty` |
| 588 | `read -r _domain_choice &lt;/dev/tty` |
| 745 | `read_secret _input_token &#124;&#124; exit 1` |
| 762 | `read -r _cf_choice &lt;/dev/tty &#124;&#124; _cf_choice=a` |
| 920 | `read -r CONFIRM` |
| 1383 | `IFS= read -r _ &lt;/dev/tty &#124;&#124; exit 1` |
| 1387 | `read_secret _new_key &#124;&#124; exit 1` |
| 1462 | `read -r _ &lt;/dev/tty` |
| 1480 | `read -r _ &lt;/dev/tty` |
| 1704 | `read -r _ &lt;/dev/tty` |
| 1854 | `read -r _ &lt;/dev/tty` |
| 1931 | `while IFS= read -r _line &lt;/dev/tty; do` |
| 2023 | `IFS= read -r _mcp_ans &lt;/dev/tty &#124;&#124; _mcp_ans=""` |
