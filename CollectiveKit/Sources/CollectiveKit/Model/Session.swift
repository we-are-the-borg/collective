import Foundation

public enum AgentStatus: Sendable, Equatable {
    case working
    /// Idle but alive, e.g. the orchestrator waiting for user input.
    case waiting
    case done
    /// Presumed dead: its process vanished or it went silent too long.
    case stale

    public var isActive: Bool { self == .working }
}

public struct Agent: Sendable, Equatable, Identifiable {
    public let id: AgentRef
    public var parent: AgentRef?
    public var spec: AgentSpec
    public var status: AgentStatus
    public var currentTool: ToolActivity?
    /// The newest tool call, kept after it finished: a call too short to
    /// read would otherwise only flicker by.
    public var lastToolCall: ToolCall?
    /// The agent's last reply; for a subagent its result.
    public var reply: String?
    public let startedAt: Date
    public var endedAt: Date?
    /// The newest event about this agent. A session's own `lastActivity`
    /// can't tell a hanging subagent from a busy sibling.
    public var lastActivity: Date
    /// A subagent's current effort; nil for the root, whose effort is the
    /// session's (`Session.effort`), as is its model.
    public var effort: EffortLevel?
    /// When `effort` was set: reports can arrive out of order.
    var effortSetAt: Date? = nil
    /// Set while the agent is stale: what it was before the sweep, so a
    /// later event can bring it back.
    var statusBeforeStale: AgentStatus? = nil
    /// The newest resume, if the subagent was resumed: a stop or report
    /// older than it belongs to the run before.
    var resumedAt: Date? = nil
    /// The start of the current run: a resumed subagent counts its runtime
    /// from the resume, like a resumed session. Its place in
    /// lists stays at `startedAt`.
    public var runStartedAt: Date { resumedAt ?? startedAt }

    init(id: AgentRef, parent: AgentRef?, spec: AgentSpec, status: AgentStatus, startedAt: Date) {
        self.id = id
        self.parent = parent
        self.spec = spec
        self.status = status
        self.startedAt = startedAt
        self.lastActivity = startedAt
    }
}

/// A tool call and when it started, by event time.
public struct ToolCall: Sendable, Equatable {
    public var tool: ToolActivity
    public var startedAt: Date

    public init(tool: ToolActivity, startedAt: Date) {
        self.tool = tool
        self.startedAt = startedAt
    }
}

