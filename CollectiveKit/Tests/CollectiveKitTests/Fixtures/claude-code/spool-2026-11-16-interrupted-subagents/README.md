# Interrupted subagents (2026-11-16)

Hook payloads taken from a live subspace spool (`events/2026-11-16/`, session
`70fde325-d096-4cf5-83dc-209523e7884f`, pid 13215). Claude Code version: not
recorded (the status file of this pid was not kept; the sibling session in the
same capture ran 2.1.325). Window: `ts` 1794820258 (the two `Agent` calls launching
`a7cf9b083293ed775` and `af1b90fb83b036cd8`, both `workflow:implementer`) through
1794821565, plus the first `PreToolUse`+`PostToolUse` pair of each of the two
agents after the root `Stop` at 1794821557 (`af1b...` at 1794821591, `a7cf...` at
1794821593). Counted as the window: 1794820258 through 1794821593. Ordered by
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

Filter (the window is too large to keep whole). Kept: every envelope without
`payload.agent_id` (root events); of the named subagents every `SubagentStart`,
`SubagentStop` and `StopFailure` and every `PreToolUse`/`PostToolUse` with
`tool_name` `SubagentHandback`; of each run of a named subagent (from its
`SubagentStart` to its `SubagentStop`/`StopFailure`, or to the window's end) the
first and the last `PreToolUse`+`PostToolUse` pair (same `tool_use_id`) other than
`SubagentHandback`. Dropped: all other tool events and the `PostToolBatch` of the
subagents, and events of other `agent_id`s. The window had 111 envelopes, 37 are kept.

Both implementers hit the spend limit. Each gets a `StopFailure` with its
`agent_id` (`af1b...` at 1794820607, `a7cf...` at 1794820708; `error: rate_limit`).
In the same second as the `af1b...` failure a `task-notification` prompt starts a
root turn that fails too (`StopFailure` without `agent_id`, 1794820607). Later the
root resumes both with `SendMessage` (1794821551 to 1794821553), which produces a
`SubagentStart` with the same ids and no new `Agent` call, then the root `Stop` at
1794821557 whose `background_tasks` lists both as `running`.

`last_assistant_message` is only mapped for `Stop`/`SubagentStop`, not for
`StopFailure` (subspace mapping), so the `StopFailure` payloads carry no mapped
last message.

| File | Spool file |
| --- | --- |
| `events/001-PreToolUse.json` | `1794820258-13215-4b386533.json` |
| `events/002-SubagentStart.json` | `1794820258-13215-49a056c3.json` |
| `events/003-SubagentStart.json` | `1794820258-13215-ecdb1ebd.json` |
| `events/004-PostToolUse.json` | `1794820258-13215-ce5603c5.json` |
| `events/005-PostToolUse.json` | `1794820258-13215-be7a5a34.json` |
| `events/006-PostToolBatch.json` | `1794820258-13215-457eebce.json` |
| `events/007-UserPromptSubmit.json` | `1794820258-13215-f5571a29.json` |
| `events/008-Stop.json` | `1794820263-13215-5d4c87a6.json` |
| `events/009-PreToolUse.json` | `1794820265-13215-da5655bf.json` |
| `events/010-PreToolUse.json` | `1794820265-13215-96d68c75.json` |
| `events/011-PostToolUse.json` | `1794820266-13215-d845d19c.json` |
| `events/012-PostToolUse.json` | `1794820266-13215-207232e3.json` |
| `events/013-PreToolUse.json` | `1794820606-13215-d362a113.json` |
| `events/014-PostToolUse.json` | `1794820607-13215-c9a0acee.json` |
| `events/015-StopFailure.json` | `1794820607-13215-997b565c.json` |
| `events/016-UserPromptSubmit.json` | `1794820607-13215-6857595a.json` |
| `events/017-StopFailure.json` | `1794820607-13215-e0dd239e.json` |
| `events/018-PreToolUse.json` | `1794820707-13215-58480ec2.json` |
| `events/019-PostToolUse.json` | `1794820707-13215-54170a8f.json` |
| `events/020-StopFailure.json` | `1794820708-13215-059f72aa.json` |
| `events/021-Notification.json` | `1794820768-13215-f6ad2235.json` |
| `events/022-UserPromptSubmit.json` | `1794821539-13215-a0454638.json` |
| `events/023-PreToolUse.json` | `1794821547-13215-7e63cc10.json` |
| `events/024-PostToolUse.json` | `1794821547-13215-62724336.json` |
| `events/025-PostToolBatch.json` | `1794821547-13215-5038c1c5.json` |
| `events/026-PreToolUse.json` | `1794821551-13215-e6669670.json` |
| `events/027-SubagentStart.json` | `1794821553-13215-b044d3da.json` |
| `events/028-PostToolUse.json` | `1794821553-13215-2990554a.json` |
| `events/029-PreToolUse.json` | `1794821553-13215-55451be4.json` |
| `events/030-SubagentStart.json` | `1794821553-13215-3038c78b.json` |
| `events/031-PostToolUse.json` | `1794821553-13215-140e2bcc.json` |
| `events/032-PostToolBatch.json` | `1794821553-13215-70a09d48.json` |
| `events/033-Stop.json` | `1794821557-13215-d83913be.json` |
| `events/034-PreToolUse.json` | `1794821591-13215-245690f5.json` |
| `events/035-PostToolUse.json` | `1794821591-13215-24f610fb.json` |
| `events/036-PreToolUse.json` | `1794821593-13215-eb4881df.json` |
| `events/037-PostToolUse.json` | `1794821593-13215-e0dcdd03.json` |
