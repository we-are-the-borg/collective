import Foundation

/// Identifies a reply: on a finished row, on a waiting card and on an idle
/// row. Keyed by when it was given, so a newer reply is another one.
public enum ReplyID: Hashable, Sendable {
    /// A session's reply while its turn is over: the waiting card's excerpt
    /// and the idle row's reply. Keyed by when it was given.
    case session(SessionKey, repliedAt: Date)
    /// A finished session's reply on its row. Keyed by when it was given as
    /// well, so the next turn's reply is another one: a finished session can
    /// be resumed and finish again with another reply. A count of turns
    /// would not do: it starts over when the session is resumed or seen
    /// again after it was forgotten.
    case finished(SessionKey, repliedAt: Date)
    /// A done subagent's result on its row in the card's subagent list.
    /// Keyed by the agent, which gives one result only.
    case agent(SessionKey, AgentRef)

    /// Nil for a subagent's result: its row counts no time since it.
    var repliedAt: Date? {
        switch self {
        case let .session(_, repliedAt), let .finished(_, repliedAt): repliedAt
        case .agent: nil
        }
    }
}

/// Identifies the fold row on one level of a card's subagent list: the
/// children of `parent`. Keyed by the level, not by its members, so an open
/// fold row stays open while more of its siblings finish.
public struct SubagentFoldID: Hashable, Sendable {
    public let session: SessionKey
    public let parent: AgentRef

    public init(session: SessionKey, parent: AgentRef) {
        self.session = session
        self.parent = parent
    }
}

/// What the user opened or closed by hand in the session list. The app keeps
/// it while it runs and passes it into every `PopoverModel`, so a choice
/// survives rebuilds. The cards themselves never expand, and
/// neither does their reply: it reads in full in the reply card.
public struct PopoverExpansion: Sendable, Equatable {
    /// The tab the popover shows. Only the user switches it, a new request
    /// for permission included: "◆ n" on Active tells of that.
    public private(set) var selectedTab: PopoverTab = .active
    /// The known sessions under a subspace warning show only when opened here.
    public private(set) var isEarlierSessionsOpen = false
    /// Each card's subagent list as the user left it: open or closed by hand.
    /// A session without an entry follows `SubagentList`'s own rule.
    private var subagentListChoices: [SessionKey: Bool] = [:]
    /// The fold rows of finished subagents the user opened.
    public private(set) var openSubagentFolds: Set<SubagentFoldID> = []

    public init() {}

    public mutating func select(_ tab: PopoverTab) {
        selectedTab = tab
    }

    /// Every opening starts on Active, whichever tab the user left open.
    public mutating func popoverOpened() {
        selectedTab = .active
    }

    public mutating func toggleEarlierSessions() {
        isEarlierSessionsOpen.toggle()
    }

    /// Opens or closes the card's subagent list, and keeps it so for as long
    /// as the app runs, whatever its own rule would say.
    /// - Parameter isOpen: Whether the list shows open now (`SubagentList.isOpen`),
    ///   which the rule may have decided rather than the user.
    public mutating func toggleSubagents(_ key: SessionKey, isOpen: Bool) {
        subagentListChoices[key] = !isOpen
    }

    public mutating func toggleSubagentFold(_ id: SubagentFoldID) {
        if openSubagentFolds.remove(id) == nil { openSubagentFolds.insert(id) }
    }

    /// The user's choice for the session's subagent list; nil while they made none.
    func subagentListChoice(_ key: SessionKey) -> Bool? {
        subagentListChoices[key]
    }
}
