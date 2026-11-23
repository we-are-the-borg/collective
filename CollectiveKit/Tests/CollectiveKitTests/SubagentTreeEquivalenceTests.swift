import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

// The references for the indexed tree walks: the subagent summary, a working agent's activity
// line and the end cascade of `finish` walked the tree by asking each node for
// its children, a scan of every agent per node. These are the recursive walks
// as they were, kept to show the indexed ones count and end exactly the same
// agents on generated trees.

private let t0 = Date(timeIntervalSince1970: 1_000)
private let key = SessionKey(source: "test-tool", sessionID: "tree")

/// A seeded generator, so a generated tree that fails fails every time.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Reference implementations

private func referenceChildren(of ref: AgentRef, in agents: [AgentRef: Agent]) -> [Agent] {
    agents.values.filter { $0.parent == ref }.sorted { $0.startedAt < $1.startedAt }
}

private func referenceDisplayState(_ agent: Agent, archived: Bool) -> AgentDisplayState {
    if archived { return .archived }
    if agent.status == .working && agent.spec.type == nil && agent.spec.title == nil { return .unassigned }
    return switch agent.status {
    case .working: .working
    case .waiting: .waiting
    case .done: .done
    case .stale: .stale
    }
}

private func referenceSummary(_ session: Session, archive: SessionArchive) -> SessionItem.Summary {
    func states(below parent: AgentRef) -> [AgentDisplayState] {
        referenceChildren(of: parent, in: session.agents).flatMap {
            [referenceDisplayState($0, archived: archive.isArchived($0.id))] + states(below: $0.id)
        }
    }
    return SessionItem.Summary(states: states(below: .root))
}

private func referenceWaitingOn(_ agent: Agent, in session: Session, archive: SessionArchive) -> Int {
    referenceChildren(of: agent.id, in: session.agents).count {
        $0.status == .working && $0.spec.isBackground != true && !archive.isArchived($0.id)
    }
}

private func referenceActivity(_ agent: Agent, in session: Session, archive: SessionArchive, now: Date) -> ActivityLine? {
    guard agent.status == .working, !archive.isArchived(agent.id) else { return nil }
    // The card's line 2 counts no subagents; a subagent's row does.
    let waitingOn = agent.id == .root ? 0 : referenceWaitingOn(agent, in: session, archive: archive)
    if waitingOn > 0 { return .subagentsWorking(waitingOn) }
    if let tool = agent.currentTool { return .tool(tool) }
    if let call = agent.lastToolCall, now.timeIntervalSince(call.startedAt) < ActivityLine.minimumToolDisplay {
        return .tool(call.tool)
    }
    if now.timeIntervalSince(agent.lastActivity) >= ActivityLine.quietThreshold { return .noActivity(since: agent.lastActivity) }
    return .thinking
}

private func referenceNextChange(_ session: Session, archive: SessionArchive, now: Date) -> Date? {
    session.agents.values.compactMap { agent -> Date? in
        guard agent.status == .working, !archive.isArchived(agent.id), agent.currentTool == nil,
              agent.id == .root || referenceWaitingOn(agent, in: session, archive: archive) == 0 else { return nil }
        let toolEnds = agent.lastToolCall.map { $0.startedAt.addingTimeInterval(ActivityLine.minimumToolDisplay) }
        let quiet = agent.lastActivity.addingTimeInterval(ActivityLine.quietThreshold)
        return [toolEnds, quiet].compactMap { $0 }.filter { $0 > now }.min()
    }.min()
}

private func referenceFinish(_ agents: inout [AgentRef: Agent], _ ref: AgentRef, as status: AgentStatus, at date: Date) {
    guard let agent = agents[ref] else { return }
    if agent.status == .working || agent.status == .waiting {
        var ended = agent
        if status == .stale { ended.statusBeforeStale = ended.status }
        ended.status = status
        ended.currentTool = nil
        ended.endedAt = date
        agents[ref] = ended
    }
    for child in referenceChildren(of: ref, in: agents) {
        referenceFinish(&agents, child.id, as: status, at: date)
    }
}

// MARK: - Generated sessions

