# Changelog

## Unreleased

- Match provider SSH keys against the selected private key even outside `~/.ssh`,
  reselect mismatches, and distinguish pre-create failures from possible billing.
- Check age-directory creation access and default-keystore writes before providers;
  require GitHub CLI 2.40 and remove obsolete install/login and clipboard fallbacks.
- Keep default B2 names unsaved until creation or reuse succeeds, preserving suffix
  retries after interruptions, and discard placeholder credentials in manual prune.
- Select the numeric n8n tag matching `stable` instead of a higher beta tag; fail
  with the reason when stable cannot be resolved or matched.
- Keep local API credentials out of curl arguments, describe the VPS PAT's access
  to deploy secrets, and limit its preflight claim to repository and Actions access.
- Use shared section headings and allow ten minutes for the nested instance suite.
- Send live-test alert emails without an initial permission prompt; stop on known
  send or webhook failures before asking about Inbox/Spam delivery.
- Report GitHub token HTTP status, repository and failure reason from the VPS;
  reject host-fingerprint mismatches without changing the saved pin.
- Report tag-list HTTP failures, retain the no-match message for successful lists,
  and use the apex hostname for the default Resend sender when needed.
- Correct encryption/decryption command hints and repository-creation instructions.
- Create healthchecks.io checks from a masked read-write API key, report API
  failure status and error before retry, and save only the returned Ping URL.
  Saved URLs and developer keys avoid the question.
- Keep workflow error alerts on Resend email, with cooldown only after delivery.
- Verify ed25519 host keys before wizard SSH, stop on saved-pin mismatches, and
  install the scanned key in known_hosts with strict checking, including first use.
  Use ed25519 consistently in later environment checks.
- Create n8n login credentials by hand in the browser and require the hidden
  API-key input with an HTTP 200 probe; retry rejected keys, keep valid saved keys
  on reruns and stop on EOF.
- Make unit tests independent of personalized instance files and run the suite
  in a personalized throwaway tree with a recursion guard.
- Report deployment-poll HTTP errors and automatically dispatch once when
  successful polling finds no run; remove automatic repository review rules.
- Standardize environment-example placeholders and discard them on shared env
  reads, including provider tokens; retain GitHub Push Protection.

- Set database credentials, B2 bucket names, and disk thresholds automatically
  while retaining saved values. Retry only B2 name collisions with bounded random
  suffixes, and reuse existing account buckets without renaming saved destinations.
- Simplify domain, Cloudflare, and Resend instructions; suggest a verified-domain
  `alerts@` sender. Centre uppercase section headings and print terminal hyperlinks
  with plain URLs in pipes and files through shared output helpers.

- Check Git operation state, filesystem access and an interactive terminal alongside
  missing tools. Validate SSH keys, local custom-node builds, push permission and
  repository-scoped PAT/Actions access before creating a billable server.
- Choose x86 provider types/sizes before available locations, show location prices,
  refresh selection after definite create rejections, and accept Enter to create
  only after the summary. Uncertain outcomes still stop for reconciliation.
- Resolve city names locally for workflow/server schedule timezones, use the machine
  zone as the default, mask secret input with asterisks and derive reused age recipients.

- Check local prerequisites before all initialization paths, with a standalone
  `npm run check-prerequisites` command, per-tool install/upgrade instructions,
  and GitHub login failures reported together.
- Pull n8n from Docker Hub without changing its pinned tag or digest; report
  registry HTTP errors, default image refresh confirmation to yes only on first
  initialization, and move the full update/rollback checklist to operations docs.
- Restore private GitHub repository creation for copied trees without
  remotes, with creation on name submission, a local root commit when needed and no
  upload until secret encryption. Check the GitHub destination before provisioning a provider server;
  preserve existing clone setup and refuse nested repositories or missing selected
  remotes alongside other configured remotes.
- Initial deployment template with provider setup, Cloudflare ingress, encrypted
  configuration, GitHub Actions, workflow synchronization, local/optional B2
  backups, custom-node example, and operator documentation.
