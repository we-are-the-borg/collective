# Antigravity plugin detection fixtures

Real outputs of the Antigravity CLI `agy` `1.5.17`, for
`AntigravityIntegrationProbe` (subspace contract §11). subspace was installed
locally from the subspace checkout `adapters/antigravity` (commit `c80aaab`;
unchanged on `main` at `0f9b53b`).

- `version.txt`: stdout of `agy --version`.
- `not-installed.json`: stdout of `agy plugin list --json` before subspace was
  installed.
- `enabled.json`: stdout of `agy plugin list --json` after
  `agy plugin install`; subspace is installed and enabled.
- `disabled.json`: the same after `agy plugin disable subspace`.
- `uninstalled.json`: the same after `agy plugin uninstall subspace`. `agy`
  1.5.16 kept `plugin_data/subspace/` then (subspace contract §2); 1.5.17,
  verified on 2026-11-26, removes both `plugin_data/subspace/` folders (CLI and
  desktop app). A `plugin.json` can still be left over from an older version.
- `hand-placed.json`: the same after `agy plugin uninstall subspace` and a clone
  by hand, `git clone --depth 1 --branch antigravity-1.0.0 https://github.com/we-are-the-borg/subspace-antigravity ~/.gemini/config/plugins/subspace`
  (captured on 2026-11-26 with `agy` 1.5.17 and Antigravity.app 2.35.1, which
  loaded the plugin after a restart): enabled, without the `source` key.

The files `agy` keeps itself, for the probe's fallback without the CLI:

- `manifest-plugin.json`: `~/.gemini/config/plugins/subspace/.antigravity-plugin/plugin.json`
  after `agy plugin install`. `agy plugin uninstall subspace` removes the
  folder. The author's name is replaced by the placeholder `Author`.
- `config-enabled.json`: `~/.gemini/config/config.json` after
  `agy plugin enable subspace`, reduced to its `plugins` key (the real file has
  more top-level keys, such as `sidecars` and `userSettings`, which the probe
  does not read).
- `config-disabled.json`: the same after `agy plugin disable subspace`.
- `config-no-entry.json`: derived, not captured: `config-enabled.json` without
  the `subspace` entry, as the real file looked right after `agy plugin install`
  (when `agy plugin list --json` reported it enabled). Confirmed by
  `config-hand-placed.json`, which has the same content.
- `config-hand-placed.json`: `config.json` reduced to its `plugins` key in the
  state of `hand-placed.json`: no `subspace` entry.

Anonymized: the home directory is `/Users/user`, the manifest's author as above.
Nothing else was changed; do not edit these files otherwise. To update them,
capture again, anonymize the same way and note the version here.
