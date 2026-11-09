# Operations

Run npm commands from the project checkout. Commands in the VPS blocks below
run as root on the deployment host. Use [configuration](configuration.md) for
secret editing and [the security contract](../SECURITY.md) for trust boundaries.

## Author, publish, deploy

Humans edit in the n8n UI, toggle Active or click Publish, then pull the exported
commits before editing locally. A per-minute VPS cron observes publish history;
plain saves/autosaves do not trigger an export. The GitHub commit uses `[skip ci]`.
Polling and API failures can delay export beyond one minute.

Agents edit JSON in [the workflow directory](../n8n/workflows/), inspect through
MCP, and deploy through Git. Both routes meet at repository JSON. Do not have
an agent create workflows directly through MCP. Read [workflow rules](workflow-rules.md)
before editing. A local `npm run pull` fetches workflow JSON from the VPS and
can modify/delete files; review the diff before committing. It has guards against
an empty remote directory and suspicious bulk deletion; review any confirmation
prompt. The `--force` option bypasses the bulk-deletion confirmation.

Pushing to `main` runs [deployment](../.github/workflows/deploy.yml), gated by
unit tests, including the complete offline suite in a personalized throwaway
instance. Change detection examines the whole push range:

| Mode | Typical changes | Effect |
| --- | --- | --- |
| Full | Compose, VPS scripts, custom nodes, deployment workflow, generated config or encrypted secrets | Build custom nodes, upload files, restart stack, push workflow JSON |
| Workflows | Only workflow JSON and/or AI system prompts | Upload files and push through the n8n API without restarting containers |
| Skip | Only Markdown/text docs, agent/harness files, developer scripts, hooks, root package metadata, `.env.example`, `.env.developer.example`, SOPS recipient config, secret-free CI workflow | No runtime deploy |

The path filter in the deployment workflow is authoritative. No generated
non-sensitive config means skip; manual dispatch on `main` forces a full deploy
once configured. A missing/invalid prior commit also selects full deployment.
During initialization, two minutes of successful API polling without a run
triggers one automatic dispatch through GitHub CLI. Failed API requests report
their HTTP status and stop the wait without dispatching; 401/403/404 point to
token or repository permissions.
Deleting or renaming workflow JSON can delete the old workflow in n8n when the
push range identifies its previous name. Review those changes as destructive.

The separate [CI workflow](../.github/workflows/ci.yml) runs on pull requests
and pushes without repository secrets. It checks shell syntax/ShellCheck,
unit tests, Compose with placeholders, and workflow JSON parsing. It does not
provision a server, decrypt project secrets, or exercise a live deployment.

Deployment waits up to ten minutes for backup and publish locks at its runtime
steps. Cleanup and upload steps occur outside those locks: deployment is not
transactional, so inspect a failed run before retrying. A full deploy can cause
downtime. If the macOS pre-push watcher is configured and the GitHub CLI is
authenticated, it opens/reuses a Terminal watcher. Use `npm run push:watch` on demand.

## Image updates and rollback

`npm run refresh-images` selects the numeric n8n tag matching Docker Hub's `stable`
digest, and the highest matching version for other images in their configured
series. If stable cannot be resolved or has no matching numeric tag, the n8n pin
stays unchanged and the command reports the reason and fails. It updates Compose
pins after confirmation and defaults to no;
`--yes` applies without prompting and `--dry-run` reports without writing.
The initializer's first-run check defaults to yes and omits the migration warning;
reruns keep the standalone behavior. Review the resulting `git diff` before pushing.

Stateful n8n and PostgreSQL updates can run one-way schema migrations on first
start, with no automatic rollback. Starting an older image against a migrated
database can fail or corrupt state.

Before deployment:

