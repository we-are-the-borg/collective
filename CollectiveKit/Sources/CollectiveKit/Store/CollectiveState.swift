import Foundation

/// All known sessions across all sources. A plain value type: every change goes
/// through `apply`, `markStale`, `markInterrupted` or `prune`, which keeps it
/// trivially testable.
public struct CollectiveState: Sendable, Equatable {
    public private(set) var sessions: [SessionKey: Session] = [:]
    /// Reports for sessions not seen yet: a source watching live state can be
    /// quicker than the session's first event, and a report alone has too
    /// little to show. Applied once the session appears. Likewise for an
    /// ended session, whose next run may report before its start arrives:
    /// kept until that run starts, the session is pruned or the report has
    /// waited too long in `prune`. A report from another process than the
    /// session's waits too, until the session has that process (see
    /// `takesReport(for:from:)`); the newest is kept per session and process.
    private var earlyReports: [ReportOrigin: Parked<ActivityReport>] = [:]
    /// Names for sessions not seen yet or ended, kept like `earlyReports`: a
    /// source can know a session's name before its first event, and a name
    /// alone must not make a session appear.
    private var earlyNames: [ReportOrigin: Parked<SessionName>] = [:]
    /// Terminal reports for sessions not seen yet, ended, or run by another
    /// process, kept like `earlyNames`; the latest arrived wins.
    private var earlyTerminalReports: [ReportOrigin: Parked<TerminalOwnership>] = [:]
    /// Sessions and agents the user archived, with when. An overlay rather
    /// than a status: the real status keeps following the events underneath,
    /// so undo restores exactly what was shown and a comeback needs no guess.
    public private(set) var archiveMarks: [ArchiveTarget: Date] = [:]
    /// Up to which turn end the user has seen each session, an overlay like
    /// `archiveMarks`: whether a session is unread follows from it and the
    /// events (`isUnread`).
    public private(set) var readMarks: [SessionKey: Date] = [:]

    public init() {}

    /// The sessions to show and count, in no order: all but those on standby
    /// (`Session.isStandby`), which the user never started. Everything shown
    /// or counted reads these rather than `sessions`.
    public var shownSessions: [Session] {
        sessions.values.filter { !$0.isStandby }
    }

    /// `key`'s session if it is among `shownSessions`.
    public func shownSession(_ key: SessionKey) -> Session? {
        sessions[key].flatMap { $0.isStandby ? nil : $0 }
    }

    /// Number of agents currently working, across all sessions and sources.
    /// Archived sessions and agents don't count: the user said they are over.
    public var activeAgentCount: Int {
        shownSessions.reduce(0) { count, session in
            guard !isArchived(session.key) else { return count }
            return count + session.agents.values.count { $0.status.isActive && !isArchived($0.id, in: session.key) }
        }
    }

    /// Whether an agent somewhere waits for the user to allow a tool call.
    /// Archived ones don't count, like for `activeAgentCount`.
    public var awaitsPermission: Bool {
        shownSessions.contains(where: awaitsPermission(in:))
    }

    /// `awaitsPermission` for one session: the popover's "◆ n" counts the
    /// sessions the menu bar would call the user to.
    func awaitsPermission(in session: Session) -> Bool {
        !isArchived(session.key) && session.agents.keys.contains {
            session.awaitsPermission($0) && !isArchived($0, in: session.key)
        }
    }

    /// Whether an agent somewhere waits for the user to answer its
    /// questions. Archived ones don't count, as for `awaitsPermission`.
    public var awaitsAnswer: Bool {
        shownSessions.contains(where: awaitsAnswer(in:))
    }

    /// `awaitsAnswer` for one session, as `awaitsPermission(in:)`.
    func awaitsAnswer(in session: Session) -> Bool {
        !isArchived(session.key) && session.agents.keys.contains {
            session.awaitsAnswer($0) && !isArchived($0, in: session.key)
        }
    }

    /// Whether a session somewhere still runs a shell in the background
    /// Archived sessions don't count, like for `activeAgentCount`.
    public var runsBackgroundShell: Bool {
        shownSessions.contains { !isArchived($0.key) && $0.runsBackgroundShell }
    }

    public func isArchived(_ key: SessionKey) -> Bool {
        archiveMarks[.session(key)] != nil
    }

    /// Also true for every agent of an archived session, and for the whole
    /// subtree of an archived subagent: its children are part of the work the
    /// user called over.
    public func isArchived(_ agent: AgentRef, in key: SessionKey) -> Bool {
        archiveMark(of: agent, in: key) != nil
    }

    /// When `agent` was archived: on its own, with an ancestor or with its
    /// session, the closest mark winning.
    func archiveMark(of agent: AgentRef, in key: SessionKey) -> Date? {
        var current: AgentRef? = agent
        var seen: Set<AgentRef> = []
        while let ref = current, seen.insert(ref).inserted {
            if let mark = archiveMarks[.agent(key, ref)] { return mark }
            current = sessions[key]?.agents[ref]?.parent
        }
        return archiveMarks[.session(key)]
    }

    /// Hides `target` without touching its status. Only events newer than
    /// `date` that show new work bring it back (see `apply`).
    public mutating func archive(_ target: ArchiveTarget, at date: Date) {
        archiveMarks[target] = date
    }

    public mutating func unarchive(_ target: ArchiveTarget) {
        archiveMarks[target] = nil
    }

    /// Replaces the marks with saved ones. Meant for app start before the
    /// spool's backlog replays: marks may name sessions not seen yet, and the
    /// older events they then meet don't bring anything back.
    public mutating func restoreArchive(_ marks: [ArchiveTarget: Date]) {
        archiveMarks = marks
    }

