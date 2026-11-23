# Claude Code 2.1.319 fixtures

Hook payloads and session status files of run 25: an interactive sonnet session taken
through every `/effort` level, a failing tool at `max`, then at `max` two `Agent`
calls, one with its own `effort: "high"`, one inheriting the orchestrator's level.

Copied from subspace's fixture of the same name, `fixtures/claude-code/2.1.319/`
(subspace commit `abc1704`). Its README describes the run. Only what the tests read is
copied: `events/`, `timeline.jsonl` and the snapshots in `status/` up to the
last `SubagentStop`, not the mapped results.

`events/NNN-<hook_event_name>.json` are raw payloads, not envelopes; the tests wrap
them. `status/NNN-status.json` are snapshots of Claude Code's `sessions/<pid>.json`;
`timeline.jsonl` gives the arrival order of events and snapshots (the `n` field is
the `NNN`). There are gaps in `NNN` where snapshots were not copied.

Do not edit these files. To update them, copy the files again from subspace and
note the commit here.