/// A session built directly, so every status, title and parent can occur:
/// nested trees whose parents may have started after their children, as
/// after a reparent, and subtrees under a parent the session doesn't know,
/// which no walk from the root reaches.
private func generatedSession(_ random: inout SplitMix64) -> (Session, SessionArchive, now: Date) {
    var session = Session(key: key, startedAt: t0)
    let statuses: [AgentStatus] = [.working, .waiting, .done, .stale]
    let tools = [ToolActivity(name: "Bash", detail: "ls"), ToolActivity(name: "Read")]
    session.agents[.root]!.status = statuses.randomElement(using: &random)!
    if Bool.random(using: &random) { session.agents[.root]!.currentTool = tools.randomElement(using: &random) }

    let count = Int.random(in: 0...40, using: &random)
    // The order in which parents are picked, unrelated to the start times:
    // a parent only ever comes earlier in it, so there is no cycle.
    let order = (0..<count).map { AgentRef.subagent("a\($0)") }.shuffled(using: &random)
    for (index, ref) in order.enumerated() {
        let parent: AgentRef = switch Int.random(in: 0..<10, using: &random) {
        case 0: .subagent("unknown")
        case 1...3: .root
        default: ([.root] + order[..<index]).randomElement(using: &random)!
        }
        let title = Int.random(in: 0..<4, using: &random) == 0 ? nil : "T"
        let background = [nil, true, false].randomElement(using: &random)!
        let startedAt = t0.addingTimeInterval(TimeInterval(Int.random(in: 0...20, using: &random)))
        var agent = Agent(
            id: ref, parent: parent, spec: AgentSpec(title: title, isBackground: background),
            status: statuses.randomElement(using: &random)!, startedAt: startedAt
        )
        agent.lastActivity = startedAt.addingTimeInterval(TimeInterval(Int.random(in: 0...100, using: &random)))
        if Int.random(in: 0..<3, using: &random) == 0 { agent.currentTool = tools.randomElement(using: &random) }
        if Bool.random(using: &random) {
            agent.lastToolCall = ToolCall(
                tool: tools[0], startedAt: agent.lastActivity.addingTimeInterval(-TimeInterval(Int.random(in: 0...2, using: &random)))
            )
        }
        session.agents[ref] = agent
    }

    // Marks on single agents, and now and then on the whole session; an
    // agent counts as archived with any marked ancestor, as `SessionArchive`
    // builds it from the state's marks.
    let marked = Set(session.agents.keys.filter { _ in Int.random(in: 0..<8, using: &random) == 0 })
    let wholeSession = Int.random(in: 0..<20, using: &random) == 0
    var archive = SessionArchive()
    for ref in session.agents.keys {
        var current: AgentRef? = ref
        var seen: Set<AgentRef> = []
        while let node = current, seen.insert(node).inserted {
            if marked.contains(node) || wholeSession { archive.marks[ref] = t0; break }
            current = session.agents[node]?.parent
        }
    }
    let now = t0.addingTimeInterval(TimeInterval(Int.random(in: 0...150, using: &random)))
    return (session, archive, now)
}

private func item(_ session: Session, archive: SessionArchive, now: Date) -> SessionItem {
    let previews = ReplyPreviewCache().beginBuild()
    defer { previews.finish() }
    return SessionItem(
        session, sourceName: key.source.rawValue,
        modelNaming: PlainModelNaming(), resumeCommand: nil,
        awaitsPermission: session.agents.keys.contains { session.awaitsPermission($0) && !archive.isArchived($0) }, now: now,
        expansion: PopoverExpansion(), replyPreviews: previews,
        archive: archive, undo: nil, undoExpiry: nil
    )
}

/// The fields `finish` changes.
private struct Ending: Equatable {
    var status: AgentStatus
    var endedAt: Date?
    var currentTool: ToolActivity?
    var statusBeforeStale: AgentStatus?

    init(_ agent: Agent) {
        status = agent.status
        endedAt = agent.endedAt
        currentTool = agent.currentTool
        statusBeforeStale = agent.statusBeforeStale
    }
}

private func endings(_ agents: [AgentRef: Agent]) -> [AgentRef: Ending] {
    agents.mapValues(Ending.init)
}