/// One orchestrator run and every subagent it spawned.
public struct Session: Sendable, Equatable, Identifiable {
    public let key: SessionKey
    public var cwd: String?
    public var pid: Int32?
    public let startedAt: Date
    public var lastActivity: Date
    public var endedAt: Date?
    /// The session's name in its tool, e.g. one the user can change there;
    /// nil when the source names none.
    public var name: String?
    /// Keyed by `AgentRef`; always contains `.root`.
    public var agents: [AgentRef: Agent]
    /// The orchestrator's current model, as the source names it.
    public var model: String?
    /// Only the latest switch; earlier ones are of no interest.
    public var lastModelSwitch: ModelSwitch?
    /// When `model` was set. Hooks run async, so a report of the model can
    /// arrive after a newer one and must not replace it.
    var modelSetAt: Date? = nil
    /// The orchestrator's current effort; a subagent's is its own
    /// (`Agent.effort`).
    public var effort: EffortLevel?
    /// Only the latest change, as for the model.
    public var lastEffortChange: EffortChange?
    /// When `effort` was set: reports can arrive out of order, as for the model.
    var effortSetAt: Date? = nil
    /// When `name` was set. Sources can report names out of order, and an
    /// older one must not replace a newer.
    var nameSetAt: Date? = nil
    /// The newest terminal of the session's process, and that process: once
    /// the session runs in another one, it is another tab's.
    var terminal: ProcessTerminal? = nil
    /// Whose terminal the source last said its process runs in, and that
    /// process; nil once it took that back. Like `terminal`, it counts only
    /// while the session runs in that process.
    var terminalReport: TerminalReport? = nil
    /// Set while `markInterrupted` guesses the root waiting: what it was
    /// before, so the next event can take the guess back.
    var rootBeforeInterruption: InterruptedRoot? = nil
    /// The newest activity report. Reports and hook events can contradict
    /// each other, so for the root's status the newer of the two wins.
    var lastReport: ActivityReport? = nil
    /// When a hook event last set the root's status. A hook event strictly older than this no longer changes it
    /// (see `setRootStatus`), so a turn's stop arriving after the next prompt leaves that newer turn running.
    var rootStatusSetAt: Date? = nil
    /// When the newest turn started. Hooks run async, so the reply of the
    /// turn before can arrive after it and must not be shown again.
    var turnStartedAt: Date? = nil
    /// When the user last sent a prompt; the popover orders sessions by it.
    /// A background agent handing back (`.turnStarted`) is no prompt: the
    /// session didn't move for the user.
    public var lastPromptAt: Date? = nil
    /// When the root's current turn ended on its own, regularly or failed:
    /// what it left for the user is unread until a read mark reaches it
    /// (`CollectiveState.isUnread`). Nil while a turn runs, after one
    /// the user interrupted, as they were there, and before any turn ended.
    public var turnEndedAt: Date? = nil
    /// The background shells the session listed last, as of
    /// `backgroundShellsListedAt`: whether one runs now the newest sign says
    /// (`runsBackgroundShell`), as no event marks a shell's end.
    public var backgroundShells: [BackgroundShell] = []
    /// When the session listed `backgroundShells`; nil until it listed any.
    /// Hooks run async, so an older listing can arrive after a newer one
    /// and must not replace it.
    public var backgroundShellsListedAt: Date? = nil
    /// When the newest background shell started, as far as an event said;
    /// a listing older than this doesn't name it yet.
    var backgroundShellStartedAt: Date? = nil
    /// The newest sign of whether a background shell runs: a report, a
    /// listing or a shell's start. They come from hooks and live reports
    /// apart, so an older one arriving late must not replace it.
    var backgroundShellSign: DatedSign? = nil
    /// Whether the root's turn runs, as the newest sign says: a prompt or a
    /// hand-back starts it; its end, or a report that no turn runs, ends it.
    /// Tells a wait within a turn from one after it.
    var rootTurn: DatedSign? = nil
    /// When the user last gave the session input: a prompt, or the answer
    /// to an open permission request or question of any agent. A long turn
    /// counts from it: the time the user waited, not the time the
    /// turn ran. A hand-back is no input, as for `lastPromptAt`.
    var lastInputAt: Date? = nil
    /// When the root gave its `reply`; nil without one, and set and cleared
    /// only together with it. Tells one reply of the session from another.
    var rootRepliedAt: Date? = nil
    /// Set when this run replaced an earlier one under the same key. Only
    /// then is `startedAt` a real start, and anything older the earlier
    /// run's; a first run begins with whichever event arrived first.
    var isLaterRun = false
    /// When each agent asked the user to allow a tool call that nothing
    /// answered yet; one per agent, as two agents can ask at the same time.
    var permissionRequests: [AgentRef: Date] = [:]
    /// What each request in `permissionRequests` asks to run, for the
    /// popover's command box. Not the agent's current tool: a waiting agent
    /// shows none, so only the request names the command.
    var permissionTools: [AgentRef: ToolActivity] = [:]
    /// What showed each agent going on so far, and the whole session: hooks
    /// run async, so a request can arrive after what answered it.
    var permissionAnswers: [AgentRef: PermissionAnswers] = [:]
    var sessionPermissionAnswers = PermissionAnswers()
    /// The questions each agent asked the user that nothing answered yet.
    /// The same events end them as `permissionRequests`, and the answer.
    var questionRequests: [AgentRef: QuestionRequest] = [:]
    /// When the session last began to rest; read it only while `rests`.
    /// Kept by the reducer rather than derived: the end of a background shell
    /// is no field once the next report replaced it, and the times the
    /// fields hold (`lastActivity`, `lastReport`) move with every event,
    /// a repeated report included, so a session would never rest long enough.
    /// Stamped with the newest event when `rests` turns true, which is the
    /// latest of the root's turn end, the last subagent's end and the
    /// background shell's end; for a session that never had a turn, its first
    /// event. Events that leave `rests` as it was don't move it.
    var restingSince: Date? = nil
    /// How many rests the session has begun. Tells a rest begun anew from
    /// the one before even when both date from the same moment: backlog
    /// read late can end a rest and bring it back with the same start, and a
    /// session the sweep took for dead rests on from the same start once an
    /// event revives it.
    var restsBegun = 0

    public var id: SessionKey { key }
    public var root: Agent { agents[.root]! }

