import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

// MARK: - Helpers

private let english = Locale(identifier: "en")
private let sourceNames: [SourceID: String] = ["claude-code": "Claude Code", "codex": "Codex", "tool": "Tool"]

/// Everything on: the fixtures show both cases.
private let bothCases = NotificationPreferences(permission: true, turnFinishedAfter: .always)

/// Everything on, a turn's end only once the turn lasted `seconds`: the
/// captured turns last seconds, the settings' thresholds minutes.
private func turnsAfter(_ seconds: TimeInterval) -> NotificationPreferences {
    var preferences = bothCases
    preferences.turnFinishedAfterSeconds = seconds
    return preferences
}

/// Feeds batches through a planner the way the app will, with `now` at the
/// batch's newest event so freshness lets the fixtures' old times through,
/// and records which batch wished or withdrew what.
private struct Recorder {
    struct Step {
        let label: String
        let plan: NotificationPlan
    }

    var planner = NotificationPlanner(locale: english)
    var state = CollectiveState()
    var preferences = bothCases
    private(set) var steps: [Step] = []

    init(armed: Bool = true) {
        if armed { _ = planner.arm(state) }
    }

    mutating func apply(_ batch: [AgentEvent], label: String, now: Date? = nil) {
        guard let newest = batch.map(\.timestamp).max() else { return }
        let plan = planner.apply(batch, to: &state, now: now ?? newest, preferences: preferences, sourceNames: sourceNames)
        steps.append(Step(label: label, plan: plan))
    }

    var wishes: [NotificationWish] { steps.flatMap(\.plan.wishes) }

    /// The batches that wished something of `kind`.
    func labels(wishing kind: NotificationWish.Kind) -> [String] {
        steps.filter { $0.plan.wishes.contains { $0.kind == kind } }.map(\.label)
    }

    /// The batch that withdrew `wish`, nil if none did.
    func label(withdrawing wish: NotificationWish) -> String? {
        steps.first { $0.plan.withdrawals.contains(wish.id) }?.label
    }

    /// The batch that wished `wish`.
    func label(of wish: NotificationWish) -> String? {
        steps.first { $0.plan.wishes.contains(wish) }?.label
    }
}

private struct NoMeta: SubagentMetaReading {
    func meta(transcriptPath: String, agentID: String) -> SubagentMeta? { nil }
}

private final class MemoryFileSystem: MappingFileSystem {
    func modificationDate(of url: URL) -> Date? { nil }
    func contents(of url: URL) throws -> Data { throw CocoaError(.fileNoSuchFile) }
}

/// A root without `model/`, so the bundled documents are used.
private func bundledMapping() -> MappingLoader {
    MappingLoader(root: URL(filePath: "/spool/root", directoryHint: .isDirectory), fileSystem: MemoryFileSystem())
}

private extension Timeline {
    /// Each hook file and status snapshot as its own batch, in arrival order,
    /// labelled with its number (`"010"`).
    func batches(statuses: Bool = true) throws -> [(label: String, events: [AgentEvent])] {
        let adapter = ClaudeCodeAdapter(metaReader: NoMeta(), mapping: bundledMapping())
        let statusMapping = try #require(bundledMapping().document(named: ClaudeCodeSessionStatusSource.mappingName))
        // Alive, and started well before the run.
        let processStart: (Int32) -> Date? = { _ in Date(timeIntervalSince1970: 1_000) }
        let pid = try envelopePID()
        return try entries.filter { statuses || $0.isHook }.map { entry in
            let label = String(format: "%03d", entry.n)
            if entry.isHook {
                let envelope = Envelope(source: "claude-code", pid: pid, payload: data(entry), receivedAt: entry.at)
                return (label, try adapter.events(from: envelope))
            }
            let event = ClaudeCodeSessionStatusSource.event(from: data(entry), mapping: statusMapping, processStart: processStart)
            return (label, event.map { [$0] } ?? [])
        }
    }

    func record(into recorder: inout Recorder, statuses: Bool = true) throws {
        for batch in try batches(statuses: statuses) { recorder.apply(batch.events, label: batch.label) }
    }
}

/// When each Codex hook file was delivered, where the run says (see
/// `PermissionWaitFixtureTests`); one second per file otherwise.
private func codexBatches(_ run: CodexRun) throws -> [(label: String, events: [AgentEvent])] {
    let url = run.directory.appendingPathComponent("delivery-seconds.json")
    let seconds = (try? JSONDecoder().decode([String: TimeInterval].self, from: Data(contentsOf: url))) ?? [:]
    let adapter = run.adapter()
    return try run.files.enumerated().map { index, file in
        let second = seconds[file.name] ?? 1_000 + TimeInterval(index)
        let envelope = Envelope(source: "codex", pid: 4242, payload: file.payload, receivedAt: Date(timeIntervalSince1970: second))
        return (String(file.name.prefix(3)), try adapter.events(from: envelope))
    }
}

// MARK: - Claude Code fixtures