    /// Whether the root's newest turn end is one the user hasn't seen: the
    /// session is shown, not archived, and its end is strictly newer than its
    /// read mark, or it has none. Derived rather than stored, so saved marks
    /// and replayed events give the same answer after a restart.
    public func isUnread(_ key: SessionKey) -> Bool {
        guard let ended = shownSession(key)?.turnEndedAt, !isArchived(key) else { return false }
        return readMarks[key].map { ended > $0 } ?? true
    }

    /// The user has seen `key` up to `date`. A mark only moves forward: a
    /// late or repeated call must not bring back an end already seen.
    public mutating func markRead(_ key: SessionKey, upTo date: Date) {
        readMarks[key] = max(readMarks[key] ?? date, date)
    }

    /// The user went to the session, by the jump button or a notification:
    /// read up to its newest turn end. True when that changed a mark, so the
    /// caller saves only then.
    @discardableResult
    public mutating func markTurnRead(_ key: SessionKey) -> Bool {
        guard let ended = sessions[key]?.turnEndedAt else { return false }
        let before = readMarks[key]
        markRead(key, upTo: ended)
        return readMarks[key] != before
    }

    /// Marks every turn end known so far as read, e.g. what the backlog
    /// brought on a first launch without saved marks.
    public mutating func markAllRead() {
        for session in sessions.values {
            if let ended = session.turnEndedAt { markRead(session.key, upTo: ended) }
        }
    }

    /// Replaces the marks with saved ones, before the backlog replays, as for
    /// `restoreArchive`: marks may name sessions not seen yet.
    public mutating func restoreReadMarks(_ marks: [SessionKey: Date]) {
        readMarks = marks
    }

