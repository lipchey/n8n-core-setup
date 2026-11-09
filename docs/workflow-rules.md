# n8n workflow rules

Load before creating, editing, or debugging files in [the workflow directory](../n8n/workflows/).

## Authoring and synchronization

- Humans may edit in the UI and publish; pull exported commits before local work.
- Agents author repository JSON and deploy through Git/Actions on `main`. MCP is
  for read/inspect operations only; do not use MCP/SDK creation or update tools.
- Read node schemas and existing examples before choosing parameters. Preserve
  credential references; ask for missing credentials rather than inlining secrets.
- Parse JSON, check unique node IDs, and ensure connection keys/targets match node
  names. Validate parameter shapes and expression prefixes against node schemas.
- Push upserts by workflow name, preserves credential blocks, and auto-links the
  Global Error Handler by name. An empty `_errorWorkflowName` explicitly opts out.
- Review deletion/renaming as destructive: deploy can remove the old workflow.
- Keep the Global Error Handler itself out of its own error path.
- Authenticate public webhooks in the workflow; Access bypass is not authentication.

## Environment access

- Shipped workflow environment prerequisite:
     - prereq: n8n must run with `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` for `$env.*` to resolve in expressions (the Compose default)
- **Do NOT read `$env` or `process.env` directly inside a Code node.** In n8n v2.22.0+, the Code node sandbox's `$env` Proxy internally references `process`, which is not in scope — triggering "process is not defined" on any `$env.VAR` access even with `N8N_BLOCK_ENV_ACCESS_IN_NODE=false`. **Fix pattern:** add a Set node before the Code node, use `={{ $env.VAR }}` in its expression fields (expressions work correctly), then read `$input.first().json.var` in the Code node.
- **`$env.VAR` works in expression fields** (any `={{ }}` context) only while `N8N_BLOCK_ENV_ACCESS_IN_NODE=false`; setting it to `true` also denies expressions and stops the shipped alert and health workflows.

## Files and project context

- Store reusable AI prompts in [the prompts directory](../n8n/ai-system-prompts/);
  Compose mounts it read-only in the container. Do not put secrets in those files.
- Read binary buffers with n8n helpers rather than treating storage references as
  base64. A file-read node may discard upstream JSON; retain template variables
  through an explicit reference to their source node.
- Keep reusable verified constraints current; do not add workflow-specific logs
  or unverified vendor/version claims to this guide.