@Suite struct ClaudeCodeNotificationFixtureTests {
    /// 010 is approved (status `busy` in 012), 021 rejected (status `idle` in
    /// 023); 028 is the `AskUserQuestion`, which asks no permission. Both
    /// turns that ran to their end stop regularly (015, 033).
    @Test func eachRealRequestNotifiesOnceAndIsWithdrawnOnceAnswered() throws {
        var recorder = Recorder()
        try Timeline("4-waiting-permission-question").record(into: &recorder)

        #expect(recorder.labels(wishing: .permission) == ["010", "021"])
        #expect(recorder.labels(wishing: .turnFinished) == ["015", "033"])

        let permissions = recorder.wishes.filter { $0.kind == .permission }
        #expect(permissions.map { recorder.label(withdrawing: $0) } == ["012", "023"])
        #expect(permissions.map(\.body) == [
            "Needs your permission: Bash · touch captures/perm-one",
            "Needs your permission: Bash · touch captures/perm-two",
        ])
    }

    /// 2.1.285 run 3: the `Read` asked for in 006 and approved; the turn's
    /// regular `Stop` (010) answers the user's "hi". The Ctrl-C that follows
    /// quits Claude Code: it ends the session (011) and reports no turn end.
    @Test func theCtrlCThatQuitsReportsNoTurnEnd() throws {
        let adapter = Run.permission.adapter()
        var recorder = Recorder()
        for (index, payload) in Run.permission.payloads.enumerated() {
            let envelope = Envelope(source: "claude-code", pid: 4242, payload: payload, receivedAt: Date(timeIntervalSince1970: 1_000 + TimeInterval(index)))
            recorder.apply(try adapter.events(from: envelope), label: String(format: "%03d", index + 1))
        }

        #expect(recorder.labels(wishing: .permission) == ["006"])
        #expect(recorder.labels(wishing: .turnFinished) == ["010"])
        let finished = try #require(recorder.wishes.first { $0.kind == .turnFinished })
        // Over once the session is.
        #expect(recorder.label(withdrawing: finished) == "011")
    }

    /// Esc (008) and Ctrl-C (011) stop the turns; only the status file tells.
    @Test func anInterruptedTurnNotifiesNothing() throws {
        var recorder = Recorder()
        try Timeline("2-interrupt-mid-turn").record(into: &recorder)
        #expect(recorder.wishes.isEmpty)
    }

    /// The orchestrator ends four turns: 012 after a foreground subagent,
    /// 019 with a background one still running, 032 after the background
    /// agents handed back (025) and 035 after the hand-back 034. Each finished
    /// notification is over once the next turn starts.
    @Test func onlyTheOrchestratorsTurnEndsNotifyAndTheNextTurnWithdrawsThem() throws {
        var recorder = Recorder()
        try Timeline("6-background-subagents").record(into: &recorder)

        #expect(recorder.labels(wishing: .permission).isEmpty)
        #expect(recorder.labels(wishing: .turnFinished) == ["012", "019", "032", "035"])
        let finished = recorder.wishes.filter { $0.kind == .turnFinished }
        #expect(finished.map { recorder.label(withdrawing: $0) } == ["014", "025", "034", "037"])
        #expect(Set(finished.map(\.id)).count == 4)
    }

    /// How long S6's turns lasted from the last prompt (014 for the later
    /// two: the hand-backs 025 and 034 are no input), by the capture's
    /// milliseconds and by the whole seconds of the hooks' envelopes:
    /// 012 4.07 s (4 s), 019 3.73 s (4 s), 032 9.69 s (10 s), 035 11.84 s
    /// (12 s). Hence 11 s rather than 10 for the threshold between the last two.
    @Test func aTurnEndNotifiesOnceTheTurnLastedLongEnough() throws {
        var five = Recorder()
        five.preferences = turnsAfter(5)
        try Timeline("6-background-subagents").record(into: &five)
        #expect(five.labels(wishing: .turnFinished) == ["032", "035"])

        var eleven = Recorder()
        eleven.preferences = turnsAfter(11)
        try Timeline("6-background-subagents").record(into: &eleven)
        #expect(eleven.labels(wishing: .turnFinished) == ["035"])
    }

    /// S4's turns last 18 s (prompt 007 at …315 to stop 015 at …333) and
    /// 19 s (prompt 025 at …359 to stop 033 at …378), but the user answered
    /// 1 s (012, …332) and 2 s (030, …376) before each end.
    @Test func aTurnCountsFromTheAnswerToItsLastRequest() throws {
        var recorder = Recorder()
        recorder.preferences = turnsAfter(10)
        try Timeline("4-waiting-permission-question").record(into: &recorder)
        #expect(recorder.labels(wishing: .turnFinished).isEmpty)
        #expect(recorder.labels(wishing: .permission) == ["010", "021"])
    }

    @Test(arguments: ["4-waiting-permission-question", "6-background-subagents", "2-interrupt-mid-turn"])
    func neverNotifiesNoTurnEnd(_ run: String) throws {
        var recorder = Recorder()
        recorder.preferences.turnFinishedAfter = .never
        try Timeline(run).record(into: &recorder)
        #expect(recorder.labels(wishing: .turnFinished).isEmpty)
    }

    /// The tests' threshold in seconds measures, it never turns `never` on.
    @Test func neverWinsOverTheTestThreshold() throws {
        var recorder = Recorder()
        recorder.preferences = turnsAfter(0)
        recorder.preferences.turnFinishedAfter = .never
        try Timeline("6-background-subagents").record(into: &recorder)
        #expect(recorder.labels(wishing: .turnFinished).isEmpty)
    }

    /// The backlog at start reports the past: nothing of it notifies, not
    /// even once armed.
    @Test func aBacklogReadDisarmedNotifiesNothing() throws {
        var recorder = Recorder(armed: false)
        try Timeline("4-waiting-permission-question").record(into: &recorder)
        #expect(recorder.wishes.isEmpty)
        #expect(recorder.steps.allSatisfy { $0.plan.withdrawals.isEmpty })
        #expect(recorder.planner.arm(recorder.state).isEmpty)
        #expect(recorder.wishes.isEmpty)
    }

    /// Armed mid-run, after the backlog ended at 011: the request 010 read
    /// with the backlog never notifies, the turn ends after it do.
    @Test func armingAfterTheBacklogNotifiesOnlyWhatFollows() throws {
        var recorder = Recorder(armed: false)
        let batches = try Timeline("4-waiting-permission-question").batches()
        for batch in batches where batch.label <= "011" { recorder.apply(batch.events, label: batch.label) }
        #expect(recorder.planner.arm(recorder.state).isEmpty)
        for batch in batches where batch.label > "011" { recorder.apply(batch.events, label: batch.label) }

        #expect(recorder.labels(wishing: .permission) == ["021"])
        #expect(recorder.labels(wishing: .turnFinished) == ["015", "033"])
    }
}

// MARK: - Codex fixtures

@Suite struct CodexNotificationFixtureTests {
    /// Requests 003 (approved), 008 (rejected, then interrupted in 010) and
    /// 012 (approved with its prefix remembered, so 017 asks nothing).
    @Test func eachManualRequestNotifiesAndTheRejectionEndsNoTurn() throws {
        var recorder = Recorder()
        for batch in try codexBatches(.manualPermission) { recorder.apply(batch.events, label: batch.label) }

        #expect(recorder.labels(wishing: .permission) == ["003", "008", "012"])
        #expect(recorder.labels(wishing: .turnFinished) == ["006", "015", "019"])
        let permissions = recorder.wishes.filter { $0.kind == .permission }
        #expect(permissions.map { recorder.label(withdrawing: $0) } == ["005", "010", "014"])
    }

    /// The turns by `delivery-seconds.json`: 006 4 s after the approval's
    /// call end 005 (10 s after prompt 002), 015 3 s after 014 (11 s after
    /// prompt 011), 019 8 s after prompt 016, which asked nothing.
    @Test func aTurnCountsFromTheLastInputAsForClaudeCode() throws {
        var five = Recorder()
        five.preferences = turnsAfter(5)
        for batch in try codexBatches(.manualPermission) { five.apply(batch.events, label: batch.label) }
        #expect(five.labels(wishing: .turnFinished) == ["019"])

        var nine = Recorder()
        nine.preferences = turnsAfter(9)
        for batch in try codexBatches(.manualPermission) { nine.apply(batch.events, label: batch.label) }
        #expect(nine.labels(wishing: .turnFinished).isEmpty)
        #expect(nine.labels(wishing: .permission) == ["003", "008", "012"])

        var never = Recorder()
        never.preferences.turnFinishedAfter = .never
        for batch in try codexBatches(.manualPermission) { never.apply(batch.events, label: batch.label) }
        #expect(never.labels(wishing: .turnFinished).isEmpty)
    }

