# Claude Code 2.1.285 fixtures

Hook payloads of three runs: headless parallel subagents (1), interactive background
subagents with a compaction and exit (2), and an interactive permission request ended
with Ctrl-C (3).

The `events/` files are copied from subspace's fixture of the same name,
`fixtures/claude-code/2.1.285/` (subspace commit `abc1704`), anonymized there. Its
README describes the runs. `events/NNN-<hook_event_name>.json` are raw payloads in
arrival order, not envelopes; the tests wrap them.

`<run>/subagents/agent-<agent_id>.meta.json` (runs 1 and 2) come from the same capture
but are not part of the subspace fixture: the side files the adapter reads to link a
subagent to its `Agent` call. They hold only the agent type, the description, the
tool use id, the spawn depth and how the agent was requested (`requestShape`,
`requestNonInteractive`).

Do not edit these files. To update them, copy the files again from subspace and
note the commit here.
