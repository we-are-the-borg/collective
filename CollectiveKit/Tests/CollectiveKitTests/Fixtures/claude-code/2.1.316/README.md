# Claude Code 2.1.316 fixtures

Hook payloads and session status files of two runs: three `AskUserQuestion` calls,
answered with a multiple choice and free text, with a note on an option with a
`preview`, and dismissed with Esc, which sends no hook (19); one `Bash` call with a
four-line heredoc, approved at the permission dialog (20).

Copied from subspace's fixture of the same name, `fixtures/claude-code/2.1.316/`
(subspace commit `abc1704`). Its README describes the runs. Only what the tests read is
copied: `events/` and `timeline.jsonl` of both runs, `status/` of run 19 and
the snapshots of run 20 up to its permission request, not the mapped results.

`events/NNN-<hook_event_name>.json` are raw payloads, not envelopes; the tests wrap
them. `status/NNN-status.json` are snapshots of Claude Code's `sessions/<pid>.json`;
`timeline.jsonl` gives the arrival order of events and snapshots (the `n` field is
the `NNN`). Run 20 has gaps in `NNN` where snapshots were not copied.

Do not edit these files. To update them, copy the files again from subspace and
note the commit here.
