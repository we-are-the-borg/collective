# Acknowledgements input

`acknowledgements.json` is the maintained half of the app's acknowledgements: display name,
SPDX id and project URL for every package pinned in `../Package.resolved` or in the app's
`Package.resolved` (packages only the app links, such as Sparkle), plus the material
that is not a package (libyaml, fonts, icons, color schemes) with its license file.
`scripts/acknowledgements.sh` merges it with the pins and the license texts of the package
checkouts into `Sources/CollectiveKit/Resources/Acknowledgements.json` and the repository's
`THIRD_PARTY_NOTICES.md`; `AcknowledgementsTests` fails when the resource no longer matches
either `Package.resolved`.

Each section has an `id` (`libraries`, `fontsAndIcons` or `colorSchemes`; the script rejects any
other). The titles come from the kit's string catalog (`SettingsText`), not from this file.

Entry keys: `package` (identity in `Package.resolved`; version and license texts come from the
pin and its checkout), `bundledIn` (a package that vendors this one; the version reads
`in <name> <version>`), `version` (fixed), `schemeIDPrefix` (counts the bundled
`Schemes/*.yaml` with that prefix and writes the number as `schemeCount` into the output, shown
instead of a version), `files` (license texts, relative to the repository root), `note` (optional
sentence printed under the entry's heading in `THIRD_PARTY_NOTICES.md` only, e.g. the trademark
note for the Lobe Icons logos; the About sheet does not show it).

The files in `texts/` are verbatim copies of upstream license files the repository has no other
copy of (checked 15.11.2026; the scheme families' texts fetched 16.11.2026 at the commit given,
copyright lines checked against `Sources/CollectiveKit/Resources/Schemes/NOTICE.md`):

| File | Upstream |
|---|---|
| `libyaml-License` | https://github.com/yaml/libyaml/blob/master/License (Yams vendors libyaml as `CYaml` without it) |
| `lobe-icons-LICENSE` | https://github.com/lobehub/lobe-icons/blob/9752d967494e48d8f83f2808feb2b0207bf70997/LICENSE (fetched 19.11.2026; the tool logos in `Sources/CollectiveKit/Resources/SourceIcons.xcassets` come from `@lobehub/icons-static-svg` 1.104.0, `icons/claude.svg`, `icons/codex.svg` and `icons/antigravity.svg`; claude and codex with the arc flags separated for CoreSVG and the geometry unchanged, antigravity byte-equal) |
| `catppuccin-LICENSE` | https://github.com/catppuccin/catppuccin/blob/main/LICENSE (the palette) |
| `primer-primitives-LICENSE` | https://github.com/primer/primitives/blob/main/LICENSE (GitHub's colors) |
| `tinted-theming-schemes-LICENSE` | https://github.com/tinted-theming/schemes/blob/spec-0.11/LICENSE (the scheme files; same text as `Sources/CollectiveKit/Resources/Schemes/NOTICE.md`) |
| `ayu-LICENSE` | https://github.com/ayu-theme/ayu-colors/blob/c6e86054896ef10c69ba899dc11fdad0e004d4d3/license |
| `dracula-LICENSE` | https://github.com/dracula/dracula-theme/blob/8d33e5492b56740c4857c5ebe7c5d5ab4040caf1/LICENSE |
| `everforest-LICENSE` | https://github.com/sainnhe/everforest/blob/85a86eb62409e3ec88713bff3d1b9d7374e112e4/LICENSE |
| `gruvbox-LICENSE` | maintained here, not a copy: https://github.com/morhetz/gruvbox (at `ef8864bb42bf244f0295d1c5a403b27e3d139695`) has no license file, its `README.md` and `package.json` name MIT, so the text is one sentence saying so over the MIT License text without a copyright line |
| `kanagawa-LICENSE` | https://github.com/rebelot/kanagawa.nvim/blob/bb85e4bfc8d89b0e62c8fa53ccdd13d12e2f77b3/LICENSE |
| `material-LICENSE` | https://github.com/ntpeters/base16-materialtheme-scheme/blob/cbbc47444208fb8f28dbc48ea986c9dc81843e9a/LICENSE |
| `nord-LICENSE` | https://github.com/nordtheme/nord/blob/1cef71605416a222e57225b544540ce0fcec18d4/license |
| `one-dark-syntax-LICENSE` | https://github.com/atom/one-dark-syntax/blob/9c96f4454362267ac45322063e193ccf9d2debb1/LICENSE.md |
| `one-light-syntax-LICENSE` | https://github.com/atom/one-light-syntax/blob/d84579027410c576086dfca14d934c4bd74b0438/LICENSE.md |
| `rose-pine-LICENSE` | https://github.com/rose-pine/rose-pine-theme/blob/781bb844aae0bcec2763b23a4c7d3cc6aede780c/LICENSE |
| `solarized-LICENSE` | https://github.com/altercation/solarized/blob/62f656a02f93c5190a8753159e34b385588d5ff3/LICENSE |
| `tokyo-night-LICENSE` | https://github.com/tokyo-night/tokyo-night-vscode-theme/blob/7c0f11eaef322f293621ca7befe462214b7ea468/LICENSE.txt |
| `tomorrow-LICENSE` | https://github.com/chriskempson/tomorrow-theme/blob/ccf6666d888198d341b26b3a99d0bc96500ad503/LICENSE.md |
