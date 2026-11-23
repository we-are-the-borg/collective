import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

// MARK: - Fixtures

/// One of the two live spools of a resumed subagent: payloads with the envelope second each arrived in.
private struct ResumeSpool {
    struct Event {
        let number: Int
        let payload: Data
        let at: Date
    }

    static let resumed = try! ResumeSpool(
        "spool-2026-11-16-resumed-subagent", pid: 84800, session: "e04a26bf-8f28-4250-a4ae-72196d570122"
    )
    static let interrupted = try! ResumeSpool(
        "spool-2026-11-16-interrupted-subagents", pid: 13215, session: "70fde325-d096-4cf5-83dc-209523e7884f"
    )

    let pid: Int32
    let session: SessionKey
    /// All events in arrival order (`NNN-<hook>.json`).
    let events: [Event]

    init(_ name: String, pid: Int32, session: String) throws {
        let directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/claude-code/\(name)")
        self.pid = pid
        self.session = SessionKey(source: "claude-code", sessionID: session)
        // The payload files carry no envelope; the README table gives each one's spool file `<ts>-<pid>-<id>.json`.
        let readme = try String(contentsOf: directory.appendingPathComponent("README.md"), encoding: .utf8)
        var seconds: [String: TimeInterval] = [:]
        for line in readme.split(separator: "\n") {
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "`")) }
            guard cells.count == 2, cells[0].hasPrefix("events/"),
                  let ts = cells[1].split(separator: "-").first.flatMap({ TimeInterval($0) }) else { continue }
            seconds[cells[0]] = ts
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("events").path).sorted()
        events = try files.map { name in
            let file = "events/\(name)"
            let ts = try #require(seconds[file], "no README row for \(file)")
            return Event(
                number: Int(name.prefix(3))!,
                payload: try Data(contentsOf: directory.appendingPathComponent(file)),
                at: Date(timeIntervalSince1970: ts)
            )
        }
    }

    func event(_ number: Int) -> Event { events.first { $0.number == number }! }

    /// Events whose number is at most `last`.
    func events(through last: Int) -> [Event] { events.filter { $0.number <= last } }

    func envelope(_ event: Event) -> Envelope {
        Envelope(source: "claude-code", pid: pid, payload: event.payload, receivedAt: event.at)
    }

    /// The adapter's events for `event`, after it saw `before`.
    func kinds(of event: Event, after before: [Event]) throws -> [AgentEvent.Kind] {
        let adapter = Self.adapter()
        for earlier in before { _ = try adapter.events(from: envelope(earlier)) }
        return try adapter.events(from: envelope(event)).map(\.kind)
    }

    /// `events` through a fresh adapter into `state`.
    func replay(_ events: [Event], onto state: inout CollectiveState) throws {
        let adapter = Self.adapter()
        for event in events {
            for agentEvent in try adapter.events(from: envelope(event)) { state.apply(agentEvent) }
        }
    }

    func state(_ events: [Event]) throws -> CollectiveState {
        var state = CollectiveState()
        try replay(events, onto: &state)
        return state
    }

    static func adapter() -> ClaudeCodeAdapter {
        ClaudeCodeAdapter(metaReader: NoMeta(), mapping: bundledMapping())
    }
}

fileprivate extension ResumeSpool.Event {
    /// The same payload, delivered in another second.
    func at(_ seconds: TimeInterval) -> Self { Self(number: number, payload: payload, at: Date(timeIntervalSince1970: seconds)) }

    /// The same hook, its `background_tasks` without `agent`: the snapshot
    /// once the user has stopped it.
    func without(_ agent: String) throws -> Self {
        var hook = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let tasks = try #require(hook["background_tasks"] as? [[String: Any]])
        hook["background_tasks"] = tasks.filter { $0["id"] as? String != agent }
        return Self(number: number, payload: try JSONSerialization.data(withJSONObject: hook), at: at)
    }
}

/// No meta files: every subagent here is linked by its `Agent` call, or
/// meant to stay unlinked.
private struct NoMeta: SubagentMetaReading {
    func meta(transcriptPath: String, agentID: String) -> SubagentMeta? { nil }
}

private final class NoFiles: MappingFileSystem {
    func modificationDate(of url: URL) -> Date? { nil }
    func contents(of url: URL) throws -> Data { throw CocoaError(.fileNoSuchFile) }
}

/// A root without `model/`, so the bundled documents are used.
private func bundledMapping() -> MappingLoader {
    MappingLoader(root: URL(filePath: "/spool/root", directoryHint: .isDirectory), fileSystem: NoFiles())
}

/// The popover at `now`, without an "Idle" group so the card stays a card.
private func popover(_ state: CollectiveState, at seconds: TimeInterval) -> PopoverModel {
    PopoverModel(state: state, now: Date(timeIntervalSince1970: seconds), settings: PopoverSettings(idleAfter: .never))
}

private func card(_ state: CollectiveState, at seconds: TimeInterval) throws -> SessionItem {
    try #require(popover(state, at: seconds).sessions.first)
}

private let implementer = "a183282c31caebc12"
private let first = "a7cf9b083293ed775"
private let second = "af1b90fb83b036cd8"

