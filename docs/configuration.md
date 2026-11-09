# Configuration reference

The initializer creates project configuration in the repository root.
Generated local files below do not exist in a fresh template checkout.
Run configuration commands from the repository root.

## Files and trust

| File or location | Stored in Git? | Contents |
| --- | --- | --- |
| `.env.config` (generated) | Yes, plaintext | Identity, domain mode, memory, retention, notification thresholds, repository destination |
| `.env.sops.yaml` (generated) | Yes, encrypted | Project secrets and deployment connection details |
| `.env` (generated) | No | Temporary plaintext used by initialization and secret editing |
| `.env.local` (generated) | No | VPS user/IP, local SSH private-key path, saved provider server ID |
| `.env.developer` (optional local file) | No | Reusable developer defaults from [the example](../.env.developer.example) |
| [`.sops.yaml`](../.sops.yaml) | Yes | age public recipient and encryption matching rule |
| `.backup_creds` (generated on the VPS) | No | Runtime values for VPS scripts, mode 600 |
| `.mcp.json` and `.codex/config.toml` (generated) | No | Instance MCP bearer token and Cloudflare service-token headers |

Initialization loads the non-sensitive config, developer defaults, project
plaintext secrets, then local overrides, in that order. Later values win.
On a rerun it can decrypt existing encrypted secrets for the session.

Values in generated environment files are unquoted and limited to
`A-Za-z0-9@._:/+=,-`. Spaces, shell substitutions, quotes, `~`, `?`, and `&`
are rejected. Use full absolute paths and bare sender email addresses.
The hand-written developer defaults file is sourced as shell and is not checked
by that alphabet validator; keep it trusted and quote values as its example directs.

## Non-sensitive settings

These defaults come from the initializer, provider presets, and Compose:

| Key | Meaning and default |
| --- | --- |
| `PROJECT_NAME` | Lowercase letters/digits/hyphens, 1–31 characters; default directory name |
| `DISPLAY_TZ` | Workflow schedules and server jobs use this IANA zone; defaults to the machine zone, otherwise UTC; storage/container time remains UTC |
| `DEVELOPER_EMAIL` | Notification recipient and Cloudflare Access identity |
| `GITHUB_REPO` | Owner/repo derived from, and required to match, the Git push destination |
| `GITHUB_BRANCH` | `main` only |
| `N8N_COMMON_DOMAIN` | Mode A: public hostname is project name plus this domain |
| `N8N_PROJECTS_DOMAIN` | Mode B: complete public hostname, used as-is |
| `POSTGRES_MEM_LIMIT` | Provider preset, otherwise `512m` |
| `N8N_MEM_LIMIT` | Provider preset, otherwise `1g` |
| `CLOUDFLARED_MEM_LIMIT` | Provider preset, otherwise `128m` |
| `EXECUTIONS_MAX_AGE` | `1440` hours; execution history pruning |
| `EXECUTIONS_MAX_COUNT` | `35000` records; oldest execution records pruned first |
| `ALERT_DISK_THRESHOLD_MEDIUM` | Automatic first-run default: `85` percent used; saved values stay |
| `ALERT_DISK_THRESHOLD_HIGH` | Automatic first-run default: `95` percent used; saved values stay |
| `BACKBLAZE_BUCKET` | Optional; automatic `<PROJECT_NAME>-backups`, with up to three random suffix retries for unsaved name collisions; saved only after creation or reuse succeeds; saved names stay |

The timezone prompt accepts a city (Berlin, New York) or an exact zone
(Europe/Berlin). City lookup uses local zoneinfo files, case-insensitively, without
network calls. Ambiguous names list matching zones and ask again. Saved `DISPLAY_TZ`
values are reused on reruns.

Set exactly one domain mode. Avoid the n8n keyword in your public hostname,
as suggested by the wizard. Cloudflare setup creates tunnel/DNS/Access rules
for that hostname, webhook bypass applications, a hostname-scoped WAF skip
rule, and a response-header rule requesting no indexing.

## Secrets and connection values

[`.env.example`](../.env.example) lists example keys; its placeholder values
use `paste_<what>_here` for user inputs and `auto_generated` for wizard-written
values; fixed defaults retain their real values. Shared wizard, provider, and
Cloudflare env loading treats both placeholder forms as unset, including direct
file-value reads. The wizard generates or collects real values.

