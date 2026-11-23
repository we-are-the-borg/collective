import Foundation

/// A tool-neutral fact about agent activity. Adapters translate their tool's raw
/// data into these; the store and UI only ever see `AgentEvent`s.
public struct AgentEvent: Sendable, Equatable {
    public let session: SessionKey
    public let timestamp: Date
    public let kind: Kind
    /// What the source knows about the session alongside any event, so a
    /// session whose start was never seen still gets its directory and
    /// process. The store only fills what it doesn't know yet. `pid` follows
    /// the rule of `sessionStarted`: only the session's own process. For
    /// `activityReported`, `sessionNamed` and `terminalReported` it is the
    /// process that reports instead, which need not be the session's: see there.
    public let cwd: String?
    public let pid: Int32?
    /// The terminal the event's process runs in, if the source knows it. It
    /// is the session's only while a source vouches for it (`terminalReported`),
    /// and the store keeps it only from the session's own process, or, for a
    /// session without one, from an event without one.
    public let terminal: TerminalIdentifiers?

    public init(
        session: SessionKey, timestamp: Date, kind: Kind, cwd: String? = nil, pid: Int32? = nil,
        terminal: TerminalIdentifiers? = nil
    ) {
        self.session = session
        self.timestamp = timestamp
        self.kind = kind
        self.cwd = cwd
        self.pid = pid
        self.terminal = terminal
    }

