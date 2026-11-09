# Security contract

Report vulnerabilities privately to Yuriy Lipchey at
[yuriy.lipchey.work@gmail.com](mailto:yuriy.lipchey.work@gmail.com).
Include affected files, a minimal reproduction, impact, and redacted logs.
Do not open a public issue with an exploit or a credential. No response-time
or supported-version guarantee is offered.

## Intended trust boundary

The supported setup is a macOS developer machine, a Debian/Ubuntu x86 VPS
created at DigitalOcean or Hetzner, root SSH, Cloudflare, GitHub Actions, and
branch `main`. Everything else is unsupported. Keep project repositories
private and restrict repository, provider, Cloudflare, and n8n access to trusted
operators. Workflow authors, custom nodes, and dependencies are trusted code.
This setup does not isolate mutually untrusted workflow authors.

The initializer can provision billed infrastructure, upgrade OS packages,
configure SSH/UFW, restart containers, set GitHub secrets/settings, and commit/push
configuration. Review prompts on an existing host. Hard reset destroys volumes.
Root access to the VPS or control of a deployment-capable repository/account
can expose data and credentials and execute code on the host.

## What is protected

- SOPS encrypts committed project secrets using age. Plaintext mirrors and local
  MCP configurations are ignored by Git; the pre-commit hook blocks several
  secret-file names/extensions and private-key contents once installed.
- The initializer rejects the template push destination, non-GitHub push
  remotes, differing fetch/push destinations, and a configured repository mismatch.
  A missing selected remote alongside other remotes or a directory inside another
  Git repository also stops setup; hard reset requires an existing remote.
  With no remotes, submitting the repository name creates it privately using
  `gh` with `repo` and `workflow` scopes. An unborn repository gets a local root commit respecting
  Git ignores; creation does not push. GitHub CLI must confirm destination privacy
  before provider creation and the later initialization commit/push, after encryption.
  Public or unconfirmed privacy stops initialization without
  a bypass. Make the repository private in GitHub Settings or create a new private
  repository; for access failures, install `gh`, run `gh auth login`, and ensure the
  authenticated account can access the repository.
- Before provider creation, setup tests push access with a dry run, validates the
  PAT on the selected repository and Actions, builds custom nodes, and requires a
  readable SSH private key usable without a passphrase. Secret input shows only
  asterisks and restores the terminal after submission, EOF or interruption.
  Reused age recipients are derived from the key with `age-keygen -y`.
- Compose publishes n8n on loopback only. Cloudflare Tunnel supplies public
  ingress and Access protects the editor hostname. PostgreSQL has no published port.
- Provisioning pre-generates an ed25519 host key. Before its first SSH command,
  the wizard scans that key and requires a match with the saved fingerprint before
  replacing the IP entry in local known_hosts. A mismatch stops without changing
  known_hosts. Without a saved fingerprint, it prints and installs the scanned key
  in known_hosts; `StrictHostKeyChecking=yes` requires that exact key when connecting.
  Cross-check first-use fingerprints in the provider console. Actions SSH/SCP
  steps use the saved fingerprint.
- Container capability restrictions, no-new-privileges, file-access restrictions,
  and log size limits reduce exposure; they are not a host security boundary.
- Restic encrypts backups with the backup password. Optional B2 Object Lock
  attempts 30-day governance retention when selected and successfully configured.

## What is exposed or conditional

`N8N_BLOCK_ENV_ACCESS_IN_NODE=false` is set in the shipped Compose file.
Workflow expressions can read environment variables, including secrets injected
into n8n. The shipped alert and health workflows use that access. Anyone able
to author or alter workflows can arrange to send those values elsewhere.
Do not grant workflow-editing access to untrusted users.

Webhook and test-webhook paths bypass Cloudflare Access. The WAF skip rule for
selected sender ASNs is not authentication. Implement signature or shared-secret
verification in each receiving workflow. Fail on Purpose is a public test
webhook when enabled; leave it inactive except during deliberate testing.

The live database, workflow definitions, execution payloads, and filesystem
volumes do not receive whole-volume encryption from this repository.
The n8n encryption key is passed to n8n for its credential encryption; it does
not encrypt arbitrary workflow content. Root can read runtime secrets and data.
Execution history can retain sensitive inputs/outputs until pruning removes it.

The VPS workflow exporter runs a limited pattern scanner before committing.
It catches private-key markers, embedded URL credentials/tokens, secret query
parameters, long bearer tokens, and Telegram bot-token URLs. Expression-like
matches are excluded in the scanner's secret portion. It is not a complete
secret detector, and blocking export does not remove the secret from n8n.
The poll retries blocked exports; clean workflows can still commit.

Initialization attempts to enable GitHub Push Protection.
Availability and enforcement depend on the repository/account, permissions, and
plan; verify the actual settings and setup outcome. This repository cannot
guarantee GitHub will detect a leaked token.

The documented VPS token must be a fine-grained PAT with **Contents: Read and
write** and **Actions: Read** on the project repository. Those permissions allow
repository content writes and deployment-run reads. The publish path only writes
`n8n/workflows/*.json`; a fine-grained token without the **Workflows** permission
cannot change `.github/workflows`. A classic token with `workflow` scope would
be different; these instructions require the fine-grained token.
Anyone holding the PAT can change code that the deploy job runs with the deploy
secrets, including custom-node packages and scripts. This can expose every secret
in `.env.sops.yaml`. Treat the PAT as sensitive as those secrets, keep it only on
the VPS once setup is complete, and rotate it together with them if the VPS is
compromised.

Local backups share the VPS disk. B2 is optional, and governance retention is
conditional on bucket configuration and key capabilities; a key with bypass
rights can weaken it. Backups cover the database and files volume, not every
host/application file. Retain original encryption/recovery keys offline and test
restores. The deploy and restore paths are not transactional or zero-downtime.

Hooks can be bypassed. Unit checks and secret-free CI validate local behavior
and syntax; they do not establish that provider configuration or live backups
are correct. Never paste plaintext environment files, keys, MCP configuration,
or unredacted logs into issues, PRs, or chat. Rotate a credential after exposure.

See [configuration](docs/configuration.md) and [operations](docs/operations.md)
for secret handling, backup scope, and recovery procedures.