    /// The interrupt 003 ends the first turn; the stop 007 the second.
    @Test func anInterruptNotifiesNothingAndTheLaterStopDoes() throws {
        var recorder = Recorder()
        for batch in try codexBatches(.pretoolInterruptRecovery) { recorder.apply(batch.events, label: batch.label) }

        #expect(recorder.labels(wishing: .permission).isEmpty)
        #expect(recorder.labels(wishing: .turnFinished) == ["007"])
    }
}

// MARK: - Rules

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private let key = SessionKey(source: "tool", sessionID: "0123456789abcdef")

private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private func event(_ kind: AgentEvent.Kind, at seconds: TimeInterval, session: SessionKey = key) -> AgentEvent {
    AgentEvent(session: session, timestamp: at(seconds), kind: kind)
}

/// A session working on a prompt sent at 0.
private func working(_ session: SessionKey = key, cwd: String? = "/Users/user/projects/collective") -> [AgentEvent] {
    [
        event(.sessionStarted(cwd: cwd, pid: nil), at: 0, session: session),
        event(.promptSubmitted("Do it"), at: 0, session: session),
    ]
}

private let bash = ToolActivity(name: "Bash", detail: "rm -rf build")

/// Armed, with a session working since 0.
private func workingRecorder(_ preferences: NotificationPreferences = bothCases) -> Recorder {
    var recorder = Recorder()
    recorder.preferences = preferences
    recorder.apply(working(), label: "start")
    return recorder
}

@Suite struct NotificationPlannerRuleTests {
    @Test func aTurnEndOlderThanFiveMinutesNotifiesNothing() {
        var late = workingRecorder()
        late.apply([event(.turnEnded(), at: 10)], label: "end", now: at(10 + 5 * 60 + 1))
        #expect(late.wishes.isEmpty)

        var fresh = workingRecorder()
        fresh.apply([event(.turnEnded(), at: 10)], label: "end", now: at(10 + 5 * 60))
        #expect(fresh.labels(wishing: .turnFinished) == ["end"])
    }

    @Test func aRequestOlderThanFiveMinutesNotifiesNothing() {
        var late = workingRecorder()
        late.apply([event(.permissionRequested(agent: .root, bash), at: 10)], label: "ask", now: at(10 + 5 * 60 + 1))
        #expect(late.wishes.isEmpty)
    }

    @Test func aTurnEndReportedTwiceNotifiesOnce() {
        var recorder = workingRecorder()
        recorder.apply([event(.turnEnded(), at: 10)], label: "end")
        recorder.apply([event(.turnEnded(), at: 10)], label: "again")
        recorder.apply([event(.turnEnded(), at: 12)], label: "later")
        recorder.apply([event(.turnEnded(), at: 13), event(.turnEnded(), at: 13)], label: "twice in one batch")
        #expect(recorder.labels(wishing: .turnFinished) == ["end"])
    }

    @Test func onlyARegularTurnEndNotifies() {
        for outcome in [TurnOutcome.interrupted, .failed] {
            var recorder = workingRecorder()
            recorder.apply([event(.turnEnded(outcome), at: 10)], label: "end")
            #expect(recorder.wishes.isEmpty)
        }
    }

    /// A late `Stop` of the turn before the current one.
    @Test func anEndOlderThanTheTurnsStartNotifiesNothing() {
        var recorder = workingRecorder()
        recorder.apply([event(.promptSubmitted("Next"), at: 20)], label: "prompt")
        recorder.apply([event(.turnEnded(), at: 10)], label: "late end", now: at(20))
        #expect(recorder.wishes.isEmpty)
    }

    @Test func aTurnThatStartedLaterInTheBatchNotifiesNothing() {
        var recorder = workingRecorder()
        recorder.apply([event(.turnEnded(), at: 10), event(.turnStarted, at: 10)], label: "end and hand-back")
        #expect(recorder.wishes.isEmpty)
    }

    @Test func eachTurnNotifiesItsOwnEnd() {
        var recorder = workingRecorder()
        recorder.apply([event(.turnEnded(), at: 10)], label: "first")
        recorder.apply([event(.promptSubmitted("Next"), at: 20)], label: "prompt")
        recorder.apply([event(.turnEnded(), at: 30)], label: "second")
        #expect(recorder.labels(wishing: .turnFinished) == ["first", "second"])
        let first = recorder.wishes[0]
        #expect(recorder.label(withdrawing: first) == "prompt")
        #expect(recorder.wishes[0].id != recorder.wishes[1].id)
        #expect(recorder.wishes[0].threadID == recorder.wishes[1].threadID)
    }

    @Test func aRequestAnsweredInTheSameBatchNotifiesNothing() {
        var recorder = workingRecorder()
        recorder.apply([
            event(.permissionRequested(agent: .root, bash), at: 10),
            event(.toolFinished(agent: .root), at: 11),
        ], label: "ask and answer")
        #expect(recorder.wishes.isEmpty)
    }

    @Test func aRequestReportedTwiceNotifiesOnce() {
        var recorder = workingRecorder()
        recorder.apply([event(.permissionRequested(agent: .root, bash), at: 10)], label: "ask")
        recorder.apply([event(.permissionRequested(agent: .root, bash), at: 10)], label: "again")
        #expect(recorder.labels(wishing: .permission) == ["ask"])
        #expect(recorder.steps.allSatisfy { $0.plan.withdrawals.isEmpty })
    }

    /// Read with the backlog, then delivered again: no new request.
    @Test func aRequestAwaitedSinceTheBacklogNotifiesNothing() {
        var recorder = Recorder(armed: false)
        recorder.apply(working() + [event(.permissionRequested(agent: .root, bash), at: 10)], label: "backlog")
        #expect(recorder.planner.arm(recorder.state).isEmpty)
        recorder.apply([event(.permissionRequested(agent: .root, bash), at: 10)], label: "again")
        #expect(recorder.wishes.isEmpty)
        // A request of its own after the answer does.
        recorder.apply([event(.toolFinished(agent: .root), at: 11)], label: "answer")
        recorder.apply([event(.permissionRequested(agent: .root, bash), at: 12)], label: "ask")
        #expect(recorder.labels(wishing: .permission) == ["ask"])
    }

    @Test func anArchivedSessionNotifiesNothing() {
        var recorder = workingRecorder()
        recorder.state.archive(.session(key), at: at(5))
        recorder.apply([event(.permissionRequested(agent: .root, bash), at: 10)], label: "ask")
        recorder.apply([event(.turnEnded(), at: 11)], label: "end")
        #expect(recorder.wishes.isEmpty)
    }

