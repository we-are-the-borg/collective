# Fonts

Copied unmodified from IBM's official [Plex](https://github.com/IBM/plex) GitHub releases, from the archives' `fonts/complete/ttf/` folders. Both families are licensed under the SIL Open Font License 1.1; each family's license text sits next to its fonts.

| Font | Release | Files | License | Role |
|---|---|---|---|---|
| IBM Plex Sans, © 2017 IBM Corp. with Reserved Font Name "Plex" | [`@ibm/plex-sans@1.1.0`](https://github.com/IBM/plex/releases/tag/%40ibm%2Fplex-sans%401.1.0) (`ibm-plex-sans.zip`) | `ibm-plex-sans/IBMPlexSans-Regular.ttf`, `ibm-plex-sans/IBMPlexSans-Medium.ttf`, `ibm-plex-sans/IBMPlexSans-SemiBold.ttf`, `ibm-plex-sans/IBMPlexSans-Italic.ttf`, `ibm-plex-sans/IBMPlexSans-MediumItalic.ttf`, `ibm-plex-sans/IBMPlexSans-SemiBoldItalic.ttf` | [`ibm-plex-sans/license.txt`](ibm-plex-sans/license.txt) | UI font (italics for emphasis in replies) |
| IBM Plex Mono, © 2017 IBM Corp. with Reserved Font Name "Plex" | [`@ibm/plex-mono@2.5.0`](https://github.com/IBM/plex/releases/tag/%40ibm%2Fplex-mono%402.5.0) (`ibm-plex-mono.zip`) | `ibm-plex-mono/IBMPlexMono-Regular.ttf`, `ibm-plex-mono/IBMPlexMono-Medium.ttf` | [`ibm-plex-mono/license.txt`](ibm-plex-mono/license.txt) | code font (paths, commands, counts) |

`IBMPlexSans-Regular.ttf` and `IBMPlexSans-SemiBold.ttf` are byte-identical (SHA-256) to the copies Unimatrix Zero bundles (`crates/ui/assets/fonts/ibm-plex-sans/`, taken from Zed `v1.27.0`), so both apps draw the same faces. Unlike Unimatrix Zero, which uses Lilex, the code font here is Plex Mono.