    public enum Kind: Sendable, Equatable {
        /// A session began. `pid` lets the store detect crashed sessions, so an
        /// adapter passes it only if it identifies this session's own process;
        /// a shared one (e.g. a daemon) would keep dead sessions alive. Without
        /// it the store falls back to a silence timeout.
        case sessionStarted(cwd: String?, pid: Int32?)
        /// The user sent a prompt to the orchestrator.
        case promptSubmitted(String)
        /// An agent started a subagent. `parent` is `.root` unless subagents nest.
        case agentSpawned(id: String, parent: AgentRef, spec: AgentSpec)
        /// An agent started using a tool. `callID` is the source's id of the
        /// call, which pairs it with its end; it stays out of
        /// `ToolActivity`, which is what is shown. `alreadyEnded` says the
        /// source knows by the time the start arrives that the call can't be
        /// running anymore: for Claude Code its end came first (hooks run
        /// async), for Codex only the turn it belongs to is over already, so
        /// its own end may still follow. The call is still reported, but no
        /// agent shows it as its tool.
        case toolStarted(agent: AgentRef, ToolActivity, callID: String? = nil, alreadyEnded: Bool = false)
        /// An agent's current tool call completed. `callID` matches the
        /// start's; `duration` is the source's own measurement of the call.
        case toolFinished(agent: AgentRef, callID: String? = nil, duration: TimeInterval? = nil)
        /// An agent asks the user to allow a tool call, shown like the call's
        /// start. The store changes no status, tool or reply for it: whether the
        /// session waits is the source's to report. The agent awaits permission
        /// until a later event shows it went on (`Session.awaitsPermission`).
        /// Like any event it still counts as activity of its agent, revokes the
        /// guess of an interrupted turn and makes an unknown session known.
        case permissionRequested(agent: AgentRef, ToolActivity)
        /// An agent asks the user and waits for the answer. `callID` pairs
        /// the questions with the call that asks them, if the source names
        /// it. Like a permission request it changes no status: the agent
        /// awaits an answer until the user answers or a later event shows it
        /// went on (`Session.awaitsAnswer`).
        case questionAsked(agent: AgentRef, [Question], callID: String? = nil)
        /// The user answered an agent's questions; `answer` is filled for
        /// each question the user answered.
        case questionAnswered(agent: AgentRef, [Question], callID: String? = nil)
        /// A subagent finished its work.
        case agentFinished(id: String)
        /// A subagent that had finished works again, e.g. because its
        /// orchestrator sent it a follow-up. The source says so explicitly:
        /// a repeated spawn never changes status, since one can arrive after
        /// the subagent's own end. A later run's start; the first start stays.
        case agentResumed(id: String)
        /// The orchestrator started working without a new user prompt, e.g.
        /// because a background subagent reported back. The shown prompt stays.
        case turnStarted
        /// The orchestrator finished its turn and waits for the user. The
        /// store treats every outcome alike except that an interrupted turn
        /// sets no `turnEndedAt`: the user stopped it themselves, so it leaves
        /// nothing unread.
        case turnEnded(TurnOutcome = .completed)
        /// The session ended.
        case sessionEnded
        /// A source that knows the session's live state reports it. The
        /// event's timestamp is when that state began. With the event's `pid`
        /// the source names the process that reports; the store then takes
        /// the report only from the session's own process and keeps it
        /// waiting until the session has that one. That pid never becomes
        /// the session's.
        case activityReported(SessionActivity)
        /// The orchestrator runs with model `to` from now on. `from` is the
        /// model before, if the source names it. Sources may repeat the
        /// current model, e.g. on a session restart; that is no switch.
        case modelChanged(to: String, from: String?)
        /// An agent runs with this effort from now on. Sources may repeat the
        /// current one; that is no change. Like a listing of background
        /// shells it says nothing about activity and comes after its hook's
        /// own events, which make the session and agent known: for an unknown
        /// or ended session, or an agent the session doesn't know, it is dropped.
        case effortReported(agent: AgentRef, EffortLevel)
        /// An agent gave its reply for the turn or task it is about to end.
        case replied(agent: AgentRef, String)
        /// A source names the session, e.g. with a name the user can change
        /// in the tool. The newest name wins; it says nothing about activity.
        /// The event's `pid` counts as for `activityReported`.
        case sessionNamed(String)
        /// A source that knows whose the terminal of the event's process is
        /// says so: the session's own, or a process's that hosts the session,
        /// e.g. a daemon's, or `.unusable` when the source can't tell
        /// anymore. Without a report other than `.unusable` from the
        /// session's own process the session has no terminal to bring to the
        /// front (`Session.terminalTarget`). The event's `pid` counts as for
        /// `activityReported`, except that one without a `pid` is only for a
        /// session without one, as a source that names no process sends it;
        /// like a name it says nothing about activity.
        /// An `.unusable` with a `pid` is about the process, not only the
        /// event's session: it takes back the terminal of every session that
        /// process reported, e.g. one it ran before it switched to another
        /// session.
        case terminalReported(TerminalOwnership)
        /// The background shells still running when an agent ended its turn
        /// or task, in the source's order; empty when none runs. Only a
        /// snapshot: no event marks a shell's end, so whether one runs now,
        /// the newest of a listing, a live report (`SessionActivity.backgroundShell`)
        /// or a shell's start says (`Session.runsBackgroundShell`).
        /// Like a name it says nothing about activity.
        case backgroundShellsListed([BackgroundShell])
        /// An agent started a shell command in the background; `id` is the
        /// source's id of the shell, as later listings name it. Whether it
        /// still runs, the next report or listing says; like a listing it
        /// says nothing about activity.
        case backgroundShellStarted(id: String)
    }
}

/// A session's live state as a source reports it, as opposed to what the
/// store infers from individual events.
public enum SessionActivity: Sendable, Equatable {
    /// A turn runs.
    case working
    /// The session needs the user, e.g. to answer a permission dialog.
    case waiting
    /// No turn runs and nothing else either, background subagents included.
    case idle
    /// No turn runs, but a shell command the agent started in the background
    /// still does. Background subagents may run too.
    case backgroundShell
    /// The tool started the session's process ahead of time, and it waits to
    /// be given work: no session the user started, so nothing shows it
    /// (`Session.isStandby`). Nothing runs, as for `idle`.
    case standby
}

/// How the orchestrator's turn ended.
public enum TurnOutcome: Sendable, Equatable {
    /// The turn ran to its regular end.
    case completed
    /// The user or the tool stopped the turn before it finished.
    case interrupted
    /// The turn ended on an error, e.g. a failed API request or a rate limit.
    case failed
}

