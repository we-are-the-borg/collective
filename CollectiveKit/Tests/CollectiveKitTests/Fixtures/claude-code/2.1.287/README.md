# Claude Code 2.1.287 fixtures

Hook payloads and session status files of eight runs: interrupts mid turn (2) and mid
tool (3), a permission request and a question (4), background subagents (6), a
background shell still running at the exit dialog (6a), an exit without a prompt (11),
a failing tool (12) and a SIGTERM without input (14).

Copied from subspace's fixture of the same name, `fixtures/claude-code/2.1.287/`
(subspace commit `abc1704`), anonymized there. Its README describes the runs. Only what
the tests read is copied: `events/` of all eight runs, `status/` and
`timeline.jsonl` of runs 2, 3, 4, 6 and 6a.

`events/NNN-<hook_event_name>.json` are raw payloads, not envelopes; the tests wrap
them. `status/NNN-status.json` are snapshots of Claude Code's `sessions/<pid>.json`;
`timeline.jsonl` gives the arrival order of events and snapshots (the `n` field is
the `NNN`). Runs 11, 12 and 14 have gaps in `NNN` where snapshots were not copied.

Do not edit these files. To update them, copy the files again from subspace and
note the commit here.