    public mutating func apply(_ event: AgentEvent) {
        if case let .sessionNamed(name) = event.kind {
            receive(SessionName(name: name, date: event.timestamp), for: event.session, from: event.pid)
            return
        }
        if case let .terminalReported(ownership) = event.kind {
            receive(terminalReported: ownership, for: event.session, from: event.pid)
            return
        }
        if case let .backgroundShellsListed(shells) = event.kind {
            receiveShellNews(at: event.timestamp, for: event.session) { $0.listBackgroundShells(shells, at: event.timestamp) }
            return
        }
        if case .backgroundShellStarted = event.kind {
            receiveShellNews(at: event.timestamp, for: event.session) { $0.startBackgroundShell(at: event.timestamp) }
            return
        }
        if case let .effortReported(agent, level) = event.kind {
            receiveEffort(level, of: agent, at: event.timestamp, for: event.session)
            return
        }
        if case let .activityReported(activity) = event.kind, !takesReport(for: event.session, from: event.pid) {
            let report = ActivityReport(activity: activity, date: event.timestamp, pid: event.pid)
            let origin = ReportOrigin(session: event.session, pid: event.pid)
            if let early = earlyReports[origin], early.value.date >= report.date { return }
            earlyReports[origin] = Parked(report)
            return
        }
        // Taken out while it changes, so it isn't copied for every event;
        // every way out puts it back.
        var session = sessions.removeValue(forKey: event.session) ?? Session(key: event.session, startedAt: event.timestamp)
        defer { sessions[event.session] = session }
        // What a later run's start left behind belongs to the run it replaced
        // and must not end or change this one. Strictly older only: hook times
        // are whole seconds, so the run's own events can share its start's.
        if session.isLaterRun, event.timestamp < session.startedAt { return }
        // A session continued under its id is a new run: nothing of the old
        // one carries over but the working directory and the name.
        if case let .sessionStarted(cwd, pid) = event.kind, session.isReplaced(byStartOf: pid, at: event.timestamp) {
            // A report no older than this start is the new run's, and a source
            // reporting only changes won't repeat it: the fresh session
            // receives it below like one that arrived early. So does one its
            // process reported while it wasn't the session's yet. One the old
            // run took from its own process stays with it unless that process
            // is the new one too.
            let anyProcess = ReportOrigin(session: event.session, pid: nil)
            let carried = session.lastReport.flatMap { $0.pid == nil || $0.pid == pid ? $0 : nil }
            let reports = [carried].compactMap { $0 } + Self.takeParked(&earlyReports, for: event.session, pid: pid)
            earlyReports[anyProcess] = reports
                .filter { $0.date >= event.timestamp }
                .max { $0.date < $1.date }
                .map(Parked.init)
            // A name carries over whatever its age: the id is the same, so
            // the earlier run's name is a fine title, and the new process's
            // own name, possibly written long before this start, is newer.
            let knownName = session.name.flatMap { name in session.nameSetAt.map { SessionName(name: name, date: $0) } }
            let names = [knownName].compactMap { $0 } + Self.takeParked(&earlyNames, for: event.session, pid: pid)
            earlyNames[anyProcess] = names
                .max { $0.date < $1.date }
                .map(Parked.init)
            session = Session(key: event.session, startedAt: event.timestamp, cwd: cwd ?? session.cwd, pid: pid)
            session.isLaterRun = true
        }
        // Stale is only a guess, so any event proves the session alive again.
        // An ended session is final: hooks can arrive late or out of order,
        // and none of that may bring it back to life.
        if session.isStale { session.revive() }
        if session.hasEnded {
            // A source can write the final Stop before SessionEnd but deliver
            // them in the opposite order. Keep only the reply that belongs to
            // this run and predates its final end, and when that turn ended,
            // as it leaves the session unread; nothing else about
            // the finished session changes. In particular, do not invent an
            // agent whose start this run never saw.
            guard let endedAt = session.endedAt, event.timestamp <= endedAt else { return }
            switch event.kind {
            case let .replied(agent, text) where session.agents[agent] != nil:
                session.setReply(text, of: agent, at: event.timestamp)
            case let .turnEnded(outcome) where outcome != .interrupted:
                session.endTurn(at: event.timestamp)
            default:
                break
            }
            return
        }
        // A session whose start was never seen learns its directory and
        // process from any event. Only while unknown: a `cd` in a tool call
        // must not rename the session, and only a start begins a new run.
        // A report's process never fills in: one gets here only from the
        // session's own (`takesReport(for:from:)`).
        if session.cwd == nil { session.cwd = event.cwd }
        if session.pid == nil { session.pid = event.pid }
        // A model switch happens at the prompt, and a call that is over
        // already says nothing about now, so neither is a sign the turn
        // still runs; both keep the interruption guess for a later event.
        if !event.kind.leavesInterruptionGuess { session.revokeInterruption() }
        session.lastActivity = max(session.lastActivity, event.timestamp)
        let now = event.timestamp
        reviveArchived(by: event)

        switch event.kind {
        case let .sessionStarted(cwd, pid):
            session.cwd = cwd ?? session.cwd
            session.pid = pid ?? session.pid

        case let .promptSubmitted(prompt):
            session.update(.root) { $0.spec.prompt = prompt }
            session.lastPromptAt = max(session.lastPromptAt ?? now, now)
            session.noteInput(at: now)
            session.startTurn(at: now)
            session.setRootStatus(.working, at: now)
            session.answerPermission(start: now)

        case .turnStarted:
            session.startTurn(at: now)
            session.setRootStatus(.working, at: now)
            // A hand-back: it drops what is open, but the user answered nothing.
            session.answerPermission(start: now, isInput: false)

        case let .agentSpawned(id, parent, spec):
            let ref = AgentRef.subagent(id)
            if session.agents[ref] != nil {
                // Spawns repeat as more is learned. They fill in details and may
                // backfill the parent, but never change the status.
                session.update(ref) { $0.spec.merge(spec) }
                session.reparent(ref, to: parent)
            } else {
                let parent = session.agents[parent] == nil ? .root : parent
                session.addSubagent(ref, parent: parent, spec: spec, at: now)
            }

        case let .toolStarted(agent, tool, _, alreadyEnded):
            // Over already or not, the agent went on to a call.
            session.answerPermission(of: agent, start: now)
            // A finished call must not show as running.
            guard !alreadyEnded else { break }
            session.ensureAgent(agent, at: now)
            // Only a working agent has a current tool; a late event must not
            // revive a finished agent or a waiting orchestrator.
            session.update(agent) {
                if $0.status == .working {
                    $0.currentTool = tool
                    $0.lastToolCall = ToolCall(tool: tool, startedAt: now)
                }
            }

        case let .toolFinished(agent, _, _):
            session.update(agent) { $0.currentTool = nil }
            session.answerPermission(of: agent, end: now)

        case let .permissionRequested(agent, tool):
            session.requestPermission(of: agent, tool: tool, at: now)

        case let .questionAsked(agent, questions, callID):
            session.askQuestions(questions, of: agent, callID: callID, at: now)

        case let .questionAnswered(agent, _, _):
            // The answers are not kept: once answered, nothing is asked.
            session.answerPermission(of: agent, end: now)

        case let .agentFinished(id):
            // A stop strictly older than the resume is the run before's,
            // arriving late. Hook times are whole seconds, so one within the
            // resume's second counts as the new run's.
            if let resumedAt = session.agents[.subagent(id)]?.resumedAt, now < resumedAt { break }
            session.finish(.subagent(id), as: .done, at: now)

        case let .agentResumed(id):
            session.resume(.subagent(id), at: now)

        case let .turnEnded(outcome):
            // Background subagents may keep running after the orchestrator's
            // turn, so only the root changes here.
            if outcome != .interrupted { session.endTurn(at: now) }
            session.setRootStatus(.waiting, at: now)
            DatedSign.note(false, at: now, in: &session.rootTurn)
            session.answerPermission(of: .root, end: now)

        case .sessionEnded:
            session.finish(.root, as: .done, at: now)
            session.endedAt = now

        case let .activityReported(activity):
            session.receive(ActivityReport(activity: activity, date: now, pid: event.pid))

        case let .modelChanged(model, from):
            session.setModel(model, from: from, at: now)

        case let .replied(agent, text):
            // A subagent's result must not be lost because its start was never seen.
            session.ensureAgent(agent, at: now)
            session.setReply(text, of: agent, at: now)
            session.answerPermission(of: agent, end: now)

        case .sessionNamed, .terminalReported, .backgroundShellsListed, .backgroundShellStarted, .effortReported:
            break // applied apart, see `receive(_:for:from:)`, `receive(terminalReported:for:from:)`, `receiveShellNews(at:for:_:)` and `receiveEffort(_:of:at:for:)`
        }

        session.update(event.kind.agent ?? .root) { $0.lastActivity = max($0.lastActivity, now) }
        // A process keeps its terminal; another process's belongs to another
        // tab, whether it runs the session later or only reports for it. A
        // session without a process takes only terminals without one.
        if let terminal = event.terminal, event.pid == session.pid {
            session.terminal = ProcessTerminal(identifiers: terminal, pid: event.pid)
        }

        // An ended session takes no report: it stays kept for a next run.
        // One from another process stays kept too, until the session has it.
        if session.endedAt == nil,
           let early = Self.takeParked(&earlyReports, for: event.session, pid: session.pid).max(by: { $0.date < $1.date }) {
            session.lastActivity = max(session.lastActivity, early.date)
            session.receive(early)
        }
        if session.endedAt == nil,
           let early = Self.takeParked(&earlyNames, for: event.session, pid: session.pid).max(by: { $0.date < $1.date }) {
            session.setName(early)
        }
        // Only the session's own process's, or none for a session without one.
        if session.endedAt == nil,
           let early = earlyTerminalReports.removeValue(forKey: ReportOrigin(session: event.session, pid: session.pid))?.value {
            session.reportTerminal(early)
        }
        session.noteRest()
    }