    /// Started ahead of time and waiting for work: no session the user
    /// started.
    @Test func aStandbySessionNotifiesNothing() {
        var recorder = workingRecorder()
        recorder.apply([event(.activityReported(.standby), at: 1)], label: "standby")
        recorder.apply([event(.permissionRequested(agent: .root, bash), at: 10)], label: "ask")
        recorder.apply([event(.turnEnded(), at: 11)], label: "end")
        #expect(recorder.wishes.isEmpty)
    }

    @Test func aSessionGoneOnStandbyWithdrawsItsNotifications() throws {
        var recorder = workingRecorder()
        recorder.apply([event(.turnEnded(), at: 10)], label: "end")
        let wish = try #require(recorder.wishes.first)
        recorder.apply([event(.activityReported(.standby), at: 11)], label: "standby")
        #expect(recorder.label(withdrawing: wish) == "standby")
    }

    @Test func anArchivedSubagentAsksWithoutNotifying() {
        var recorder = workingRecorder()
        recorder.apply([event(.agentSpawned(id: "a1", parent: .root, spec: AgentSpec(type: "Explore")), at: 1)], label: "spawn")
        recorder.state.archive(.agent(key, .subagent("a1")), at: at(5))
        recorder.apply([event(.permissionRequested(agent: .subagent("a1"), bash), at: 10)], label: "ask")
        #expect(recorder.wishes.isEmpty)
    }

    /// By default a turn's end notifies once the turn lasted five minutes.
    @Test func byDefaultATurnOfFiveMinutesNotifies() {
        var short = workingRecorder(NotificationPreferences())
        short.apply([event(.turnEnded(), at: 299)], label: "end")
        #expect(short.wishes.isEmpty)

        var long = workingRecorder(NotificationPreferences())
        long.apply([event(.turnEnded(), at: 300)], label: "end")
        #expect(long.labels(wishing: .turnFinished) == ["end"])
    }

    /// A hand-back starts the turn but is no input: without a prompt or an
    /// answer, the turn counts from its start.
    @Test func withoutInputATurnCountsFromItsStart() {
        var recorder = Recorder()
        recorder.preferences = turnsAfter(5)
        recorder.apply([event(.sessionStarted(cwd: nil, pid: nil), at: 0), event(.turnStarted, at: 10)], label: "hand-back")
        recorder.apply([event(.turnEnded(), at: 14)], label: "short")
        recorder.apply([event(.turnStarted, at: 20)], label: "hand-back again")
        recorder.apply([event(.turnEnded(), at: 25)], label: "long")
        #expect(recorder.labels(wishing: .turnFinished) == ["long"])
    }

    /// Neither an input nor the turn's start known: only `always` notifies.
    @Test func aTurnOfUnknownLengthNotifiesOnlyAlways() {
        for (preferences, wished) in [(turnsAfter(5), false), (bothCases, true)] {
            var recorder = Recorder()
            recorder.preferences = preferences
            recorder.apply([event(.sessionStarted(cwd: nil, pid: nil), at: 0)], label: "start")
            recorder.apply([event(.turnEnded(), at: 600)], label: "end")
            #expect(recorder.labels(wishing: .turnFinished) == (wished ? ["end"] : []))
        }
    }

    /// Hooks run async: the call end that answered the request arrived
    /// before the turn's stop it preceded.
    @Test func anEndBeforeTheLastInputNotifiesOnlyAlways() {
        for (preferences, wished) in [(turnsAfter(1), false), (bothCases, true)] {
            var recorder = workingRecorder(preferences)
            recorder.apply([event(.permissionRequested(agent: .root, bash), at: 2)], label: "ask")
            recorder.apply([event(.toolFinished(agent: .root), at: 12)], label: "answered")
            recorder.apply([event(.turnEnded(), at: 10)], label: "end", now: at(12))
            #expect(recorder.labels(wishing: .turnFinished) == (wished ? ["end"] : []))
        }
    }

    @Test func permissionsCanBeTurnedOff() {
        var recorder = workingRecorder(NotificationPreferences(permission: false, turnFinishedAfter: .always))
        recorder.apply([event(.permissionRequested(agent: .root, bash), at: 10)], label: "ask")
        #expect(recorder.wishes.isEmpty)
    }

    @Test func aMutedToolNotifiesNothingAndOthersStillDo() {
        let other = SessionKey(source: "other", sessionID: "s2")
        var preferences = bothCases
        preferences.setNotifies(false, for: "tool")
        var recorder = workingRecorder(preferences)
        recorder.apply(working(other), label: "other start")
        recorder.apply([event(.turnEnded(), at: 10), event(.turnEnded(), at: 10, session: other)], label: "ends")
        #expect(recorder.wishes.map(\.session) == [other])
    }

    @Test func soundFollowsThePreference() {
        var preferences = bothCases
        preferences.sound = false
        var recorder = workingRecorder(preferences)
        recorder.apply([event(.turnEnded(), at: 10)], label: "end")
        #expect(recorder.wishes.map(\.playsSound) == [false])

        var withSound = workingRecorder()
        withSound.apply([event(.turnEnded(), at: 10)], label: "end")
        #expect(withSound.wishes.map(\.playsSound) == [true])
    }

    @Test func changingPreferencesWithdrawsNothing() {
        var recorder = workingRecorder()
        recorder.apply([event(.permissionRequested(agent: .root, bash), at: 10)], label: "ask")
        recorder.preferences = NotificationPreferences(permission: false, turnFinishedAfter: .never, mutedSources: ["tool"])
        recorder.apply([event(.modelChanged(to: "m", from: nil), at: 11)], label: "other")
        #expect(recorder.steps.allSatisfy { $0.plan.withdrawals.isEmpty })
    }

    @Test func aSessionGoneStaleWithdrawsItsRequest() throws {
        var recorder = workingRecorder()
        recorder.apply([event(.permissionRequested(agent: .root, bash), at: 10)], label: "ask")
        let wish = try #require(recorder.wishes.first)
        #expect(recorder.planner.reconcile(recorder.state).isEmpty)

        recorder.state.markStale(now: at(13 * 3_600), silenceTimeout: 30 * 60, waitingTimeout: 12 * 3_600) { _ in nil }
        #expect(recorder.planner.reconcile(recorder.state) == [wish.id])
        #expect(recorder.planner.reconcile(recorder.state).isEmpty)
    }