/// Events of one session, one second apart: spawns under known, unknown and
/// later parents, spawns repeated with another parent, tool calls, ends of
/// subagents and turns. Subagents end up working or done, the root working
/// or waiting.
private func generatedEvents(_ random: inout SplitMix64) -> [AgentEvent] {
    var kinds: [AgentEvent.Kind] = [.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go")]
    var ids: [String] = []
    let tool = ToolActivity(name: "Bash", detail: "ls")
    for _ in 0..<Int.random(in: 0...60, using: &random) {
        let parents: [AgentRef] = [.root] + ids.map(AgentRef.subagent) + [.subagent("later\(ids.count)")]
        switch Int.random(in: 0..<10, using: &random) {
        case 0...3:
            let id = "a\(ids.count)"
            ids.append(id)
            let title = Bool.random(using: &random) ? "T" : nil
            kinds.append(.agentSpawned(id: id, parent: parents.randomElement(using: &random)!, spec: AgentSpec(title: title)))
        case 4:
            // A known spawn again, now with its real parent: a reparent.
            guard let id = ids.randomElement(using: &random) else { continue }
            kinds.append(.agentSpawned(id: id, parent: parents.randomElement(using: &random)!, spec: AgentSpec(title: "T")))
        case 5, 6:
            let agent = ([.root] + ids.map(AgentRef.subagent)).randomElement(using: &random)!
            kinds.append(.toolStarted(agent: agent, tool))
        case 7, 8:
            guard let id = ids.randomElement(using: &random) else { continue }
            kinds.append(.agentFinished(id: id))
        default:
            kinds.append(Bool.random(using: &random) ? .turnEnded() : .promptSubmitted("again"))
        }
    }
    return kinds.enumerated().map { offset, kind in
        AgentEvent(session: key, timestamp: t0.addingTimeInterval(TimeInterval(offset)), kind: kind)
    }
}

private extension CollectiveState {
    var onlySession: Session? { sessions.count == 1 ? sessions.values.first : nil }
}

private func state(_ events: [AgentEvent]) -> CollectiveState {
    var state = CollectiveState()
    events.forEach { state.apply($0) }
    return state
}

// MARK: - Tests

@Suite(.heavy) struct SubagentTreeEquivalenceTests {
    @Test(arguments: 0..<20)
    func theSummaryCountsWhatTheRecursiveWalkCounted(seed: Int) {
        var random = SplitMix64(seed: UInt64(seed))
        for _ in 0..<50 {
            let (session, archive, _) = generatedSession(&random)
            #expect(SessionItem.Summary(session, archive: archive) == referenceSummary(session, archive: archive))
        }
    }

    @Test(arguments: 0..<20)
    func theActivityLineAndItsNextChangeAreWhatTheRecursiveWalkGave(seed: Int) {
        var random = SplitMix64(seed: UInt64(seed) &+ 1_000)
        for _ in 0..<50 {
            let (session, archive, now) = generatedSession(&random)
            let built = item(session, archive: archive, now: now)
            #expect(built.activity == referenceActivity(session.root, in: session, archive: archive, now: now))
            #expect(built.nextChange == referenceNextChange(session, archive: archive, now: now))
            // What the subagents' rows count from.
            let waitingOn = ActivityLine.waitingOn(in: session, archive: archive)
            for agent in session.agents.values {
                #expect(waitingOn[agent.id, default: 0] == referenceWaitingOn(agent, in: session, archive: archive))
            }
        }
    }

    @Test(arguments: 0..<20)
    func aFinishedSubagentEndsWhatTheRecursiveWalkEnded(seed: Int) throws {
        var random = SplitMix64(seed: UInt64(seed) &+ 2_000)
        for _ in 0..<30 {
            let events = generatedEvents(&random)
            let before = try #require(state(events).onlySession)
            let refs = before.agents.keys.compactMap { if case let .subagent(id) = $0 { id } else { nil } }
            let id = refs.randomElement(using: &random) ?? "unknown"
            let date = t0.addingTimeInterval(TimeInterval(events.count))

            let after = try #require(state(events + [AgentEvent(session: key, timestamp: date, kind: .agentFinished(id: id))]).onlySession)
            var expected = before.agents
            referenceFinish(&expected, .subagent(id), as: .done, at: date)
            #expect(endings(after.agents) == endings(expected))
        }
    }

    @Test(arguments: 0..<20)
    func anEndedSessionEndsWhatTheRecursiveWalkEnded(seed: Int) throws {
        var random = SplitMix64(seed: UInt64(seed) &+ 3_000)
        for _ in 0..<30 {
            let events = generatedEvents(&random)
            let before = try #require(state(events).onlySession)
            let date = t0.addingTimeInterval(TimeInterval(events.count))

            let after = try #require(state(events + [AgentEvent(session: key, timestamp: date, kind: .sessionEnded)]).onlySession)
            var expected = before.agents
            referenceFinish(&expected, .root, as: .done, at: date)
            #expect(endings(after.agents) == endings(expected))
        }
    }

    /// The sweep ends the tree as stale, keeping what each agent was.
    @Test(arguments: 0..<20)
    func aStaleSessionEndsWhatTheRecursiveWalkEnded(seed: Int) throws {
        var random = SplitMix64(seed: UInt64(seed) &+ 4_000)
        for _ in 0..<30 {
            let events = generatedEvents(&random)
            var swept = state(events)
            let before = try #require(swept.onlySession)
            let date = t0.addingTimeInterval(TimeInterval(events.count + 10))

            swept.markStale(now: date, silenceTimeout: 1, waitingTimeout: 1, processStart: { _ in nil })
            let after = try #require(swept.onlySession)
            var expected = before.agents
            referenceFinish(&expected, .root, as: .stale, at: date)
            #expect(endings(after.agents) == endings(expected))
        }
    }

    /// `reparent` keeps cycles out, but a walk must not hang on one either.
    @Test func aCycleIsWalkedOnce() {
        var session = Session(key: key, startedAt: t0)
        session.agents[.subagent("a")] = Agent(id: .subagent("a"), parent: .subagent("b"), spec: AgentSpec(), status: .working, startedAt: t0)
        session.agents[.subagent("b")] = Agent(id: .subagent("b"), parent: .subagent("a"), spec: AgentSpec(), status: .working, startedAt: t0)
        #expect(session.descendants(of: .subagent("a")).map(\.id) == [.subagent("b")])
        #expect(session.descendants(of: .root).isEmpty)
    }
}
