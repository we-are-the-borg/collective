# Test fixtures

Captured hook payloads, copied byte for byte from the subspace dev repo's
`fixtures/` (`../../we-are-the-borg/subspace/fixtures/`):

| File | Origin |
| --- | --- |
| `claude-code/008-Stop.json` | `fixtures/claude-code/2.1.287/1-idle-exit/events/008-Stop.json` |
| `claude-code/009-PostToolUse.json` | `fixtures/claude-code/2.1.287/13-file-tools/events/009-PostToolUse.json` |
| `codex/005-Stop.json` | `fixtures/codex/0.159.3/10-cwd-with-spaces/events/005-Stop.json` |
| `codex/008-PostToolUse.json` | `fixtures/codex/0.159.3/1-headless-parallel-reused-child-failure/events/008-PostToolUse.json` |
| `claude-code/terminal.json` | `fixtures/claude-code/2.1.317/21-terminal-env/terminal.json` |

They are raw payloads, not spool files: no envelope was captured. The tests wrap
each one in a version-1 envelope (contract §4) with the `envelopeJSON` helper in
`SpoolTests.swift`; the envelope fields (`source`, `ts`, `pid`) are the helper's.

`claude-code/terminal.json` is not a payload: it is the `terminal` value of an
envelope (contract §4) captured from Claude Code 2.1.317 running in Warp. The
tests put it into an envelope with `envelopeJSON(terminal:payload:)`.