    /// Direct children of `ref`, oldest first.
    public func children(of ref: AgentRef) -> [Agent] {
        agents.values
            .filter { $0.parent == ref }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// Every agent below `ref` at any depth, each once and in no order.
    /// Indexes the parents once rather than scanning every agent per node,
    /// so a session with thousands of subagents costs no more than its
    /// size. `reparent` keeps cycles out, but one must not hang the walk.
    func descendants(of ref: AgentRef) -> [Agent] {
        let byParent = Dictionary(grouping: agents.values, by: \.parent)
        var found: [Agent] = []
        var seen: Set<AgentRef> = [ref]
        var pending = [ref]
        while let next = pending.popLast() {
            for child in byParent[next] ?? [] where seen.insert(child.id).inserted {
                found.append(child)
                pending.append(child.id)
            }
        }
        return found
    }

    public var activeAgentCount: Int {
        agents.values.count { $0.status.isActive }
    }

    /// A shell command an agent started in the background still runs, as
    /// the newest sign says, whatever the root does meanwhile: a report of
    /// one, a shell's start or a listing that names any. A turn running says
    /// nothing either way, so the shell runs on into the next one; a report
    /// that the session waits, idles or stands by, or an empty listing, says
    /// none runs. No event marks a shell's end.
    public var runsBackgroundShell: Bool {
        endedAt == nil && backgroundShellSign?.isSet == true
    }

    /// Whether `backgroundShells` names what runs: no shell started after
    /// that listing. Until the next one, which shells run is unknown. Hook
    /// times are whole seconds, so a start in the listing's second may be
    /// newer than it and counts as unlisted: the pill says only what is
    /// certain.
    public var listsNewestBackgroundShell: Bool {
        guard let listedAt = backgroundShellsListedAt else { return false }
        return backgroundShellStartedAt.map { $0 < listedAt } ?? true
    }

    /// Where to bring the session's terminal to the front; nil unless a
    /// source reported whose the terminal of the session's current process
    /// is (`AgentEvent.Kind.terminalReported`), or of the session itself for
    /// a source that names no process. Nor while presumed dead: a crashed
    /// process may never have its report taken back.
    public var terminalTarget: TerminalTarget? {
        guard agents[.root]?.status != .stale, let terminalReport, terminalReport.pid == pid,
              let terminal, terminal.pid == pid else { return nil }
        return terminal.identifiers.target(terminalReport.ownership)
    }

    /// Takes whose terminal the session's current process runs in; an
    /// `.unusable` takes the report back.
    mutating func reportTerminal(_ ownership: TerminalOwnership) {
        terminalReport = ownership == .unusable ? nil : TerminalReport(ownership: ownership, pid: pid)
    }

    /// Started ahead of time and waiting to be given work, as the newest
    /// report says: no session the user started, so it is neither shown nor
    /// counted (`CollectiveState.shownSessions`). Any later report from its
    /// own process shows it again, as does a new run, which starts without a
    /// report. Still once ended or presumed dead: a session that was never
    /// given work is none the user started either way.
    public var isStandby: Bool {
        lastReport?.activity == .standby
    }

    /// Whether `ref` waits for the user to allow a tool call. Not once it is
    /// done or presumed dead: nothing would answer its request anymore, and
    /// a revived agent waits again.
    public func awaitsPermission(_ ref: AgentRef) -> Bool {
        guard permissionRequests[ref] != nil, let status = agents[ref]?.status else { return false }
        return status == .working || status == .waiting
    }

    /// Whether any agent waits for the user to allow a tool call.
    public var awaitsPermission: Bool {
        agents.keys.contains(where: awaitsPermission)
    }

    /// Whether `ref` waits for the user to answer its questions; like
    /// `awaitsPermission(_:)`, not once it is done or presumed dead.
    public func awaitsAnswer(_ ref: AgentRef) -> Bool {
        guard questionRequests[ref] != nil, let status = agents[ref]?.status else { return false }
        return status == .working || status == .waiting
    }

    /// Whether any agent waits for the user to answer its questions.
    public var awaitsAnswer: Bool {
        agents.keys.contains(where: awaitsAnswer)
    }

    /// What `ref` asks the user while it `awaitsAnswer(_:)`, empty otherwise.
    public func openQuestions(of ref: AgentRef) -> [Question] {
        awaitsAnswer(ref) ? questionRequests[ref]?.questions ?? [] : []
    }

    /// Waits for nothing but the user's next prompt: the root waits, no agent
    /// works, no background shell runs, nothing asks to allow a tool call or
    /// asks a question and the newest report doesn't say the session needs
    /// the user, e.g. for a dialog. The popover moves a session that rests long enough to its
    /// "Idle" group. Archives don't matter here: an archived
    /// agent the source still reports working keeps the session from resting.
    var rests: Bool {
        endedAt == nil && root.status == .waiting && !agents.values.contains { $0.status == .working }
            && !runsBackgroundShell && !awaitsPermission && !awaitsAnswer && lastReport?.activity != .waiting
    }

    /// Waits for the user, not merely silent: no event is due, so silence
    /// says nothing about whether the session is still alive. Not when
    /// `markInterrupted` only guessed the wait, or an agent still works,
    /// unless an agent asks to allow a tool call or asks a question: until
    /// the user answers, nothing is due either.
    var reallyWaits: Bool {
        if awaitsPermission || awaitsAnswer { return true }
        return root.status == .waiting && rootBeforeInterruption == nil
            && !agents.values.contains { $0.status == .working }
    }

    init(key: SessionKey, startedAt: Date, cwd: String? = nil, pid: Int32? = nil) {
        self.key = key
        self.cwd = cwd
        self.pid = pid
        self.startedAt = startedAt
        self.lastActivity = startedAt
        self.agents = [
            .root: Agent(id: .root, parent: nil, spec: AgentSpec(), status: .waiting, startedAt: startedAt),
        ]
    }
}

/// The newest events that answer a permission request or a question.
/// Sources send a call's start alongside its request, before the user
/// answers, so a start in the request's second is likely the call it asks
/// for; anything else in that second comes after it and answers it. Hook
/// times are whole seconds. A status report counts as a start: it has no
/// order against the hooks of its second.
struct PermissionAnswers: Sendable, Equatable {
    var start: Date?
    var end: Date?

