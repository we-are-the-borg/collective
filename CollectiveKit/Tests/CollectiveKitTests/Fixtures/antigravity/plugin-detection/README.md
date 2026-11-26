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
- `uninstalled.json`: the same after `agy plugin uninstall subspace`. Antigravity
  keeps `plugin_data/subspace/` then, so `plugin.json` can be left over.

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
  (when `agy plugin list --json` reported it enabled).

Anonymized: the home directory is `/Users/user`, the manifest's author as above.
Nothing else was changed; do not edit these files otherwise. To update them,
capture again, anonymize the same way and note the version here.
