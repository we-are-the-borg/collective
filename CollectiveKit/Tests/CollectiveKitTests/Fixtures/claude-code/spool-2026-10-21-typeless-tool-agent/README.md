# Typeless tool-only agents (2026-10-21)

Hook payloads taken from a live subspace spool (`events/2026-10-21/`, session
`800dce8e-418e-472b-8f66-8b9d20541cdf`, pid 47156): every event of that session
from the root `PreToolUse` (`Agent`) at 1792564848 through the first root `Stop`
after the `SubagentStop` of `a4e7313b0f002387e` (1792565649). Ordered by envelope
`ts`, then by file mtime. The Claude Code version is unknown.

Only the `payload` object of each envelope is kept; the tests wrap them. The
payloads are anonymized: the home is `/Users/user`, the project
`/Users/user/dev/project` (also in Claude Code's encoded project names),
free text (prompts, replies, tool input and output) is placeholder words of the
same length in the same places, with whitespace, punctuation and line breaks kept
(typographic quotes straightened), and agent descriptions are hand-written
neutral titles. Ids, times, models, agent types, tool names and the structure
are as captured; Claude Code's own fixed texts (hand-back frames, launch notes,
notification messages) are kept.

`subagents/` holds the `meta.json` files of the three real subagents as Claude
Code wrote them next to the transcript, anonymized the same way.

Two Claude Code internal agents send a tool call and nothing else: no
`SubagentStart`, no `agent_type`, no `PostToolUse`, no `SubagentStop`, no
transcript or `meta.json`.

- `a5cdc00045d1bf391`: `PreToolUse` (Bash) and `PostToolBatch` (`053`, `054`), the
  same command in the same second as a call of `a04fa4778180bb7b5`.
- `adc6a0620e0106fb7`: `PreToolUse` (`SubagentHandback`) and `PostToolBatch` (`155`,
  `156`).

They must stay invisible and never count as working. Around them: two real
`implementer` subagents with typed tool hooks, `a04fa4778180bb7b5`
(`002-SubagentStart` … `119-SubagentStop`) and `a4e7313b0f002387e`
(`121-SubagentStart` … `226-SubagentStop`); a third, `adf12bbce1aab5633`, starts
at `228` and still works at the final root `Stop`. Also in the window: the
typeless `SubagentStop`s of many other internal agents (e.g. `a41e84ec95155bbb6`),
and the root's prompts, tools and `Stop`s (the implementers ran in the background).

