# Codex CLI 0.159.3 fixtures

Hook payloads of ten runs: a headless root with overlapping child turns, child reuse
and a failed command (1), a shared app-server host with automatic permission review
and compaction (2), manual approval and a remembered rejection (3), turns interrupted
before a tool call (4, 5) and during a running shell (6, 7, 10), a resumed session (8),
an ephemeral session (9) and a cwd containing spaces (10).

Copied from subspace's fixture of the same name, `fixtures/codex/0.159.3/` (subspace
commit `abc1704`), anonymized there. Its README describes the runs and the edited
rollout excerpt. Only what the tests read is copied: `events/` of all ten runs and
run 1's `rollouts/session_meta.jsonl`, not the mapped results.
`events/NNN-<hook_event_name>.json` are raw payloads, not envelopes; the tests wrap
them.

## Delivery seconds

`2-daemon-permission-compact/delivery-seconds.json` and
`3-manual-permission-remembered-rejection/delivery-seconds.json` are not part of the
subspace fixture. They give, for each `events/NNN-<hook_event_name>.json`, the epoch
second at which the hook was delivered, taken from the names of the raw capture files
(`captures/events/<epoch>-<pid>-<id>.json`); each fixture file was matched to the raw
file with the same hook, session, turn and command. The payloads carry no times, and
Codex sends a call's `PreToolUse` and `PermissionRequest` in the same second, so a
replay one second per file would mislead tests that compare event times.

Do not edit these files. To update them, copy the files again from subspace and
note the commit here.
