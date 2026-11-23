# Codex CLI 0.167.0 fixtures

Hook payloads and rollout excerpts of five runs: automatic review approving four
requests (1), automatic review rejecting one request and approving two (2), the manual
reviewer with one approval and one denial (3), reasoning effort per turn with a switch
and a child agent (4), and an approved heredoc of a five-line command (5).

Copied from subspace's fixture of the same name, `fixtures/codex/0.167.0/` (subspace
commit `abc1704`), anonymized there. Its README describes the runs, the findings and
the edited excerpts. Only what the tests read is copied: `events/` and
`rollouts/excerpt.jsonl` of all five runs, not the mapped results.

`events/NNN-<hook_event_name>.json` are raw payloads, not envelopes; the tests wrap
them. `rollouts/excerpt.jsonl` holds the `turn_context` records the adapter reads for
the reviewer and the effort of a turn.

Do not edit these files. To update them, copy the files again from subspace and
note the commit here.