    /// A terminal report is no sign of activity either: it changes nothing
    /// but whether and how the session's terminal counts, and waits like a
    /// name. Except a withdrawal, which is about the process: the source
    /// withdraws its report when the process ends or can't be vouched for
    /// anymore, possibly only after the session ended, so it takes back the
    /// terminal of any finished row that process reported, including a
    /// session it ran before it switched to another one. What it reported
    /// since an end, kept for a next run, goes with it. Unlike a report or
    /// name, one without a process is only for a session without one, and
    /// waits for nothing else: its terminal must be the session's process's.
    private mutating func receive(terminalReported ownership: TerminalOwnership, for key: SessionKey, from pid: Int32?) {
        let origin = ReportOrigin(session: key, pid: pid)
        let withdrawal = ownership == .unusable
        let ownWithdrawal = withdrawal && pid != nil && pid == sessions[key]?.pid
        if withdrawal, let pid {
            for (other, session) in sessions where session.terminalReport?.pid == pid {
                sessions[other]?.terminalReport = nil
            }
            earlyTerminalReports = earlyTerminalReports.filter { $0.key.pid != pid }
        }
        guard ownWithdrawal || (takesReport(for: key, from: pid) && pid == sessions[key]?.pid), var session = sessions[key] else {
            earlyTerminalReports[origin] = Parked(ownership)
            return
        }
        session.reportTerminal(ownership)
        sessions[key] = session
    }

    /// A name is no sign of activity: it changes nothing but the name, and
    /// waits like a report for a session not seen yet or ended, or for the
    /// process that named it.
    private mutating func receive(_ name: SessionName, for key: SessionKey, from pid: Int32?) {
        guard takesReport(for: key, from: pid), var session = sessions[key] else {
            let origin = ReportOrigin(session: key, pid: pid)
            if let early = earlyNames[origin], early.value.date > name.date { return }
            earlyNames[origin] = Parked(name)
            return
        }
        session.setName(name)
        sessions[key] = session
    }

    /// A listing of background shells or a shell's start is no sign of
    /// activity either: it changes nothing but what the session lists and
    /// whether a shell runs, so no status, time or count; whether the
    /// session rests follows the shell. It comes after its hook's own
    /// events, so it has a session to go to; without one, or for one that
    /// is over, it is dropped. What a later run's start left behind is the
    /// run's before, as in `apply`.
    private mutating func receiveShellNews(at date: Date, for key: SessionKey, _ change: (inout Session) -> Void) {
        guard var session = sessions[key], !session.hasEnded,
              !(session.isLaterRun && date < session.startedAt) else { return }
        change(&session)
        // One presumed dead rests on from where it was once an event revives it (`markStale`).
        if !session.isStale { session.noteRest() }
        sessions[key] = session
    }

    /// An effort is no sign of activity either, unlike a model, which counts
    /// as an event of the session: it changes nothing but the effort, so no
    /// status, time or interruption guess, and it brings no stale session
    /// back. Like shell news it comes after its hook's own events, so it has
    /// a session to go to; without one it is dropped. For one that is over,
    /// only a report from up to its end counts, as for a late reply: it
    /// belongs to the run. What a later run's start left behind is the run's before.
    private mutating func receiveEffort(_ level: EffortLevel, of agent: AgentRef, at date: Date, for key: SessionKey) {
        // A stale session still takes the report: it may come back (`hasEnded` excludes stale sessions).
        guard var session = sessions[key],
              !session.hasEnded || session.endedAt.map({ date <= $0 }) == true,
              !(session.isLaterRun && date < session.startedAt) else { return }
        session.setEffort(level, of: agent, at: date)
        sessions[key] = session
    }

    /// Takes out what waits for a session run by `pid`: what came from its
    /// own process, then what named none.
    private static func takeParked<Value>(
        _ parked: inout [ReportOrigin: Parked<Value>], for key: SessionKey, pid: Int32?
    ) -> [Value] {
        let own = pid.flatMap { parked.removeValue(forKey: ReportOrigin(session: key, pid: $0))?.value }
        let anyProcess = parked.removeValue(forKey: ReportOrigin(session: key, pid: nil))?.value
        return [own, anyProcess].compactMap { $0 }
    }

    /// Whether a report or name applies to the session now rather than
    /// waiting: the session is known and not over, and the report names no
    /// process or the session's own. Another process can report for a
    /// session for a moment without running it; its report waits
    /// until the session has that process, as after a resume in it, and so
    /// does any while the session's process is unknown.
    private func takesReport(for key: SessionKey, from pid: Int32?) -> Bool {
        guard let session = sessions[key], !session.hasEnded else { return false }
        return pid == nil || pid == session.pid
    }

    /// New work after the user archived something means it wasn't over after
    /// all. Ends, reports and the like never count: a late end event or a
    /// source still claiming "working" is just what made the user archive.
    /// Strictly newer only, so replaying the backlog at start keeps the marks.
    private mutating func reviveArchived(by event: AgentEvent) {
        let worker: AgentRef?
        switch event.kind {
        case .promptSubmitted, .turnStarted: worker = nil
        case let .toolStarted(agent, _, _, alreadyEnded):
            // A call over already is no new work.
            guard !alreadyEnded else { return }
            worker = agent
        case let .agentSpawned(id, _, _), let .agentResumed(id): worker = .subagent(id)
        default: return
        }
        var targets: [ArchiveTarget] = [.session(event.session)]
        if let worker { targets.append(.agent(event.session, worker)) }
        for target in targets {
            if let mark = archiveMarks[target], event.timestamp > mark { archiveMarks[target] = nil }
        }
    }

