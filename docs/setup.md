# Setup walkthrough

Use the [supported environment](../README.md#supported-environment). Run commands
from your project directory on macOS. No local n8n installation is needed.

## Prepare accounts and credentials

1. Use **Use this template → Create a new repository**, make it private, clone it,
   and work on `main`. Alternatively, copy the template files without `.git` into
   a new directory outside any other Git repository: submitting the repository name creates a private
   repository when no remotes exist. Configure your Git name and email
   and authenticate `gh` with `repo` and `workflow` scopes
   (run `gh auth login`, choose GitHub.com; for an existing login,
   run `gh auth refresh -s repo,workflow`).
2. Prepare either a DigitalOcean API token or a Hetzner Cloud project API token.
   The provider dialog selects an x86 type/size, then one of its available
   locations/regions, a Debian/Ubuntu image, SSH public key, server name, and optional
   provider backups before confirmation. Sizes with at least
   2 GB RAM are marked as recommended. Review the quoted monthly price.
3. Have a local SSH key pair usable without a passphrase and know the absolute private-key path. The dialog
   can select an existing provider key or upload a local public key.
4. Put the intended domain on Cloudflare DNS and create a Cloudflare API token.
5. Create a fine-grained GitHub PAT for your new repository with **Contents: Read and write**
   and **Actions: Read**. The VPS uses it to commit workflow JSON; initialization
   uses it to follow the deployment run. Authenticate the installed GitHub CLI
   to confirm repository privacy and manage repository settings and secret uploads.
   If the wizard creates the repository, create its PAT once the repository exists,
   at the GitHub destination token prompt before VPS creation. A failed secret upload
   stops setup so you can fix permissions or connectivity and rerun.

The Cloudflare token needs the permissions listed by the initializer:

| Scope | Permission |
| --- | --- |
| Account | Cloudflare Tunnel: Edit |
| Account | Access: Apps and Policies: Edit |
| Account | Access: Service Tokens: Edit |
| Account | Account Settings: Read |
| Zone | DNS: Edit |
| Zone | Firewall Services: Edit |
| Zone | WAF: Edit |
| Zone | Transform Rules: Edit |
| User | User Details: Read |

Run `npm run check-prerequisites` before setup, or
`bash scripts/check-prerequisites.sh` if npm is absent. The required local tools,
version floors, Homebrew commands, and optional clipboard/sound/window helpers
are listed in [the README prerequisites table](../README.md#prerequisites-and-costs)
and [the standalone checker](../scripts/check-prerequisites.sh).
The check also runs first in the wizard, including `--hard-reset`, before
loading helpers, reading environment files, or prompting. It lists
all missing or outdated tools with install/upgrade instructions and exits without
installing anything. When `gh` is available, `gh auth status --active` must also
succeed; login or connectivity failures appear in the same report. Run
`gh auth login`, choose GitHub.com, and ensure `repo` and `workflow` scopes
(`gh auth refresh -s repo,workflow` for an existing login).
It also reports unfinished Git operations, unmerged paths and index locks;
inspect `git status` and finish or abort the operation, or wait for the running Git
process. Never delete a lock. Empty-file probes check the project and `${TMPDIR:-/tmp}`;
existing env/config paths must be readable files, `.sops.yaml` writable, and the
nearest existing age-directory ancestor must permit creation when needed. An existing
age directory must allow creation unless the project's key and default keystore
already exist; an existing `keys.txt` must be writable. Reused project keys need not
be writable. Run from an interactive terminal; a closed terminal stops setup.
Each failure names its path and remedy without sourcing env files.
Resolve the reported problems, then re-run `npm run initialize`. Homebrew
absence is reported with https://brew.sh; optional helpers never block setup.
Base macOS userland is assumed; VPS tools are excluded. Other local platforms are
unsupported, with best-effort `apt-get install` advice for known packages.
Use your provider dashboards to create API tokens; do not put them in Git.

## Check the destination first

For an existing clone, inspect its destination:

```bash
git branch --show-current
git remote -v
git remote get-url --push --all origin
```

The guard chooses the branch's push remote, then the global push default, then
the branch's remote, falling back to `origin`. It checks every push URL and the
selected remote's fetch URL. All must resolve to the same GitHub repository,
and it must be your project repository.
The template destination, non-GitHub destinations, and a `GITHUB_REPO`
mismatch stop initialization before local environment files are sourced.
If remotes exist but the selected remote is missing, setup stops rather than
creating another repository. A directory inside a parent Git repository is also
refused. `--hard-reset` requires an existing remote.
The repository answer is checked again before being saved. At that point,
`gh api repos/owner/repo --jq .private` must return `true`; public repositories
and unconfirmed privacy stop setup before provider creation or the later
initialization commit/push. Make a public
repository private in GitHub Settings, or create and clone a new private repository.
If the check cannot confirm privacy, install `gh`, run `gh auth login`, and ensure
the authenticated account has access to the destination. There is no bypass.

With no `.git` or no remotes, the repository prompt defaults to
`<GitHub login>/<project name>`, or a saved `GITHUB_REPO`. You may enter another
`owner/repo`. Submitting the name creates that private repository immediately and
prints its name; there is no second confirmation. EOF or a closed terminal at the
name prompt stops setup.
For both existing remotes and creation, setup requires a Git name and email,
refuses detached HEAD or a committed branch other than `main`, and checks that
HEAD contains `.github/workflows/deploy.yml`. Copy dotfiles along with the rest
of the template. A new repository is initialized on `main`; an unborn branch
becomes `main` and gets a local commit of the non-ignored tree. That commit runs
the secret checks in the repository hook; only the custom-node build gate is
skipped until dependencies are installed. A rejected commit leaves files unstaged.
Existing commits are left alone. The wizard creates the private remote without
pushing, then checks the destination and privacy again. A conflicting saved
`GITHUB_REPO` stops before creation. The creation name always prompts, using a
saved value as the default, so you can change a name that is already taken.
Nothing is uploaded until the existing push stage after secret encryption.
A rerun uses the existing remote.
If creation fails, resolve the reported name, scope, or network error, or create
the private repo yourself and run `git remote add origin git@github.com:owner/repo.git`
before rerunning `npm run initialize`.

For HTTPS creation, a classic `gh` token must include `workflow` scope; if it is
missing, run `gh auth refresh -s workflow`. A fine-grained token has no OAuth
scope header and is not rejected by that check. With either destination path,
setup tests `git push --dry-run --no-verify -- <remote> HEAD:refs/heads/main`
before provider creation. This also works with an empty repository. Fix SSH keys,
Git credentials, or a diverged remote branch before continuing. No push is performed
by this check. The PAT is then checked for repository and Actions read access;
a failure identifies the access problem and asks for another token. Repository role
metadata does not prove the token's Contents write grant; the first workflow publish
from the VPS confirms it. The PAT is retained in ignored `.env` with mode 600, including
on reruns and through the later secrets-file rewrite. A skipped push stops setup.

Use `git@github.com:owner/repo.git` or `https://github.com/owner/repo.git`.
Standard ports (`https://github.com:443/owner/repo.git` and
`ssh://git@github.com:22/owner/repo.git`) are also accepted. SSH host aliases such
as `github-work` cannot be verified and are refused. For multiple GitHub accounts,
keep a `github.com` URL and select the key in that clone:

```bash
git config core.sshCommand "ssh -i <key>"
```

## Run the wizard

```bash
npm run initialize
```

Follow [the generated tables](setup-prompts.md) for source-ordered phases,
actions, helper prompts, default expressions, and direct terminal reads.

The image check selects the numeric n8n tag matching Docker Hub's `stable` digest;
other images use the highest version matching their configured filter. An unresolved
stable digest or missing numeric match reports the reason and leaves the n8n pin unchanged.
On a first run, its
`Apply these changes? [Y/n]` prompt accepts Enter without a migration warning.
An existing `.env.config`, `.env`, or `.env.sops.yaml` marks a rerun, including
after plaintext secrets have been encrypted and removed. Reruns and standalone
`npm run refresh-images` default to no with `[y/N]` and warn about stateful
updates. EOF or a closed terminal never applies changes. See the
[image update checklist and rollback procedure](operations.md#image-updates-and-rollback)
before updating an existing instance.

Before provider dispatch, setup validates the selected local SSH key with
`ssh-keygen -y -P '' -f <key>` and discards the output. Missing, unreadable or
passphrase-protected keys stop setup with a dedicated-key generation command;
Actions has no passphrase input. Provider-selected keys must match the public key
derived from that private key, including paths outside `~/.ssh`. A mismatch returns
to provider key selection; without a selected key, standalone provisioning scans
`~/.ssh/*.pub` for a matching private key. Provider-selected keys receive the same check.
The local custom-node install/build/prune also runs here, once; its built directory
is uploaded later after the remote OS exists.

Hetzner lists x86 types available in at least one non-deprecated location, cheapest
first. Varying prices show “from €X” and the location count; choose a type and then
an available location with its exact price. A single location is still shown and
Enter selects it. DigitalOcean likewise lists available sizes before their regions.
Review the summary above `Create this server? [Y/n/r]`: Enter creates, `n` aborts,
`r` starts selection again. EOF or a closed terminal never creates. No capacity
stops with guidance to try later or the other provider. A definite create rejection
shows the API message and refreshes availability before reselection; a lost response,
server error or other uncertain outcome stops for dashboard reconciliation.
Availability is an indicator and can change between selection and creation.

Your timezone sets when scheduled workflows and server jobs run. Enter a city or
an exact timezone; the machine zone from `/etc/localtime` is the default, with UTC
as fallback. City lookup uses local zoneinfo files, without network access. Several
matches are listed so you can enter a full `Region/City`; no match suggests a nearby
large city. A saved `DISPLAY_TZ` on reruns is accepted without asking. Storage remains UTC.
Hidden prompts show `*` for every character, including paste; Backspace/Delete
removes one character. Enter submits; EOF or Ctrl-C stops and restores terminal echo.

Conditional steps may be skipped when already configured. The tables do not
describe the repository creation name dialog or every dialog inside
the provider, Cloudflare, refresh, retry, or test scripts.

A small first run can use this answer set; use real values for your project:

| Dialog | Suggested answer |
| --- | --- |
| Image refresh | Yes; review changed pins and continue when satisfied |
| Project | A short lowercase project name |
| GitHub repository | Keep the private remote's value; with no remotes, submitting the name creates it privately |
| GitHub PAT | Supply the repository PAT; repository and Actions read access are checked before the provider; the first VPS publish confirms Contents write |
| City or timezone | Your nearest large city (Berlin, New York) or zone (Europe/Berlin); Enter accepts the machine zone, or UTC |
| Developer email | Your notification and Cloudflare Access email |
| SSH private key | Absolute path to a key usable without a passphrase; checked before the provider |
| Provider | Your chosen account; review x86 size/image/key and creation confirmation |
| Memory and execution retention | Keep provider/default values initially |
| VPS SSH user | `root` |
| Domain mode | A for project-name prefix; B for a complete hostname you control |
| B2 | Enable for recovery after server loss; otherwise explicitly accept local-only risk |
| Cloudflare token | Supply your prepared token; keep a valid saved token on rerun |
| Disk email alerts | Enable or decline; thresholds default to 85% and 95% used; Enter accepts the suggested `alerts@` sender after verifying its domain in Resend |
| Health Ping | Enter a healthchecks.io read-write API key with masked input, or leave blank; a saved Ping URL or developer key skips the question |
| Owner account/API | Create the account in the browser using your own email and strong password; save both in your password manager, create an API key under Settings → API, then paste it; only an HTTP 200 probe accepts the key |
| Fingerprint | Before SSH, a matching saved ed25519 fingerprint replaces any stale IP entry in known_hosts; a mismatch stops; without a saved fingerprint, the scanned key is printed and installed, then enforced with strict checking |
| GitHub secrets | Upload both key contents through gh; fix any upload failure before rerunning |
| B2 Object Lock | Keep enabled; an existing bucket without Object Lock stops offsite setup when lock is requested |
| Age key backup | Save an offline copy, then acknowledge |
| MCP | Paste the instance token JSON only if you want agent inspection access |
| Tests/retries | Review failures; fix the cause before retrying or accepting a skip |

Database setup asks no questions: the first run uses `n8n_db_user`,
`n8n_database`, and a generated password. Saved database credentials, disk
thresholds, B2 bucket names, and sender addresses are retained on reruns.
B2 uses `<PROJECT_NAME>-backups` automatically. If another account owns that name,
an unsaved name gets up to three random lowercase suffix retries and prints the final
name. Other API errors stop bucket setup without retrying; an existing bucket in
your account is reused. The name is saved only after creation or reuse succeeds,
so interrupted setup retains collision retries. A saved bucket name is never changed automatically.

For Resend, visit [Add Domain](https://resend.com/domains/add), enter your domain,
choose **Auto configure**, and sign in to Cloudflare. Wait for verification, then
visit [API keys](https://resend.com/api-keys) and create a key with any name,
**Sending access**, and your domain. Copy it when shown; it is shown only once.
The sender defaults to `alerts@<N8N_COMMON_DOMAIN>` in mode A. In mode B, it uses
the full hostname minus its first label: `ops.eu.example.com` suggests
`alerts@eu.example.com`. If removing the first label leaves no dot, the hostname
itself is the domain: `example.com` suggests `alerts@example.com`.
Without a known domain, supply a sender explicitly.
The sender must be a plain email address on a verified Resend domain.

For Health Ping, open [healthchecks.io](https://healthchecks.io), choose project
**Settings → API Access**, and create a **read-write API key**. The wizard masks
input with asterisks, creates the check, and saves only the returned Ping URL.
It reports API failure status and error before asking again; blank skips.
A saved Ping URL or `HEALTHCHECKS_API_KEY` in `.env.developer` avoids the question.
The prompted key is never exported or written to `.env`, `.env.local`, or other files.

The OS setup upgrades packages and configures Docker, UFW, swap, SSH hardening,
and cron jobs. It requires root and can interrupt the running stack on a rerun.
Before OS setup, the wizard scans the ed25519 host key with brief boot retries.
A saved fingerprint must match before it replaces the local known_hosts entry.
Without a saved fingerprint, the scanned key is printed and installed in known_hosts.
SSH uses `StrictHostKeyChecking=yes` so it must present that exact key when connecting.
Cross-check the printed fingerprint in the provider console.
After stack startup, owner/API setup precedes the GitHub secret dialogs and backup repository setup. Encryption and plaintext deletion
precede the initialization commit/push, deployment wait, workflow-ID synchronization,
MCP setup, and live tests. Test failures produce a nonzero final result.

The wizard does not collect or generate n8n login credentials. `DEVELOPER_EMAIL`
still controls alerts and Cloudflare Access. The API-key prompt retries empty
input and every probe result other than HTTP 200, showing the status before asking
again; EOF stops initialization. A valid saved API key skips account setup and
the key prompt on reruns.

After the push, the wizard polls for this commit's deployment. If the API answers
normally but no run appears within two minutes, it dispatches the deploy once
through the authenticated GitHub CLI and follows the run. Failed requests report
the HTTP status; 401/403/404 identify a token or repository-permission problem.
API failures stop the wait without dispatching.

## Save recovery material

The wizard creates a per-project age key under the developer's home directory,
registers it in the default SOPS age keystore, and writes its public recipient to
[`.sops.yaml`](../.sops.yaml). Keep an offline private-key copy.
It uploads or asks you to save exactly two GitHub Actions secrets:

| GitHub secret | Value |
| --- | --- |
| `SSH_PRIVATE_KEY` | SSH private-key contents, not the local path |
| `SOPS_AGE_KEY` | Generated age private-key contents |

Keep the original `N8N_ENCRYPTION_KEY` and `BACKUP_PASSWORD` recoverable through
your encrypted configuration and age key. Never regenerate them to fix a login
or restore problem. See [configuration](configuration.md) for file locations and
[operations](operations.md) for backup and recovery limits.

## Rerun safely

Existing valid saved values are often accepted automatically. To change secrets,
use `npm run edit-env`; edit the generated non-sensitive config directly.
Rerunning `npm run initialize` can upgrade OS packages and restart containers;
it asks for confirmation when encrypted configuration already exists.
A saved provider server ID resumes that server, and a saved IP skips creation.
If server creation returns an unknown outcome, inspect the provider dashboard
before retrying so you do not pay for an accidental duplicate.

`npm run init-cloudflare` reruns only Cloudflare configuration. It reads local
configuration, so decrypt secrets first if needed, then re-encrypt afterwards.
`npm run initialize:hard-reset` destroys database and application volumes and
requires the literal confirmation `wipe-all-data`; use it only for a deliberate wipe.