| Keys | Purpose |
| --- | --- |
| `N8N_ENCRYPTION_KEY` | Generated once; retain to decrypt existing n8n credentials |
| `N8N_API_KEY` | Created in n8n UI under Settings → API; required hidden input, accepted only after an HTTP 200 probe, unless a valid saved key is available |
| `N8N_LOCAL_API_URL` | Defaults to `http://localhost:5678/api/v1` on the VPS |
| `N8N_LOG_LEVEL` | Compose default `info`; optional value preserved when configured |
| `DB_USER`, `DB_PASSWORD`, `DB_NAME` | Automatic defaults `n8n_db_user`, generated password, `n8n_database`; saved credentials stay |
| `BACKUP_PASSWORD` | Generated once; restic encryption password, retain for every existing snapshot |
| `GITHUB_PERSONAL_ACCESS_TOKEN` | VPS workflow auto-commit token and initialization deployment polling |
| `N8N_VPS_USER`, `N8N_VPS_IP` | Deployment connection; user must be `root` |
| `N8N_VPS_HOST_FINGERPRINT` | Expected ed25519 fingerprint checked before wizard SSH and used by Actions SSH/SCP; a mismatch stops initialization |
| `RESEND_API_KEY`, `RESEND_FROM_EMAIL` | Optional email alerts; sender defaults to `alerts@` on the common domain (mode A) or hostname minus its first label (mode B); saved sender stays and its domain must be verified in Resend |
| `HEALTH_PING_URL` | Optional healthchecks.io Ping URL; the wizard saves the API-created URL and skips the key question when a URL is saved |
| `BACKBLAZE_KEY_ID`, `BACKBLAZE_APPLICATION_KEY` | Optional B2 credentials; bucket setting also required |
| `CLOUDFLARE_API_TOKEN` | Local Cloudflare setup token; excluded by the deploy secret loader |
| `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET` | Cloudflare service-token credentials used for MCP configuration |
| `DIGITAL_OCEAN_API_TOKEN`, `HETZNER_API_TOKEN` | Provider setup tokens; excluded by the deploy secret loader |
| `TUNNEL_TOKEN` | Generated tunnel credential; retained on the VPS for deployment |

Create the n8n owner account by hand with your own email and a strong password,
and save them in your password manager. Login credentials are not stored in env
files; reruns remove the retired login keys when rewriting those files.
`DEVELOPER_EMAIL` remains the alert recipient and Cloudflare Access identity.

The initializer encrypts the entire local plaintext file. A value not selected
by the deploy loader is not thereby excluded from the encrypted file.
Provider and Cloudflare tokens can be retained there if present; do not assume
that comments describing a value as local-only mean it is filtered at encryption.
The deployment retrieves `TUNNEL_TOKEN` from the existing VPS runtime credentials.

In local overrides, `SSH_PRIVATE_KEY` is a file path. The GitHub secret with that
same name holds key contents. `DIGITALOCEAN_DROPLET_ID` or `HETZNER_SERVER_ID`
records an existing server for provider reruns. The private key must be readable
and usable without a passphrase, because Actions provides no passphrase input.
The PAT is tested against this repository and its Actions runs before provider
creation; missing repository or Actions read access prompts again. The check does
not prove Contents write; the first workflow publish from the VPS confirms it.

Developer defaults support `GITHUB_PERSONAL_ACCESS_TOKEN`, `RESEND_FROM_EMAIL`,
and `HEALTHCHECKS_API_KEY`. The healthchecks API key creates a named check with
a 600-second timeout and 1800-second grace. Without a saved Ping URL or developer
key, the wizard asks for a masked read-write API key from project Settings → API
Access at [healthchecks.io](https://healthchecks.io). Blank skips; API failures show
the HTTP status and error and ask again. Prompted keys are neither exported nor
saved to files; only the returned Ping URL is saved. The shipped Health Ping
workflow runs every five minutes, independently of that check timeout.

## Edit secrets

```bash
npm run edit-env
```

This refuses an existing plaintext file, decrypts, opens your editor, and
re-encrypts after a successful editor exit. Alternatively use `npm run decrypt-env`,
edit locally, and run `npm run encrypt-env`; encryption deletes plaintext on success.
If editing/encryption fails, check for plaintext left locally before sharing files.
Commit the encrypted result and push to `main` to deploy it.

The SOPS wrapper looks for the project-specific age key under the developer's
home configuration directory, then the default keystore, then a gitignored
project-root age-key fallback. Restore an offline copy to the expected location
before decrypting on a replacement developer machine.

## Extending configuration

Update the example, initializer prompts/generation and writers, deploy config
allowlist, deploy secret loader, runtime credential writer, and consuming code
as applicable. Keeping a new key in an environment file does not automatically
deliver it to a container or VPS script. Regenerate [the setup tables](setup-prompts.md)
and run the unit checks after changing prompts.