// MARK: - Tests

/// A subagent interrupted by an API error ends with a `StopFailure` of its
/// own, and its orchestrator resumes it with `SendMessage`: a second
/// `SubagentStart` of the same id, no new `Agent` call.
@Suite struct ResumedSubagentFixtureTests {
    // MARK: Adapter

    /// `015-StopFailure` names `af1b…`: its end, not the orchestrator's.
    @Test func aSubagentsStopFailureFinishesItAndNotTheTurn() throws {
        let spool = ResumeSpool.interrupted
        #expect(try spool.kinds(of: spool.event(15), after: spool.events(through: 14)) == [.agentFinished(id: second)])
    }

    /// `017-StopFailure` names no agent: the orchestrator's own turn failed.
    @Test func theOrchestratorsStopFailureEndsItsTurnAsFailed() throws {
        let spool = ResumeSpool.interrupted
        #expect(try spool.kinds(of: spool.event(17), after: spool.events(through: 16)) == [.turnEnded(.failed)])
    }

    /// `026-SubagentStart` comes after the agent's `013-SubagentStop`.
    @Test func aStartAfterTheAgentsStopResumesIt() throws {
        let spool = ResumeSpool.resumed
        #expect(try spool.kinds(of: spool.event(26), after: spool.events(through: 25)).contains(.agentResumed(id: implementer)))
    }

    /// Without its async launch (`002-PostToolUse`) nothing says the agent
    /// runs on its own, until it is resumed: then it does.
    @Test func aResumedSubagentCountsAsBackground() throws {
        let spool = ResumeSpool.resumed
        let before = spool.events(through: 25).filter { $0.number != 2 }
        let kinds = try spool.kinds(of: spool.event(26), after: before)
        let spawns = kinds.compactMap { kind -> AgentSpec? in
            if case let .agentSpawned(id, _, spec) = kind, id == implementer { spec } else { nil }
        }
        #expect(spawns.map(\.isBackground) == [true])
        #expect(kinds.last == .agentResumed(id: implementer))
    }

    // MARK: Card and list

    /// Between the hand-back (`013-SubagentStop`) and the resume: the
    /// `<agent-message>` of `012` started a turn of the orchestrator's own, so
    /// it works through its question (answered in `017`), not waits.
    @Test func theHandedBackSubagentIsDoneWhileTheOrchestratorWorksOn() throws {
        let spool = ResumeSpool.resumed
        let state = try spool.state(spool.events(through: 23))
        let session = try #require(state.sessions[spool.session])
        #expect(session.root.status == .working)
        #expect(session.agents[.subagent(implementer)]?.status == .done)

        let item = try card(state, at: 1_794_836_021)
        #expect(item.cardState == .working)
        #expect(item.rowStatus == .working)
        #expect(item.summary.doneCount == 1)
        #expect(popover(state, at: 1_794_836_021).needYouCount == 0)
    }

    /// The orchestrator's `028-Stop` lists the resumed agent as running: the
    /// card shows it at work, not "waiting for you".
    @Test func aResumedSubagentKeepsTheCardWorkingAfterTheTurn() throws {
        let spool = ResumeSpool.resumed
        for last in [28, 30] {
            let state = try spool.state(spool.events(through: last))
            let session = try #require(state.sessions[spool.session])
            let agent = try #require(session.agents[.subagent(implementer)])
            #expect(session.root.status == .waiting, "through \(last)")
            #expect(AgentDisplayState(orchestratorOf: session, archive: SessionArchive()) == .backgroundWorking, "through \(last)")
            #expect(agent.status == .working, "through \(last)")
            #expect(agent.spec.isBackground == true, "through \(last)")
            #expect(agent.runStartedAt == Date(timeIntervalSince1970: 1_794_836_048), "through \(last)")
            #expect(agent.startedAt == Date(timeIntervalSince1970: 1_794_834_825), "through \(last)")

            let item = try card(state, at: 1_794_836_080)
            #expect(item.rowStatus == .backgroundAgents(count: 1), "through \(last)")
            #expect(item.summary.doneCount == 0, "through \(last)")
            #expect(popover(state, at: 1_794_836_080).needYouCount == 0, "through \(last)")
        }
    }

    /// Each implementer's `StopFailure` ends it alone; the orchestrator's
    /// state is what its own hooks left.
    @Test func interruptedSubagentsAreDoneAndLeaveTheOrchestratorAlone() throws {
        let spool = ResumeSpool.interrupted
        for (failure, agent) in [(15, second), (20, first)] {
            let before = try #require(try spool.state(spool.events(through: failure - 1)).sessions[spool.session])
            let after = try #require(try spool.state(spool.events(through: failure)).sessions[spool.session])
            #expect(after.agents[.subagent(agent)]?.status == .done, "\(failure)")
            #expect(after.root.status == before.root.status, "\(failure)")
            #expect(after.rootStatusSetAt == before.rootStatusSetAt, "\(failure)")
        }
        // Through `020`: the orchestrator waits since its own failed turn, `017`.
        let session = try #require(try spool.state(spool.events(through: 20)).sessions[spool.session])
        #expect(session.root.status == .waiting)
        #expect(session.rootStatusSetAt == Date(timeIntervalSince1970: 1_794_820_607))
    }

