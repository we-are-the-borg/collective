# Custom theme fixtures

Foreign tinted-theming schemes for reading a folder of custom themes (`CustomThemeFolder`).
None of them is bundled with the app. Upstream files are unmodified copies from
https://github.com/tinted-theming/schemes at ref `spec-0.11` (commit
1bd5ad4c2c554c9c8e288b56deab2364ac8dada0, MIT). Every other file is derived from one of them by
the minimal edit listed, so the tests read real files, not guessed formats.

## Upstream

| File | Source |
| --- | --- |
| `horizon-dark.yaml` | https://raw.githubusercontent.com/tinted-theming/schemes/spec-0.11/base16/horizon-dark.yaml (base16, dark) |
| `embers-light.yaml` | https://raw.githubusercontent.com/tinted-theming/schemes/spec-0.11/base16/embers-light.yaml (base16, light) |
| `espresso.yaml` | https://raw.githubusercontent.com/tinted-theming/schemes/spec-0.11/base24/espresso.yaml (base24, dark) |

## Derived

Every scheme at `spec-0.11` declares `variant`, so the file without it is derived too.

| File | From | Edit |
| --- | --- | --- |
| `horizon-light-without-variant.yaml` | https://raw.githubusercontent.com/tinted-theming/schemes/spec-0.11/base16/horizon-light.yaml | line `variant: "light"` removed |
| `missing-base0D.yaml` | `horizon-dark.yaml` | line `base0D: …` removed |
| `base0A-not-a-color.yaml` | `horizon-dark.yaml` | `base0A: "#EFB993"` → `base0A: "EFB993"` |
| `not-yaml.yaml` | `horizon-dark.yaml` | `palette:` → `palette: [` |
| `two-documents.yaml` | `horizon-dark.yaml` | the file, a line `---`, the file again |
| `not-a-mapping.yaml` | `horizon-dark.yaml` | `- ` before every line |
| `wrong-system.yaml` | `horizon-dark.yaml` | `system: "base16"` → `system: "base17"` |
| `missing-system.yaml` | `horizon-dark.yaml` | line `system: …` removed |
| `missing-name.yaml` | `horizon-dark.yaml` | line `name: …` removed |
| `empty-name.yaml` | `horizon-dark.yaml` | `name: "Horizon Dark"` → `name: ""` |
| `invalid-variant.yaml` | `horizon-dark.yaml` | `variant: "dark"` → `variant: "dusk"` |
| `invalid-author.yaml` | `horizon-dark.yaml` | `author: …` → `author: 42` |
| `missing-palette.yaml` | `horizon-dark.yaml` | `palette:` → `colors:` |
| `not-utf8.yaml` | `horizon-dark.yaml` | the `ë` in the author (UTF-8 `C3 AB`) → Latin-1 byte `EB` |
| `all-same.yaml` | `espresso.yaml` | all 24 colors → `#808080` |
| `all-black.yaml` | `espresso.yaml` | all 24 colors → `#000000` |
| `all-white.yaml` | `espresso.yaml` | all 24 colors → `#ffffff` |