/// What is known about a subagent when it is spawned. Everything is optional
/// because tools expose different amounts of detail.
public struct AgentSpec: Sendable, Equatable {
    public var type: String?
    public var title: String?
    public var prompt: String?
    /// The model the spawn call asked for, as the source names it (often an
    /// alias such as `haiku`); `nil` when the subagent inherits its model.
    public var modelAlias: String?
    /// The full model the subagent runs with, inherited or not.
    public var modelID: String?
    /// Whether the subagent runs in the background, i.e. may outlive the
    /// orchestrator's turn. `nil` when the source doesn't say.
    public var isBackground: Bool?

    public init(
        type: String? = nil,
        title: String? = nil,
        prompt: String? = nil,
        modelAlias: String? = nil,
        modelID: String? = nil,
        isBackground: Bool? = nil
    ) {
        self.type = type
        self.title = title
        self.prompt = prompt
        self.modelAlias = modelAlias
        self.modelID = modelID
        self.isBackground = isBackground
    }
}

/// A question an agent asks the user, with the choices it offers.
public struct Question: Sendable, Equatable {
    /// A short label for the question, if the source gives one.
    public var header: String?
    public var text: String
    public var options: [QuestionOption]
    /// Whether the user may pick more than one option.
    public var allowsMultiple: Bool
    /// Whether the source lets the user type an answer of their own besides
    /// the options, offered as the last choice ("Other"). Off unless the
    /// adapter knows its tool offers one: a choice the tool lacks would send
    /// the user to look for it in Terminal.
    public var allowsOwnAnswer: Bool
    /// The answer as the source reports it, nil while unanswered. Not
    /// necessarily one of the options' labels: the user may type their own,
    /// and several picked options may come as one text.
    public var answer: String?

    public init(
        header: String? = nil,
        text: String,
        options: [QuestionOption] = [],
        allowsMultiple: Bool = false,
        allowsOwnAnswer: Bool = false,
        answer: String? = nil
    ) {
        self.header = header
        self.text = text
        self.options = options
        self.allowsMultiple = allowsMultiple
        self.allowsOwnAnswer = allowsOwnAnswer
        self.answer = answer
    }
}

public struct QuestionOption: Sendable, Equatable {
    public var label: String
    /// What the option means, if the source describes it.
    public var detail: String?

    public init(label: String, detail: String? = nil) {
        self.label = label
        self.detail = detail
    }
}

/// A shell command an agent started in the background, as a snapshot lists it.
public struct BackgroundShell: Sendable, Equatable {
    /// The source's id of the shell, stable across snapshots.
    public var id: String
    public var command: String?
    /// What the agent said the command does, if it said.
    public var description: String?

    public init(id: String, command: String? = nil, description: String? = nil) {
        self.id = id
        self.command = command
        self.description = description
    }
}

public struct ToolActivity: Sendable, Equatable {
    /// Tool name as the source reports it, e.g. `"Bash"`.
    public var name: String
    /// Short human-readable detail, e.g. the command or file path.
    public var detail: String?
    /// The whole text `detail` was cut from, e.g. a multi-line command; nil
    /// when `detail` says it all. Adapters fill it on a permission request,
    /// whose command box shows more than one line.
    public var fullDetail: String?

    public init(name: String, detail: String? = nil, fullDetail: String? = nil) {
        self.name = name
        self.detail = detail
        self.fullDetail = fullDetail
    }

    /// A request asks to run the whole command, so it carries all of it
    /// besides the first line. Without the blank lines and spaces around it:
    /// the box would show them, and a one-line command would differ from its
    /// detail only by them. The detail stays as a tool start's. The popover's
    /// command box shows `fullDetail`, so this is what fills it.
    public func requesting(_ command: String?) -> ToolActivity {
        var tool = self
        let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let command = command?.trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty, command != detail { tool.fullDetail = command }
        return tool
    }
}