    func answer(requestAt date: Date) -> Bool {
        if let start, start > date { return true }
        if let end, end >= date { return true }
        return false
    }

    mutating func note(start date: Date) { start = max(start ?? date, date) }
    mutating func note(end date: Date) { end = max(end ?? date, date) }
}

/// An agent's open questions and when it asked them.
struct QuestionRequest: Sendable, Equatable {
    var date: Date
    var questions: [Question]
    /// The call that asks them, once a hook named it.
    var callID: String?
}

/// The orchestrator switched to `Session.model` at `at`.
public struct ModelSwitch: Sendable, Equatable {
    public var from: String
    public var at: Date

    public init(from: String, at: Date) {
        self.from = from
        self.at = at
    }
}

/// The orchestrator changed to `Session.effort` at `at`.
public struct EffortChange: Sendable, Equatable {
    public var from: EffortLevel
    public var at: Date

    public init(from: EffortLevel, at: Date) {
        self.from = from
        self.at = at
    }
}

/// The root's state before `markInterrupted` guessed it waiting.
struct InterruptedRoot: Sendable, Equatable {
    var status: AgentStatus
    var currentTool: ToolActivity?
}

/// A yes or no as of `date`, from events that can arrive in any order.
struct DatedSign: Sendable, Equatable {
    var isSet: Bool
    var date: Date

    /// Takes `isSet` unless `sign` is strictly newer. Hook times are whole
    /// seconds, so within one second the later applied wins; a report has
    /// milliseconds, so one within a hook's second counts as newer, as for
    /// the root's status (`setRootStatus`).
    static func note(_ isSet: Bool, at date: Date, in sign: inout DatedSign?) {
        if let sign, date < sign.date { return }
        sign = DatedSign(isSet: isSet, date: date)
    }
}

struct ActivityReport: Sendable, Equatable {
    var activity: SessionActivity
    var date: Date
    /// The process that reported, if the source names it: a session takes
    /// such a report only from its own, so a new run in another process
    /// must not inherit it.
    var pid: Int32? = nil
}

/// Terminal identifiers and the process whose events carried them; nil for
/// a source that names no process.
struct ProcessTerminal: Sendable, Equatable {
    var identifiers: TerminalIdentifiers
    var pid: Int32?
}

/// Whose terminal a process runs in, as its source reported; never
/// `.unusable`, which takes the report back.
struct TerminalReport: Sendable, Equatable {
    var ownership: TerminalOwnership
    var pid: Int32?
}

/// A session's name and when the source named it.
struct SessionName: Sendable, Equatable {
    var name: String
    var date: Date
}
