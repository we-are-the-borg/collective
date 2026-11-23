import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

private let source: SourceID = "test-tool"
private let t0 = Date(timeIntervalSince1970: 1_000)
private let s1 = SessionKey(source: source, sessionID: "s1")

/// Events of one session, one second apart from `t0` on.
private func state(_ kinds: [AgentEvent.Kind]) -> CollectiveState {
    var state = CollectiveState()
    for (offset, kind) in kinds.enumerated() {
        state.apply(AgentEvent(session: s1, timestamp: t0.addingTimeInterval(TimeInterval(offset)), kind: kind))
    }
    return state
}

private struct ShortNaming: ModelNaming {
    func displayName(forModel model: String) -> String? {
        ["claude-haiku-5-5": "Haiku 5.5", "haiku": "Haiku", "claude-sonnet-5": "Sonnet 5"][model] ?? model
    }
}

/// The session's item `seconds` after `t0`, wherever it is listed.
private func item(
    _ state: CollectiveState, at seconds: TimeInterval = 30,
    expansion: PopoverExpansion = PopoverExpansion(), idleAfter: IdleAfter = .never, undo: ArchiveUndo = ArchiveUndo()
) throws -> SessionItem {
    let popover = PopoverModel(
        state: state, now: t0.addingTimeInterval(seconds),
        settings: PopoverSettings(finishedRetention: .oneHour, idleAfter: idleAfter),
        modelNaming: [source: ShortNaming()], expansion: expansion, undo: undo
    )
    return try #require((popover.sessions + popover.idle + popover.finished).first)
}

private func item(_ kinds: [AgentEvent.Kind], at seconds: TimeInterval = 30, expansion: PopoverExpansion = PopoverExpansion()) throws -> SessionItem {
    try item(state(kinds), at: seconds, expansion: expansion)
}

/// The expansion with `s1`'s list opened by the user.
private var opened: PopoverExpansion {
    var expansion = PopoverExpansion()
    expansion.toggleSubagents(s1, isOpen: false)
    return expansion
}

/// The list of `session` as an active card builds it, opened by the user.
private func build(_ session: Session, at seconds: TimeInterval = 30, expansion: PopoverExpansion = opened) -> SubagentListBuild {
    let archive = SessionArchive()
    return SubagentListBuild(
        session: session, archive: archive, modelNaming: ShortNaming(), now: t0.addingTimeInterval(seconds),
        expansion: expansion, replyPreviews: ReplyPreviewCache().beginBuild(),
        waitingOn: ActivityLine.waitingOn(in: session, archive: archive)
    )
}

private func spawn(
    _ id: String, parent: AgentRef = .root, type: String? = "explore", title: String? = nil,
    alias: String? = nil, modelID: String? = nil, background: Bool? = nil, prompt: String? = nil
) -> AgentEvent.Kind {
    .agentSpawned(id: id, parent: parent, spec: AgentSpec(
        type: type, title: title ?? id.uppercased(), prompt: prompt, modelAlias: alias, modelID: modelID, isBackground: background
    ))
}