    /// How much later than the session's first event its process may seem to
    /// have started. Event times are truncated to whole seconds, so the real
    /// start can appear up to a second after them; anything later means the
    /// pid now belongs to another process.
    static let processStartTolerance: TimeInterval = 2

    /// Marks sessions whose process is gone, or which went silent longer than
    /// `silenceTimeout` without a known process, as stale. A session that
    /// really waits for the user sends nothing, and some tools never send an
    /// end, so without a process it gets the longer `waitingTimeout`.
    /// `processStart` gives a pid's start time, or nil when no such process
    /// runs; comparing it with the session's start catches pids reused by the
    /// system.
    public mutating func markStale(now: Date, silenceTimeout: TimeInterval, waitingTimeout: TimeInterval, processStart: (Int32) -> Date?) {
        for key in sessions.keys {
            guard var session = sessions[key], session.endedAt == nil else { continue }

            let dead: Bool
            if let pid = session.pid {
                let latestStart = session.startedAt.addingTimeInterval(Self.processStartTolerance)
                dead = processStart(pid).map { $0 > latestStart } ?? true
            } else {
                let limit = session.reallyWaits ? waitingTimeout : silenceTimeout
                dead = now.timeIntervalSince(session.lastActivity) > limit
            }
            guard dead else { continue }

            session.finish(.root, as: .stale, at: now)
            session.endedAt = now
            sessions[key] = session
        }
    }

    /// Guesses that the user aborted the turn when a working root went silent:
    /// some tools send nothing on an interrupt. Only for sessions without a
    /// live state report, which would know better. An open tool call may run
    /// for long without events, hence the separate `toolTimeout`. The guess
    /// touches only the root and is taken back by the session's next event.
    public mutating func markInterrupted(now: Date, idleTimeout: TimeInterval, toolTimeout: TimeInterval) {
        for key in sessions.keys {
            guard var session = sessions[key], session.endedAt == nil, session.lastReport == nil,
                  session.root.status == .working else { continue }

            let toolOpen = session.agents.values.contains { $0.currentTool != nil }
            let limit = toolOpen ? toolTimeout : idleTimeout
            guard now.timeIntervalSince(session.lastActivity) > limit else { continue }

            session.rootBeforeInterruption = InterruptedRoot(status: .working, currentTool: session.root.currentTool)
            session.update(.root) {
                $0.status = .waiting
                $0.currentTool = nil
            }
            session.noteRest()
            sessions[key] = session
        }
    }

    /// Drops sessions that ended more than `retention` ago, and reports and
    /// names that waited longer than that for their session. A report kept
    /// for an ended session goes with it: once the session is forgotten,
    /// nothing could tell anymore that the report is older than a later run.
    public mutating func prune(now: Date, retention: TimeInterval) {
        earlyReports = earlyReports.compactMapValues { $0.waiting(at: now, retention: retention) }
        earlyNames = earlyNames.compactMapValues { $0.waiting(at: now, retention: retention) }
        earlyTerminalReports = earlyTerminalReports.compactMapValues { $0.waiting(at: now, retention: retention) }
        for (key, session) in sessions {
            guard let endedAt = session.endedAt, now.timeIntervalSince(endedAt) > retention else { continue }
            sessions[key] = nil
            earlyReports = earlyReports.filter { $0.key.session != key }
            earlyNames = earlyNames.filter { $0.key.session != key }
            earlyTerminalReports = earlyTerminalReports.filter { $0.key.session != key }
        }
    }
}

/// Whom a parked report or name is from: a session and, if the source names
/// it, the process that reported.
private struct ReportOrigin: Hashable, Sendable {
    let session: SessionKey
    let pid: Int32?
}

/// A report or name waiting for its session, aged by how long it has waited
/// rather than by its own date: an idle session's status file can be hours
/// old, and its source won't send it again. The reducer has no clock, so the
/// first `prune` to see the entry stamps when it started waiting.
private struct Parked<Value: Sendable & Equatable>: Sendable, Equatable {
    let value: Value
    var since: Date?

    init(_ value: Value) {
        self.value = value
    }

    /// Nil once it has waited longer than `retention`.
    func waiting(at now: Date, retention: TimeInterval) -> Parked? {
        var parked = self
        let since = since ?? now
        parked.since = since
        return now.timeIntervalSince(since) <= retention ? parked : nil
    }
}

private extension Session {
    mutating func update(_ ref: AgentRef, _ change: (inout Agent) -> Void) {
        guard var agent = agents[ref] else { return }
        change(&agent)
        agents[ref] = agent
    }

    /// Events can arrive for subagents we never saw spawn, e.g. when the app
    /// started mid-session. Attach those to the root rather than dropping them.
    mutating func ensureAgent(_ ref: AgentRef, at date: Date) {
        guard agents[ref] == nil else { return }
        addSubagent(ref, parent: .root, spec: AgentSpec(), at: date)
    }

    /// A subagent first seen in an event surely older than an idle or standby
    /// report ended before that report: the report can be applied before the
    /// backlog it postdates, when no subagent existed yet for it to end.
    /// Hook times are whole seconds, so only an earlier second counts.
    mutating func addSubagent(_ ref: AgentRef, parent: AgentRef, spec: AgentSpec, at date: Date) {
        var agent = Agent(id: ref, parent: parent, spec: spec, status: .working, startedAt: date)
        if let report = lastReport, [.idle, .standby].contains(report.activity), date.addingTimeInterval(1) <= report.date {
            agent.status = .done
            agent.endedAt = report.date
        }
        agents[ref] = agent
    }