| File | Spool file |
| --- | --- |
| `events/001-PreToolUse.json` | `1792564848-47156-fed12689.json` |
| `events/002-SubagentStart.json` | `1792564849-47156-8d404d6f.json` |
| `events/003-PostToolUse.json` | `1792564849-47156-0768ac6f.json` |
| `events/004-PostToolBatch.json` | `1792564849-47156-7c437919.json` |
| `events/005-PreToolUse.json` | `1792564851-47156-9964543a.json` |
| `events/006-Stop.json` | `1792564852-47156-2be69352.json` |
| `events/007-PreToolUse.json` | `1792564853-47156-42ec953c.json` |
| `events/008-PostToolUse.json` | `1792564853-47156-fcec6fbf.json` |
| `events/009-PostToolUse.json` | `1792564853-47156-eb1c0914.json` |
| `events/010-PostToolBatch.json` | `1792564853-47156-b80be2d5.json` |
| `events/011-SubagentStop.json` | `1792564854-47156-aab410aa.json` |
| `events/012-PreToolUse.json` | `1792564863-47156-ae0497a8.json` |
| `events/013-UserPromptSubmit.json` | `1792564863-47156-6937c88b.json` |
| `events/014-PostToolUse.json` | `1792564863-47156-5ba828e4.json` |
| `events/015-PostToolBatch.json` | `1792564863-47156-4bd1c4ff.json` |
| `events/016-PreToolUse.json` | `1792564868-47156-1334d131.json` |
| `events/017-PostToolUse.json` | `1792564868-47156-d0e9cc95.json` |
| `events/018-PostToolBatch.json` | `1792564868-47156-468a8e65.json` |
| `events/019-PreToolUse.json` | `1792564870-47156-826c9742.json` |
| `events/020-PostToolUse.json` | `1792564870-47156-8bc8032c.json` |
| `events/021-PostToolBatch.json` | `1792564870-47156-ac1ce441.json` |
| `events/022-PreToolUse.json` | `1792564872-47156-fa684663.json` |
| `events/023-PostToolUse.json` | `1792564873-47156-f5fe8030.json` |
| `events/024-PostToolBatch.json` | `1792564873-47156-ef53b2bf.json` |
| `events/025-PreToolUse.json` | `1792564876-47156-b891d07c.json` |
| `events/026-PostToolUse.json` | `1792564877-47156-515b2468.json` |
| `events/027-PostToolBatch.json` | `1792564877-47156-9ed4f6f4.json` |
| `events/028-PreToolUse.json` | `1792564878-47156-7fc02a06.json` |
| `events/029-PostToolUse.json` | `1792564879-47156-b66adf73.json` |
| `events/030-PostToolBatch.json` | `1792564879-47156-62f0bc52.json` |
| `events/031-UserPromptSubmit.json` | `1792564881-47156-a9a01235.json` |
| `events/032-SubagentStop.json` | `1792564881-47156-23bd1029.json` |
| `events/033-PreToolUse.json` | `1792564884-47156-46580aaa.json` |
| `events/034-PostToolUse.json` | `1792564884-47156-3d697187.json` |
| `events/035-PostToolBatch.json` | `1792564884-47156-7161ba8e.json` |
| `events/036-PreToolUse.json` | `1792564888-47156-3ebfa66b.json` |
| `events/037-PostToolUse.json` | `1792564888-47156-e3bc73cd.json` |
| `events/038-PostToolBatch.json` | `1792564888-47156-b5320778.json` |
| `events/039-Stop.json` | `1792564890-47156-d410c344.json` |
| `events/040-PreToolUse.json` | `1792564895-47156-a4c30ecf.json` |
| `events/041-PostToolUseFailure.json` | `1792564898-47156-1ffea73c.json` |
| `events/042-PostToolBatch.json` | `1792564898-47156-5093007e.json` |
| `events/043-PreToolUse.json` | `1792564903-47156-b3e8055a.json` |
| `events/044-Stop.json` | `1792564903-47156-aef28803.json` |
| `events/045-PostToolUse.json` | `1792564903-47156-8f05d2f3.json` |
| `events/046-PostToolBatch.json` | `1792564904-47156-6505d56c.json` |
| `events/047-PreToolUse.json` | `1792564909-47156-b2b5b496.json` |
| `events/048-PostToolUse.json` | `1792564909-47156-fe773bd7.json` |
| `events/049-PostToolBatch.json` | `1792564910-47156-76421a8d.json` |
| `events/050-PreToolUse.json` | `1792564915-47156-165a2814.json` |
| `events/051-PostToolUse.json` | `1792564915-47156-ab76a302.json` |
| `events/052-PostToolBatch.json` | `1792564915-47156-0fe0affe.json` |
| `events/053-PreToolUse.json` | `1792564915-47156-2d2cc274.json` |
| `events/054-PostToolBatch.json` | `1792564916-47156-7b407703.json` |
| `events/055-PreToolUse.json` | `1792564930-47156-470aaadc.json` |
| `events/056-PostToolUse.json` | `1792564941-47156-66c3c728.json` |
| `events/057-PostToolBatch.json` | `1792564941-47156-49953311.json` |
| `events/058-UserPromptSubmit.json` | `1792564943-47156-93254f71.json` |
| `events/059-PreToolUse.json` | `1792564946-47156-a3b71325.json` |
| `events/060-PreToolUse.json` | `1792564947-47156-4d68f6bc.json` |
| `events/061-PostToolUse.json` | `1792564947-47156-fed33a2a.json` |
| `events/062-PostToolBatch.json` | `1792564948-47156-51b8b5b7.json` |
| `events/063-SubagentStop.json` | `1792564948-47156-205f98d5.json` |
| `events/064-PreToolUse.json` | `1792564949-47156-ffc70b76.json` |
| `events/065-PostToolUse.json` | `1792564950-47156-a9d95d0b.json` |
| `events/066-PostToolBatch.json` | `1792564950-47156-3f0a4da9.json` |
| `events/067-PreToolUse.json` | `1792564966-47156-8c79fd4a.json` |
| `events/068-PostToolUse.json` | `1792564968-47156-f2083e39.json` |
| `events/069-PostToolBatch.json` | `1792564968-47156-18cbc616.json` |
| `events/070-PostToolUse.json` | `1792564970-47156-d310f553.json` |
| `events/071-PostToolBatch.json` | `1792564970-47156-9058e7de.json` |
| `events/072-Stop.json` | `1792564973-47156-38cdd477.json` |
| `events/073-PreToolUse.json` | `1792564974-47156-331fa338.json` |
| `events/074-PostToolUse.json` | `1792564975-47156-c3e2a54e.json` |
| `events/075-PreToolUse.json` | `1792564975-47156-9c794579.json` |
| `events/076-SubagentStop.json` | `1792564980-47156-6f066a5b.json` |
| `events/077-PostToolUse.json` | `1792564981-47156-62b4ac91.json` |
| `events/078-PostToolBatch.json` | `1792564981-47156-eb9c11e7.json` |
| `events/079-PreToolUse.json` | `1792564988-47156-ee87d465.json` |
| `events/080-PostToolUse.json` | `1792564989-47156-ea849cec.json` |
| `events/081-PostToolBatch.json` | `1792564989-47156-0cd40bfa.json` |
| `events/082-UserPromptSubmit.json` | `1792564989-47156-f89fd9b3.json` |
| `events/083-PreToolUse.json` | `1792564991-47156-4eb2f35a.json` |
| `events/084-PostToolUse.json` | `1792564992-47156-47d88e10.json` |
| `events/085-PreToolUse.json` | `1792564992-47156-6248d273.json` |
| `events/086-PostToolBatch.json` | `1792564992-47156-c2f70400.json` |
| `events/087-PostToolUse.json` | `1792564994-47156-a6a62a98.json` |
| `events/088-PostToolBatch.json` | `1792564994-47156-0d463927.json` |
| `events/089-Stop.json` | `1792565002-47156-e49294be.json` |
| `events/090-PreToolUse.json` | `1792565003-47156-01aee782.json` |
| `events/091-PostToolUse.json` | `1792565003-47156-170492bb.json` |
| `events/092-PostToolBatch.json` | `1792565003-47156-6636eb3c.json` |
| `events/093-SubagentStop.json` | `1792565003-47156-4ba161fe.json` |
| `events/094-PreToolUse.json` | `1792565008-47156-c7660646.json` |
| `events/095-SubagentStop.json` | `1792565011-47156-590dec33.json` |
| `events/096-PostToolUse.json` | `1792565027-47156-6be82530.json` |
| `events/097-PostToolBatch.json` | `1792565027-47156-31de7465.json` |
| `events/098-PreToolUse.json` | `1792565031-47156-1fd6d306.json` |
| `events/099-PostToolUse.json` | `1792565036-47156-91d1aa69.json` |
| `events/100-PostToolBatch.json` | `1792565036-47156-b3cdc5e5.json` |
| `events/101-PreToolUse.json` | `1792565039-47156-69b2fcca.json` |
| `events/102-PostToolUse.json` | `1792565040-47156-6085a601.json` |
| `events/103-PostToolBatch.json` | `1792565040-47156-877a2bf5.json` |
| `events/104-SubagentStop.json` | `1792565042-47156-c03dd702.json` |
| `events/105-PreToolUse.json` | `1792565046-47156-90d563aa.json` |
| `events/106-PostToolUse.json` | `1792565054-47156-96f4c662.json` |
| `events/107-PostToolBatch.json` | `1792565054-47156-99b7d63c.json` |
| `events/108-PreToolUse.json` | `1792565059-47156-a982237e.json` |
| `events/109-PostToolUse.json` | `1792565069-47156-612f2ca5.json` |
| `events/110-PostToolBatch.json` | `1792565069-47156-e0695e5f.json` |
| `events/111-PreToolUse.json` | `1792565072-47156-d782dc45.json` |
| `events/112-SubagentStop.json` | `1792565073-47156-b2b53b44.json` |
| `events/113-PostToolUse.json` | `1792565081-47156-65182d4f.json` |
| `events/114-PostToolBatch.json` | `1792565081-47156-9b15d9e2.json` |
| `events/115-PreToolUse.json` | `1792565096-47156-ee06b143.json` |
| `events/116-PostToolUse.json` | `1792565096-47156-641e4100.json` |
| `events/117-UserPromptSubmit.json` | `1792565096-47156-ed9820d8.json` |
| `events/118-PostToolBatch.json` | `1792565096-47156-5d300e97.json` |
| `events/119-SubagentStop.json` | `1792565096-47156-3e0c2129.json` |
| `events/120-PreToolUse.json` | `1792565116-47156-aca0fda0.json` |
| `events/121-SubagentStart.json` | `1792565116-47156-6c3e65ec.json` |
| `events/122-PostToolUse.json` | `1792565116-47156-581a9d31.json` |
| `events/123-PostToolBatch.json` | `1792565116-47156-9ca62cb8.json` |
| `events/124-PreToolUse.json` | `1792565119-47156-4b5df6d1.json` |
| `events/125-Stop.json` | `1792565121-47156-49e1cf4d.json` |
| `events/126-PostToolUse.json` | `1792565122-47156-90903555.json` |
| `events/127-PreToolUse.json` | `1792565122-47156-55a15c33.json` |
| `events/128-PreToolUse.json` | `1792565122-47156-78192cd5.json` |
| `events/129-PostToolUse.json` | `1792565122-47156-087a5bcd.json` |
| `events/130-PostToolUse.json` | `1792565122-47156-4472d878.json` |
| `events/131-PostToolBatch.json` | `1792565122-47156-0e53f861.json` |
| `events/132-PreToolUse.json` | `1792565123-47156-71331e97.json` |
| `events/133-PostToolUse.json` | `1792565124-47156-eaf00ffd.json` |
| `events/134-PostToolBatch.json` | `1792565124-47156-9bf2d2e4.json` |
| `events/135-PreToolUse.json` | `1792565126-47156-98417090.json` |
| `events/136-PostToolUse.json` | `1792565126-47156-af636c9d.json` |
| `events/137-PostToolBatch.json` | `1792565126-47156-1c86afee.json` |
| `events/138-PreToolUse.json` | `1792565129-47156-87d7e7b5.json` |
| `events/139-PostToolUse.json` | `1792565129-47156-9e31a674.json` |
| `events/140-PostToolBatch.json` | `1792565129-47156-18f2bc9f.json` |
| `events/141-SubagentStop.json` | `1792565147-47156-3aa3c6dc.json` |
| `events/142-PreToolUse.json` | `1792565162-47156-d33822a9.json` |
| `events/143-PostToolUse.json` | `1792565162-47156-8c92ce2b.json` |
| `events/144-PostToolBatch.json` | `1792565162-47156-42645aba.json` |
| `events/145-PreToolUse.json` | `1792565164-47156-91ba1125.json` |
| `events/146-PostToolUse.json` | `1792565164-47156-33e144b2.json` |
| `events/147-PostToolBatch.json` | `1792565165-47156-196509c7.json` |
| `events/148-SubagentStop.json` | `1792565179-47156-57e0aa73.json` |
| `events/149-PreToolUse.json` | `1792565180-47156-560fd074.json` |
| `events/150-PostToolUse.json` | `1792565180-47156-58a2113b.json` |
| `events/151-PostToolBatch.json` | `1792565180-47156-0babfd17.json` |
| `events/152-PreToolUse.json` | `1792565182-47156-78fb9125.json` |
| `events/153-PostToolUse.json` | `1792565183-47156-3eaadc07.json` |
| `events/154-PostToolBatch.json` | `1792565183-47156-698aff9d.json` |
| `events/155-PreToolUse.json` | `1792565210-47156-17d4a8ea.json` |
| `events/156-PostToolBatch.json` | `1792565210-47156-44784b9b.json` |
| `events/157-PreToolUse.json` | `1792565279-47156-52af8cc5.json` |
| `events/158-PostToolUse.json` | `1792565279-47156-ab19a145.json` |
| `events/159-PostToolBatch.json` | `1792565279-47156-ce43586b.json` |
| `events/160-PreToolUse.json` | `1792565281-47156-dee718b3.json` |
| `events/161-PostToolUse.json` | `1792565281-47156-aad423e3.json` |
| `events/162-PostToolBatch.json` | `1792565281-47156-d249f87c.json` |
| `events/163-PreToolUse.json` | `1792565284-47156-39390f98.json` |
| `events/164-PostToolUse.json` | `1792565284-47156-3301fdf2.json` |
| `events/165-PostToolBatch.json` | `1792565284-47156-ce47a038.json` |
| `events/166-PreToolUse.json` | `1792565286-47156-0cc57013.json` |
| `events/167-PostToolUse.json` | `1792565286-47156-b23eca8c.json` |
| `events/168-PostToolBatch.json` | `1792565286-47156-3d92d095.json` |
| `events/169-PreToolUse.json` | `1792565293-47156-98776c63.json` |
| `events/170-PostToolUse.json` | `1792565297-47156-e0908986.json` |
| `events/171-PostToolBatch.json` | `1792565297-47156-d8f501a6.json` |
| `events/172-PreToolUse.json` | `1792565300-47156-98a6e495.json` |
| `events/173-PostToolUse.json` | `1792565301-47156-e35154bc.json` |
| `events/174-PostToolBatch.json` | `1792565301-47156-6eed1ccf.json` |
| `events/175-SubagentStop.json` | `1792565301-47156-e0c2eb75.json` |
| `events/176-PreToolUse.json` | `1792565303-47156-606a3f63.json` |
| `events/177-PostToolUse.json` | `1792565303-47156-e50e0cf2.json` |
| `events/178-PreToolUse.json` | `1792565304-47156-3631d44f.json` |
| `events/179-PostToolUse.json` | `1792565304-47156-041104f0.json` |
| `events/180-PostToolBatch.json` | `1792565304-47156-eb347eca.json` |
| `events/181-PreToolUse.json` | `1792565318-47156-5adc4165.json` |
| `events/182-PostToolUse.json` | `1792565318-47156-9867dfd1.json` |
| `events/183-PostToolBatch.json` | `1792565318-47156-ca7486ae.json` |
| `events/184-SubagentStop.json` | `1792565335-47156-393ffc66.json` |
| `events/185-PreToolUse.json` | `1792565344-47156-e42141d0.json` |
| `events/186-PostToolUse.json` | `1792565364-47156-64d86f11.json` |
| `events/187-PostToolBatch.json` | `1792565364-47156-15326d89.json` |
| `events/188-SubagentStop.json` | `1792565366-47156-ea0fb116.json` |
| `events/189-PreToolUse.json` | `1792565380-47156-9446f703.json` |
| `events/190-PostToolUse.json` | `1792565397-47156-26991c0f.json` |
| `events/191-PostToolBatch.json` | `1792565397-47156-45d0a4a1.json` |
| `events/192-SubagentStop.json` | `1792565407-47156-f8973210.json` |
| `events/193-PreToolUse.json` | `1792565420-47156-7909f548.json` |
| `events/194-PostToolUse.json` | `1792565420-47156-3022fafe.json` |
| `events/195-PostToolBatch.json` | `1792565420-47156-17bcffa2.json` |
| `events/196-SubagentStop.json` | `1792565442-47156-ee41ebcf.json` |
| `events/197-SubagentStop.json` | `1792565480-47156-60a62e20.json` |
| `events/198-PreToolUse.json` | `1792565492-47156-147cfa5f.json` |
| `events/199-PostToolUse.json` | `1792565492-47156-cfb4c65d.json` |
| `events/200-PostToolBatch.json` | `1792565492-47156-94d6d443.json` |
| `events/201-PreToolUse.json` | `1792565497-47156-41d43f56.json` |
| `events/202-PostToolUse.json` | `1792565501-47156-ba3ef888.json` |
| `events/203-PostToolBatch.json` | `1792565501-47156-4cbb3e6c.json` |
| `events/204-SubagentStop.json` | `1792565514-47156-5fe6a2cb.json` |
| `events/205-PreToolUse.json` | `1792565520-47156-9b84b2fb.json` |
| `events/206-PostToolUse.json` | `1792565535-47156-ff8e220b.json` |
| `events/207-PostToolBatch.json` | `1792565535-47156-357cee57.json` |
| `events/208-PreToolUse.json` | `1792565543-47156-b83352e9.json` |
| `events/209-SubagentStop.json` | `1792565546-47156-745cc702.json` |
| `events/210-PostToolUse.json` | `1792565546-47156-d649a33f.json` |
| `events/211-PostToolBatch.json` | `1792565546-47156-0ffb5585.json` |
| `events/212-PreToolUse.json` | `1792565553-47156-b75c9bfe.json` |
| `events/213-PostToolUse.json` | `1792565553-47156-1dde19dc.json` |
| `events/214-PostToolBatch.json` | `1792565553-47156-9f9789ef.json` |
| `events/215-PreToolUse.json` | `1792565562-47156-507625d7.json` |
| `events/216-PostToolUse.json` | `1792565579-47156-6595dc8e.json` |
| `events/217-PostToolBatch.json` | `1792565580-47156-5da43041.json` |
| `events/218-SubagentStop.json` | `1792565582-47156-cec52b45.json` |
| `events/219-PreToolUse.json` | `1792565586-47156-bbcebbc9.json` |
| `events/220-PostToolUse.json` | `1792565589-47156-8739d435.json` |
| `events/221-PostToolBatch.json` | `1792565589-47156-1eef5ced.json` |
| `events/222-PreToolUse.json` | `1792565611-47156-07300aff.json` |
| `events/223-PostToolUse.json` | `1792565612-47156-082a9586.json` |
| `events/224-UserPromptSubmit.json` | `1792565612-47156-9b10d893.json` |
| `events/225-PostToolBatch.json` | `1792565612-47156-fe065854.json` |
| `events/226-SubagentStop.json` | `1792565612-47156-1d727917.json` |
| `events/227-PreToolUse.json` | `1792565645-47156-ee6120a3.json` |
| `events/228-SubagentStart.json` | `1792565645-47156-c08ee635.json` |
| `events/229-PostToolUse.json` | `1792565645-47156-799c7845.json` |
| `events/230-PostToolBatch.json` | `1792565645-47156-feb13a57.json` |
| `events/231-PreToolUse.json` | `1792565648-47156-9b38b655.json` |
| `events/232-PostToolUse.json` | `1792565648-47156-dc3f0f84.json` |
| `events/233-PostToolBatch.json` | `1792565648-47156-309649ad.json` |
| `events/234-Stop.json` | `1792565649-47156-ae6d455d.json` |
