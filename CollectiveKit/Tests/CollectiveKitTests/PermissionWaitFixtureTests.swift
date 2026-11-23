import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

// MARK: - Codex

/// When each hook file of the run was delivered (`delivery-seconds.json`,
/// see the fixtures' README). Codex sends a call's `PreToolUse` and its
/// `PermissionRequest` in the same second, before the user answers; replayed
/// one second apart, the call's own start would look like a later one.
private func deliverySeconds(_ run: CodexRun) throws -> [String: TimeInterval] {
    let data = try Data(contentsOf: run.directory.appendingPathComponent("delivery-seconds.json"))
    return try JSONDecoder().decode([String: TimeInterval].self, from: data)
}

/// The run replayed through the hook file starting with `last`, all when nil,
/// with what holds after each file.
private func replayCodex(_ run: CodexRun, through last: String? = nil, after: (String, CollectiveState) -> Void = { _, _ in }) throws -> CollectiveState {
    let seconds = try deliverySeconds(run)
    let adapter = run.adapter()
    var state = CollectiveState()
    for file in run.files {
        let second = try #require(seconds[file.name])
        let envelope = Envelope(source: "codex", pid: 4242, payload: file.payload, receivedAt: Date(timeIntervalSince1970: second))
        for event in try adapter.events(from: envelope) { state.apply(event) }
        after(file.name, state)
        if let last, file.name.hasPrefix(last) { break }
    }
    return state
}

/// The hook files after which the run's session awaits permission.
private func codexFilesAwaitingPermission(_ run: CodexRun) throws -> [String] {
    var awaiting: [String] = []
    _ = try replayCodex(run) { name, state in
        if state.awaitsPermission { awaiting.append(String(name.prefix(3))) }
    }
    return awaiting
}

/// Reducer seam with captured Codex runs: a request waits until the call's end
/// or the end of its turn; the call's own start, sent alongside, is no answer.
@Suite struct CodexPermissionWaitTests {
    /// Both writes were approved by the automatic reviewer.
    @Test func aRequestWaitsUntilItsCallEnds() throws {
        #expect(try codexFilesAwaitingPermission(.daemonCompact) == ["004", "008", "009"])
    }

    /// 003 approved, 008 rejected (the interrupt 010 ends the turn without a
    /// post), 012 approved with its prefix remembered, so 017 asks nothing.
    @Test func aRejectedRequestWaitsUntilTheInterruptAndARememberedOneNeverAsks() throws {
        #expect(try codexFilesAwaitingPermission(.manualPermission) == ["003", "004", "008", "009", "012", "013"])
    }

    /// Codex names no process, so silence decides; a session at the dialog
    /// sends nothing until the user answers, however long that takes.
    @Test func aSessionAtTheDialogOutlastsTheSilenceTimeout() throws {
        var state = try replayCodex(.manualPermission, through: "009")
        let session = try #require(state.sessions.values.first)
        #expect(session.awaitsPermission)
        let last = session.lastActivity

        state.markStale(now: last.addingTimeInterval(40 * 60), silenceTimeout: 30 * 60, waitingTimeout: 12 * 3_600) { _ in nil }
        #expect(state.sessions.values.first?.endedAt == nil)
        #expect(state.awaitsPermission)
        state.markStale(now: last.addingTimeInterval(12 * 3_600 + 1), silenceTimeout: 30 * 60, waitingTimeout: 12 * 3_600) { _ in nil }
        #expect(state.sessions.values.first?.root.status == .stale)
    }
}

// MARK: - Claude Code

/// Reducer seam with captured Claude Code runs: a request waits until the
/// status file reports the session working again or idle, or a hook shows the
/// agent going on. `waiting` in the status file is no request of its own: it
/// also stands for questions and the exit dialog.
@Suite struct ClaudeCodePermissionWaitTests {
    private let run = Timeline("4-waiting-permission-question")