    /// Opens a new run of a subagent, e.g. one that had finished; one never
    /// seen before starts working with it. A resume surely older than an
    /// idle or standby report ended before that report, as for a first start
    /// (`addSubagent`); one surely older than the agent's end arrived late,
    /// its run over already: the counterpart of `agentFinished` ignoring a
    /// stop older than the resume, for sources that don't sort that out
    /// themselves. Hook times are whole seconds, so only an earlier second
    /// counts. A stale one is back already: the resume revived its session
    /// (`revive()`).
    mutating func resume(_ ref: AgentRef, at date: Date) {
        guard let agent = agents[ref] else {
            addSubagent(ref, parent: .root, spec: AgentSpec(), at: date)
            update(ref) { $0.resumedAt = date }
            return
        }
        if agent.status == .done, let endedAt = agent.endedAt, date.addingTimeInterval(1) <= endedAt { return }
        if let report = lastReport, [.idle, .standby].contains(report.activity), date.addingTimeInterval(1) <= report.date { return }
        update(ref) {
            $0.resumedAt = max($0.resumedAt ?? date, date)
            $0.status = .working
            $0.endedAt = nil
            $0.currentTool = nil
        }
    }

    /// Moves `ref` under `parent` once the real parent is known. Ignored when
    /// the parent is unknown or the move would create a cycle.
    mutating func reparent(_ ref: AgentRef, to parent: AgentRef) {
        guard parent != ref, agents[parent] != nil, !isDescendant(parent, of: ref) else { return }
        update(ref) { $0.parent = parent }
    }

    func isDescendant(_ ref: AgentRef, of ancestor: AgentRef) -> Bool {
        var current = agents[ref]?.parent
        while let node = current {
            if node == ancestor { return true }
            current = agents[node]?.parent
        }
        return false
    }

    /// Ends `ref` and every still-running descendant. Every agent descends
    /// from `.root`, so finishing the root ends the whole session.
    mutating func finish(_ ref: AgentRef, as status: AgentStatus, at date: Date) {
        guard let agent = agents[ref] else { return }
        for node in [agent] + descendants(of: ref) where node.status == .working || node.status == .waiting {
            update(node.id) {
                if status == .stale { $0.statusBeforeStale = $0.status }
                $0.status = status
                $0.currentTool = nil
                $0.endedAt = date
            }
        }
    }

    /// Sets the root's status for a hook event, unless a newer report or
    /// hook event already said otherwise: the stop of a turn can arrive
    /// after the next prompt. Strictly older only: hook times are whole
    /// seconds, so a report within the same second counts as newer, and the
    /// source reports again on its next change anyway; between hook events
    /// of one second the later applied wins.
    mutating func setRootStatus(_ status: AgentStatus, at date: Date) {
        if let report = lastReport, date < report.date { return }
        if let setAt = rootStatusSetAt, date < setAt { return }
        rootStatusSetAt = date
        update(.root) {
            $0.status = status
            if status != .working { $0.currentTool = nil }
        }
    }

    /// Applies a report unless an older one arrived late or a newer hook
    /// event already set the root's status. Whatever its age, it may answer
    /// a permission request that arrives late.
    mutating func receive(_ report: ActivityReport) {
        answerPermission(by: report)
        noteBackgroundShell(by: report)
        if let last = lastReport, report.date <= last.date { return }
        lastReport = report
        if let hookDate = rootStatusSetAt, report.date <= hookDate { return }

        switch report.activity {
        case .working:
            update(.root) { $0.status = .working }
        case .waiting, .backgroundShell:
            // Often a subagent is the one waiting for the user, so they keep
            // running; a background shell says nothing about subagents either.
            // Whether the shell runs is noted apart, see `noteBackgroundShell(by:)`.
            update(.root) {
                $0.status = .waiting
                $0.currentTool = nil
            }
        case .idle, .standby:
            update(.root) {
                $0.status = .waiting
                $0.currentTool = nil
            }
            // Idle and standby mean nothing runs, so no subagent can either. A
            // report that arrives late says nothing about subagents started
            // or resumed after it.
            for ref in agents.keys where ref != .root {
                update(ref) {
                    guard $0.status == .working || $0.status == .waiting,
                          $0.runStartedAt <= report.date else { return }
                    $0.status = .done
                    $0.currentTool = nil
                    $0.endedAt = report.date
                }
            }
        }
    }

    /// Clears the reply of the turn before, however late the start arrives.
    /// A reply strictly newer than this start is the turn's own, or a later
    /// one's, whose stop arrived first. Hook times are whole seconds, so
    /// within one second the later applied wins: a prompt sent in the second
    /// of the reply clears it, at the price that a turn answered within its
    /// first second loses its reply if its start arrives after its stop.
    /// The turn end that made the session unread goes the same way.
    mutating func startTurn(at date: Date) {
        DatedSign.note(true, at: date, in: &rootTurn)
        turnStartedAt = max(turnStartedAt ?? date, date)
        if let turnEndedAt, turnEndedAt <= date { self.turnEndedAt = nil }
        if let repliedAt = rootRepliedAt, repliedAt > date { return }
        rootRepliedAt = nil
        update(.root) { $0.reply = nil }
    }

    /// Ignores an end strictly older than the newest turn's start: the stop of
    /// the turn before, arriving after the next prompt. Keeps the newest of
    /// two ends.
    mutating func endTurn(at date: Date) {
        if let turnStartedAt, date < turnStartedAt { return }
        turnEndedAt = max(turnEndedAt ?? date, date)
    }

