# Contributing

Report reproducible bugs with the issue template. For security vulnerabilities,
use [the private reporting address](SECURITY.md). General project contact:
[Yuriy Lipchey](mailto:yuriy.lipchey.work@gmail.com).

Keep patches focused and preserve the [support boundary](README.md#supported-environment).
Explain the concrete behavior changed, how you checked it, and any operational
risk. Never include real environment values, tokens, private keys, host details,
or generated MCP configuration in a patch or issue.

## Local checks

The offline unit suite needs Bash, Git, jq, Node.js, and Python 3:

```bash
npm run test:unit
```

It tests workflow secret scanning, VPS script behavior using stubs, config
validators, wizard helpers, and setup documentation generation/drift. It does
not need a VPS or Docker. Shell changes also need `bash -n` and
`shellcheck -S warning` for all shell files and Git hooks. Workflow YAML can be
checked with `actionlint`. [CI](.github/workflows/ci.yml) additionally validates
Compose with placeholders and parses the shipped workflow JSON.

If you change initialization prompts or headings, regenerate the committed table:

```bash
python3 scripts/generate-setup-docs.py
```

The generator extracts helper calls and action headings from
[the initializer](scripts/initialize.sh) without executing shell code. It also
inventories direct terminal reads. Their wording/defaults, called-script dialogs,
and [recommended answers](docs/setup.md) still need manual review.
Unit tests prove rejection of stale output in a throwaway copy.

Custom-node changes use `npm run nodes:install`, `npm run nodes:build`, and
`npm run nodes:lint`. Keep the package lockfile in the patch. Do not add a
dependency when the standard library or existing code solves the problem.

`npm test` is a live, interactive environment suite that can change deployed
state; use a disposable instance for integration verification. Provisioning,
deployment, restore, and hard reset are not offline tests.

## Workflows and comments

Follow [the workflow rules](docs/workflow-rules.md). Humans may author in the UI;
agents author repository JSON and use MCP to inspect only. Keep comments English, short, and limited
to a non-obvious constraint or reason; avoid narration and process history.
In C-family languages use block comments except tool directives/required doc forms.