    /// The timeline entries after which the session awaits permission.
    private func entriesAwaitingPermission(statuses: Bool = true) throws -> [Int] {
        try run.entries
            .filter { statuses || $0.isHook }
            .filter { try run.replay(through: $0.n, statuses: statuses).awaitsPermission }
            .map(\.n)
    }

    /// 010 is approved (status `busy` in 012), 021 rejected (status `idle` in
    /// 023, no hook at all); 028, the question, asks nothing, though the status
    /// file says `waiting` (027) like for both requests (008, 020).
    @Test func aRequestWaitsUntilTheStatusFileSaysTheAnswer() throws {
        #expect(run.snapshotStatus(run.entry(n: 27)) == "waiting")
        #expect(try entriesAwaitingPermission() == [10, 11, 21, 22])
    }

    /// Without the status file the approval shows only with the call's end
    /// (013), the rejection only with the next prompt (025).
    @Test func hooksAloneWaitUntilTheCallEndsOrTheNextPrompt() throws {
        #expect(try entriesAwaitingPermission(statuses: false) == [10, 11, 21, 22])
    }

    /// 2.1.285 run 3: the request 006 for a `Read`, approved, ends with 008.
    @Test func anApprovedReadWaitsUntilItsEnd() throws {
        let adapter = Run.permission.adapter()
        var state = CollectiveState()
        var awaiting: [Int] = []
        for (index, payload) in Run.permission.payloads.enumerated() {
            let envelope = Envelope(source: "claude-code", pid: 4242, payload: payload, receivedAt: Date(timeIntervalSince1970: 1_000 + TimeInterval(index)))
            for event in try adapter.events(from: envelope) { state.apply(event) }
            if state.awaitsPermission { awaiting.append(index + 1) }
        }
        #expect(awaiting == [6, 7])
    }
}

// MARK: - Popover row

/// The restyled row of a captured request: its status and its command box.
@Suite struct PermissionRowFixtureTests {
    private func row(_ state: CollectiveState) throws -> SessionItem {
        let last = try #require(state.sessions.values.first?.lastActivity)
        let model = PopoverModel(state: state, now: last.addingTimeInterval(1), settings: PopoverSettings(idleAfter: .never))
        return try #require(model.sessions.first)
    }

    /// The command box names what the request asks to run (`manual-permission`, 003).
    @Test func aCodexRequestShowsItsCommand() throws {
        let item = try row(try replayCodex(.manualPermission, through: "003"))
        #expect(item.rowStatus == .needsPermission)
        guard case let .permission(command)? = item.rowDetail else {
            Issue.record("no command box: \(String(describing: item.rowDetail))")
            return
        }
        #expect(command.toolName == "Bash")
        #expect(command.command == #"printf 'manual-approved\n' > captures/manual-permission-approved-probe"#)
    }

    private func commandBox(_ item: SessionItem) -> PermissionCommand? {
        if case let .permission(command)? = item.rowDetail { command } else { nil }
    }

    /// Approved (status `busy` in 012) or rejected (status `idle` in 023), the
    /// row leaves the request and its box; the second request (021) shows its
    /// own command, not the first's.
    @Test func aClaudeCodeRowDropsTheBoxOnceAnsweredAndShowsTheNewerRequest() throws {
        let run = Timeline("4-waiting-permission-question")
        for n in [12, 13, 23, 25] {
            let item = try row(try run.replay(through: n))
            #expect(item.rowStatus != .needsPermission, "entry \(n)")
            #expect(commandBox(item) == nil, "entry \(n)")
        }
        let second = try row(try run.replay(through: 21))
        #expect(second.rowStatus == .needsPermission)
        #expect(commandBox(second)?.command == "touch captures/perm-two")
    }