    /// For the root, ignores a reply strictly older than the current turn's
    /// start or than the reply shown: a stop can arrive after the next
    /// prompt. Hook times are whole seconds, so a reply within the second of
    /// the turn's start counts as that turn's, at the price that the reply of
    /// the turn before is shown as the current one if it arrives late from
    /// that same second.
    mutating func setReply(_ text: String, of ref: AgentRef, at date: Date) {
        if ref == .root {
            if let newest = [turnStartedAt, rootRepliedAt].compactMap({ $0 }).max(), date < newest { return }
            rootRepliedAt = date
        }
        update(ref) { $0.reply = text }
    }

    /// Ignores a report strictly older than the current model's. Hook times
    /// are whole seconds, so within one second the later applied wins.
    mutating func setModel(_ model: String, from: String?, at date: Date) {
        if let setAt = modelSetAt, date < setAt { return }
        if let previous = self.model ?? from, previous != model {
            lastModelSwitch = ModelSwitch(from: previous, at: date)
        }
        self.model = model
        modelSetAt = date
    }

    /// Ignores a report strictly older than the agent's current effort, as
    /// for the model; within one second the later applied wins. The root's
    /// is the session's, with its last change; a subagent unknown to the
    /// session gets none.
    mutating func setEffort(_ level: EffortLevel, of ref: AgentRef, at date: Date) {
        guard ref == .root else {
            update(ref) {
                if let setAt = $0.effortSetAt, date < setAt { return }
                $0.effort = level
                $0.effortSetAt = date
            }
            return
        }
        if let setAt = effortSetAt, date < setAt { return }
        if let previous = effort, previous != level {
            lastEffortChange = EffortChange(from: previous, at: date)
        }
        effort = level
        effortSetAt = date
    }

    /// Ignores a name strictly older than the current one. Times can be
    /// whole seconds, so within one second the later applied wins.
    mutating func setName(_ name: SessionName) {
        if let setAt = nameSetAt, name.date < setAt { return }
        self.name = name.name
        nameSetAt = name.date
    }

    /// Ignores a listing strictly older than the current one. Hook times
    /// are whole seconds, so within one second the later applied wins.
    mutating func listBackgroundShells(_ shells: [BackgroundShell], at date: Date) {
        noteBackgroundShell(runs: !shells.isEmpty, at: date)
        if let listedAt = backgroundShellsListedAt, date < listedAt { return }
        backgroundShells = shells
        backgroundShellsListedAt = date
    }

    /// A shell started now runs, and no listing before names it.
    mutating func startBackgroundShell(at date: Date) {
        backgroundShellStartedAt = max(backgroundShellStartedAt ?? date, date)
        noteBackgroundShell(runs: true, at: date)
    }

    /// A report of a shell says one runs. One that the session idles or
    /// stands by says none does, and no turn either: a source that knows a
    /// shell runs reports `backgroundShell` instead, and on standby nothing
    /// runs at all. So does one that it waits, but only while no turn of the
    /// root runs: within one, e.g. for a permission or a question, the
    /// source waits instead of working, not instead of reporting the shell,
    /// and the turn's end lists what runs. A working one says nothing:
    /// shells started before the turn may still run, and one it starts comes
    /// with its own sign; nor does it start the root's turn, as background
    /// subagents work without one. Known corner: a dialog after the turn,
    /// e.g. on exit, ends a shell that still runs.
    mutating func noteBackgroundShell(by report: ActivityReport) {
        switch report.activity {
        case .backgroundShell:
            DatedSign.note(false, at: report.date, in: &rootTurn)
            noteBackgroundShell(runs: true, at: report.date)
        case .idle, .standby:
            DatedSign.note(false, at: report.date, in: &rootTurn)
            noteBackgroundShell(runs: false, at: report.date)
        case .waiting:
            if rootTurn?.isSet != true { noteBackgroundShell(runs: false, at: report.date) }
        case .working:
            break
        }
    }

    mutating func noteBackgroundShell(runs: Bool, at date: Date) {
        DatedSign.note(runs, at: date, in: &backgroundShellSign)
    }

    /// Notes that `ref`, or the whole session when nil, started something
    /// at `date`, and drops the requests that answers.
    mutating func answerPermission(of ref: AgentRef? = nil, start date: Date, isInput: Bool = true) {
        answerPermission(of: ref, at: date, isInput: isInput) { $0.note(start: date) }
    }

    /// Notes that `ref`, or the whole session when nil, ended something at
    /// `date`, and drops the requests that answers.
    mutating func answerPermission(of ref: AgentRef? = nil, end date: Date) {
        answerPermission(of: ref, at: date, isInput: true) { $0.note(end: date) }
    }

    /// Drops the requests `note` answers, questions included. Dropping one
    /// is the user's input at `date` when `isInput`: they answered it.
    private mutating func answerPermission(
        of ref: AgentRef?, at date: Date, isInput: Bool, _ note: (inout PermissionAnswers) -> Void
    ) {
        if let ref {
            note(&permissionAnswers[ref, default: PermissionAnswers()])
        } else {
            note(&sessionPermissionAnswers)
        }
        let open = permissionRequests.count + questionRequests.count
        permissionRequests = permissionRequests.filter { !isAnswered($0.key, requestAt: $0.value) }
        permissionTools = permissionTools.filter { permissionRequests[$0.key] != nil }
        questionRequests = questionRequests.filter { !isAnswered($0.key, requestAt: $0.value.date) }
        if isInput, permissionRequests.count + questionRequests.count < open { noteInput(at: date) }
    }

