# Codex plugin detection fixtures

Real outputs of Codex, for `CodexIntegrationProbe` (subspace contract §11). Only
read-only commands were run.

- `plugin-list.json`: stdout of `codex plugin list --json` of Codex `0.160.1`,
  reduced to two installed entries; subspace is installed and enabled.

Captured on 2026-10-31 with `codex-cli 0.166.0`:

- `marketplace-list.json`: stdout of `codex plugin marketplace list --json`. The
  subspace marketplace is added (`"name": "subspace"`, git source
  `https://github.com/we-are-the-borg/subspace-codex.git`) next to bundled, local
  and other git marketplaces; `openai-curated` has no `marketplaceSource`.
- `marketplace-list-empty.json`: stdout of `codex plugin marketplace list --json`
  with `CODEX_HOME` pointing to an empty folder.

Anonymized: the home directory is `/Users/user`. Nothing else was changed; do not
edit these files otherwise. To update them, capture again, anonymize the same way
and note the date and version here.