    @Test func aPrunedSessionWithdrawsItsRequest() throws {
        var recorder = workingRecorder()
        recorder.apply([event(.permissionRequested(agent: .root, bash), at: 10)], label: "ask")
        let wish = try #require(recorder.wishes.first)
        // Ended without an answer: the agent is done, so the request is over.
        recorder.apply([event(.sessionEnded, at: 20)], label: "end")
        #expect(recorder.label(withdrawing: wish) == "end")

        var pruned = workingRecorder()
        pruned.apply([event(.permissionRequested(agent: .root, bash), at: 10)], label: "ask")
        pruned.state.markStale(now: at(13 * 3_600), silenceTimeout: 30 * 60, waitingTimeout: 12 * 3_600) { _ in nil }
        pruned.state.prune(now: at(15 * 3_600), retention: 3_600)
        #expect(pruned.state.sessions.isEmpty)
        #expect(pruned.planner.reconcile(pruned.state) == [try #require(pruned.wishes.first).id])
    }

    @Test func aPrunedSessionWithdrawsItsFinishedTurn() throws {
        var recorder = workingRecorder()
        recorder.apply([event(.turnEnded(), at: 10)], label: "end")
        let wish = try #require(recorder.wishes.first)
        #expect(recorder.planner.reconcile(recorder.state).isEmpty)
        recorder.state.markStale(now: at(13 * 3_600), silenceTimeout: 30 * 60, waitingTimeout: 12 * 3_600) { _ in nil }
        recorder.state.prune(now: at(15 * 3_600), retention: 3_600)
        #expect(recorder.planner.reconcile(recorder.state) == [wish.id])
    }

    /// Archiving says the user has seen to it.
    @Test func archivingASessionWithdrawsItsNotifications() throws {
        var recorder = workingRecorder()
        recorder.apply([event(.permissionRequested(agent: .root, bash), at: 10)], label: "ask")
        recorder.apply([event(.toolFinished(agent: .root), at: 11), event(.turnEnded(), at: 12)], label: "end")
        let finished = try #require(recorder.wishes.first { $0.kind == .turnFinished })
        #expect(recorder.planner.reconcile(recorder.state).isEmpty)

        recorder.state.archive(.session(key), at: at(20))
        #expect(recorder.planner.reconcile(recorder.state) == [finished.id])
        #expect(recorder.planner.reconcile(recorder.state).isEmpty)
    }

    @Test func archivingASubagentWithdrawsOnlyItsRequest() throws {
        var recorder = workingRecorder()
        recorder.apply([
            event(.agentSpawned(id: "a1", parent: .root, spec: AgentSpec(type: "Explore")), at: 1),
            event(.agentSpawned(id: "a2", parent: .subagent("a1"), spec: AgentSpec(type: "Plan")), at: 2),
        ], label: "spawn")
        recorder.apply([event(.permissionRequested(agent: .subagent("a2"), bash), at: 10)], label: "child asks")
        recorder.apply([event(.permissionRequested(agent: .root, bash), at: 10)], label: "root asks")
        let child = try #require(recorder.wishes.first)
        #expect(recorder.wishes.count == 2)

        // The child goes with its parent's subtree.
        recorder.state.archive(.agent(key, .subagent("a1")), at: at(20))
        #expect(recorder.planner.reconcile(recorder.state) == [child.id])
        #expect(recorder.planner.reconcile(recorder.state).isEmpty)
    }

    /// The reader starts over: the rebuilt state is in flux until its backlog
    /// is read, so only arming again reconciles.
    @Test func disarmedNothingIsWithdrawnUntilArmedAgain() throws {
        var recorder = workingRecorder()
        recorder.apply([event(.permissionRequested(agent: .root, bash), at: 10)], label: "ask")
        let wish = try #require(recorder.wishes.first)

        recorder.planner.disarm()
        recorder.state = CollectiveState()
        #expect(recorder.planner.reconcile(recorder.state).isEmpty)
        recorder.apply(working() + [event(.permissionRequested(agent: .root, bash), at: 10)], label: "backlog")
        #expect(recorder.steps.last?.plan == NotificationPlan())
        #expect(recorder.planner.arm(recorder.state).isEmpty)

        recorder.apply([event(.toolFinished(agent: .root), at: 12)], label: "answer")
        #expect(recorder.label(withdrawing: wish) == "answer")
    }
}

// MARK: - Texts

@Suite struct NotificationTextTests {
    @Test func theTitleIsTheCardsAndTheSubtitleTheTools() throws {
        var recorder = workingRecorder()
        recorder.apply([event(.turnEnded(), at: 10)], label: "end")
        let wish = try #require(recorder.wishes.first)
        #expect(wish.title == "collective")
        #expect(wish.subtitle == "Tool")
        #expect(wish.session == key)
    }

    @Test func aToolWithoutDisplayNameShowsItsID() throws {
        let unnamed = SessionKey(source: "unnamed", sessionID: "s")
        var recorder = workingRecorder()
        recorder.apply(working(unnamed), label: "start")
        recorder.apply([event(.turnEnded(), at: 10, session: unnamed)], label: "end")
        #expect(recorder.wishes.map(\.subtitle) == ["unnamed"])
    }