    /// Never moves `lastInputAt` back: hooks run async.
    mutating func noteInput(at date: Date) {
        lastInputAt = max(lastInputAt ?? date, date)
    }

    /// Keeps the newest request of `ref` unless something already answered it.
    mutating func requestPermission(of ref: AgentRef, tool: ToolActivity, at date: Date) {
        guard !isAnswered(ref, requestAt: date) else { return }
        if let current = permissionRequests[ref], current > date { return }
        permissionRequests[ref] = date
        permissionTools[ref] = tool
    }

    /// Keeps the newest questions of `ref` unless something already answered
    /// them, as for a permission request. A call's start and its dialog ask
    /// the same questions, in either order: the later merges into the
    /// earlier and keeps the call's id.
    mutating func askQuestions(_ questions: [Question], of ref: AgentRef, callID: String?, at date: Date) {
        guard !isAnswered(ref, requestAt: date) else { return }
        let current = questionRequests[ref]
        if let current, current.date > date { return }
        let sameCall = current.map { $0.questions == questions } ?? false
        questionRequests[ref] = QuestionRequest(date: date, questions: questions, callID: callID ?? (sameCall ? current?.callID : nil))
    }

    func isAnswered(_ ref: AgentRef, requestAt date: Date) -> Bool {
        sessionPermissionAnswers.answer(requestAt: date) || permissionAnswers[ref]?.answer(requestAt: date) == true
    }

    /// Working again means the user answered; idle and standby mean nothing
    /// runs, so nothing asks either; a background shell alone means the turn
    /// is over.
    /// Waiting says nothing: the source also waits for questions and dialogs.
    /// A report has milliseconds, but hook times are whole seconds, so one
    /// in the request's second may be older than the request; like a start,
    /// it answers only requests from seconds before its own.
    /// Known corner: a report that drops an open request counts as the user's
    /// input (`isInput` defaults to true), even when a hand-back left the
    /// request open in its own second and the report only shows the agent
    /// carrying on; such a long turn then counts from the report and may not
    /// notify.
    mutating func answerPermission(by report: ActivityReport) {
        let date = Date(timeIntervalSince1970: report.date.timeIntervalSince1970.rounded(.down))
        switch report.activity {
        case .working, .idle, .standby: answerPermission(start: date)
        case .backgroundShell: answerPermission(of: .root, start: date)
        case .waiting: break
        }
    }

    /// Stamps `restingSince` when the session begins to rest and clears it
    /// when it stops; anything else leaves it, so a repeated report does not
    /// restart the rest. The newest event is when the last work ended, even
    /// if the events arrived out of order. `markStale` does not call it: a
    /// session it revives rests on from where it was.
    mutating func noteRest() {
        if !rests {
            restingSince = nil
        } else if restingSince == nil {
            restingSince = lastActivity
            restsBegun += 1
        }
    }

    /// Undoes `markInterrupted` before the next event applies on top.
    mutating func revokeInterruption() {
        guard let before = rootBeforeInterruption else { return }
        rootBeforeInterruption = nil
        update(.root) {
            $0.status = before.status
            $0.currentTool = before.currentTool
        }
    }

    /// The root is running until the session ends, so the sweep always
    /// makes it stale.
    var isStale: Bool { agents[.root]?.status == .stale }

    /// Really ended, not just presumed dead by the sweep.
    var hasEnded: Bool { endedAt != nil && !isStale }

    /// Whether a session start of process `pid` at `date` begins a new run.
    /// After a real end, any later start does. Without one, e.g. after a
    /// crash, only another process shows it: the same process, or none
    /// named, starts again within a run, as when it compacts. Strictly newer
    /// only: hook times are whole seconds, so a start within the second of
    /// the end or of this run's start may be a late one of this run.
    func isReplaced(byStartOf pid: Int32?, at date: Date) -> Bool {
        if let endedAt, hasEnded { return date > endedAt }
        guard let pid, let known = self.pid else { return false }
        return pid != known && date > startedAt
    }

    /// Undoes `markStale`: the session and every agent the sweep caught run
    /// again as before; agents that had finished on their own stay done.
    /// The rest keeps its start but counts as begun anew: the open popover
    /// showed the session as finished, and coming back is no reason to move
    /// it into the "Idle" group under the user's eyes.
    mutating func revive() {
        endedAt = nil
        restsBegun += 1
        for ref in agents.keys {
            update(ref) {
                guard let previous = $0.statusBeforeStale else { return }
                $0.status = previous
                $0.endedAt = nil
                $0.statusBeforeStale = nil
            }
        }
    }
}

private extension AgentEvent.Kind {
    /// The agent the event is about; nil for events about the whole session,
    /// which the orchestrator stands for.
    var agent: AgentRef? {
        switch self {
        case let .toolStarted(agent, _, _, _), let .toolFinished(agent, _, _), let .permissionRequested(agent, _), let .replied(agent, _),
             let .questionAsked(agent, _, _), let .questionAnswered(agent, _, _): agent
        case let .agentSpawned(id, _, _), let .agentFinished(id), let .agentResumed(id): .subagent(id)
        default: nil
        }
    }

    /// Whether the event says nothing about the turn still running, so a guess
    /// that it was interrupted stays.
    var leavesInterruptionGuess: Bool {
        switch self {
        case .modelChanged: true
        case let .toolStarted(_, _, _, alreadyEnded): alreadyEnded
        default: false
        }
    }
}

private extension AgentSpec {
    mutating func merge(_ other: AgentSpec) {
        type = other.type ?? type
        title = other.title ?? title
        prompt = other.prompt ?? prompt
        modelAlias = other.modelAlias ?? modelAlias
        modelID = other.modelID ?? modelID
        isBackground = other.isBackground ?? isBackground
    }
}
