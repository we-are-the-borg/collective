#if DEBUG
import CollectiveKit
import Foundation
import SubspaceKit

/// Sample sessions for previews, modeled on the design mock. They go through
/// the real reducer and `PopoverModel`, so previews show what the app shows.
enum PreviewData {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let source: SourceID = "claude-code"
    static let codexSource: SourceID = "codex"
    /// The tools previews show, so views need not import `SubspaceKit` for a `SourceID`.
    enum Tool {
        case claudeCode, codex
        /// One without an adapter: shows its raw id.
        case other

        var source: SourceID {
            switch self {
            case .claudeCode: PreviewData.source
            case .codex: PreviewData.codexSource
            case .other: "other-tool"
            }
        }
    }
    static let sourceIDs = [source, codexSource]
    static let sourceNames: [SourceID: String] = [source: "Claude Code", codexSource: "Codex"]
    /// As the adapters name them; "other-tool" has none and shows its raw id.
    static let sourceLogos: [SourceID: String] = [source: "claude-code", codexSource: "codex"]

    private static func key(_ id: String) -> SessionKey { SessionKey(source: source, sessionID: id) }

    private static func events(
        _ id: String, source: SourceID = source, _ steps: [(ago: TimeInterval, kind: AgentEvent.Kind)]
    ) -> [AgentEvent] {
        steps.map {
            AgentEvent(session: SessionKey(source: source, sessionID: id), timestamp: now.addingTimeInterval(-$0.ago), kind: $0.kind)
        }
    }

    private static func spawn(
        _ id: String, parent: AgentRef = .root, type: String? = "general-purpose",
        title: String?, prompt: String? = nil, background: Bool? = nil, alias: String? = nil, modelID: String? = nil
    ) -> AgentEvent.Kind {
        .agentSpawned(id: id, parent: parent, spec: AgentSpec(
            type: type, title: title, prompt: prompt, modelAlias: alias, modelID: modelID, isBackground: background
        ))
    }

    /// The old previews show their sessions on top; the idle group has its own scenarios.
    static let noIdle = PopoverSettings(idleAfter: .never)

    static let longPrompt = "Replace every hard-coded color in the renderer with the theme tokens. Keep the snapshot tests green, do not touch the asset catalog, and report which files changed when you are done."

    /// Working orchestrator waiting on foreground subagents, nested three deep.
    static let abnahme: [AgentEvent] = events("abnahme", [
        (840, .sessionStarted(cwd: "/Users/user/Developer/abnahme", pid: 100)),
        (839, .promptSubmitted(longPrompt)),
        (300, spawn("a", title: "D: Apply theme in renderer", prompt: "Apply the theme tokens in the renderer module.")),
        (290, .toolStarted(agent: .subagent("a"), ToolActivity(name: "Edit", detail: "Sources/Renderer/ThemeApplier.swift"))),
        (200, spawn("b", parent: .subagent("a"), type: "Explore", title: "Find all hard-coded colors", prompt: "Search the renderer for literal color values.")),
        (190, .toolStarted(agent: .subagent("b"), ToolActivity(name: "Grep", detail: "#[0-9a-f]{6}"))),
        (150, spawn("c", parent: .subagent("b"), type: "Explore", title: "Check asset catalog usage")),
        (140, .toolStarted(agent: .subagent("c"), ToolActivity(name: "Read", detail: "Assets.xcassets/Contents.json"))),
        (120, spawn("d", parent: .subagent("b"), type: "Explore", title: "List theme token names")),
        (60, .agentFinished(id: "d")),
        (100, spawn("e", parent: .subagent("a"), type: "general-purpose", title: nil)),
        (80, spawn("f", type: "general-purpose", title: "Update snapshot tests", background: true)),
        (70, .toolStarted(agent: .subagent("f"), ToolActivity(name: "Bash", detail: "swift test --filter Snapshot"))),
        (260, spawn("g", type: "Explore", title: "Audit entitlements")),
        (30, .agentFinished(id: "g")),
    ])

