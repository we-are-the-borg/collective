# Claude Code 2.1.289 fixtures

Hook payloads of three runs: two `Agent` calls, one with `model: haiku`, one
inheriting the model (16); `/model sonnet`, then `/clear` in the same process (17);
`--continue` of run 17's second session with `--model haiku` (18).

Copied from subspace's fixture of the same name, `fixtures/claude-code/2.1.289/`
(subspace commit `abc1704`), anonymized there. Its README describes the runs. Only what
the tests read is copied: `events/` of all three runs and `status/` of run 17.

`events/NNN-<hook_event_name>.json` are raw payloads, not envelopes; the tests wrap
them. `status/NNN-status.json` are snapshots of Claude Code's `sessions/<pid>.json`
(`kind: interactive`). `NNN` has gaps where snapshots were not copied.

Do not edit these files. To update them, copy the files again from subspace and
note the commit here.