    /// `manual-permission`: the rejected request 008 ends with the interrupt
    /// 010; the next request 012 shows its own command.
    @Test func aCodexRowDropsTheBoxAfterTheRejectionsInterruptAndShowsTheNewerRequest() throws {
        let denied = try row(try replayCodex(.manualPermission, through: "008"))
        #expect(commandBox(denied)?.command == #"printf 'manual-denied\n' > captures/manual-permission-denied-probe"#)

        let interrupted = try row(try replayCodex(.manualPermission, through: "010"))
        #expect(interrupted.rowStatus != .needsPermission)
        #expect(commandBox(interrupted) == nil)

        let next = try row(try replayCodex(.manualPermission, through: "012"))
        #expect(next.rowStatus == .needsPermission)
        #expect(commandBox(next)?.command == #"printf 'manual-approved\n' > captures/manual-permission-approved-probe"#)
    }

    /// 0.167.0 under the manual reviewer: approved (post 005), then denied
    /// (009), which only the interrupt 010 ends.
    @Test func aCodexRowUnderTheManualReviewerDropsTheBoxAfterEachAnswer() throws {
        let run = CodexReviewRun.manual
        let adapter = run.adapter()
        var state = CollectiveState()
        var boxes: [String: String?] = [:]
        for (index, file) in run.files.enumerated() {
            let envelope = Envelope(source: "codex", pid: 4242, payload: file.payload, receivedAt: Date(timeIntervalSince1970: 1_000 + TimeInterval(index)))
            for event in try adapter.events(from: envelope) { state.apply(event) }
            boxes[String(file.name.prefix(3))] = commandBox(try row(state))?.command
        }
        #expect(boxes["004"] == #"printf 'manual-review-probe\n' > "$HOME/subspace-auto-review-probe.txt""#)
        #expect(boxes["005"] == .some(nil))
        #expect(boxes["009"] == #"printf 'manual-denied\n' > "$HOME/subspace-auto-review-probe.txt""#)
        #expect(boxes["010"] == .some(nil))
    }

    /// The captured multi-line request of 0.167.0 (`5-multiline-command`, 004):
    /// the box gets all of it, the view cuts it to `lineLimit` lines; the
    /// notification keeps the first.
    @Test func aCodexRequestShowsItsWholeMultiLineCommand() throws {
        let run = CodexReviewRun.multiLine
        let adapter = run.adapter()
        var state = CollectiveState()
        for (index, file) in run.files.enumerated() {
            let envelope = Envelope(source: "codex", pid: 4242, payload: file.payload, receivedAt: Date(timeIntervalSince1970: 1_000 + TimeInterval(index)))
            for event in try adapter.events(from: envelope) { state.apply(event) }
            if file.name.hasPrefix("003") { #expect(commandBox(try row(state)) == nil) }
            if file.name.hasPrefix("004") { break }
        }
        let item = try row(state)
        #expect(item.rowStatus == .needsPermission)
        #expect(commandBox(item) == PermissionCommand(toolName: "Bash", command: "cat > captures/multiline-probe.txt <<'EOF'\nfirst line\nsecond line\nthird line\nEOF"))
    }

    /// The status file said `waiting` first (008), so the call's start (009)
    /// shows no tool: only the request names the command (010).
    @Test func aClaudeCodeRequestShowsItsCommand() throws {
        let item = try row(try Timeline("4-waiting-permission-question").replay(through: 10))
        #expect(item.rowStatus == .needsPermission)
        guard case let .permission(command)? = item.rowDetail else {
            Issue.record("no command box: \(String(describing: item.rowDetail))")
            return
        }
        #expect(command.toolName == "Bash")
        #expect(command.command == "touch captures/perm-one")
    }

    /// The question of entry 028: options without "Other", no "Choose one".
    @Test func aClaudeCodeQuestionShowsItsOptions() throws {
        let item = try row(try Timeline("4-waiting-permission-question").replay(through: 28))
        #expect(item.rowStatus == .question(count: 1))
        guard case let .question(question)? = item.rowDetail else {
            Issue.record("no question box: \(String(describing: item.rowDetail))")
            return
        }
        #expect(question.text == "Which color do you like?")
        #expect(question.listedOptions.map(\.label) == [.option("Red"), .option("Blue")])
        #expect(question.multiSelectHint == nil)
        #expect(question.moreLine == nil)
    }
}