    /// Working orchestrator with its own tool and no subagents.
    static let contractTests: [AgentEvent] = events("contract-tests", [
        (240, .sessionStarted(cwd: "/Users/user/Developer/subspace-contract", pid: 101)),
        (239, .promptSubmitted("Run the contract tests and fix whatever fails.")),
        (5, .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "swift test --filter SpoolReaderTests"))),
    ])

    /// Turn finished while two background subagents keep running.
    static let subspace: [AgentEvent] = events("subspace", [
        (1_500, .sessionStarted(cwd: "/Users/user/Developer/subspace", pid: 102)),
        (1_499, .promptSubmitted("Sync the nightly fixtures and refresh the mapping documents.")),
        (400, spawn("n1", type: "general-purpose", title: "Run nightly fixtures sync", background: true)),
        (390, spawn("n2", type: "Explore", title: "Diff mapping documents", background: true)),
        (380, .toolStarted(agent: .subagent("n2"), ToolActivity(name: "Bash", detail: "diff -r model/ bundled/"))),
        (300, .turnEnded()),
    ])

    /// Ended cleanly two minutes ago.
    static let docsSite: [AgentEvent] = events("docs-site", [
        (600, .sessionStarted(cwd: "/Users/user/Developer/docs-site", pid: 103)),
        (599, .promptSubmitted("Fix the broken anchor links in the contract chapter.\nThen rebuild the site.")),
        (120, .sessionEnded),
    ])

    /// Lost contact: its process vanished with a subagent still running.
    static let oldExperiment: [AgentEvent] = events("old-experiment", [
        (900, .sessionStarted(cwd: "/Users/user/Developer/old-experiment", pid: 104)),
        (899, .promptSubmitted("Prototype the sparkle animation.")),
        (800, spawn("x", type: "Explore", title: "Trace frame timings", prompt: "Measure how long each frame takes.")),
    ])

    /// A Codex session waiting for the user, so the sample mixes tools.
    static let codexReview: [AgentEvent] = events("codex-review", source: codexSource, [
        (1_800, .sessionStarted(cwd: "/Users/user/Developer/subspace", pid: nil)),
        (1_799, .promptSubmitted("Review the mapping change and say what breaks.")),
        (1_798, .modelChanged(to: "gpt-5-codex", from: nil)),
        (200, .turnEnded()),
    ])

    /// A source no adapter is registered for: neutral card, raw name.
    static let unknownTool: [AgentEvent] = events("mystery", source: "other-tool", [
        (300, .sessionStarted(cwd: "/Users/user/Developer/scratch", pid: nil)),
        (299, .promptSubmitted("Tidy the scratch folder.")),
        (10, .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "ls -la"))),
    ])

    static let state: CollectiveState = {
        var state = CollectiveState()
        let all = abnahme + contractTests + subspace + docsSite + oldExperiment + codexReview + unknownTool
        for event in all.sorted(by: { $0.timestamp < $1.timestamp }) { state.apply(event) }
        state.markStale(now: now.addingTimeInterval(-360), silenceTimeout: 0, waitingTimeout: 0) { pid in
            pid == 104 ? nil : now.addingTimeInterval(-86_400)
        }
        return state
    }()

    private static let modelNaming: [SourceID: any ModelNaming] = ["claude-code": ClaudeCodeModelNaming()]

    static func model() -> PopoverModel {
        PopoverModel(
            state: state,
            now: now,
            settings: PreviewData.noIdle,
            sourceNames: sourceNames,
            sourceLogos: sourceLogos,
            modelNaming: modelNaming,
            lastEventAt: now.addingTimeInterval(-2)
        )
    }

    static let popover = model()

    private static func session(_ id: String, in model: PopoverModel) -> SessionItem {
        (model.sessions + model.finished).first { $0.key == key(id) }!
    }

    static func item(_ id: String) -> SessionItem {
        session(id, in: model())
    }

    /// A card of another tool than Claude Code: Codex, or one without an adapter.
    static var otherToolItem: SessionItem { model().sessions.first { $0.key.source == codexSource }! }
    static var unknownItem: SessionItem { model().sessions.first { $0.key.source == "other-tool" }! }

    static var finishedDone: SessionItem { item("docs-site") }
    static var finishedStale: SessionItem { item("old-experiment") }

    /// A cleanly ended session of its own, to preview the finished row with any
    /// prompt (nil: the session never got one).
    /// - Parameter doneSubagents: Subagents that finished before the session did ("✓ n").
    static func finishedItem(_ id: String, prompt: String?, doneSubagents: Int = 0) -> SessionItem {
        var steps: [(ago: TimeInterval, kind: AgentEvent.Kind)] = [(600, .sessionStarted(cwd: "/Users/user/Developer/\(id)", pid: nil))]
        if let prompt { steps.append((599, .promptSubmitted(prompt))) }
        for index in 0..<doneSubagents {
            steps.append((500 - TimeInterval(index), spawn("s\(index)", title: "Subagent \(index + 1)")))
            steps.append((300 - TimeInterval(index), .agentFinished(id: "s\(index)")))
        }
        steps.append((120, .sessionEnded))
        var state = CollectiveState()
        for event in events(id, steps) { state.apply(event) }
        let model = PopoverModel(
            state: state,
            now: now,
            settings: PreviewData.noIdle,
            sourceNames: sourceNames,
            sourceLogos: sourceLogos,
            modelNaming: modelNaming,
            lastEventAt: now.addingTimeInterval(-2)
        )
        return model.finished.first { $0.key == key(id) }!
    }

    /// A session with `done` finished and `running` working subagents on one
    /// level; `waiting` ends the orchestrator's turn, `needYou` more ask for
    /// permission, `open` opens the subagent list as "✓ n" or the knob would.
    static func crowded(done: Int, running: Int, needYou: Int = 0, waiting: Bool = false, open: Bool = false) -> SessionItem {
        let id = "crowded-\(done)-\(running)-\(needYou)\(waiting ? "-waiting" : "")"
        var steps: [(ago: TimeInterval, kind: AgentEvent.Kind)] = [
            (3_000, .sessionStarted(cwd: "/Users/user/Developer/\(id)", pid: 105)),
            (2_999, .promptSubmitted("Work through the ticket list.")),
        ]
        for index in 0..<(done + running) {
            steps.append((2_900 - TimeInterval(index), spawn("s\(index)", title: "Subagent \(index + 1)")))
        }
        for index in 0..<done { steps.append((1_000 - TimeInterval(index), .agentFinished(id: "s\(index)"))) }
        let remove = ToolActivity(name: "Bash", detail: "rm -rf .build")
        for index in 0..<needYou {
            let agent = "n\(index)"
            steps.append((2_800 - TimeInterval(index), spawn(agent, title: "Clean up \(index + 1)")))
            steps.append((60 - TimeInterval(index), .toolStarted(agent: .subagent(agent), remove)))
            steps.append((59 - TimeInterval(index), .permissionRequested(agent: .subagent(agent), remove)))
        }
        if waiting { steps.append((500, .turnEnded())) }
        var expansion = PopoverExpansion()
        if open { expansion.toggleSubagents(key(id), isOpen: false) }
        let model = PopoverModel(
            state: state(from: events(id, steps)),
            now: now,
            settings: PreviewData.noIdle,
            sourceNames: sourceNames,
            sourceLogos: sourceLogos,
            modelNaming: modelNaming,
            lastEventAt: now.addingTimeInterval(-2),
            expansion: expansion
        )
        return session(id, in: model)
    }

    /// Turn ended while `count` background subagents work.
    static func backgroundWorking(count: Int) -> SessionItem {
        let id = "background-\(count)"
        var steps: [(ago: TimeInterval, kind: AgentEvent.Kind)] = [
            (900, .sessionStarted(cwd: "/Users/user/Developer/\(id)", pid: nil)),
            (899, .promptSubmitted("Run the nightly checks and report what they found.")),
        ]
        for index in 0..<count {
            steps.append((600 - TimeInterval(index), spawn("b\(index)", title: "Nightly check \(index + 1)", background: true)))
        }
        steps.append((300, .turnEnded()))
        let model = PopoverModel(
            state: state(from: events(id, steps)),
            now: now,
            settings: PreviewData.noIdle,
            sourceNames: sourceNames,
            sourceLogos: sourceLogos,
            modelNaming: modelNaming,
            lastEventAt: now.addingTimeInterval(-2)
        )
        return session(id, in: model)
    }

    /// A shell the agent started in the background runs. `agents` background
    /// subagents work beside it; `newTurn` starts another turn after the report;
    /// the turn end lists the first `listed` of `previewShells`.
    static func backgroundShell(agents: Int = 0, newTurn: Bool = false, listed: Int = 0) -> SessionItem {
        let id = "shell-\(agents)-\(newTurn)-\(listed)"
        var steps: [(ago: TimeInterval, kind: AgentEvent.Kind)] = [
            (900, .sessionStarted(cwd: "/Users/user/Developer/\(id)", pid: nil)),
            (899, .promptSubmitted("Start the dev server in the background and tell me when it is up.")),
        ]
        for index in 0..<agents {
            steps.append((600 - TimeInterval(index), spawn("b\(index)", title: "Nightly check \(index + 1)", background: true)))
        }
        steps.append((300, .turnEnded()))
        if listed > 0 { steps.append((300, .backgroundShellsListed(Array(previewShells.prefix(listed))))) }
        steps.append((299, .activityReported(.backgroundShell)))
        if newTurn {
            steps.append((20, .promptSubmitted("Now run the smoke tests against it.")))
            steps.append((5, .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "swift test --filter SmokeTests"))))
        }
        let model = PopoverModel(
            state: state(from: events(id, steps)),
            now: now,
            settings: PreviewData.noIdle,
            sourceNames: sourceNames,
            sourceLogos: sourceLogos,
            modelNaming: modelNaming,
            lastEventAt: now.addingTimeInterval(-2)
        )
        return session(id, in: model)
    }

    private static let previewShells = [
        BackgroundShell(id: "b1", command: "npm run dev -- --port 5173", description: "Start the dev server"),
        BackgroundShell(id: "b2", description: "Tail the server log"),
        BackgroundShell(id: "b3"),
    ]

    private static let permissionCall = ToolActivity(name: "Bash", detail: "swift build --configuration release")
    private static let permissionEvents: [AgentEvent] = events("needs-permission", [
        (500, .sessionStarted(cwd: "/Users/user/Developer/needs-permission", pid: nil)),
        (499, .promptSubmitted("Install the dependencies and run the build.")),
        (20, .toolStarted(agent: .root, permissionCall)),
        (15, .permissionRequested(agent: .root, permissionCall)),
    ])

    /// An orchestrator asking to allow a tool call.
    static var permission: SessionItem {
        let model = PopoverModel(
            state: state(from: permissionEvents),
            now: now,
            settings: PreviewData.noIdle,
            sourceNames: sourceNames,
            sourceLogos: sourceLogos,
            modelNaming: modelNaming,
            lastEventAt: now.addingTimeInterval(-2)
        )
        return session("needs-permission", in: model)
    }

    private static let questionEvents: [AgentEvent] = events("open-question", [
        (500, .sessionStarted(cwd: "/Users/user/Developer/open-question", pid: nil)),
        (499, .promptSubmitted("Update the subspace mapping to the latest revision.")),
        (20, .questionAsked(agent: .root, [
            Question(
                header: "Mapping",
                text: "Which revision of the subspace mapping should the Claude Code adapter read?",
                options: [
                    QuestionOption(label: "Revision 5", detail: "Bundled today, no new fields"),
                    QuestionOption(label: "Revision 6", detail: "Adds the question fields and the option descriptions the card now shows beneath each label"),
                    QuestionOption(label: "Revision 7, the one bundled with SubspaceKit today"),
                ],
                allowsOwnAnswer: true
            ),
            Question(header: "Tests", text: "Run the full suite afterwards?", options: [QuestionOption(label: "Yes"), QuestionOption(label: "No")], allowsOwnAnswer: true),
        ], callID: "question-1")),
    ])

    /// An orchestrator asking two questions at once: pill count 2,
    /// the first one with three options, "+1 more question".
    static var question: SessionItem {
        let model = PopoverModel(
            state: state(from: questionEvents),
            now: now,
            settings: PreviewData.noIdle,
            sourceNames: sourceNames,
            sourceLogos: sourceLogos,
            modelNaming: modelNaming,
            lastEventAt: now.addingTimeInterval(-2)
        )
        return session("open-question", in: model)
    }

    /// Every card state in one list: permission, waiting with its
    /// excerpt, working, background agents.
    static func cardStates() -> PopoverModel {
        PopoverModel(
            state: state(from: permissionEvents + questionEvents + restingSession("waiting-soon", restedAgo: 120) + contractTests + subspace),
            now: now,
            settings: PreviewData.noIdle,
            sourceNames: sourceNames,
            sourceLogos: sourceLogos,
            modelNaming: modelNaming,
            lastEventAt: now.addingTimeInterval(-2)
        )
    }

    // MARK: Subagents (1a)

    private static let subagentsSampleID = "agent-collective-1a"

    /// The design's sample: waiting with one background subagent at work,
    /// four done, one still unassigned.
    private static let subagentsSampleEvents: [AgentEvent] = events(subagentsSampleID, [
        (2_520, .sessionStarted(cwd: "/Users/user/Developer/agent-collective", pid: nil)),
        (2_519, .promptSubmitted("Start a subagent for about 30 s, then report what it did.")),
        (2_518, .modelChanged(to: opus, from: nil)),
        (600, spawn("k", type: "implementer", title: "Kit: subagents header rules", prompt: "Implement the header rules in the kit.", background: true, modelID: opus)),
        (500, spawn("u", type: "implementer", title: "UI: subagents header view", background: true, alias: "sonnet", modelID: "claude-sonnet-5-5")),
        (400, spawn("r", type: "change-reviewer", title: "Review the diff", background: true)),
        (300, spawn("c", type: "implementer", title: "Catalog comments + todo tick", background: true, alias: "sonnet", modelID: "claude-sonnet-5-5")),
        (60, .agentFinished(id: "k")),
        (50, .agentFinished(id: "u")),
        (40, .agentFinished(id: "r")),
        (35, spawn("t", title: "Test subagent, 30s wait", prompt: "Run a loop for 30 seconds and report the output.\nThen say what it printed.", background: true, alias: "haiku", modelID: "claude-haiku-4-5-20251001")),
        (30, .agentFinished(id: "c")),
        (20, .toolStarted(agent: .subagent("t"), ToolActivity(name: "Bash", detail: "for i in 1 2 3 4 5 6; do echo $i; sleep 5; done"))),
        (10, .turnEnded()),
        (1, spawn("x", type: nil, title: nil)),
    ])

    /// The design's sample session.
    static var subagentsSample: SessionItem {
        let model = PopoverModel(
            state: state(from: subagentsSampleEvents),
            now: now,
            settings: PreviewData.noIdle,
            sourceNames: sourceNames,
            sourceLogos: sourceLogos,
            modelNaming: modelNaming,
            lastEventAt: now.addingTimeInterval(-2)
        )
        return session(subagentsSampleID, in: model)
    }

    // MARK: Subagent list

    /// The states of the design for subagents listed one by one in a row.
    /// Lost contact is not among them: a
    /// subagent only loses contact with its whole session, which then
    /// finishes (`subagentLostContact`).
    enum SubagentBoard: CaseIterable {
        /// Working, one Explore agent searching.
        case a
        /// Turn over, two background agents at work, one with a child of its own.
        case b
        /// 35 subagents, 2 working, the 33 done ones folded.
        case c
        /// One asks for permission, one has a question: the list opens by itself.
        case d
        /// One still waiting for its type.
        case e
        /// Idle with four done subagents: the row's preview names them.
        case f
    }

    private static let haiku = "claude-haiku-5-5"
    private static let sonnet = "claude-sonnet-5"

    private static func subagentBoardEvents(_ board: SubagentBoard) -> (id: String, events: [AgentEvent]) {
        func session(_ id: String, start: TimeInterval, _ more: [(ago: TimeInterval, kind: AgentEvent.Kind)]) -> (String, [AgentEvent]) {
            (id, events(id, [
                (start, .sessionStarted(cwd: "/Users/user/Developer/\(id)", pid: nil)),
                (start - 1, .promptSubmitted("Find out where the reply view is used and tidy it up.")),
                (start - 2, .modelChanged(to: opus, from: nil)),
            ] + more))
        }
        switch board {
        case .a:
            return session("agent-collective", start: 240, [
                (40, spawn("e1", type: "Explore", title: "Find all uses of ReplyView", prompt: "Find every place that uses ReplyView and list them.", alias: "haiku", modelID: haiku)),
                (39, .toolStarted(agent: .root, ToolActivity(name: "Agent", detail: "Explore: find all uses of ReplyView"))),
                (5, .toolStarted(agent: .subagent("e1"), ToolActivity(name: "Grep", detail: "ReplyView"))),
            ])
        case .b:
            return session("borg-cube", start: 1_080, [
                (180, spawn("rev", type: "code-reviewer", title: "Review the store change", prompt: "Review the store change for races.", background: true, alias: "sonnet", modelID: sonnet)),
                (170, .toolStarted(agent: .subagent("rev"), ToolActivity(name: "Read", detail: "Sources/CollectiveKit/Store/CollectiveState.swift"))),
                (120, spawn("run", type: "test-runner", title: "Run the full suite", background: true, alias: "haiku", modelID: haiku)),
                (110, .toolStarted(agent: .subagent("run"), ToolActivity(name: "Bash", detail: "swift test --parallel"))),
                (100, .replied(agent: .root, "Started two reviewers in the background. I’ll report back when they finish.")),
                (99, .turnEnded()),
                (70, spawn("exp", parent: .subagent("rev"), type: "Explore", title: "Find the callers", alias: "haiku", modelID: haiku)),
                (20, .toolStarted(agent: .subagent("exp"), ToolActivity(name: "Grep", detail: "markStale"))),
                (19, .toolFinished(agent: .subagent("exp"))),
            ])
        case .c:
            var steps: [(ago: TimeInterval, kind: AgentEvent.Kind)] = []
            for index in 0..<35 {
                let ago = 4_000 - TimeInterval(index) * 100
                steps.append((ago, spawn("p\(index)", title: "Port fixture \(index + 1)", prompt: "Port spool fixture \(index + 1) to the new layout.", alias: "sonnet", modelID: sonnet)))
                if index < 33 {
                    steps.append((ago - 50, .replied(agent: .subagent("p\(index)"), "Ported fixture \(index + 1); the decoder test passes.")))
                    steps.append((ago - 50, .agentFinished(id: "p\(index)")))
                }
            }
            steps.append((60, .toolStarted(agent: .subagent("p33"), ToolActivity(name: "Write", detail: "Fixtures/claude-code/spool-34.json"))))
            steps.append((10, .toolStarted(agent: .subagent("p34"), ToolActivity(name: "Edit", detail: "Fixtures/claude-code/spool-35.json"))))
            return session("transwarp-hub", start: 4_320, steps)
        case .d:
            let remove = ToolActivity(name: "Bash", detail: "rm -rf .build")
            return session("unimatrix-zero", start: 1_320, [
                (360, spawn("mig", type: "migration-writer", title: "Write the store migration", prompt: "Write the migration for the new archive table.", alias: "opus", modelID: opus)),
                (120, spawn("exq", type: "Explore", title: "Scan the test targets", alias: "haiku", modelID: haiku)),
                (30, .toolStarted(agent: .subagent("mig"), remove)),
                (29, .permissionRequested(agent: .subagent("mig"), remove)),
                (10, .questionAsked(agent: .subagent("exq"), [
                    Question(header: "Target", text: "Which test target should I scan?", options: [QuestionOption(label: "CollectiveKitTests"), QuestionOption(label: "All")]),
                ], callID: "q-exq")),
            ])
        case .e:
            return session("tertiary-adjunct", start: 540, [
                (5, spawn("new", type: nil, title: nil)),
                (3, .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "swift build"))),
            ])
        case .f:
            var steps: [(ago: TimeInterval, kind: AgentEvent.Kind)] = []
            let models = [("sonnet", sonnet), ("haiku", haiku), ("sonnet", sonnet), ("haiku", haiku)]
            for (index, model) in models.enumerated() {
                steps.append((3_600 - TimeInterval(index) * 60, spawn("r\(index)", type: "code-reviewer", title: "Review part \(index + 1)", alias: model.0, modelID: model.1)))
                steps.append((3_300 - TimeInterval(index) * 60, .agentFinished(id: "r\(index)")))
            }
            steps.append((48 * 60 + 1, .replied(agent: .root, "Both reviewers agree; I applied the two small fixes and reran the tests.")))
            steps.append((48 * 60, .turnEnded()))
            return session("vinculum", start: 4_000, steps)
        }
    }

    /// The design state's session. Its list is open, as the design draws every
    /// state; `d` opens by itself, so it shows the rule rather than the user's choice.
    /// - Parameter opensFold: `c` with its 33 done ones unfolded, past the list's 220 pt.
    static func subagentBoard(_ board: SubagentBoard, open: Bool = true, opensFold: Bool = false) -> SessionItem {
        let (id, events) = subagentBoardEvents(board)
        var expansion = PopoverExpansion()
        if open, board != .d { expansion.toggleSubagents(key(id), isOpen: false) }
        if opensFold { expansion.toggleSubagentFold(SubagentFoldID(session: key(id), parent: .root)) }
        let model = PopoverModel(
            state: state(from: events),
            now: now,
            settings: board == .f ? PopoverSettings() : PreviewData.noIdle,
            sourceNames: sourceNames,
            sourceLogos: sourceLogos,
            modelNaming: modelNaming,
            lastEventAt: now.addingTimeInterval(-2),
            expansion: expansion
        )
        return (model.sessions + model.idle).first { $0.key == key(id) }!
    }

    /// A finished session whose process went away while its subagent worked:
    /// the one way a subagent loses contact. Its list is open.
    static var subagentLostContact: SessionItem {
        let id = "probe-gone"
        var state = state(from: events(id, [
            (600, .sessionStarted(cwd: "/Users/user/Developer/\(id)", pid: 4_242)),
            (599, .promptSubmitted("Map the spool layout.")),
            (590, spawn("scan", type: "Explore", title: "Scan the spool", alias: "haiku", modelID: haiku)),
            (300, .toolStarted(agent: .subagent("scan"), ToolActivity(name: "Read", detail: "spool/claude-code"))),
        ]))
        state.markStale(now: now.addingTimeInterval(-60), silenceTimeout: 60, waitingTimeout: 60) { _ in nil }
        var expansion = PopoverExpansion()
        expansion.toggleSubagents(key(id), isOpen: false)
        let model = PopoverModel(
            state: state, now: now, settings: PreviewData.noIdle, sourceNames: sourceNames, sourceLogos: sourceLogos, modelNaming: modelNaming,
            lastEventAt: now.addingTimeInterval(-2), expansion: expansion
        )
        return (model.sessions + model.finished).first { $0.key == key(id) }!
    }

    /// State `d` moments after the user archived its migration writer: the
    /// undo row stands in its place, the list stays open.
    static var subagentUndo: SessionItem {
        let (id, events) = subagentBoardEvents(.d)
        var state = state(from: events)
        var undo = ArchiveUndo()
        undo.archive(.subagent(key(id), .subagent("mig")), in: &state, at: now)
        let model = PopoverModel(
            state: state, now: now, settings: PreviewData.noIdle, sourceNames: sourceNames, sourceLogos: sourceLogos, modelNaming: modelNaming,
            lastEventAt: now.addingTimeInterval(-2), undo: undo
        )
        return model.sessions.first { $0.key == key(id) }!
    }

    // MARK: Archive (revision 5)

    /// The sample popover after the user archived `kind`; its undo rows are up.
    static func archived(_ kind: ArchiveUndo.Kind, in tab: PopoverTab = .active) -> PopoverModel {
        var state = Self.state
        var undo = ArchiveUndo()
        undo.archive(kind, in: &state, at: now)
        var expansion = PopoverExpansion()
        expansion.select(tab)
        return PopoverModel(
            state: state,
            now: now,
            settings: PreviewData.noIdle,
            sourceNames: sourceNames,
            sourceLogos: sourceLogos,
            modelNaming: modelNaming,
            lastEventAt: now.addingTimeInterval(-2),
            expansion: expansion,
            undo: undo
        )
    }

    /// The card of a session archived moments ago.
    static func undoItem(_ id: String) -> SessionItem {
        session(id, in: archived(.session(key(id))))
    }

    /// The finished row of a session archived moments ago.
    static func finishedUndoItem(_ id: String) -> SessionItem {
        session(id, in: archived(.finishedSession(key(id))))
    }

    /// "Archive All Finished" over the sample's finished sessions, on Finished where its row shows.
    static var bulkUndo: PopoverModel {
        archived(.allFinished(model().finished.map(\.key)), in: .finished)
    }

    // MARK: Whole-popover scenarios

    enum Scenario {
        case empty, loading, single, five, unassigned, background, nested, finished, finishedOpen
        case long0, long2, three
        case modelOrchestrator, modelCodex
    }

    /// - Parameter keepsSilentSessions: Only the old experiment's process is
    ///   gone; sessions without a pid keep waiting, so idle ones stay idle.
    ///   Otherwise the sweep also ends every session without a pid, as the
    ///   older previews show it.
    private static func state(from events: [AgentEvent], staleOldExperiment: Bool = false, keepsSilentSessions: Bool = false) -> CollectiveState {
        var state = CollectiveState()
        for event in events.sorted(by: { $0.timestamp < $1.timestamp }) { state.apply(event) }
        if staleOldExperiment {
            let timeout: TimeInterval = keepsSilentSessions ? .infinity : 0
            state.markStale(now: now.addingTimeInterval(-360), silenceTimeout: timeout, waitingTimeout: timeout) { pid in
                pid == 104 ? nil : now.addingTimeInterval(-86_400)
            }
        }
        return state
    }

    /// A long-running session with `count` subagents of which the first `done`
    /// finished. The ones still running are background agents, so the turn can end
    /// (`waiting`) while they work.
    private static func longSession(
        _ id: String, runtime: TimeInterval, count: Int, done: Int, waiting: Bool
    ) -> [AgentEvent] {
        var steps: [(ago: TimeInterval, kind: AgentEvent.Kind)] = [
            (runtime, .sessionStarted(cwd: "/Users/user/Developer/\(id)", pid: nil)),
            (runtime - 1, .promptSubmitted("Work through the open tickets, one after the other, and report what is left.")),
        ]
        for index in 0..<count {
            steps.append((2_900 - TimeInterval(index), spawn("s\(index)", title: "Subagent \(index + 1)", background: index >= done ? true : nil)))
        }
        for index in 0..<done { steps.append((1_000 - TimeInterval(index), .agentFinished(id: "s\(index)"))) }
        if waiting { steps.append((60, .turnEnded())) }
        return events(id, steps)
    }

    private static let codexSession: [AgentEvent] = events("codex-1", source: "codex", [
        (900, .sessionStarted(cwd: "/Users/user/Developer/codex-playground", pid: nil)),
        (899, .promptSubmitted("Port the shell script to Swift.")),
        (4, .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "swift build"))),
    ])

    private static let threeSubagents: [AgentEvent] = events("three", [
        (600, .sessionStarted(cwd: "/Users/user/Developer/three", pid: nil)),
        (599, .promptSubmitted("Compare the three approaches.")),
        (300, spawn("t1", title: "One of Three")),
        (290, spawn("t2", title: "Two of Three")),
        (280, spawn("t3", title: "Three of Three")),
        (10, .toolStarted(agent: .subagent("t3"), ToolActivity(name: "Read", detail: "Package.swift"))),
    ])

    // MARK: Tool strips

    /// One session per strip state, in the order of the design.
    private static let strips: [AgentEvent] = {
        func session(_ id: String, project: String, start: TimeInterval = 720, _ more: [(ago: TimeInterval, kind: AgentEvent.Kind)]) -> [AgentEvent] {
            events(id, [
                (start, .sessionStarted(cwd: "/Users/user/Developer/\(project)", pid: nil)),
                (start - 1, .promptSubmitted("Make the activity line read as a tool call. Keep the card height steady.")),
                (start - 2, .modelChanged(to: opus, from: nil)),
            ] + more)
        }
        return session("strip-bash", project: "abnahme", [
            (5, .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "deno task test src/renderer/app/theme-flavors.test.ts"))),
        ]) + session("strip-edit", project: "agent-collective", [
            (5, .toolStarted(agent: .root, ToolActivity(name: "Edit", detail: "/Users/user/Developer/agent-collective/CollectiveKit/Sources/CollectiveUI/ActivityLineView+Accessibility.swift"))),
        ]) + session("strip-mcp", project: "website", [
            (5, .toolStarted(agent: .root, ToolActivity(name: "mcp__github__create_pull_request", detail: "title: \"Update the imprint page\""))),
        ]) + session("strip-thinking", project: "subspace", [
            (10, .toolFinished(agent: .root)),
        ]) + session("strip-quiet", project: "subspace", start: 52 * 60, [
            (47 * 60, .toolFinished(agent: .root)),
        ]) + session("strip-subagents", project: "abnahme", [
            (300, spawn("s1", title: "Find all hard-coded colors")),
            (290, spawn("s2", title: "Apply theme in renderer")),
            (280, spawn("s3", title: "Update snapshot tests")),
            (270, spawn("s4", title: "Audit entitlements")),
            (30, .agentFinished(id: "s4")),
        ])
    }()

    /// The session `id` of the strip sample.
    static func strip(_ id: String) -> SessionItem {
        let model = PopoverModel(
            state: state(from: strips),
            now: now,
            settings: PreviewData.noIdle,
            sourceNames: sourceNames,
            sourceLogos: sourceLogos,
            modelNaming: modelNaming,
            lastEventAt: now.addingTimeInterval(-2)
        )
        return session(id, in: model)
    }

    // MARK: Models (revision 4)

    private static let opus = "claude-opus-5-5"

    private static func orchestrator(_ id: String, model: String? = opus, _ more: [(ago: TimeInterval, kind: AgentEvent.Kind)] = []) -> [AgentEvent] {
        var steps: [(ago: TimeInterval, kind: AgentEvent.Kind)] = [
            (900, .sessionStarted(cwd: "/Users/user/Developer/\(id)", pid: nil)),
            (899, .promptSubmitted("Review the open changes.")),
        ]
        if let model { steps.append((898, .modelChanged(to: model, from: nil))) }
        return events(id, steps + more)
    }

    /// The orchestrator alone, with its model.
    private static let modelOrchestrator = orchestrator("models-one", [
        (5, .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "swift test"))),
    ])

    private static let modelCodex: [AgentEvent] = events("codex-models", source: "codex", [
        (900, .sessionStarted(cwd: "/Users/user/Developer/codex-playground", pid: nil)),
        (899, .promptSubmitted("Port the shell script to Swift.")),
        (898, .modelChanged(to: "gpt-5-codex", from: nil)),
        (4, .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "swift build"))),
    ])

    static func scenario(_ scenario: Scenario) -> PopoverModel {
        var expansion = PopoverExpansion()
        let events: [AgentEvent]
        switch scenario {
        case .empty, .loading: events = []
        case .single: events = contractTests
        case .five: events = abnahme + contractTests + subspace + docsSite + oldExperiment
        case .unassigned:
            events = Self.events("fresh", [
                (20, .sessionStarted(cwd: "/Users/user/Developer/fresh", pid: nil)),
                (19, .promptSubmitted("Split the parser into modules.")),
                (3, spawn("u", type: nil, title: nil)),
            ])
        case .background: events = subspace
        case .nested: events = abnahme
        case .finished, .finishedOpen:
            events = contractTests + docsSite + oldExperiment
            if scenario == .finishedOpen { expansion.select(.finished) }
        case .long0:
            events = longSession("agent-collective", runtime: 3_000, count: 13, done: 13, waiting: false) + contractTests
        case .long2:
            events = longSession("agent-collective", runtime: 40 * 3_600 + 56 * 60, count: 15, done: 13, waiting: true) + codexSession
        case .three: events = threeSubagents
        case .modelOrchestrator: events = Self.modelOrchestrator
        case .modelCodex: events = Self.modelCodex + Self.modelOrchestrator
        }
        return PopoverModel(
            state: state(from: events, staleOldExperiment: scenario == .finished || scenario == .finishedOpen || scenario == .five),
            now: now,
            settings: PreviewData.noIdle,
            sourceNames: sourceNames,
            sourceLogos: sourceLogos,
            modelNaming: modelNaming,
            lastEventAt: events.isEmpty ? nil : now.addingTimeInterval(-2),
            expansion: expansion,
            isLoading: scenario == .loading,
            loadingIndicatorVisible: scenario == .loading
        )
    }

    // MARK: Last reply

    static let shortReply = "Done. All **12** contract tests pass again; the flaky one waited on the spool."
    static let longReply = """
    Replaced every hard-coded color in the renderer with the theme tokens.

    - `ThemeApplier.swift`: reads the palette from `Theme.current`
    - `SnapshotTests`: re-recorded, all green
    - The asset catalog is untouched

    ## Notes
    Two colors had no token yet, so I added `accentMuted` and `warningInk` to the theme and \
    documented them in the README. Dark mode uses the same tokens; the snapshot tests cover both.

    ```swift
    let color = Theme.current.color(.accentMuted)
    ```

    | File | Lines |
    |---|---:|
    | ThemeApplier.swift | 42 |
    | Theme.swift | 18 |

    Let me know whether the new token names fit, or whether they should follow the design file.
    """
    static let codeReply = """
    ```sh
    swift test --filter SpoolReaderTests
    swift test --filter ContractTests
    ```
    """

    enum ReplyScenario {
        case short, longClosed, workingAgain, background, noReply, finished, codex
    }

    /// A session whose turn ended with `reply` (nil: no reply event); `before`
    /// comes ahead of the reply, `after` follows the end of the turn.
    private static func repliedSession(
        _ id: String, source: SourceID = source, model: String = opus, reply: String?,
        before: [(ago: TimeInterval, kind: AgentEvent.Kind)] = [],
        after: [(ago: TimeInterval, kind: AgentEvent.Kind)] = []
    ) -> [AgentEvent] {
        var steps: [(ago: TimeInterval, kind: AgentEvent.Kind)] = [
            (1_200, .sessionStarted(cwd: "/Users/user/Developer/\(id)", pid: nil)),
            (1_199, .promptSubmitted("Replace the hard-coded colors in the renderer and report what changed.")),
            (1_198, .modelChanged(to: model, from: nil)),
        ]
        steps += before
        if let reply { steps.append((61, .replied(agent: .root, reply))) }
        steps.append((60, .turnEnded()))
        return events(id, source: source, steps + after)
    }

    /// Finished rows: a short and a long reply, and a session that lost contact
    /// before it replied.
    private static let finishedReplies: [AgentEvent] =
        repliedSession("fin-short", reply: shortReply, after: [(50, .sessionEnded)])
        + repliedSession("fin-long", reply: longReply, after: [(40, .sessionEnded)])
        + events("fin-stale", [
            (1_500, .sessionStarted(cwd: "/Users/user/Developer/fin-stale", pid: 104)),
            (1_499, .promptSubmitted("Prototype the sparkle animation.")),
        ])

    /// Every reply scenario of the design that the app can show, through the
    /// real reducer and `PopoverModel`.
    static func replies(_ scenario: ReplyScenario) -> PopoverModel {
        let events: [AgentEvent]
        var expansion = PopoverExpansion()
        switch scenario {
        case .short: events = repliedSession("reply-short", reply: shortReply)
        case .longClosed: events = repliedSession("reply-long", reply: longReply)
        case .workingAgain:
            events = repliedSession("reply-again", reply: shortReply, after: [
                (30, .promptSubmitted("Now fix the flaky test as well.")),
                (5, .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "swift test --filter SpoolReaderTests"))),
            ])
        case .background:
            events = repliedSession("reply-background", reply: shortReply, before: [
                (600, spawn("b1", title: "Update snapshot tests", background: true)),
                (590, .toolStarted(agent: .subagent("b1"), ToolActivity(name: "Bash", detail: "swift test --filter Snapshot"))),
            ])
        case .noReply: events = repliedSession("reply-none", reply: nil) + repliedSession("reply-blank", reply: " \n ")
        case .finished:
            events = finishedReplies
            expansion.select(.finished)
        case .codex:
            events = repliedSession("reply-claude", reply: shortReply)
                + repliedSession("reply-codex", source: codexSource, model: "gpt-5-codex", reply: codeReply)
        }
        func build(_ expansion: PopoverExpansion) -> PopoverModel {
            PopoverModel(
                state: state(from: events, staleOldExperiment: scenario == .finished),
                now: now,
                settings: PreviewData.noIdle,
                sourceNames: sourceNames,
                sourceLogos: sourceLogos,
                modelNaming: modelNaming,
                lastEventAt: now.addingTimeInterval(-2),
                expansion: expansion
            )
        }
        return build(expansion)
    }

    // MARK: Idle group

    enum IdleScenario {
        /// 2 working, 1 permission, 1 waiting 2 min, 3 idle, 2 finished.
        case mixed
        /// Nothing runs: the header says so and the idle group follows directly.
        case allIdle
        case collapsed
    }

    /// A session whose turn ended `restedAgo` seconds ago, with a reply.
    private static func restingSession(
        _ id: String, source: SourceID = source, model: String = opus, restedAgo: TimeInterval, reply: String? = shortReply
    ) -> [AgentEvent] {
        var steps: [(ago: TimeInterval, kind: AgentEvent.Kind)] = [
            (restedAgo + 1_200, .sessionStarted(cwd: "/Users/user/Developer/\(id)", pid: nil)),
            (restedAgo + 1_199, .promptSubmitted("Replace the hard-coded colors in the renderer and report what changed.")),
            (restedAgo + 1_198, .modelChanged(to: model, from: nil)),
        ]
        if let reply { steps.append((restedAgo + 1, .replied(agent: .root, reply))) }
        steps.append((restedAgo, .turnEnded()))
        return events(id, source: source, steps)
    }

    private static let idleSessions: [AgentEvent] =
        restingSession("vinculum", restedAgo: 48 * 60, reply: longReply)
        + restingSession("unimatrix-zero", source: codexSource, model: "gpt-5-codex", restedAgo: 2 * 3_600 + 5 * 60, reply: codeReply)
        + restingSession("borg-cube", restedAgo: 7 * 60, reply: nil)

    static func idle(_ scenario: IdleScenario) -> PopoverModel {
        var events = idleSessions
        var expansion = PopoverExpansion()
        expansion.select(.idle)
        switch scenario {
        case .mixed:
            events += contractTests + abnahme + docsSite + oldExperiment
            events += restingSession("waiting-soon", restedAgo: 2 * 60)
            events += Self.events("needs-permission", [
                (500, .sessionStarted(cwd: "/Users/user/Developer/needs-permission", pid: nil)),
                (499, .promptSubmitted("Install the dependencies and run the build.")),
                (20, .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "swift build"))),
                (15, .permissionRequested(agent: .root, ToolActivity(name: "Bash", detail: "swift build"))),
            ])
        case .allIdle: break
        case .collapsed: expansion.select(.active)
        }
        func build(_ expansion: PopoverExpansion) -> PopoverModel {
            PopoverModel(
                state: state(from: events, staleOldExperiment: scenario == .mixed, keepsSilentSessions: true),
                now: now,
                settings: PopoverSettings(),
                sourceNames: sourceNames,
                sourceLogos: sourceLogos,
                modelNaming: modelNaming,
                lastEventAt: now.addingTimeInterval(-2),
                expansion: expansion
            )
        }
        return build(expansion)
    }

    // MARK: Tabs

    /// A dev server the agent left running in the background, nothing else at work.
    private static let devServer: [AgentEvent] = events("dev-server", [
        (3_900, .sessionStarted(cwd: "/Users/user/Developer/dev-server", pid: nil)),
        (3_899, .promptSubmitted("Start the dev server in the background and tell me when it is up.")),
        (300, .turnEnded()),
        (300, .backgroundShellsListed(Array(previewShells.prefix(1)))),
        (299, .activityReported(.backgroundShell)),
    ])

    /// The restyled popover as the design draws it with `tab` selected: Active holds a permission request, a
    /// question, a session waiting for you, one working, background agents and a shell; three
    /// sessions rest in Idle, two in Finished. The working row and vinculum
    /// report an effort, so their jump lines show the gauge.
    static func tabs(_ tab: PopoverTab) -> PopoverModel {
        var expansion = PopoverExpansion()
        expansion.select(tab)
        let effortEvents = Self.events("contract-tests", [(238, .modelChanged(to: opus, from: nil)), (237, effort(3))])
            + Self.events("vinculum", [(48 * 60 + 1_100, effort(2))])
        let events = permissionEvents + questionEvents + restingSession("waiting-soon", restedAgo: 120)
            + contractTests + subspace + devServer + idleSessions + docsSite + oldExperiment + effortEvents
        return PopoverModel(
            state: state(from: events, staleOldExperiment: true, keepsSilentSessions: true),
            now: now,
            settings: PopoverSettings(),
            sourceNames: sourceNames,
            sourceLogos: sourceLogos,
            modelNaming: modelNaming,
            lastEventAt: now.addingTimeInterval(-2),
            expansion: expansion
        )
    }

    // MARK: Effort

    private static let effortNames = ["low", "medium", "high", "xhigh", "max"]

    private static func effort(_ step: Int, agent: AgentRef = .root) -> AgentEvent.Kind {
        .effortReported(agent: agent, EffortLevel(step: step, name: effortNames[step - 1])!)
    }

    /// One working card per step; the last switched from high to max and has
    /// one subagent with its own effort and one without. Then a card without a
    /// known effort and an idle row with the orchestrator's.
    static func effort(colors: Bool = true) -> PopoverModel {
        var events: [AgentEvent] = []
        for step in 1...4 {
            events += orchestrator("effort-\(effortNames[step - 1])", [
                (897, effort(step)),
                (TimeInterval(5 + step), .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "swift test"))),
            ])
        }
        events += orchestrator("effort-max", [
            (897, effort(3)),
            (300, effort(5)),
            (60, spawn("own", type: "Explore", title: "Find all uses of ReplyView", alias: "haiku", modelID: haiku)),
            (59, effort(1, agent: .subagent("own"))),
            (50, spawn("no-effort", type: "code-reviewer", title: "Review the store change", alias: "sonnet", modelID: sonnet)),
            (5, .toolStarted(agent: .subagent("own"), ToolActivity(name: "Grep", detail: "ReplyView"))),
        ])
        events += orchestrator("effort-unknown", [
            (4, .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "swift build"))),
        ])
        events += restingSession("effort-idle", restedAgo: 48 * 60)
        events += Self.events("effort-idle", [(48 * 60 + 1_100, effort(2))])
        var expansion = PopoverExpansion()
        expansion.toggleSubagents(key("effort-max"), isOpen: false)
        return PopoverModel(
            state: state(from: events),
            now: now,
            settings: PopoverSettings(colorsEffortLevels: colors),
            sourceNames: sourceNames,
            sourceLogos: sourceLogos,
            modelNaming: modelNaming,
            lastEventAt: now.addingTimeInterval(-2),
            expansion: expansion
        )
    }

    // MARK: Show in terminal

    enum TerminalPreview {
        /// Warp with the session's tab: "Show in Warp ⌘↩".
        case warp
        /// An app known only by its bundle: "Brings Terminal to the front. …".
        case appOnly
        /// An installed bundle the system has no name for: "Show Terminal", the `terminal` symbol.
        case nameless

        var identifiers: TerminalIdentifiers {
            switch self {
            case .warp:
                TerminalIdentifiers([
                    "WARP_FOCUS_URL": "warp://session/16e5a860f58d4186bd579a30d87d0d18",
                    "__CFBundleIdentifier": "dev.warp.Warp-Stable",
                ])
            case .appOnly, .nameless: TerminalIdentifiers(["__CFBundleIdentifier": "com.apple.Terminal"])
            }
        }

        var apps: PreviewTerminalApps {
            PreviewTerminalApps(names: self == .nameless ? [:] : ["dev.warp.Warp-Stable": "Warp", "com.apple.Terminal": "Terminal"])
        }
    }

    /// Every app installed, under the names the preview gives.
    struct PreviewTerminalApps: TerminalApps {
        let names: [String: String]
        func app(bundleID: String) -> TerminalApp? { TerminalApp(bundleID: bundleID, name: names[bundleID]) }
        func app(opening url: URL) -> TerminalApp? { nil }
    }

    /// `events` run in `terminal` by their own process `pid`, which the source
    /// confirms, so the session offers "Show in …".
    private static func inTerminal(_ events: [AgentEvent], pid: Int32, _ terminal: TerminalIdentifiers) -> [AgentEvent] {
        var result = events.map { event in
            let kind: AgentEvent.Kind = if case let .sessionStarted(cwd, _) = event.kind { .sessionStarted(cwd: cwd, pid: pid) } else { event.kind }
            return AgentEvent(session: event.session, timestamp: event.timestamp, kind: kind, cwd: event.cwd, pid: pid, terminal: terminal)
        }
        if let first = result.first {
            result.insert(AgentEvent(session: first.session, timestamp: first.timestamp, kind: .terminalReported(.session), pid: pid), at: 1)
        }
        return result
    }

    /// One of each place the action shows: the jump button while the session
    /// runs (permission and question with their hint), the menu in every row,
    /// finished ones included, which jump from the menu only.
    static func terminal(_ preview: TerminalPreview) -> PopoverModel {
        let ids = preview.identifiers
        let events = inTerminal(events("show-working", [
            (300, .sessionStarted(cwd: "/Users/user/Developer/show-working", pid: nil)),
            (299, .promptSubmitted("Run the contract tests and fix whatever fails.")),
            (5, .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "swift test --filter SpoolReaderTests"))),
        ]), pid: 901, ids)
            + inTerminal(restingSession("show-waiting", restedAgo: 120), pid: 902, ids)
            + inTerminal(permissionEvents, pid: 903, ids)
            + inTerminal(questionEvents, pid: 904, ids)
            + inTerminal(restingSession("show-idle", restedAgo: 48 * 60, reply: longReply), pid: 905, ids)
            + inTerminal(repliedSession("show-finished", reply: shortReply, after: [(50, .sessionEnded)]), pid: 906, ids)
            // Without a terminal: everything as before.
            + restingSession("no-terminal", restedAgo: 90)
        var expansion = PopoverExpansion()
        expansion.select(.finished)
        return PopoverModel(
            state: state(from: events),
            now: now,
            settings: PopoverSettings(),
            sourceNames: sourceNames,
            sourceLogos: sourceLogos,
            modelNaming: modelNaming,
            lastEventAt: now.addingTimeInterval(-2),
            expansion: expansion,
            terminalApps: preview.apps
        )
    }

    static func terminalItem(_ preview: TerminalPreview, _ id: String) -> SessionItem {
        let model = terminal(preview)
        return (model.sessions + model.idle + model.finished).first { $0.key == key(id) }!
    }

    // MARK: Warning

    static let missingIntegration = IntegrationStatus(
        source: source,
        toolName: "Claude Code",
        cliName: "claude",
        cli: .found(path: "/opt/homebrew/bin/claude", version: "2.1.285"),
        plugin: .notInstalled,
        // Made-up commands: the real ones belong to the tool's probe.
        commands: SetupCommands(
            install: ["claude plugin marketplace add example/plugins", "claude plugin install example --scope user"],
            installInApp: ["/plugin marketplace add example/plugins", "/plugin install example"],
            enable: ["claude plugin enable example"],
            enableInApp: ["/plugin enable example"],
            marketplaceLine: "claude plugin marketplace add example/plugins",
            sourceURL: URL(string: "https://github.com/example/plugins")
        )
    )

    static let marketplaceKnownIntegration: IntegrationStatus = {
        var status = missingIntegration
        status.marketplaceAdded = true
        return status
    }()

    /// A tool whose install adds a marketplace first, then installs the plugin: two lines, the first one skippable.
    static let codexMissingIntegration = IntegrationStatus(
        source: codexSource,
        toolName: "Codex",
        cliName: "codex",
        cli: .found(path: "/opt/homebrew/bin/codex", version: "0.20.0"),
        plugin: .notInstalled,
        commands: SetupCommands(
            install: ["codex plugin marketplace add example/plugins", "codex plugin install example"],
            installInApp: [],
            enable: [],
            enableInApp: [],
            marketplaceLine: "codex plugin marketplace add example/plugins",
            sourceURL: URL(string: "https://github.com/example/plugins")
        )
    )

    /// A run as the card shows it: `states` per command, with `outputs` for the lines that ran.
    static func run(
        _ status: IntegrationStatus,
        states: [SetupCommandRun.Line.State],
        phase: SetupCommandRun.Phase,
        outputs: [String?] = []
    ) -> [SourceID: SetupCommandRun.Snapshot] {
        let lines = status.commands.install.enumerated().map { index, command in
            SetupCommandRun.Line(command: command, state: states[index], output: index < outputs.count ? outputs[index] : nil)
        }
        return [status.source: SetupCommandRun.Snapshot(kind: .install, lines: lines, phase: phase)]
    }

    static let marketplaceOutput = "$ claude plugin marketplace add example/plugins\nAdding marketplace…\nSuccessfully added marketplace: example"
    static let installOutput = "$ claude plugin install example --scope user\nInstalling plugin \"example\"…\nSuccessfully installed plugin: example"

    static let disabledIntegration: IntegrationStatus = {
        var status = missingIntegration
        status.plugin = .disabled(version: "0.4.0")
        return status
    }()

    static let waitingIntegration: IntegrationStatus = {
        var status = missingIntegration
        status.plugin = .enabled(version: "0.4.0")
        return status
    }()

    static let readyIntegration: IntegrationStatus = {
        var status = waitingIntegration
        status.lastSessionStartAt = now.addingTimeInterval(-120)
        return status
    }()

    // MARK: Updates

    /// Connected with an older subspace than the newest release; made-up commands and repository.
    static let updatableIntegration: IntegrationStatus = {
        var status = readyIntegration
        status.plugin = .enabled(version: "1.0.1")
        status.commands.update = ["claude plugin marketplace update example", "claude plugin update example@example --scope user"]
        status.commands.release = SubspaceRelease(tagsRepository: "example/plugins", tagPrefix: "claude-code-", changesRepository: "example/plugins-dev")
        return status
    }()

    static let installedVersion = SubspaceVersion(major: 1, minor: 0, patch: 1)
    static let latestVersion = SubspaceVersion(major: 1, minor: 1, patch: 0)
    static let updateAvailable = UpdateAvailability.available(installed: installedVersion, latest: latestVersion)
    static let updateRequired = UpdateAvailability.required(installed: installedVersion, minimum: latestVersion, latest: nil)

    /// An update run as the group shows it: `states` per command, with `outputs` for the lines that ran.
    static func updateRun(
        _ status: IntegrationStatus,
        states: [SetupCommandRun.Line.State],
        phase: SetupCommandRun.Phase,
        outputs: [String?] = []
    ) -> SetupCommandRun.Snapshot {
        let lines = status.commands.update.enumerated().map { index, command in
            SetupCommandRun.Line(command: command, state: states[index], output: index < outputs.count ? outputs[index] : nil)
        }
        return SetupCommandRun.Snapshot(kind: .update(from: installedVersion, to: latestVersion), lines: lines, phase: phase)
    }

    enum UpdateFooter { case available, required, restart }

    /// The footer's update link, or the restart hint after a probe saw the plugin rise.
    static func updateFooter(_ kind: UpdateFooter) -> PopoverModel {
        let status = updatableIntegration
        var hints = SubspaceRestartHints()
        var link: UpdateFooterLink?
        switch kind {
        case .available:
            link = UpdateFooterLink(statuses: [status], availability: [status.source: updateAvailable], checksForUpdates: true)
        case .required:
            link = UpdateFooterLink(statuses: [status], availability: [status.source: updateRequired], checksForUpdates: true)
        case .restart:
            var updated = status
            updated.plugin = .enabled(version: latestVersion.description)
            hints.observe([status], probeStartedAt: now.addingTimeInterval(-60))
            hints.observe([updated], probeStartedAt: now.addingTimeInterval(-30))
        }
        return PopoverModel(
            state: state(from: abnahme + contractTests),
            now: now,
            settings: PreviewData.noIdle,
            sourceNames: sourceNames,
            sourceLogos: sourceLogos,
            modelNaming: modelNaming,
            lastEventAt: now.addingTimeInterval(-2),
            updateLink: link,
            restartHints: hints
        )
    }

    enum Warning { case missing, disabled }

    /// `earlierOpen`: the earlier sessions unfolded under the warning.
    static func warning(_ kind: Warning, sessions: Bool, earlierOpen: Bool = false) -> PopoverModel {
        let events = sessions ? abnahme + contractTests : []
        var expansion = PopoverExpansion()
        if earlierOpen { expansion.toggleEarlierSessions() }
        return PopoverModel(
            state: state(from: events),
            now: now,
            settings: PreviewData.noIdle,
            sourceNames: sourceNames,
            sourceLogos: sourceLogos,
            modelNaming: modelNaming,
            lastEventAt: sessions ? now.addingTimeInterval(-2) : nil,
            expansion: expansion,
            connection: kind == .missing ? .missing(missingIntegration) : .disabled(disabledIntegration)
        )
    }
}
#endif
