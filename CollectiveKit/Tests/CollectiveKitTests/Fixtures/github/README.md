# GitHub tags API fixtures

Real responses of the GitHub REST API, captured on 2026-11-04 with `curl`
(headers `Accept: application/vnd.github+json` and a `User-Agent`, no token),
for `SubspaceReleaseChecker`. Both answered `HTTP/2 200`.

- `tags-subspace-claude-code.json`: body of
  `GET https://api.github.com/repos/we-are-the-borg/subspace-claude-code/tags?per_page=100`.
  Tags `claude-code-1.0.0` to `claude-code-1.3.0`, newest first; the latest release is 1.3.0.
- `tags-subspace-codex.json`: body of
  `GET https://api.github.com/repos/we-are-the-borg/subspace-codex/tags?per_page=100`.
  Tags `codex-1.0.0` to `codex-1.1.0`; the latest release is 1.1.0.

They prove the shape the checker decodes (a JSON array of objects with `name`)
and that each marketplace repo tags its versions as `<prefix>X.Y.Z`.

Do not edit these files. To update them, capture again and note the date here.
