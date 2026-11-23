# Internal agent with a tool call (2026-10-03)

Hook payloads taken from a live subspace spool (`events/2026-10-03/`, session
`6d89e664-694c-4aa5-bd27-0530ccdc5231`). The Claude Code version is unknown.

| File | Spool file |
| --- | --- |
| `events/001-PreToolUse.json` | `1791017103-70960-4939e8cd.json` |
| `events/002-PostToolBatch.json` | `1791017103-70960-f298f080.json` |
| `events/003-SubagentStop.json` | `1791017105-70960-31f5cb49.json` |

Only the `payload` object of each envelope is kept; the tests wrap them. The
payloads are anonymized: the home is `/Users/user`, the project
`/Users/user/dev/project` (also in Claude Code's encoded project names),
free text (prompts, replies, tool input and output) is placeholder words of the
same length in the same places, with whitespace, punctuation and line breaks kept
(typographic quotes straightened), and agent descriptions are hand-written
neutral titles. Ids, times, models, agent types, tool names and the structure
are as captured; Claude Code's own fixed texts (hand-back frames, launch notes,
notification messages) are kept.

An internal Claude Code agent (no `SubagentStart`, no `agent_type`) runs a tool
and then stops with `agent_type: ""`. It never identifies itself, so it stays
invisible: neither its tool nor its stop shows anything.
