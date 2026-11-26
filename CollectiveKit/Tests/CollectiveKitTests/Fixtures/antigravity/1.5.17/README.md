# Antigravity CLI 1.5.16 / 1.5.17 and Desktop App 2.35.1 fixtures

Hook payloads of seven runs: a headless parent with tools, a failing command and one
subagent conversation (1), two parallel subagent conversations (2), an approved and a
denied permission in the interactive CLI in Warp (3), a running tool interrupted with
`Esc` (4), a resumed conversation without `SessionStart` (5), a cwd containing spaces
(6) and two conversations of the Desktop App on one shared host process (7).

Copied from subspace's fixture of the same name, `fixtures/antigravity/1.5.17/`
(subspace commit `0f9b53b`), anonymized there. Its
README describes the runs, the findings and the edited excerpts. Copied are `events/`
of all seven runs, `transcripts/excerpt.jsonl` of runs 1, 2, 3 and 7 and
`terminal.json` of runs 3 and 7, not the mapped results.

`events/NNN-<hookEventName>.json` are raw payloads, not envelopes; the tests wrap
them. `terminal.json` holds the terminal identifiers the capture recorded for the run;
the tests put them into the envelope's `terminal`.

Do not edit these files. To update them, copy the files again from subspace and
note the commit here.
