# Claude Code plugin detection fixtures

Real outputs captured on 2026-10-07 with Claude Code `2.1.292 (Claude Code)`, for
`ClaudeCodeIntegrationProbe` (subspace contract §11). Only read-only commands were run.

- `version.txt`: stdout of `claude --version`.
- `plugin-list-enabled.json`: stdout of `claude plugin list --json`. subspace is
  installed with scope `user` and enabled; other plugins are disabled, and
  `mattpocock-skills@mattpocock` appears once per scope (`project` and `user`).
- `plugin-list-empty.json`: stdout of `claude plugin list --json` with
  `CLAUDE_CONFIG_DIR` pointing to an empty folder.
- `installed_plugins.json`: copy of `~/.claude/plugins/installed_plugins.json`.
- `settings-enabledPlugins.json`: an excerpt of `~/.claude/settings.json`, only the
  `enabledPlugins` object with its content unchanged.

Captured on 2026-10-31 with Claude Code `2.1.316 (Claude Code)`, again read-only:

- `marketplace-list.json`: stdout of `claude plugin marketplace list --json`. The
  subspace marketplace is added (`"name": "subspace"`,
  `"repo": "we-are-the-borg/subspace-claude-code"`) next to three others.
- `marketplace-list-empty.json`: stdout of `claude plugin marketplace list --json`
  with `CLAUDE_CONFIG_DIR` pointing to an empty folder.

Anonymized: the home directory is `/Users/user`, the project of the
project-scoped plugin `/Users/user/dev/other-project`. Nothing else was changed;
do not edit these files otherwise. To update them, capture again, anonymize the
same way and note the date and version here.
