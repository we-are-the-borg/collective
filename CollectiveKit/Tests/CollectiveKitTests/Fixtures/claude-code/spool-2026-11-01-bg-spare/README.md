# Unclaimed `claude bg-spare` process (2026-11-01)

Hook payloads taken from a live subspace spool (`events/2026-11-01/`, session
`92f09628-0235-4c9c-b054-9e7a01a56f32`, Claude Code 2.1.316, pid 31141): every
event of that session and of that pid, all in the second 1793535434. Ordered by
envelope `ts`, then by file mtime.

Only the `payload` object of each envelope is kept; the tests wrap them. The
payloads are anonymized: the home is `/Users/user`, the project
`/Users/user/dev/project` (also in Claude Code's encoded project names),
free text (prompts, replies, tool input and output) is placeholder words of the
same length in the same places, with whitespace, punctuation and line breaks kept
(typographic quotes straightened), and agent descriptions are hand-written
neutral titles. Ids, times, models, agent types, tool names and the structure
are as captured; Claude Code's own fixed texts (hand-back frames, launch notes,
notification messages) are kept.

Claude Code's background daemon keeps pre-warmed `claude bg-spare` processes
ready for its next job. Such a process already runs a session of its own: a
`SessionStart` (`source: startup`, with `model`) and two `InstructionsLoaded`,
then nothing until a job claims it. The payloads carry no spare marker, so on
their own they look like a session waiting for the user.

Only its status file `<config>/sessions/31141.json` tells it apart (`spare: true`,
`kind: bg`, `jobId` and `name` equal to the short session id, `status: idle`;
subspace contract §13, "Spare processes"). That file was **not captured**; the tests
derive it from a captured 2.1.287 status file. No claim was captured either.

| File | Spool file |
| --- | --- |
| `events/001-SessionStart.json` | `1793535434-31141-635db7e8.json` |
| `events/002-InstructionsLoaded.json` | `1793535434-31141-50c2abe4.json` |
| `events/003-InstructionsLoaded.json` | `1793535434-31141-9c24e9a4.json` |