    @Test func theOrchestratorAsks() {
        var recorder = workingRecorder()
        recorder.apply([event(.permissionRequested(agent: .root, bash), at: 10)], label: "with detail")
        recorder.apply([event(.toolFinished(agent: .root), at: 11)], label: "answer")
        recorder.apply([event(.permissionRequested(agent: .root, ToolActivity(name: "WebFetch")), at: 12)], label: "without")
        #expect(recorder.wishes.map(\.body) == [
            "Needs your permission: Bash · rm -rf build",
            "Needs your permission: WebFetch",
        ])
    }

    /// Only the popover's command box shows a multi-line command whole.
    @Test func aMultiLineCommandAsksWithItsFirstLine() {
        var recorder = workingRecorder()
        let heredoc = ToolActivity(name: "Bash", detail: "cat <<EOF", fullDetail: "cat <<EOF\nsecret\nEOF")
        recorder.apply([event(.permissionRequested(agent: .root, heredoc), at: 10)], label: "ask")
        #expect(recorder.wishes.map(\.body) == ["Needs your permission: Bash · cat <<EOF"])
    }

    @Test func aSubagentAsksByItsType() {
        var recorder = workingRecorder()
        recorder.apply([
            event(.agentSpawned(id: "a1", parent: .root, spec: AgentSpec(type: "Explore")), at: 1),
            event(.agentSpawned(id: "a2", parent: .root, spec: AgentSpec()), at: 1),
        ], label: "spawn")
        recorder.apply([event(.permissionRequested(agent: .subagent("a1"), bash), at: 10)], label: "typed")
        recorder.apply([event(.permissionRequested(agent: .subagent("a2"), ToolActivity(name: "Read")), at: 10)], label: "typeless")
        recorder.apply([event(.permissionRequested(agent: .subagent("a1"), ToolActivity(name: "Read")), at: 11)], label: "typed, no detail")
        recorder.apply([event(.permissionRequested(agent: .subagent("a2"), bash), at: 11)], label: "typeless, detail")
        #expect(recorder.wishes.map(\.body) == [
            "Explore needs your permission: Bash · rm -rf build",
            "A subagent needs your permission: Read",
            "Explore needs your permission: Read",
            "A subagent needs your permission: Bash · rm -rf build",
        ])
        #expect(Set(recorder.wishes.map(\.id)).count == 4)
    }

    @Test func aFinishedTurnShowsTheReplyAsPlainText() {
        var recorder = workingRecorder()
        recorder.apply([
            event(.replied(agent: .root, "All **tests** pass.\n\nSee `build.log`."), at: 10),
            event(.turnEnded(), at: 10),
        ], label: "end")
        #expect(recorder.wishes.map(\.body) == ["All tests pass.\nSee build.log."])
    }

    @Test func aFinishedTurnWithoutReplySaysSo() {
        var none = workingRecorder()
        none.apply([event(.turnEnded(), at: 10)], label: "end")
        var blank = workingRecorder()
        blank.apply([event(.replied(agent: .root, "  \n"), at: 10), event(.turnEnded(), at: 10)], label: "end")
        #expect((none.wishes + blank.wishes).map(\.body) == ["Finished its turn", "Finished its turn"])
    }

    @Test func aLongReplyIsCut() throws {
        let word = "lighthouse "
        let reply = String(repeating: word, count: 40)
        var recorder = workingRecorder()
        recorder.apply([event(.replied(agent: .root, reply), at: 10), event(.turnEnded(), at: 10)], label: "end")
        let body = try #require(recorder.wishes.first?.body)
        // Between two words.
        #expect(body.count <= 300)
        #expect(body.count > 280)
        #expect(body.hasSuffix(" lighthouse…"))
        #expect(body.hasPrefix(word))
    }

    @Test func aReplyWithinTheLimitStaysWhole() {
        let reply = String(repeating: "x", count: 300)
        #expect(NotificationPlanner.cut(reply) == reply)
        // A word longer than the limit is cut inside.
        #expect(NotificationPlanner.cut(reply + "y") == String(repeating: "x", count: 299) + "…")
        #expect(NotificationPlanner.cut("See " + reply) == "See " + String(repeating: "x", count: 295) + "…")
    }
}

@Suite struct SessionTitleTests {
    private func session(name: String? = nil, cwd: String?) throws -> Session {
        var state = CollectiveState()
        state.apply(event(.sessionStarted(cwd: cwd, pid: nil), at: 0))
        if let name { state.apply(event(.sessionNamed(name), at: 1)) }
        return try #require(state.sessions[key])
    }

    @Test func theToolsNameComesFirst() throws {
        #expect(try session(name: "Fix the build", cwd: "/Users/user/collective").title == "Fix the build")
    }

    @Test func thenTheProjectFolder() throws {
        #expect(try session(cwd: "/Users/user/collective").title == "collective")
    }

    @Test func thenTheStartOfTheID() throws {
        #expect(try session(cwd: nil).title == "01234567")
    }
}

// MARK: - Preferences

@Suite struct NotificationPreferencesTests {
    @Test func defaultsNotifyPermissionsWithSoundAndTurnsOverFiveMinutes() {
        let preferences = NotificationPreferences()
        #expect(preferences.permission)
        #expect(preferences.turnFinishedAfter == .fiveMinutes)
        #expect(preferences.sound)
    }

    /// The settings popup lists them in this order, `never` after a divider.
    @Test func theTurnThresholdsInThePopupsOrder() {
        #expect(TurnFinishedAfter.allCases == [
            .always, .oneMinute, .threeMinutes, .fiveMinutes, .tenMinutes, .thirtyMinutes, .never,
        ])
        #expect(TurnFinishedAfter.default == .fiveMinutes)
        let texts = TurnFinishedAfter.allCases.map { option in
            var resource = option.optionText
            resource.locale = english
            return String(localized: resource)
        }
        #expect(texts == [
            "Always", "After 1 minute", "After 3 minutes", "After 5 minutes", "After 10 minutes", "After 30 minutes", "Never",
        ])
    }

    @Test func aToolNeverSeenNotifies() {
        var preferences = NotificationPreferences()
        preferences.setNotifies(false, for: "codex")
        #expect(!preferences.notifies(for: "codex"))
        #expect(preferences.notifies(for: "tool-added-later"))
        preferences.setNotifies(true, for: "codex")
        #expect(preferences.notifies(for: "codex"))
    }

    @Test func theStoredFormRoundTrips() {
        let preferences = NotificationPreferences(permission: false, turnFinishedAfter: .always, sound: false, mutedSources: ["codex", "claude-code"])
        #expect(NotificationPreferences(fromStored: preferences.stored) == preferences)
        #expect(preferences.stored["mutedSources"] as? [String] == ["claude-code", "codex"])
        let quiet = NotificationPreferences(question: false)
        #expect(NotificationPreferences(fromStored: quiet.stored) == quiet)
    }

    @Test(arguments: TurnFinishedAfter.allCases)
    func everyTurnThresholdRoundTrips(_ option: TurnFinishedAfter) {
        let preferences = NotificationPreferences(turnFinishedAfter: option)
        #expect(NotificationPreferences(fromStored: preferences.stored) == preferences)
        #expect(preferences.stored["turnFinished"] == nil)
    }

    /// Once a switch: on notified every turn's end, so it stays
    /// `always`; off, missing or damaged takes the default.
    @Test func theFormerSwitchMigrates() {
        #expect(NotificationPreferences(fromStored: ["turnFinished": true]).turnFinishedAfter == .always)
        #expect(NotificationPreferences(fromStored: ["turnFinished": false]).turnFinishedAfter == .fiveMinutes)
        #expect(NotificationPreferences(fromStored: ["turnFinished": "yes"]).turnFinishedAfter == .fiveMinutes)
        #expect(NotificationPreferences(fromStored: ["permission": true]).turnFinishedAfter == .fiveMinutes)
    }

    /// Once the threshold is stored, the former switch says nothing.
    @Test func aStoredThresholdWinsOverTheFormerSwitch() {
        let stored: [String: Any] = ["turnFinishedAfter": "never", "turnFinished": true]
        #expect(NotificationPreferences(fromStored: stored).turnFinishedAfter == .never)
        let damaged: [String: Any] = ["turnFinishedAfter": "sometimes", "turnFinished": true]
        #expect(NotificationPreferences(fromStored: damaged).turnFinishedAfter == .fiveMinutes)
        #expect(NotificationPreferences(fromStored: ["turnFinishedAfter": 5]).turnFinishedAfter == .fiveMinutes)
    }

    /// Stored before questions notified: they notify, as by default.
    @Test func questionsNotifyByDefaultAlsoForPreferencesStoredWithoutThem() {
        #expect(NotificationPreferences().question)
        let older: [String: Any] = ["permission": false, "turnFinished": true, "sound": true, "mutedSources": ["codex"]]
        let preferences = NotificationPreferences(fromStored: older)
        #expect(preferences.question)
        #expect(!preferences.permission)
    }

    @Test func nothingOrDamagedStoredFallsBackToTheDefaults() {
        #expect(NotificationPreferences(fromStored: nil) == NotificationPreferences())
        #expect(NotificationPreferences(fromStored: "junk") == NotificationPreferences())
        let damaged: [String: Any] = ["permission": "yes", "turnFinishedAfter": "always", "mutedSources": 3]
        #expect(NotificationPreferences(fromStored: damaged) == NotificationPreferences(turnFinishedAfter: .always))
    }
}

