# Bundled mapping documents

Fallback copies of the subspace mapping documents in `Mappings/`, used when
the installed plugin has not written `$ROOT/model/<name>.json` (or wrote
something unusable). `MappingLoader` takes whichever known-format document has
the higher revision. This README stays outside `Mappings/` so it is not
shipped in the bundle.

Source: subspace dev repo, `model/`, commit `0f9b53b`.

| File | Revision |
| --- | --- |
| `antigravity.json` | 1 |
| `claude-code.json` | 9 |
| `claude-code-session.json` | 3 |
| `codex.json` | 2 |

To update, copy the files from `subspace/model/` again, byte for byte, and
adjust this table. `MappingLoaderTests` compares them to the sibling checkout
and fails on drift.