    /// Both are resumed (`027`, `030`) and listed running by `033-Stop`.
    @Test func resumedInterruptedSubagentsKeepTheCardWorking() throws {
        let spool = ResumeSpool.interrupted
        for last in [33, 37] {
            let state = try spool.state(spool.events(through: last))
            let session = try #require(state.sessions[spool.session])
            #expect(AgentDisplayState(orchestratorOf: session, archive: SessionArchive()) == .backgroundWorking, "through \(last)")
            for id in [first, second] {
                let agent = try #require(session.agents[.subagent(id)])
                #expect(agent.status == .working, "\(id) through \(last)")
                #expect(agent.spec.isBackground == true, "\(id) through \(last)")
                #expect(agent.runStartedAt == Date(timeIntervalSince1970: 1_794_821_553), "\(id) through \(last)")
            }
            let item = try card(state, at: 1_794_821_600)
            #expect(item.rowStatus == .backgroundAgents(count: 2), "through \(last)")
            #expect(item.summary.doneCount == 0, "through \(last)")
            #expect(popover(state, at: 1_794_821_600).needYouCount == 0, "through \(last)")
        }
    }

    // MARK: Limits of the rule

    /// A start in the same second as the agent's stop may be delivered after
    /// the stop of its own run: no resume (documented limit).
    @Test func aStartInTheSameSecondAsTheStopIsNoResume() throws {
        let spool = ResumeSpool.resumed
        let stop = spool.event(13).at
        let events = spool.events(through: 25) + [spool.event(26).at(stop.timeIntervalSince1970)]
        let agent = try #require(try spool.state(events).sessions[spool.session]?.agents[.subagent(implementer)])
        #expect(agent.status == .done)
        #expect(agent.runStartedAt == agent.startedAt)
    }

    /// The resume's start arrives only after the new run's own stop: the
    /// newest stop is later than it, so it is no resume and the run stays over.
    @Test func aResumeStartDeliveredAfterTheNewRunsStopIsNoResume() throws {
        let spool = ResumeSpool.resumed
        let laterStop = spool.event(13).at(1_794_836_100)
        let events = spool.events(through: 25) + [laterStop, spool.event(26)]
        let agent = try #require(try spool.state(events).sessions[spool.session]?.agents[.subagent(implementer)])
        #expect(agent.status == .done)
        #expect(agent.runStartedAt == agent.startedAt)
    }

    /// The user stops a resumed agent: it drops out of the next snapshot. One
    /// from the resume's own second may not list it yet; a later one ends
    /// it, whether its `Agent` call launched async (`002`) or not.
    @Test(arguments: [false, true])
    func aSnapshotWithoutTheResumedAgentEndsItOnlyAfterTheResumesSecond(launchedInForeground: Bool) throws {
        let spool = ResumeSpool.resumed
        let resumed = spool.events(through: 26).filter { !launchedInForeground || $0.number != 2 }
        let stopped = try spool.event(28).without(implementer)

        let sameSecond = try spool.state(resumed + [stopped.at(1_794_836_048)])
        #expect(sameSecond.sessions[spool.session]?.agents[.subagent(implementer)]?.status == .working)

        let later = try spool.state(resumed + [stopped])
        let agent = try #require(later.sessions[spool.session]?.agents[.subagent(implementer)])
        #expect(agent.status == .done)
        #expect(agent.endedAt == Date(timeIntervalSince1970: 1_794_836_053))
    }

    /// The user stops the agent's first run: `005-Stop` without it ends it,
    /// with no `SubagentStop`. A later start, here `026`, is a resume.
    @Test func aStartAfterASnapshotEndedTheAgentResumesIt() throws {
        let spool = ResumeSpool.resumed
        let launched = spool.events(through: 4)
        let stopped = try spool.event(5).without(implementer)
        #expect(try spool.kinds(of: stopped, after: launched).contains(.agentFinished(id: implementer)))
        #expect(try spool.kinds(of: spool.event(26), after: launched + [stopped]).contains(.agentResumed(id: implementer)))
    }

    /// The old run's `013-SubagentStop`, delivered again after the resume,
    /// belongs to the run before: the resumed run still ends by the snapshot
    /// rule, and goes on while the snapshot lists it.
    @Test func aLateStopOfTheRunBeforeLeavesTheResumedRunGoing() throws {
        let spool = ResumeSpool.resumed
        let resumed = spool.events(through: 26) + [spool.event(13)]

        let listed = try spool.state(resumed + [spool.event(28)])
        #expect(listed.sessions[spool.session]?.agents[.subagent(implementer)]?.status == .working)

        let stopped = try spool.state(resumed + [try spool.event(28).without(implementer)])
        let agent = try #require(stopped.sessions[spool.session]?.agents[.subagent(implementer)])
        #expect(agent.status == .done)
        #expect(agent.endedAt == Date(timeIntervalSince1970: 1_794_836_053))
    }
}