// MARK: - Questions

private let tea = Question(header: "Drink", text: "Tea or coffee?", options: [QuestionOption(label: "Tea"), QuestionOption(label: "Coffee")], allowsOwnAnswer: true)
private let milk = Question(text: "Milk?", options: [QuestionOption(label: "Yes"), QuestionOption(label: "No")], allowsOwnAnswer: true)

/// An agent asks the user: notified like a permission request, once
/// per dialog, and withdrawn once it is no longer awaited.
@Suite struct QuestionNotificationTests {
    private func asked(_ questions: [Question] = [tea], by agent: AgentRef = .root, at seconds: TimeInterval = 10, callID: String? = "c1") -> AgentEvent {
        event(.questionAsked(agent: agent, questions, callID: callID), at: seconds)
    }

    /// S4 asks with 026, again through the dialog's hook (028); the status
    /// file says `busy` with the answer (030), right before its hook (031).
    @Test func theCapturedQuestionNotifiesOnceAndIsWithdrawnWithItsAnswer() throws {
        var recorder = Recorder()
        try Timeline("4-waiting-permission-question").record(into: &recorder)
        #expect(recorder.labels(wishing: .question) == ["026"])
        let wish = try #require(recorder.wishes.first { $0.kind == .question })
        #expect(wish.body == "Question for you: Which color do you like?\n1 Red · 2 Blue · 3 Other")
        #expect(wish.subtitle == "Claude Code")
        #expect(recorder.label(withdrawing: wish) == "030")

        var hooksOnly = Recorder()
        try Timeline("4-waiting-permission-question").record(into: &hooksOnly, statuses: false)
        #expect(hooksOnly.labels(wishing: .question) == ["026"])
        #expect(hooksOnly.label(withdrawing: try #require(hooksOnly.wishes.first { $0.kind == .question })) == "031")
    }

    /// S19's third dialog asks with 031 and again through the dialog's hook
    /// (033), then is dismissed with Esc, which sends no hook: only the
    /// status file going `idle` (035) withdraws it. The two dialogs before
    /// were answered.
    @Test func aDismissedQuestionIsWithdrawnWhenTheStatusFileSaysIdle() throws {
        var recorder = Recorder()
        try Timeline("19-ask-user-question", version: "2.1.316").record(into: &recorder)
        #expect(recorder.labels(wishing: .question) == ["008", "020", "031"])
        let dismissed = try #require(recorder.wishes.last { $0.kind == .question })
        #expect(dismissed.body == "Question for you: Tea or coffee?\n1 tea · 2 coffee · 3 Other")
        #expect(recorder.label(withdrawing: dismissed) == "035")
    }

    /// Armed between the two asks: the dialog was asked before, so it is no new one.
    @Test func aDialogAskedBeforeArmingNotifiesNothing() throws {
        var recorder = Recorder(armed: false)
        let batches = try Timeline("4-waiting-permission-question").batches()
        for batch in batches where batch.label <= "026" { recorder.apply(batch.events, label: batch.label) }
        #expect(recorder.planner.arm(recorder.state).isEmpty)
        for batch in batches where batch.label > "026" { recorder.apply(batch.events, label: batch.label) }
        #expect(recorder.labels(wishing: .question).isEmpty)
    }

    /// The dialog's second ask moves the request's time and names no call:
    /// still the same dialog, neither notified again nor withdrawn.
    @Test func theSameDialogAskedAgainLaterNotifiesOnce() {
        var recorder = workingRecorder()
        recorder.apply([asked(at: 10)], label: "start")
        recorder.apply([asked(at: 12, callID: nil)], label: "dialog")
        recorder.apply([asked(at: 13, callID: nil)], label: "again")
        #expect(recorder.labels(wishing: .question) == ["start"])
        #expect(recorder.steps.allSatisfy { $0.plan.withdrawals.isEmpty })
    }

    @Test func bothAsksInOneBatchNotifyOnce() {
        var recorder = workingRecorder()
        recorder.apply([asked(at: 10), asked(at: 11, callID: nil)], label: "both")
        #expect(recorder.wishes.count == 1)
    }

    @Test func aNewDialogAfterTheAnswerNotifiesAgain() throws {
        var recorder = workingRecorder()
        recorder.apply([asked(at: 10)], label: "first")
        recorder.apply([event(.questionAnswered(agent: .root, [tea], callID: "c1"), at: 11)], label: "answer")
        recorder.apply([asked(at: 12, callID: "c2")], label: "second")
        #expect(recorder.labels(wishing: .question) == ["first", "second"])
        let first = try #require(recorder.wishes.first)
        #expect(recorder.label(withdrawing: first) == "answer")
        #expect(recorder.wishes[0].id != recorder.wishes[1].id)
    }

    @Test func aQuestionAnsweredInTheSameBatchNotifiesNothing() {
        var recorder = workingRecorder()
        recorder.apply([asked(at: 10), event(.questionAnswered(agent: .root, [tea], callID: "c1"), at: 11)], label: "ask and answer")
        #expect(recorder.wishes.isEmpty)
    }

    @Test func aQuestionOlderThanFiveMinutesNotifiesNothing() {
        var late = workingRecorder()
        late.apply([asked(at: 10)], label: "ask", now: at(10 + 5 * 60 + 1))
        #expect(late.wishes.isEmpty)
    }

    @Test func questionsCanBeTurnedOffOnTheirOwn() {
        var off = workingRecorder(NotificationPreferences(permission: true, question: false, turnFinishedAfter: .always))
        off.apply([asked()], label: "ask")
        #expect(off.wishes.isEmpty)

        var permissionOff = workingRecorder(NotificationPreferences(permission: false))
        permissionOff.apply([asked()], label: "ask")
        #expect(permissionOff.labels(wishing: .question) == ["ask"])
    }

    @Test func aMutedToolNotifiesNoQuestion() {
        var preferences = bothCases
        preferences.setNotifies(false, for: "tool")
        var recorder = workingRecorder(preferences)
        recorder.apply([asked()], label: "ask")
        #expect(recorder.wishes.isEmpty)
    }