1. Take a fresh manual backup with `npm run backup-database` and confirm success.
2. Record the old image tags and digests from `git diff` for rollback.
3. Read the [n8n release notes](https://docs.n8n.io/release-notes/) and
   [PostgreSQL release notes](https://www.postgresql.org/docs/release/) for
   breaking changes affecting the update.
4. Plan to smoke-test critical workflows in the n8n UI after deployment.

If deployment breaks, never start the old image before restoring its compatible
backup:

1. Stop writers on the VPS: `docker stop n8n_cloudflared n8n_app`.
2. Restore the pre-update backup while keeping n8n stopped. The shipped
   `npm run restore-database` **restarts n8n on the current image** at the end,
   which can immediately migrate the restored database again. It cannot perform
   this rollback step as shipped; use a restore procedure that omits that restart.
3. Select the old pinned images by running `git revert` on the image-update commit.
4. Push the revert to `main`; deployment starts the old images. Verify workflows,
   credentials, and application results before resuming normal use.

## Inspect a running host

The VPS runtime directory is `/root/n8n`; these paths are created at setup.
Its plaintext environment file is removed after startup. Use these commands
on the VPS instead of assuming a manual Compose command can load that file:

```bash
docker ps
docker logs --tail 100 n8n_app
docker logs --tail 100 n8n_postgres
docker logs --tail 100 n8n_cloudflared
tail -n 100 /root/n8n/backup.log
tail -n 100 /root/n8n/poll-publish.log
tail -n 100 /root/n8n/disk-check.log
```

Redact logs before sharing. Publish-poll schema errors refer to n8n internal
tables `workflow_publish_history` and `workflow_published_version`; an upgrade
that changes these needs a corresponding poller update.

## Backup schedule and limits

[The cron installer](../n8n/scripts/install-crons.sh) schedules jobs in the host
system timezone. Keep the deployment host on UTC; `DISPLAY_TZ` changes job
display timestamps rather than the scheduling timezone.

| Job | Schedule in UTC |
| --- | --- |
| Publish poll | Every minute |
| Database/files backup | Daily 02:00 |
| Backup pruning | Sunday 03:00 |
| Disk-space alert check | Hourly |

Each backup stages a compressed `pg_dump --create` and, when present, a tar of
the n8n files volume, then encrypts them in local restic storage under
`/root/db-backups/` in a project-named directory. It does not back up the whole
server or the separate n8n application volume. Keep the repository, original
encryption key, age key, and backup password separately recoverable.
The database and file archive are not one atomic application snapshot.

```bash
npm run backup-database
npm run restore-database
```

Backup skips a run if another backup/restore/deploy holds its lock. Monitor the
backup log; a cron entry alone does not prove you have a usable snapshot.
Pruning chooses local retention by free disk percentage:

| Free disk | Daily | Weekly | Monthly |
| --- | --- | --- | --- |
| Below 10% | 3 | 2 | 2 |
| Below 25% | 5 | 3 | 4 |
| Below 50% | 7 | 4 | 6 |
| At least 50% | 14 | 8 | 12 |

Optional B2 creates a second encrypted copy through rclone. It needs the bucket
setting and both B2 key values. The wizard offers Object Lock (default yes)
and attempts to apply 30-day governance retention. Verify success in the
provider dashboard; declining it or a failed retention update removes that
protection. Limit the VPS key's capabilities, especially governance bypass.

B2 pruning uses 7 daily, 4 weekly, and 6 monthly snapshots. Governance retention
can delay deletion and cause pruning errors. The backup script works around
restic's locked-file cleanup by terminating the B2 process once its saved-snapshot
message appears; it also has retries and a timeout. Check actual snapshot access.
A local backup failure still attempts B2, then fails the run.
`npm run prune-backblaze` is a manual developer-side pruning command requiring
local restic and rclone; it avoids the Sunday 02:00–04:00 UTC overlap window
unless explicitly overridden. Its best-effort warnings need review.

## Restore an existing host

`npm run restore-database` asks for local/B2 source when B2 is configured, a
snapshot, and confirmation before replacing the database. Record the chosen
snapshot ID. It fetches and validates compressed data before stopping n8n and
dropping the database, then restores files when included and restarts n8n.
Files are merged into the volume: files newer than the snapshot survive.

After a failure following the database drop, n8n stays stopped. Inspect data
before starting it manually. A readiness timeout fails with n8n already running;
stop it if the restored data is wrong. Success requires the readiness endpoint,
but still verify workflows, credentials, and application-specific results.
The readiness timeout is controlled by `RESTORE_HEALTH_TIMEOUT_SECS` (300 seconds).

## Recover after server loss

Local-only backups cannot recover a lost VPS disk. For B2 recovery:

1. Recover your private project repository and offline age key. Decrypt secrets
   with `npm run decrypt-env`. Keep the original n8n encryption key and backup
   password; do not overwrite them with fresh values.
2. Verify the required offsite snapshot from a trusted machine with restic and
   rclone installed. In that checkout, run the following and record an ID:

   ```bash
   set -a
   . .env.config
   . .env
   set +a
   export RCLONE_CONFIG_B2_TYPE=b2
   export RCLONE_CONFIG_B2_ACCOUNT="$BACKBLAZE_KEY_ID"
   export RCLONE_CONFIG_B2_KEY="$BACKBLAZE_APPLICATION_KEY"
   export RESTIC_PASSWORD="$BACKUP_PASSWORD"
   restic -r "rclone:b2:$BACKBLAZE_BUCKET" snapshots --no-lock --tag n8n-db
   ```

3. If the old server is reachable, preserve its disk and power it off before
   bringing up the replacement; two tunnel connections can route to different data.
4. Clear the old IP and saved provider ID in local overrides, the old IP in
   plaintext secrets, and the old host fingerprint. Provision with
   `npm run init-digital-ocean` or `npm run init-hetzner`, retaining the project name.
5. Run `npm run initialize` on the replacement. This starts an empty database,
   can publish seed workflows, and runs live tests; it does not restore your backup.
   Keep the original secrets and reuse the intended tunnel and B2 bucket.
6. Run `npm run restore-database`, select B2 and the recorded snapshot ID.
   Do not blindly pick latest: replacement setup/tests may have made a newer
   snapshot of an empty database.
7. Restoring the database also restores its API keys. If the key configured
   during empty-server setup no longer works, create/choose a valid key in the
   restored instance and update encrypted config with `npm run edit-env`, then deploy.
8. Run `npm test`, inspect workflows and credential decryption, test an actual
   workflow, and verify a new backup and publish export. Delete the old server
   only after recovery is verified.

Do a recovery rehearsal on a disposable host before relying on this procedure.
Snapshot/schema compatibility matters: match the n8n version to the restored
data before attempting a different version. Recovery time is not guaranteed.

## Alerts and live checks

Resend email alerts need an API key, verified sender, and developer email.
The hourly disk check defaults to 85%/95% used. Workflow error notifications
use Resend email. The Global Error Handler shares one 15-minute cooldown across
workflow errors, starting only after successful email delivery; failed sends
remain eligible for retry on the next error.

Health Ping ships active and runs every five minutes. An empty Ping URL disables
its HTTP request. The wizard uses a masked read-write API key (or the developer
default) to create a check, retaining only its Ping URL; blank skips and a saved
URL skips the key question. API failures show their status and error before retry.
The check has a ten-minute timeout and thirty-minute grace; configure notification
channels in that service. Those check settings do not change the workflow's five-minute schedule.

`npm test` runs interactive checks against your actual VPS, including backup/
restore and publish/deploy behavior. The disk and workflow-error email tests send
immediately after a one-line notice, then ask you to check Inbox and Spam.
Known send or webhook failures stop the test with a reason before that question.
The workflow-error test waits up to 75 seconds for the handler's successful-send
timestamp; if it never advances, inspect **Send Error Email** in the n8n execution
for Resend's failure details.
Manual workflow steps retain a skip option; database restore still requires confirmation.
The error-email test may clear the cooldown and restart n8n before triggering.
Fail on Purpose ships inactive; its POST webhook is public when active, so turn
it off after testing. Unit checks are the offline alternative: `npm run test:unit`.

GitHub token checks run on the VPS and report the HTTP status and `GITHUB_REPO`:
401 means an invalid or expired token, 403 means a missing permission, and 404
means the token cannot access that repository or its name is wrong. Other failures
include curl's exit code. Tokens and API response bodies are not printed.

The host-fingerprint check fails on a mismatch and prints both values without
rewriting plaintext or encrypted secrets. Check the VPS IP and independently
verify the ed25519 fingerprint in the provider console. After a real rebuild,
run `npm run decrypt-env` if `.env` is absent, set `N8N_VPS_HOST_FINGERPRINT` to
the verified value, run `npm run encrypt-env`, then commit and push the encrypted file.

## Upgrade images and custom nodes

Run `npm run refresh-images` to propose fresh tags and digests within the pinned
major versions, review the diff, verify a current backup, then push to `main`.
A major-version change requires deliberately editing the image pin and checking
upstream migration guidance; this helper does not perform it. A failed registry
lookup makes the helper fail; tag-list and digest HTTP errors include the status.
"No tags matched filter" means the tag list succeeded but contained no match.
Test restored data against the intended version.

Use `npm run nodes:install`, `npm run nodes:build`, and `npm run nodes:lint` for
[the custom-node package](../n8n/custom-nodes/). `npm run nodes:dev` watches edits.
Commit its lockfile. Full deployment uses Node 22, `npm ci --ignore-scripts`,
builds, prunes development dependencies, and mounts the package read-only.
Dependencies requiring install scripts will not be built by that deployment path.
The installed pre-commit hook type-checks/lints staged custom-node changes.
