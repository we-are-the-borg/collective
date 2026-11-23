# Origin of the theme schemes

The `.yaml` files in this folder are taken **unmodified** from the repository
[tinted-theming/schemes](https://github.com/tinted-theming/schemes):

- Ref: `spec-0.11`
- Folders: `base24/` and `base16/`, see below

| Folder    | Files |
| --------- | ----- |
| `base24/` | `catppuccin-*` (4), `github*` (5), `dracula`, `gruvbox-dark`, `gruvbox-light`, `tokyo-night-dark`, `tokyo-night-light`, `tokyo-night-moon`, `tokyo-night-storm`, `one-dark`, `one-light`, `ayu-dark`, `ayu-light`, `ayu-mirage`, `kanagawa-dragon` |
| `base16/` | `kanagawa`, `tomorrow`, `tomorrow-night`, `tomorrow-night-eighties`, `material`, `material-darker`, `material-lighter`, `material-palenight`, `solarized-dark`, `solarized-light`, `nord`, `rose-pine`, `rose-pine-moon`, `rose-pine-dawn`, `everforest-dark-medium`, `everforest-light-medium` |

The `author` fields in the files name the authors of the individual schemes.
The files must not be modified; how to add a theme is described in
`docs/theme-tokens.md` under "Adding a theme".

## License of the scheme repository

SPDX: MIT

```
Copyright (c) 2022 Tinted Theming (https://github.com/tinted-theming)

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## Licenses of the scheme families

The schemes are derived from the color themes of these projects. The
licenses were read from each upstream repository's license file.

| Family | Upstream | SPDX | Copyright |
| ------ | -------- | ---- | --------- |
| Catppuccin | [catppuccin/catppuccin](https://github.com/catppuccin/catppuccin/blob/main/LICENSE) | MIT | Copyright (c) 2021 Catppuccin |
| GitHub (Primer primitives) | [primer/primitives](https://github.com/primer/primitives/blob/main/LICENSE) | MIT | Copyright (c) 2018 GitHub Inc. |
| Dracula | [dracula/dracula-theme](https://github.com/dracula/dracula-theme/blob/main/LICENSE) | MIT | Copyright (c) 2023 Dracula Theme |
| Gruvbox | [morhetz/gruvbox](https://github.com/morhetz/gruvbox) | MIT | none stated; the repository has no license file, its `README.md` ("MIT/X11") and `package.json` ("MIT") name the license |
| Tokyo Night | [tokyo-night/tokyo-night-vscode-theme](https://github.com/tokyo-night/tokyo-night-vscode-theme/blob/master/LICENSE.txt) (formerly enkia/tokyo-night-vscode-theme) | MIT | Copyright (c) 2018-present Enkia |
| One (Atom One Dark/Light) | [atom/one-dark-syntax](https://github.com/atom/one-dark-syntax/blob/master/LICENSE.md), [atom/one-light-syntax](https://github.com/atom/one-light-syntax/blob/master/LICENSE.md) | MIT | Copyright (c) 2016 GitHub Inc. |
| Ayu | [ayu-theme/ayu-colors](https://github.com/ayu-theme/ayu-colors/blob/master/license) | MIT | Copyright (c) Konstantin Pschera <me@kons.ch> (kons.ch) |
| Kanagawa | [rebelot/kanagawa.nvim](https://github.com/rebelot/kanagawa.nvim/blob/master/LICENSE) | MIT | Copyright (c) 2021 Tommaso Laurenzi |
| Tomorrow | [chriskempson/tomorrow-theme](https://github.com/chriskempson/tomorrow-theme/blob/master/LICENSE.md) | MIT | Copyright (C) 2011 Chris Kempson |
| Material (Material Theme) | [ntpeters/base16-materialtheme-scheme](https://github.com/ntpeters/base16-materialtheme-scheme/blob/master/LICENSE) | MIT | Copyright (c) 2017 Nathan Peterson |
| Solarized | [altercation/solarized](https://github.com/altercation/solarized/blob/master/LICENSE) | MIT | Copyright (c) 2011 Ethan Schoonover |
| Nord | [nordtheme/nord](https://github.com/nordtheme/nord/blob/develop/license) (formerly arcticicestudio/nord) | MIT | Copyright (c) 2016-present Sven Greb <development@svengreb.de> (https://www.svengreb.de) |
| Rosé Pine | [rose-pine/rose-pine-theme](https://github.com/rose-pine/rose-pine-theme/blob/main/LICENSE) | MIT | Copyright (c) 2023 Rosé Pine |
| Everforest | [sainnhe/everforest](https://github.com/sainnhe/everforest/blob/master/LICENSE) | MIT | Copyright (c) 2019 sainnhe |

Notes:

- The Dracula scheme is based on the
  [Dracula spec](https://github.com/dracula/draculatheme.com/blob/main/content/spec.mdx).
  That repository has no license file; its `readme.md` names the MIT License.
- The One schemes are by FredHappyface after Atom's One Dark and One Light.
- The five `github*` files stem from an earlier revision of the upstream
  schemes repository
  ([`2ccef2f`](https://github.com/tinted-theming/schemes/commit/2ccef2f4b22e3cab5a9292811f7133a07eeba4a7),
  "update `*-github` themes"), not from the current state of `spec-0.11`.
  They are unmodified copies of that revision.