    @Test func anArchivedSessionOrSubagentNotifiesNothing() {
        var session = workingRecorder()
        session.state.archive(.session(key), at: at(5))
        session.apply([asked()], label: "ask")
        #expect(session.wishes.isEmpty)

        var subagent = workingRecorder()
        subagent.apply([event(.agentSpawned(id: "a1", parent: .root, spec: AgentSpec(type: "Explore")), at: 1)], label: "spawn")
        subagent.state.archive(.agent(key, .subagent("a1")), at: at(5))
        subagent.apply([asked(by: .subagent("a1"))], label: "ask")
        #expect(subagent.wishes.isEmpty)
    }

    @Test func archivingWithdrawsTheQuestion() throws {
        var recorder = workingRecorder()
        recorder.apply([asked()], label: "ask")
        let wish = try #require(recorder.wishes.first)
        #expect(recorder.planner.reconcile(recorder.state).isEmpty)
        recorder.state.archive(.session(key), at: at(20))
        #expect(recorder.planner.reconcile(recorder.state) == [wish.id])
    }

    @Test func theSessionEndingGoingStaleOrDroppingOutWithdrawsTheQuestion() throws {
        var ended = workingRecorder()
        ended.apply([asked()], label: "ask")
        ended.apply([event(.sessionEnded, at: 20)], label: "end")
        #expect(ended.label(withdrawing: try #require(ended.wishes.first)) == "end")

        var stale = workingRecorder()
        stale.apply([asked()], label: "ask")
        let wish = try #require(stale.wishes.first)
        stale.state.markStale(now: at(13 * 3_600), silenceTimeout: 30 * 60, waitingTimeout: 12 * 3_600) { _ in nil }
        #expect(stale.planner.reconcile(stale.state) == [wish.id])

        // No longer shown: a spare process waiting for work.
        var standby = workingRecorder()
        standby.apply([asked()], label: "ask")
        standby.apply([event(.activityReported(.standby), at: 20)], label: "standby")
        #expect(standby.label(withdrawing: try #require(standby.wishes.first)) == "standby")
    }

    /// The app's sweep goes stale and prunes in one go, without an event in
    /// between: the reconcile after it withdraws what the dropped session asked.
    @Test func aPrunedSessionWithdrawsItsQuestion() throws {
        var recorder = workingRecorder()
        recorder.apply([asked()], label: "ask")
        let wish = try #require(recorder.wishes.first)
        recorder.state.markStale(now: at(13 * 3_600), silenceTimeout: 30 * 60, waitingTimeout: 12 * 3_600) { _ in nil }
        recorder.state.prune(now: at(15 * 3_600), retention: 3_600)
        #expect(recorder.state.sessions.isEmpty)
        #expect(recorder.planner.reconcile(recorder.state) == [wish.id])
        #expect(recorder.planner.reconcile(recorder.state).isEmpty)
    }

    // MARK: Texts

    @Test func theOrchestratorAsks() throws {
        var recorder = workingRecorder()
        recorder.apply([asked()], label: "ask")
        let wish = try #require(recorder.wishes.first)
        #expect(wish.kind == .question)
        #expect(wish.title == "collective")
        #expect(wish.subtitle == "Tool")
        #expect(wish.body == "Question for you: Tea or coffee?\n1 Tea · 2 Coffee · 3 Other")
    }

    @Test func aSubagentAsksByItsType() {
        var recorder = workingRecorder()
        recorder.apply([
            event(.agentSpawned(id: "a1", parent: .root, spec: AgentSpec(type: "Explore")), at: 1),
            event(.agentSpawned(id: "a2", parent: .root, spec: AgentSpec()), at: 1),
        ], label: "spawn")
        recorder.apply([asked(by: .subagent("a1"), callID: "c1")], label: "typed")
        recorder.apply([asked(by: .subagent("a2"), callID: "c2")], label: "typeless")
        #expect(recorder.wishes.map(\.body) == [
            "Explore has a question for you: Tea or coffee?\n1 Tea · 2 Coffee · 3 Other",
            "A subagent has a question for you: Tea or coffee?\n1 Tea · 2 Coffee · 3 Other",
        ])
        #expect(Set(recorder.wishes.map(\.id)).count == 2)
    }

    @Test func moreQuestionsAreCounted() {
        var recorder = workingRecorder()
        recorder.apply([asked([tea, milk])], label: "two")
        #expect(recorder.wishes.map(\.body) == ["Question for you: Tea or coffee?\n1 Tea · 2 Coffee · 3 Other\n+1 more question"])
    }

    /// "Other" is the source's free-text entry, not a choice of every tool.
    @Test func aQuestionWithoutAnOwnAnswerListsOnlyItsOptions() {
        var recorder = workingRecorder()
        recorder.apply([asked([Question(text: "Tea or coffee?", options: [QuestionOption(label: "Tea"), QuestionOption(label: "Coffee")])])], label: "ask")
        #expect(recorder.wishes.map(\.body) == ["Question for you: Tea or coffee?\n1 Tea · 2 Coffee"])
    }

    /// The descriptions belong to the popover card; the banner stays one line.
    @Test func optionDescriptionsStayOutOfTheBody() {
        var recorder = workingRecorder()
        let described = Question(text: "Tea or coffee?", options: [QuestionOption(label: "Tea", detail: "Green, hot"), QuestionOption(label: "Coffee", detail: "Black")], allowsOwnAnswer: true)
        recorder.apply([asked([described])], label: "ask")
        #expect(recorder.wishes.map(\.body) == ["Question for you: Tea or coffee?\n1 Tea · 2 Coffee · 3 Other"])
    }

    @Test func aQuestionWithoutOptionsHasOneLine() {
        var recorder = workingRecorder()
        recorder.apply([asked([Question(text: "Anything else?"), milk, tea])], label: "ask")
        #expect(recorder.wishes.map(\.body) == ["Question for you: Anything else?\n+2 more questions"])
    }
}

@Suite struct NotificationUserInfoTests {
    private let key = SessionKey(source: "claude-code", sessionID: "6f1c")

    @Test func aClickedNotificationNamesTheSessionItWasPostedFor() {
        let userInfo: [AnyHashable: Any] = SessionKey.notificationUserInfo(for: key)
        #expect(SessionKey(notificationUserInfo: userInfo) == key)
    }

    /// The previous run's notifications carry no key; a click on them opens the popover.
    @Test(arguments: [
        [:],
        ["source": "claude-code"],
        ["sessionID": "6f1c"],
    ] as [[String: String]])
    func withoutAWholeKeyItNamesNoSession(userInfo: [String: String]) {
        #expect(SessionKey(notificationUserInfo: userInfo) == nil)
    }

    @Test func aKeyThatIsNoTextNamesNoSession() {
        #expect(SessionKey(notificationUserInfo: ["source": 1, "sessionID": "6f1c"]) == nil)
    }
}