private func en(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

private let started: AgentEvent.Kind = .sessionStarted(cwd: "/tmp/alpha", pid: nil)
private let grep = ToolActivity(name: "Grep", detail: "ReplyView")

private extension SubagentEntry {
    var ref: AgentRef? { row?.ref }
}

private func refs(_ list: SubagentList?) -> [String] {
    (list?.entries ?? []).map { entry in
        switch entry {
        case let .agent(row): if case let .subagent(id) = row.ref { id } else { "root" }
        case let .fold(fold): "fold(\(en(fold.textParts.first!)))"
        }
    }
}

/// A session's subagents one by one on its compact card.
@Suite struct SubagentListTests {
    // MARK: Open state

    @Test func theListStartsClosedAndBuildsNoRows() throws {
        let list = try #require(try item([started, .promptSubmitted("Go"), spawn("a"), spawn("b")]).subagentToggle?.list)
        #expect(!list.isOpen)
        #expect(list.entries.isEmpty)
    }

    @Test func aSessionWithoutSubagentsHasNoList() throws {
        #expect(try item([started, .promptSubmitted("Go")]).subagentToggle?.list == nil)
    }

    @Test func theUsersToggleOpensTheList() throws {
        let list = try #require(try item([started, .promptSubmitted("Go"), spawn("a")], expansion: opened).subagentToggle?.list)
        #expect(list.isOpen)
        #expect(refs(list) == ["a"])
    }

    /// No captured payload has a subagent asking for permission or a
    /// question yet, so these states are built from events.
    @Test func aSubagentAwaitingPermissionOpensTheListByItself() throws {
        let list = try #require(try item([started, .promptSubmitted("Go"), spawn("a"), .permissionRequested(agent: .subagent("a"), grep)]).subagentToggle?.list)
        #expect(list.isOpen)
        #expect(refs(list) == ["a"])
    }

    @Test func aSubagentAwaitingAnAnswerOpensTheListByItself() throws {
        let question = Question(text: "Which file?", options: [], allowsMultiple: false, allowsOwnAnswer: false)
        let list = try #require(try item([started, .promptSubmitted("Go"), spawn("a"), .questionAsked(agent: .subagent("a"), [question])]).subagentToggle?.list)
        #expect(list.isOpen)
    }

    @Test func anArchivedSubagentAwaitingPermissionLeavesTheListClosed() throws {
        var s = state([started, .promptSubmitted("Go"), spawn("a"), spawn("b"), .permissionRequested(agent: .subagent("a"), grep)])
        s.archive(.agent(s1, .subagent("a")), at: t0.addingTimeInterval(20))
        #expect(try #require(try item(s).subagentToggle?.list).isOpen == false)
    }

    @Test func theUsersChoiceWinsOverTheAutomaticOpening() throws {
        let kinds: [AgentEvent.Kind] = [started, .promptSubmitted("Go"), spawn("a"), .permissionRequested(agent: .subagent("a"), grep)]
        var expansion = PopoverExpansion()
        expansion.toggleSubagents(s1, isOpen: true)
        let closed = try #require(try item(kinds, expansion: expansion).subagentToggle?.list)
        #expect(!closed.isOpen)
        #expect(closed.entries.isEmpty)

        // Still closed once nothing asks anymore, and open again only by hand.
        expansion.toggleSubagents(s1, isOpen: false)
        #expect(try #require(try item([started, .promptSubmitted("Go"), spawn("a")], expansion: expansion).subagentToggle?.list).isOpen)
    }

    // MARK: Order and depth

    /// a ─ a1, a2;  b ─ b1 ─ b11;  c, spawned in that order of time.
    @Test func newestFirstOnEveryLevelEachFollowedByItsOwn() throws {
        let item = try item([
            started, .promptSubmitted("Go"), spawn("a"), spawn("a1", parent: .subagent("a")), spawn("b"),
            spawn("a2", parent: .subagent("a")), spawn("b1", parent: .subagent("b")), spawn("b11", parent: .subagent("b1")), spawn("c"),
        ], expansion: opened)
        let list = try #require(item.subagentToggle?.list)
        #expect(refs(list) == ["c", "b", "b1", "b11", "a", "a2", "a1"])
        #expect(list.entries.map(\.depth) == [1, 1, 2, 3, 1, 2, 2])
    }

    @Test func subagentsStartedInTheSameMomentKeepAStableOrder() throws {
        var s = CollectiveState()
        for kind in [started, .promptSubmitted("Go")] { s.apply(AgentEvent(session: s1, timestamp: t0, kind: kind)) }
        for id in ["b", "a", "c"] { s.apply(AgentEvent(session: s1, timestamp: t0.addingTimeInterval(1), kind: spawn(id))) }
        #expect(refs(try item(s, expansion: opened).subagentToggle?.list) == ["a", "b", "c"])
    }

    // MARK: Folding

    @Test func doneSubagentsFoldIntoOneRowAtTheNewestOnesPlace() throws {
        let item = try item([
            started, .promptSubmitted("Go"), spawn("d1"), spawn("w1"), spawn("d2"), spawn("d3"), spawn("w2"),
            .agentFinished(id: "d1"), .agentFinished(id: "d2"), .agentFinished(id: "d3"),
        ], expansion: opened)
        let list = try #require(item.subagentToggle?.list)
        #expect(refs(list) == ["w2", "fold(3 done)", "w1"])
        guard case let .fold(fold) = list.entries[1] else { Issue.record("no fold row"); return }
        #expect(fold.id == SubagentFoldID(session: s1, parent: .root))
        #expect(fold.depth == 1)
        #expect(!fold.isOpen)
        #expect(fold.textParts.map(en) == ["3 done"])
        #expect(en(fold.accessibilityText) == "3 done, folded")
    }

    @Test func evenASingleDoneSubagentFolds() throws {
        let item = try item([started, .promptSubmitted("Go"), spawn("a"), spawn("b"), .agentFinished(id: "a")], expansion: opened)
        #expect(refs(item.subagentToggle?.list) == ["b", "fold(1 done)"])
    }

    @Test func archivedSubagentsFoldWithTheDoneOnes() throws {
        var s = state([started, .promptSubmitted("Go"), spawn("a"), spawn("b"), spawn("c"), spawn("w"), .agentFinished(id: "a")])
        s.archive(.agent(s1, .subagent("b")), at: t0.addingTimeInterval(20))
        s.archive(.agent(s1, .subagent("c")), at: t0.addingTimeInterval(20))
        let list = try #require(try item(s, expansion: opened).subagentToggle?.list)
        #expect(refs(list) == ["w", "fold(1 done)"])
        guard case let .fold(fold) = list.entries[1] else { Issue.record("no fold row"); return }
        #expect(fold.textParts.map(en) == ["1 done", "2 archived"])
        #expect(en(fold.accessibilityText) == "1 done, 2 archived, folded")
    }

    @Test func onlyArchivedSubagentsFoldWithoutADoneCount() throws {
        var s = state([started, .promptSubmitted("Go"), spawn("a"), spawn("w")])
        s.archive(.agent(s1, .subagent("a")), at: t0.addingTimeInterval(20))
        #expect(refs(try item(s, expansion: opened).subagentToggle?.list) == ["w", "fold(1 archived)"])
    }

    /// Events never leave a subagent stale on an active card: the sweep ends
    /// the whole session, and its next event revives every agent it caught.
    /// The row has the state all the same, so it is set by hand here.
    @Test func lostContactStaysARowOfItsOwn() throws {
        var session = try #require(state([started, .promptSubmitted("Go"), spawn("a"), spawn("b"), .agentFinished(id: "a")]).sessions[s1])
        session.agents[.subagent("b")]?.status = .stale
        let list = SubagentList(build(session), needsYou: false)
        #expect(refs(list) == ["b", "fold(1 done)"])
        #expect(list.entries.compactMap(\.row).map(\.status) == [.lostContact])
    }

    /// d ─ w: d is done, but w, spawned under it later, still works.
    @Test func aDoneSubagentWhoseSubagentStillWorksKeepsItsRow() throws {
        let item = try item([
            started, .promptSubmitted("Go"), spawn("d"), spawn("e"), .agentFinished(id: "d"), .agentFinished(id: "e"),
            spawn("w", parent: .subagent("d")),
        ], expansion: opened)
        let list = try #require(item.subagentToggle?.list)
        #expect(refs(list) == ["fold(1 done)", "d", "w"])
        #expect(list.entries.compactMap(\.row).map(\.status) == [.done, .working])
    }

    @Test func anOpenFoldRowListsItsMembersOneLevelDeeper() throws {
        let kinds: [AgentEvent.Kind] = [
            started, .promptSubmitted("Go"), spawn("d1"), spawn("x", parent: .subagent("d1")), spawn("w"), spawn("d2"),
            .agentFinished(id: "x"), .agentFinished(id: "d1"), .agentFinished(id: "d2"),
        ]
        var expansion = opened
        expansion.toggleSubagentFold(SubagentFoldID(session: s1, parent: .root))
        let list = try #require(try item(kinds, expansion: expansion).subagentToggle?.list)
        // d1's own subagent folds again, one level below d1.
        #expect(refs(list) == ["fold(2 done)", "d2", "d1", "fold(1 done)", "w"])
        #expect(list.entries.map(\.depth) == [1, 2, 2, 3, 1])
        guard case let .fold(fold) = list.entries[0] else { Issue.record("no fold row"); return }
        #expect(fold.isOpen)
        #expect(en(fold.accessibilityText) == "2 done, unfolded")
    }

    // MARK: Row fields

    private func row(_ id: String, in item: SessionItem) throws -> SubagentRow {
        try #require(item.subagentToggle?.list.entries.compactMap(\.row).first { $0.ref == .subagent(id) })
    }

    /// a ─ a1;  b (done);  c: the position counts every depth by start.
    @Test func aFinishedRowCountsItsSpawnPositionAWorkingOneItsRuntime() throws {
        var expansion = opened
        expansion.toggleSubagentFold(SubagentFoldID(session: s1, parent: .root))
        let item = try item([
            started, .promptSubmitted("Go"), spawn("a"), spawn("a1", parent: .subagent("a")), spawn("b"), spawn("c"), .agentFinished(id: "b"),
        ], at: 42, expansion: expansion)
        let b = try row("b", in: item)
        #expect((b.position, b.total) == (3, 4))
        #expect(b.runningSince == nil)

        let a1 = try row("a1", in: item)
        #expect((a1.position, a1.total) == (2, 4))
        #expect(a1.runningSince == t0.addingTimeInterval(3))
    }

    @Test func aWorkingRowShowsItsActivity() throws {
        let item = try item([started, .promptSubmitted("Go"), spawn("a"), .toolStarted(agent: .subagent("a"), grep)], expansion: opened)
        #expect(try row("a", in: item).detail == .activity(.tool(grep)))
    }

    @Test func aRowWaitingOnItsOwnSubagentsSaysHowMany() throws {
        let item = try item([started, .promptSubmitted("Go"), spawn("a"), spawn("x", parent: .subagent("a")), spawn("y", parent: .subagent("a"))], expansion: opened)
        #expect(try row("a", in: item).detail == .activity(.subagentsWorking(2)))
    }

    /// A background subagent is not waited on.
    @Test func aRowCountsOnlyItsForegroundSubagents() throws {
        let item = try item([
            started, .promptSubmitted("Go"), spawn("a"), spawn("x", parent: .subagent("a"), background: true),
            spawn("y", parent: .subagent("a"), background: false),
        ], expansion: opened)
        #expect(try row("a", in: item).detail == .activity(.subagentsWorking(1)))
    }

    @Test func aRowAwaitingPermissionShowsWhatItAsksToRun() throws {
        let item = try item([
            started, .promptSubmitted("Go"), spawn("a"), .toolStarted(agent: .subagent("a"), grep), .permissionRequested(agent: .subagent("a"), grep),
        ])
        let a = try row("a", in: item)
        #expect(a.status == .needsPermission)
        #expect(a.status.needsYou)
        #expect(a.detail == .needsPermission(.tool(grep)))
        #expect(en(SubagentDetail.needsPermissionText) == "Needs your permission")
        #expect(a.runningSince != nil)
    }

    @Test func aRowWithAQuestionShowsTheFirstOne() throws {
        let questions = [Question(text: "Which file?"), Question(text: "Which line?")]
        let item = try item([started, .promptSubmitted("Go"), spawn("a"), .questionAsked(agent: .subagent("a"), questions)])
        let a = try row("a", in: item)
        #expect(a.status == .question)
        #expect(a.detail == .question(count: 2, text: "Which file?"))
        #expect(en(SubagentDetail.questionText(count: 1)) == "Question for you")
    }

    @Test func aLostRowSaysWhenItsLastEventCame() throws {
        var session = try #require(state([started, .promptSubmitted("Go"), spawn("a"), .toolStarted(agent: .subagent("a"), grep)]).sessions[s1])
        session.agents[.subagent("a")]?.status = .stale
        let a = try #require(SubagentList(build(session), needsYou: false).entries.first?.row)
        #expect(a.detail == .lostContact(lastEvent: t0.addingTimeInterval(3)))
        #expect(en(a.accessibilityText(at: t0.addingTimeInterval(183))).hasSuffix("lost contact, 1 of 1, last event 3 min ago"))
    }

    @Test func doneAndUnassignedRowsHaveNoSecondLine() throws {
        var expansion = opened
        expansion.toggleSubagentFold(SubagentFoldID(session: s1, parent: .root))
        let item = try item([
            started, .promptSubmitted("Go"), spawn("d"), .agentFinished(id: "d"),
            .agentSpawned(id: "u", parent: .root, spec: AgentSpec()),
        ], expansion: expansion)
        let u = try row("u", in: item)
        #expect(u.status == .unassigned)
        #expect(u.detail == nil)
        #expect(en(u.titleText) == "Awaiting designation…")
        #expect(try row("d", in: item).detail == nil)
    }

    /// "Awaiting designation…" is for a subagent the source has not named at
    /// all; a type alone names it, as a title alone does.
    @Test func aTypedButUntitledSubagentWorksRatherThanWaitingForAType() throws {
        let item = try item([
            started, .promptSubmitted("Go"), .agentSpawned(id: "t", parent: .root, spec: AgentSpec(type: "Explore")),
            .agentSpawned(id: "n", parent: .root, spec: AgentSpec()),
        ], expansion: opened)
        #expect(try row("t", in: item).status == .working)
        #expect(try row("n", in: item).status == .unassigned)
        #expect(SubagentsHeader(summary: item.summary).statusParts.map(en) == ["1 working", "1 waiting for a type"])
    }

    @Test func aRowIsTitledByItsTypeElseItsTitle() throws {
        let item = try item([
            started, .promptSubmitted("Go"), spawn("t", type: "Explore", title: "Find the view"), spawn("n", type: nil, title: "Find the view"),
            .agentSpawned(id: "x", parent: .root, spec: AgentSpec()),
        ], expansion: opened)
        #expect(en(try row("t", in: item).titleText) == "Explore")
        #expect(en(try row("n", in: item).titleText) == "Find the view")
        #expect(en(try row("x", in: item).titleText) == "Awaiting designation…")
    }

    @Test func aRowNamesItsOwnModelOnlyNeverTheSessions() throws {
        let item = try item([
            started, .modelChanged(to: "claude-sonnet-5", from: nil), .promptSubmitted("Go"),
            spawn("chosen", alias: "haiku", modelID: "claude-haiku-5-5"), spawn("alias", alias: "haiku"),
            spawn("inherited", modelID: "claude-sonnet-5"), spawn("unknown"),
        ], expansion: opened)
        let chosen = try #require(try row("chosen", in: item).model)
        #expect(chosen.name == "Haiku 5.5")
        #expect(chosen.helpDetail.map(en) == "Set at spawn")
        #expect(try row("alias", in: item).model?.name == "Haiku")
        let inherited = try #require(try row("inherited", in: item).model)
        #expect(inherited.name == "Sonnet 5")
        #expect(inherited.helpDetail.map(en) == "Inherited")
        #expect(item.model?.name == "Sonnet 5")
        #expect(try row("unknown", in: item).model == nil)
    }

    @Test func aRowShowsItsOwnEffortOnlyNeverTheSessions() throws {
        let high = EffortLevel(step: 3, name: "high")!
        let low = EffortLevel(step: 1, name: "low")!
        let item = try item([
            started, .modelChanged(to: "claude-sonnet-5", from: nil), .promptSubmitted("Go"),
            .effortReported(agent: .root, high),
            spawn("own", alias: "haiku"), spawn("none", alias: "haiku"),
            .effortReported(agent: .subagent("own"), low),
        ], expansion: opened)
        let own = try #require(try row("own", in: item).model)
        #expect(own.effort?.step == 1)
        #expect(own.effort?.name == "low")
        #expect(own.helpLines.map(en) == ["Set at spawn", "Effort: low"])
        let none = try #require(try row("none", in: item).model)
        #expect(none.effort == nil)
        #expect(none.helpLines.map(en) == ["Set at spawn"])
        #expect(item.model?.effort?.name == "high")
    }

    @Test func aRowKnowsItRunsInTheBackgroundAndItsPrompt() throws {
        let item = try item([
            started, .promptSubmitted("Go"), spawn("bg", background: true, prompt: "\n  Run the tests.\n"), spawn("fg", background: false),
        ], expansion: opened)
        let bg = try row("bg", in: item)
        #expect(bg.isBackground)
        #expect(bg.prompt == "Run the tests.")
        #expect(try row("fg", in: item).isBackground == false)
    }

    @Test func onlyADoneRowCarriesItsReply() throws {
        var expansion = opened
        expansion.toggleSubagentFold(SubagentFoldID(session: s1, parent: .root))
        let item = try item([
            started, .promptSubmitted("Go"), spawn("d"), spawn("w"),
            .replied(agent: .subagent("d"), "Found **it**."), .agentFinished(id: "d"), .replied(agent: .subagent("w"), "Halfway."),
        ], expansion: expansion)
        let reply = try #require(try row("d", in: item).reply)
        #expect(reply.id == .agent(s1, .subagent("d")))
        #expect(reply.text == "Found **it**.")
        #expect(try row("w", in: item).reply == nil)
    }

    // MARK: VoiceOver

    @Test func aRowReadsTypeModelStateTimeAndActivity() throws {
        let item = try item([
            started, .promptSubmitted("Go"), spawn("a", type: "Explore", alias: "haiku", modelID: "claude-haiku-5-5"),
            .toolStarted(agent: .subagent("a"), grep),
        ], expansion: opened)
        #expect(en(try row("a", in: item).accessibilityText(at: t0.addingTimeInterval(42))) == "Explore, Haiku 5.5, working, 40 s, Grep ReplyView")
    }

    @Test func aRowReadsItsEffortAfterTheModel() throws {
        let item = try item([
            started, .promptSubmitted("Go"), spawn("a", type: "Explore", alias: "haiku", modelID: "claude-haiku-5-5"),
            .effortReported(agent: .subagent("a"), EffortLevel(step: 1, name: "low")!),
            .toolStarted(agent: .subagent("a"), grep),
        ], expansion: opened)
        #expect(en(try row("a", in: item).accessibilityText(at: t0.addingTimeInterval(42))) == "Explore, Haiku 5.5, effort low, working, 40 s, Grep ReplyView")
    }

    @Test func aDoneBackgroundRowReadsItsPositionInWords() throws {
        var expansion = opened
        expansion.toggleSubagentFold(SubagentFoldID(session: s1, parent: .root))
        let item = try item([started, .promptSubmitted("Go"), spawn("a", type: "Explore", background: true), spawn("b"), .agentFinished(id: "a")], expansion: expansion)
        #expect(en(try row("a", in: item).accessibilityText(at: t0.addingTimeInterval(42))) == "Explore, background, done, 1 of 2")
    }

    @Test func aRowAwaitingPermissionReadsWhatItAsks() throws {
        let item = try item([
            started, .promptSubmitted("Go"), spawn("a", type: "Explore"), .toolStarted(agent: .subagent("a"), grep), .permissionRequested(agent: .subagent("a"), grep),
        ])
        #expect(en(try row("a", in: item).accessibilityText(at: t0.addingTimeInterval(12))) == "Explore, Needs your permission, 10 s, Grep ReplyView")
    }

    @Test func aRowAskingTwoQuestionsReadsTheirCount() throws {
        let questions = [Question(text: "Which file?"), Question(text: "Which line?")]
        let item = try item([started, .promptSubmitted("Go"), spawn("a"), .questionAsked(agent: .subagent("a"), questions)])
        #expect(en(try row("a", in: item).accessibilityText(at: t0.addingTimeInterval(12))).contains(en(SubagentDetail.questionText(count: 2))))
    }

    @Test func everyActiveRowWithSubagentsHasItsToggleLine() throws {
        let cases: [(CardState, [AgentEvent.Kind])] = [
            (.working, [started, .promptSubmitted("Go"), spawn("a")]),
            (.waiting, [started, .promptSubmitted("Go"), spawn("a"), .agentFinished(id: "a"), .turnEnded()]),
            (.working, [started, .promptSubmitted("Go"), spawn("a", background: true), .turnEnded()]),
            (.needsPermission, [started, .promptSubmitted("Go"), spawn("a"), .permissionRequested(agent: .subagent("a"), grep)]),
            (.question, [started, .promptSubmitted("Go"), spawn("a"), .questionAsked(agent: .subagent("a"), [Question(text: "Which?")])]),
        ]
        for (expected, kinds) in cases {
            let item = try item(kinds)
            #expect(item.cardState == expected, "\(expected) got \(String(describing: item.cardState))")
            #expect(item.subagentToggle != nil, "\(expected)")
        }
    }

    // MARK: Clock

    /// "Thinking…" turns into "No activity" by the clock alone. The
    /// orchestrator's call that started the subagent runs on, so its own line
    /// does not change.
    @Test func aQuietSubagentsRowChangesByTheClock() throws {
        let kinds: [AgentEvent.Kind] = [
            started, .promptSubmitted("Go"), .toolStarted(agent: .root, ToolActivity(name: "Agent", detail: "A")), spawn("a"),
            .toolStarted(agent: .subagent("a"), grep), .toolFinished(agent: .subagent("a")),
        ]
        let s = state(kinds)
        let before = try item(s, at: 10, expansion: opened)
        #expect(try row("a", in: before).detail == .activity(.thinking))
        let change = try #require(before.nextChange)
        #expect(change == t0.addingTimeInterval(5 + ActivityLine.quietThreshold))
        let after = try item(s, at: change.timeIntervalSince(t0), expansion: opened)
        #expect(try row("a", in: after).detail == .activity(.noActivity(since: t0.addingTimeInterval(5))))
    }

    // MARK: Summary

    @Test func subagentsThatNeedYouCountApartFromTheWorkingOnes() throws {
        let item = try item([
            started, .promptSubmitted("Go"), spawn("p"), spawn("q"), spawn("w"), spawn("d"), .agentFinished(id: "d"),
            .agentSpawned(id: "u", parent: .root, spec: AgentSpec()),
            .permissionRequested(agent: .subagent("p"), grep), .questionAsked(agent: .subagent("q"), [Question(text: "Which?")]),
        ])
        // The one waiting for a type works as far as the toggle line is concerned.
        let toggle = try #require(item.subagentToggle)
        #expect(toggle.parts.map { en($0.text) } == ["2 working", "2 need you", "1 done"])
        #expect(toggle.parts.map(\.kind) == [.working, .needYou, .done])
    }

    @Test func aSubagentWaitingForATypeStillKeepsTheSessionFromBeingArchived() throws {
        let item = try item([
            started, .promptSubmitted("Go"), .agentSpawned(id: "u", parent: .root, spec: AgentSpec()), .turnEnded(),
        ])
        #expect(SubagentsHeader(summary: item.summary).statusParts.map(en) == ["1 waiting for a type"])
        #expect(item.summary.workingCount == 1)
        #expect(!item.isArchivable)
        #expect(item.subagentToggle?.parts.map { en($0.text) } == ["1 working"])
    }

    @Test func aSubagentThatNeedsYouStillKeepsTheSessionFromBeingArchived() throws {
        let item = try item([started, .promptSubmitted("Go"), spawn("p"), .turnEnded(), .permissionRequested(agent: .subagent("p"), grep)])
        #expect(SubagentsHeader(summary: item.summary).statusParts.map(en) == ["1 needs you"])
        #expect(!item.isArchivable)
    }

    /// A subagent that only needs the user is no work.
    @Test func aSubagentThatOnlyNeedsYouCountsAsNoWork() throws {
        let permission = try item([started, .promptSubmitted("Go"), spawn("p"), .turnEnded(), .permissionRequested(agent: .subagent("p"), grep)])
        #expect(permission.state != .working)
        #expect(permission.subagentToggle?.parts.map { en($0.text) } == ["1 needs you"])
        #expect(permission.subagentsAccessibilityText == nil)

        let question = try item([
            started, .promptSubmitted("Go"), spawn("q"), spawn("r"), .agentFinished(id: "r"), .turnEnded(),
            .questionAsked(agent: .subagent("q"), [Question(text: "Which?")]),
        ])
        #expect(question.subagentToggle?.parts.map { en($0.text) } == ["1 needs you", "1 done"])
        #expect(question.subagentsAccessibilityText.map(en) == "1 subagent done")
    }

    // MARK: Archive

    /// "Archive Subagent" from the row's menu, `seconds` after `t0`.
    private func archive(_ id: String, in state: inout CollectiveState, undo: inout ArchiveUndo, at seconds: TimeInterval = 20) -> ArchiveUndo.ID {
        undo.archive(.subagent(s1, .subagent(id)), in: &state, at: t0.addingTimeInterval(seconds))
    }

    @Test func anArchivedSubagentKeepsItsPlaceAsAnUndoRowUntilItsUndoIsGone() throws {
        var s = state([started, .promptSubmitted("Go"), spawn("a", type: "Explore"), spawn("w"), spawn("d"), .agentFinished(id: "d")])
        var undo = ArchiveUndo()
        let id = archive("a", in: &s, undo: &undo)

        let during = try #require(try item(s, at: 22, expansion: opened, undo: undo).subagentToggle?.list)
        #expect(refs(during) == ["fold(1 done)", "w", "a"])
        let row = try #require(during.entries.compactMap(\.row).first { $0.ref == .subagent("a") })
        #expect(row.status == .archived)
        #expect(row.undo?.id == id)
        #expect(en(try #require(row.undo).text) == "Explore archived")

        // Six seconds on, the archive stays and the row folds with the done one.
        let after = try #require(try item(s, at: 26, expansion: opened, undo: undo).subagentToggle?.list)
        #expect(refs(after) == ["fold(1 done)", "w"])
        guard case let .fold(fold) = after.entries[0] else { Issue.record("no fold row"); return }
        #expect(fold.textParts.map(en) == ["1 done", "1 archived"])
    }

    @Test func aSubagentArchivedWithoutAnUndoEntryFoldsAtOnce() throws {
        var s = state([started, .promptSubmitted("Go"), spawn("a"), spawn("w")])
        s.archive(.agent(s1, .subagent("a")), at: t0.addingTimeInterval(20))
        #expect(refs(try item(s, at: 22, expansion: opened).subagentToggle?.list) == ["w", "fold(1 archived)"])
    }

    @Test func anUnnamedSubagentsUndoRowSaysSubagent() throws {
        var s = state([started, .promptSubmitted("Go"), spawn("u", type: nil, title: ""), spawn("w")])
        var undo = ArchiveUndo()
        _ = archive("u", in: &s, undo: &undo)
        let row = try #require(try item(s, at: 22, expansion: opened, undo: undo).subagentToggle?.list.entries.compactMap(\.row).first { $0.ref == .subagent("u") })
        #expect(en(try #require(row.undo).text) == "Subagent archived")
    }

    /// a ─ c: the undo row stands in for a's whole subtree, as a session's
    /// undo row does for its card; afterwards both fold.
    @Test func theUndoRowStandsInForTheSubagentsSubtree() throws {
        var s = state([started, .promptSubmitted("Go"), spawn("a"), spawn("c", parent: .subagent("a")), spawn("w")])
        var undo = ArchiveUndo()
        _ = archive("a", in: &s, undo: &undo)

        #expect(refs(try item(s, at: 22, expansion: opened, undo: undo).subagentToggle?.list) == ["w", "a"])
        #expect(refs(try item(s, at: 26, expansion: opened, undo: undo).subagentToggle?.list) == ["w", "fold(1 archived)"])
    }

    @Test func undoBringsTheRowBack() throws {
        var s = state([started, .promptSubmitted("Go"), spawn("a"), spawn("w")])
        var undo = ArchiveUndo()
        let id = archive("a", in: &s, undo: &undo)
        undo.undo(id, in: &s)

        let list = try #require(try item(s, at: 22, expansion: opened, undo: undo).subagentToggle?.list)
        #expect(refs(list) == ["w", "a"])
        #expect(list.entries.compactMap(\.row).allSatisfy { $0.undo == nil && $0.status == .working })
    }

    /// Opened by itself for the permission, the list stays open while the
    /// undo row shows, so archiving does not take the row out from under the pointer.
    @Test func theListStaysOpenWhileTheUndoRowShows() throws {
        var s = state([started, .promptSubmitted("Go"), spawn("a"), spawn("w"), .permissionRequested(agent: .subagent("a"), grep)])
        var undo = ArchiveUndo()
        _ = archive("a", in: &s, undo: &undo, at: 10)

        let during = try #require(try item(s, at: 12, undo: undo).subagentToggle?.list)
        #expect(during.isOpen)
        #expect(during.entries.compactMap(\.row).first { $0.ref == .subagent("a") }?.undo != nil)
        #expect(try #require(try item(s, at: 16, undo: undo).subagentToggle?.list).isOpen == false)
    }

    @Test func theUsersCloseWinsOverAPendingUndo() throws {
        var s = state([started, .promptSubmitted("Go"), spawn("a"), spawn("w")])
        var undo = ArchiveUndo()
        _ = archive("a", in: &s, undo: &undo, at: 10)
        var expansion = opened
        expansion.toggleSubagents(s1, isOpen: true)
        #expect(try #require(try item(s, at: 12, expansion: expansion, undo: undo).subagentToggle?.list).isOpen == false)
    }

    @Test func theCardChangesWhenTheSubagentsUndoRowGoes() throws {
        var s = state([started, .promptSubmitted("Go"), spawn("a"), spawn("w"), .turnEnded()])
        var undo = ArchiveUndo()
        _ = archive("a", in: &s, undo: &undo, at: 10)
        #expect(try item(s, at: 12, expansion: opened, undo: undo).nextChange == t0.addingTimeInterval(16))
    }

    @Test func archivingTheLastWorkingSubagentMakesTheSessionArchivable() throws {
        var s = state([started, .promptSubmitted("Go"), spawn("a"), .turnEnded()])
        #expect(try !item(s, expansion: opened).isArchivable)
        var undo = ArchiveUndo()
        _ = archive("a", in: &s, undo: &undo)

        let during = try item(s, at: 22, expansion: opened, undo: undo)
        #expect(during.isArchivable)
        #expect(during.summary.workingCount == 0)
        #expect(during.subagentToggle?.list.entries.compactMap(\.row).first?.undo != nil)
    }

    /// Only an undo row is left to show: the toggle line reads "Subagents"
    /// alone and keeps the list reachable until the undo row goes.
    @Test func theToggleStaysWhileOnlyAnUndoRowIsLeft() throws {
        var s = state([started, .promptSubmitted("Go"), spawn("a"), .turnEnded()])
        var undo = ArchiveUndo()
        _ = archive("a", in: &s, undo: &undo)

        let toggle = try #require(try item(s, at: 22, expansion: opened, undo: undo).subagentToggle)
        #expect(toggle.parts.isEmpty)
        #expect(toggle.isOpen)
        #expect(refs(toggle.list) == ["a"])
        #expect(en(toggle.accessibilityLabel) == "Subagents")

        #expect(try item(s, at: 26, expansion: opened, undo: undo).subagentToggle == nil)
    }

    /// The user closed the list by hand: an undo row alone neither reopens it
    /// nor takes the toggle away.
    @Test func aListTheUserClosedStaysClosedWhileOnlyAnUndoRowIsLeft() throws {
        var s = state([started, .promptSubmitted("Go"), spawn("a"), .turnEnded()])
        var undo = ArchiveUndo()
        _ = archive("a", in: &s, undo: &undo)
        var closed = opened
        closed.toggleSubagents(s1, isOpen: true)

        let toggle = try #require(try item(s, at: 22, expansion: closed, undo: undo).subagentToggle)
        #expect(toggle.parts.isEmpty)
        #expect(!toggle.isOpen)
        #expect(toggle.list.entries.isEmpty)
    }

    /// Archived first, then its session: Undo of the session brings the card
    /// back with the subagent's undo row still in place.
    @Test func undoingTheSessionBringsBackTheSubagentsUndoRow() throws {
        var s = state([started, .promptSubmitted("Go"), spawn("a"), spawn("w"), .agentFinished(id: "w"), .turnEnded()])
        var undo = ArchiveUndo()
        let agent = archive("a", in: &s, undo: &undo, at: 20)
        let session = undo.archive(.session(s1), in: &s, at: t0.addingTimeInterval(21))

        let archived = try item(s, at: 22, expansion: opened, undo: undo)
        #expect(archived.undo?.id == session)
        #expect(archived.subagentToggle?.list == nil)

        undo.undo(session, in: &s)
        let back = try #require(try item(s, at: 22, expansion: opened, undo: undo).subagentToggle?.list)
        #expect(back.entries.compactMap(\.row).first { $0.ref == .subagent("a") }?.undo?.id == agent)
    }

    @Test func onlyASubagentThatMayHangCanBeArchived() throws {
        var session = try #require(state([
            started, .promptSubmitted("Go"), spawn("w"), spawn("p"), spawn("q"), spawn("d"), spawn("l"),
            .agentSpawned(id: "u", parent: .root, spec: AgentSpec()),
            .agentFinished(id: "d"),
            .permissionRequested(agent: .subagent("p"), grep), .questionAsked(agent: .subagent("q"), [Question(text: "Which?")]),
        ]).sessions[s1])
        session.agents[.subagent("l")]?.status = .stale
        var expansion = opened
        expansion.toggleSubagentFold(SubagentFoldID(session: s1, parent: .root))
        let rows = SubagentList(build(session, expansion: expansion), needsYou: true).entries.compactMap(\.row)
        let archivable = Set(rows.map { "\($0.status): \($0.isArchivable)" })
        #expect(archivable == [
            "working: true", "needsPermission: true", "question: true", "unassigned: true", "lostContact: true", "done: false",
        ])
    }

    @Test func anArchivedRowCannotBeArchivedAgain() throws {
        var s = state([started, .promptSubmitted("Go"), spawn("a"), spawn("w")])
        var undo = ArchiveUndo()
        _ = archive("a", in: &s, undo: &undo)
        let row = try #require(try item(s, at: 22, expansion: opened, undo: undo).subagentToggle?.list.entries.compactMap(\.row).first { $0.ref == .subagent("a") })
        #expect(!row.isArchivable)
    }

    @Test func theMenuSaysWhenTheSubagentsLastEventCame() throws {
        let row = try #require(try item([started, .promptSubmitted("Go"), spawn("a")], expansion: opened).subagentToggle?.list.entries.first?.row)
        #expect(en(row.lastEventText(at: t0.addingTimeInterval(12))) == "Last event 10 s ago")
    }

    // MARK: Idle row

    private func idle(_ kinds: [AgentEvent.Kind]) throws -> SessionItem {
        let idle = try item(state(kinds), at: 1_000, idleAfter: .fiveMinutes)
        try #require(idle.idleSince != nil)
        return idle
    }

    @Test func anIdleRowSumsUpItsSubagentsAndTheirModels() throws {
        let item = try idle([
            started, .promptSubmitted("Go"), spawn("a", modelID: "claude-sonnet-5"), spawn("b", alias: "haiku", modelID: "claude-haiku-5-5"),
            spawn("c", modelID: "claude-sonnet-5"), spawn("d"),
            .agentFinished(id: "a"), .agentFinished(id: "b"), .agentFinished(id: "c"), .agentFinished(id: "d"), .turnEnded(),
        ])
        let line = try #require(item.idleSubagents)
        #expect(en(line.title) == "4 subagents, all done")
        #expect(line.statusParts.isEmpty)
        #expect(line.modelNames == ["Sonnet 5", "Haiku 5.5"])
    }

    @Test func anIdleRowWhoseSubagentsDidNotAllFinishCountsThem() throws {
        var s = state([
            started, .promptSubmitted("Go"), spawn("a"), spawn("b"), .agentFinished(id: "a"), .agentFinished(id: "b"), .turnEnded(),
        ])
        s.archive(.agent(s1, .subagent("b")), at: t0.addingTimeInterval(20))
        let item = try item(s, at: 1_000, idleAfter: .fiveMinutes)
        let line = try #require(item.idleSubagents)
        #expect(en(line.title) == "2 subagents")
        #expect(line.statusParts.map(en) == ["1 done", "1 archived"])
        #expect(line.modelNames.isEmpty)
    }

    @Test func aSingleDoneSubagentReadsInTheSingular() throws {
        let item = try idle([started, .promptSubmitted("Go"), spawn("a"), .agentFinished(id: "a"), .turnEnded()])
        #expect(en(try #require(item.idleSubagents).title) == "1 subagent, done")
    }

    @Test func onlyAnIdleRowWithSubagentsSumsThemUp() throws {
        #expect(try idle([started, .promptSubmitted("Go"), .turnEnded()]).idleSubagents == nil)
        #expect(try item([started, .promptSubmitted("Go"), spawn("a"), .agentFinished(id: "a"), .turnEnded()]).idleSubagents == nil)
    }
}

