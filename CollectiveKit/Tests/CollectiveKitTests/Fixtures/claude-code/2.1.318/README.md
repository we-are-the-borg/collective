# Claude Code 2.1.318 fixtures

Hook payloads, session status files and the envelope's terminal identifiers of run 22:
a background session started with `claude --bg`, run by a process of Claude Code's
daemon.

Copied from subspace's fixture of the same name, `fixtures/claude-code/2.1.318/`
(subspace commit `abc1704`). Its README describes the run. Only what the tests read is
copied: `events/`, `terminal.json` and three of the status snapshots.

`events/NNN-<hook_event_name>.json` are raw payloads, not envelopes; the tests wrap
them. `terminal.json` is the envelope's `terminal` field for those hooks: the daemon's
Warp tab, not the driver's. `status/NNN-status.json` are snapshots of Claude Code's
`sessions/<pid>.json` (`kind: bg`).

Do not edit these files. To update them, copy the files again from subspace and
note the commit here.
