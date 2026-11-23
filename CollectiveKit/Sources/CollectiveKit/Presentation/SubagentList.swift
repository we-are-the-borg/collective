import Foundation

/// A session's subagents one by one, opened from its row's toggle line.
/// Closed by default; open by itself while a subagent needs the user or a
/// subagent's undo row shows, until the user opens or closes it by hand
/// (`PopoverExpansion.toggleSubagents`).
public struct SubagentList: Sendable, Equatable {
    /// What the toggle passes on.
    public let session: SessionKey
    public let isOpen: Bool
    /// Empty while closed: a session can have hundreds of subagents, and the
    /// summary line counts them anyway. Newest first on every level, each
    /// agent followed by its own subagents; the done and archived ones of a
    /// level folded into one row at the place of the newest. An archived
    /// subagent whose undo row shows keeps its place and stands in for its
    /// subtree until the row goes.
    public let entries: [SubagentEntry]

    /// - Parameter needsYou: A subagent that is not archived waits for the
    ///   user to allow a tool call or to answer a question.
    init(_ build: SubagentListBuild, needsYou: Bool) {
        session = build.session.key
        // Archiving the subagent that opened the list must not take its undo row away.
        isOpen = build.expansion.subagentListChoice(build.session.key) ?? (needsYou || !build.archive.undo.isEmpty)
        entries = isOpen ? build.entries() : []
    }
}

/// A line in a card's subagent list: a subagent, or the fold row standing in
/// for the finished ones of a level.
public enum SubagentEntry: Sendable, Equatable, Identifiable {
    case agent(SubagentRow)
    case fold(SubagentFoldRow)

    public enum ID: Hashable, Sendable {
        case agent(AgentRef)
        case fold(SubagentFoldID)
    }

    public var id: ID {
        switch self {
        case let .agent(row): .agent(row.id)
        case let .fold(fold): .fold(fold.id)
        }
    }

    /// 1 for the orchestrator's own subagents; the view indents each level once more.
    public var depth: Int {
        switch self {
        case let .agent(row): row.depth
        case let .fold(fold): fold.depth
        }
    }

    public var row: SubagentRow? {
        if case let .agent(row) = self { row } else { nil }
    }
}

/// "33 done | 2 archived": the done and archived subagents of one level,
/// with their own subagents, in one row. Open, its members follow one level
/// deeper. Lost contact never folds: it may still need a look.
public struct SubagentFoldRow: Sendable, Equatable, Identifiable {
    /// What the view passes on when the row is toggled.
    public let id: SubagentFoldID
    public let depth: Int
    /// Archived members count only as archived, whatever their status.
    public let doneCount: Int
    public let archivedCount: Int
    public let isOpen: Bool

    /// The non-zero counts, e.g. "13 done", "1 archived"; the view joins them
    /// with its separator.
    public var textParts: [LocalizedStringResource] {
        var parts: [LocalizedStringResource] = []
        if doneCount > 0 { parts.append(.kit("%lld done", defaultValue: "\(doneCount) done")) }
        if archivedCount > 0 { parts.append(.kit("%lld archived", defaultValue: "\(archivedCount) archived")) }
        return parts
    }

    /// "33 done, folded".
    public var accessibilityText: LocalizedStringResource {
        let state: LocalizedStringResource = isOpen
            ? .kit("unfolded", defaultValue: "unfolded")
            : .kit("folded", defaultValue: "folded")
        return AccessibilityParts.joined(textParts.map(AccessibilityParts.Part.text) + [.text(state)])
    }
}

/// What a subagent's row shows it doing.
public enum SubagentStatus: Sendable, Equatable {
    case working
    /// Waits for the user to allow a tool call; wins over every other state
    /// but `archived`, as on the card.
    case needsPermission
    /// Waits for the user to answer its questions.
    case question
    case done
    /// The source stopped reporting it (`AgentStatus.stale`).
    case lostContact
    /// Working, but the source has not named it yet ("Awaiting designation…").
    case unassigned
    /// Put away by the user; only shows among the members of an open fold row.
    case archived

    /// Needs the user: the row draws its status in amber.
    public var needsYou: Bool { self == .needsPermission || self == .question }

    /// The runtime counts while the subagent is alive; afterwards VoiceOver
    /// reads its spawn position instead.
    var countsRuntime: Bool {
        switch self {
        case .working, .needsPermission, .question, .unassigned: true
        case .done, .lostContact, .archived: false
        }
    }
}

/// Which name a subagent row's title shows.
public enum SubagentTitleKind: Sendable, Equatable {
    /// The source's agent type ("plugin:implementer").
    case type
    /// No type yet: the task's title stands in.
    case title
    /// Neither: "Awaiting designation…".
    case awaitingDesignation
}

/// What VoiceOver reads of a subagent beyond its status; the row itself
/// shows no second line.
public enum SubagentDetail: Sendable, Equatable {
    /// "Needs your permission", then what it asks to run; nil while nothing says.
    case needsPermission(ActivityLine?)
    /// "Question for you", then the first open question's text; nil for a
    /// question the source sent without one.
    case question(count: Int, text: String?)
    /// The working subagent's tool, "Thinking…", "No activity", or the
    /// subagents it waits on.
    case activity(ActivityLine)
    /// "last event 3 min ago", counted from `lastEvent`.
    case lostContact(lastEvent: Date)

    /// What VoiceOver names a subagent waiting for permission.
    public static var needsPermissionText: LocalizedStringResource {
        .kit("Needs your permission", defaultValue: "Needs your permission")
    }

    /// What VoiceOver names `.question`: "Question for you", "2 Questions for you".
    public static func questionText(count: Int) -> LocalizedStringResource {
        .kit("%lld Questions for you", defaultValue: "\(count) Questions for you")
    }
}

/// One subagent in a card's list.
public struct SubagentRow: Sendable, Equatable, Identifiable {
    public let ref: AgentRef
    /// 1 for the orchestrator's own subagents, one more per level; members of
    /// an open fold row sit one level below it.
    public let depth: Int
    public let status: SubagentStatus
    /// The kind of agent the source names, e.g. "Explore"; what the row is titled by.
    public let type: String?
    /// The source's short description of the task, e.g. "Run sleep command".
    public let title: String?
    public let isBackground: Bool
    /// The subagent's own model; nil while the source names none, never the
    /// session's in its place.
    public let model: ModelLabel?
    /// The start of the current run, which the runtime counts from: a
    /// resumed subagent's is its resume. Its place goes by its
    /// first start (`position`).
    public let startedAt: Date
    /// When its last event arrived, for the context menu's "Last event … ago".
    public let lastActivity: Date
    /// 1-based place among all of the session's subagents, at any depth, by
    /// start: the "5" of VoiceOver's "5 of 6".
    public let position: Int
    /// The session's subagents at any depth: the "6" of "5 of 6".
    public let total: Int
    /// What VoiceOver reads after the status; nil for a done subagent and one
    /// still waiting for a type.
    public let detail: SubagentDetail?
    /// Trimmed like `SessionItem.prompt`; nil if blank. For the row's preview.
    public let prompt: String?
    /// The subagent's result, only once it is done. For the row's preview.
    public let reply: ReplyItem?
    /// Set while its archive can be undone: the row shows this in its place
    /// instead, and its subtree waits below it unlisted.
    public let undo: UndoRow?

    public var id: AgentRef { ref }

    /// "Archive Subagent" in the menu: exactly while it may hang, working
    /// included, since the archive is for subagents that never end;
    /// nothing to put away once done or archived.
    public var isArchivable: Bool {
        switch status {
        case .working, .needsPermission, .question, .unassigned, .lostContact: true
        case .done, .archived: false
        }
    }

    /// The disabled first line of the row's menu, so the user can tell a
    /// hanging subagent from a quiet one before archiving it; counts from
    /// `lastActivity`.
    public func lastEventText(at now: Date) -> LocalizedStringResource {
        .kit("Last event %@ ago", defaultValue: "Last event \(DurationText.format(now.timeIntervalSince(lastActivity))) ago")
    }

    /// The type, else the title, else "Awaiting designation…": a subagent
    /// the source has not named at all yet.
    public var titleText: LocalizedStringResource {
        if let name = type ?? title { return .kit("%@", defaultValue: "\(name)") }
        return Self.awaitingDesignationText
    }

    /// What `titleText` is, so the row draws only a type in mono.
    public var titleKind: SubagentTitleKind {
        if type != nil { return .type }
        if title != nil { return .title }
        return .awaitingDesignation
    }

    /// The model behind the title; a subagent without a name shows none.
    public var titleModel: ModelLabel? {
        titleKind == .awaitingDesignation ? nil : model
    }

    public static var awaitingDesignationText: LocalizedStringResource {
        .kit("Awaiting designation…", defaultValue: "Awaiting designation…")
    }

    /// Follows the model of a subagent that runs on its own, on the row and for VoiceOver.
    public static var backgroundText: LocalizedStringResource {
        .kit("background", defaultValue: "background")
    }

    /// The start while VoiceOver reads the runtime; nil once it reads the
    /// position instead, so the view's clock can stop.
    public var runningSince: Date? { status.countsRuntime ? startedAt : nil }

    /// What VoiceOver reads for the row at the view's clock: "Explore, Haiku
    /// 5.5, effort low, background, working, 40 s, Grep ReplyView"; missing parts left out.
    public func accessibilityText(at now: Date) -> LocalizedStringResource {
        var parts: [AccessibilityParts.Part] = [.text(titleText)]
        // The row ignores its children, so the model's own element with the effort is never read.
        if let model { parts.append(.text(model.accessibilityLabel)) }
        if isBackground { parts.append(.text(Self.backgroundText)) }
        parts.append(.text(statusText))
        parts.append(.text(
            runningSince.map { DurationText.format(now.timeIntervalSince($0)) }
                ?? .kit("%lld of %lld", defaultValue: "\(position) of \(total)")
        ))
        switch detail {
        case let .needsPermission(activity?), let .activity(activity): parts += activity.accessibilityParts(at: now)
        case let .question(_, text?): parts.append(.verbatim(text))
        case let .lostContact(lastEvent):
            parts.append(.text(.kit("last event %@ ago", defaultValue: "last event \(DurationText.format(now.timeIntervalSince(lastEvent))) ago")))
        case .needsPermission(nil), .question(_, nil), nil: break
        }
        return AccessibilityParts.joined(parts)
    }

    /// The state as VoiceOver names it.
    private var statusText: LocalizedStringResource {
        switch status {
        case .working: .kit("working", defaultValue: "working")
        case .needsPermission: SubagentDetail.needsPermissionText
        case .question:
            // The detail's count, not 1: a subagent can ask several at once.
            if case let .question(count, _) = detail { SubagentDetail.questionText(count: count) } else { SubagentDetail.questionText(count: 1) }
        case .done: .kit("done", defaultValue: "done")
        case .lostContact: .kit("lost contact", defaultValue: "lost contact")
        case .unassigned: .kit("awaiting designation", defaultValue: "awaiting designation")
        case .archived: .kit("archived", defaultValue: "archived")
        }
    }
}

/// Joins the parts of a VoiceOver label with commas, the agent's own words
/// (types, model names, tool details) as they are.
enum AccessibilityParts {
    enum Part {
        case text(LocalizedStringResource)
        case verbatim(String)
    }

    /// Nests each part into one resource, so all of them resolve together
    /// in the same language.
    static func joined(_ parts: [Part]) -> LocalizedStringResource {
        guard let first = parts.first else { return .kit("%@", defaultValue: "\(String())") }
        let start: LocalizedStringResource = switch first {
        case let .text(text): text
        case let .verbatim(text): .kit("%@", defaultValue: "\(text)")
        }
        return parts.dropFirst().reduce(start) { joined, part in
            switch part {
            case let .text(text): .kit("%@, %@", defaultValue: "\(joined), \(text)")
            case let .verbatim(text): .kit("%@, %@", defaultValue: "\(joined), \(text)")
            }
        }
    }
}

private extension ActivityLine {
    /// The line as VoiceOver reads it, as the card's line 2 does.
    func accessibilityParts(at now: Date) -> [AccessibilityParts.Part] {
        switch self {
        case let .tool(tool):
            if let detail = tool.detail, !detail.isEmpty { [.verbatim("\(tool.name) \(detail)")] } else { [.verbatim(tool.name)] }
        case let .subagentsWorking(count): [.text(.kit("%lld subagents working", defaultValue: "\(count) subagents working"))]
        case .thinking: [.text(.kit("Thinking…", defaultValue: "Thinking…"))]
        case let .noActivity(since): [.text(Self.noActivityText(since: since, at: now))]
        }
    }
}

/// Everything a session's subagent rows are made of, built once per item.
struct SubagentListBuild {
    let session: Session
    let archive: SessionArchive
    let modelNaming: any ModelNaming
    let now: Date
    let expansion: PopoverExpansion
    let replyPreviews: ReplyPreviewCache.Build
    /// `ActivityLine.waitingOn(in:archive:)`, counted once for the item.
    let waitingOn: [AgentRef: Int]
    /// `PopoverSettings.colorsEffortLevels`.
    var colorsEffortLevels = true

    /// Depth-first from the orchestrator's own subagents, each level
    /// newest first with its finished ones folded. Indexes the tree once:
    /// asking each node for its children would scan the session per node.
    func entries() -> [SubagentEntry] {
        let all = session.descendants(of: .root)
        let byParent = Dictionary(grouping: all, by: \.parent).mapValues { $0.sorted(by: Self.newestFirst) }
        let positions = Dictionary(uniqueKeysWithValues: all.sorted { Self.newestFirst($1, $0) }.enumerated().map { ($1.id, $0 + 1) })
        let statuses = Dictionary(uniqueKeysWithValues: all.map { ($0.id, status(of: $0)) })
        var tree = Tree(byParent: byParent, positions: positions, statuses: statuses, total: all.count, undo: archive.undo)
        return entries(below: .root, depth: 1, in: &tree)
    }

    private struct Tree {
        let byParent: [AgentRef?: [Agent]]
        let positions: [AgentRef: Int]
        let statuses: [AgentRef: SubagentStatus]
        let total: Int
        /// Archived subagents whose undo row still shows.
        let undo: [AgentRef: ArchiveUndo.ID]
        /// Whether each agent folds, worked out once per agent.
        var folds: [AgentRef: Bool] = [:]

        /// Done or archived with its undo row gone, and so is everything
        /// below it: a finished agent whose subagent still works keeps its
        /// row, so the work stays in view.
        mutating func foldsAway(_ agent: Agent) -> Bool {
            if let known = folds[agent.id] { return known }
            let over = statuses[agent.id] == .done || (statuses[agent.id] == .archived && undo[agent.id] == nil)
            let result = over && (byParent[agent.id] ?? []).allSatisfy { foldsAway($0) }
            folds[agent.id] = result
            return result
        }
    }

    private func entries(below parent: AgentRef, depth: Int, in tree: inout Tree) -> [SubagentEntry] {
        let level = tree.byParent[parent] ?? []
        let folded = level.filter { tree.foldsAway($0) }
        var result: [SubagentEntry] = []
        var placedFold = false
        for agent in level {
            guard tree.foldsAway(agent) else {
                result += subtree(agent, depth: depth, in: &tree)
                continue
            }
            guard !placedFold else { continue }
            placedFold = true
            let id = SubagentFoldID(session: session.key, parent: parent)
            let isOpen = expansion.openSubagentFolds.contains(id)
            result.append(.fold(SubagentFoldRow(
                id: id, depth: depth,
                doneCount: folded.count { tree.statuses[$0.id] == .done },
                archivedCount: folded.count { tree.statuses[$0.id] == .archived },
                isOpen: isOpen
            )))
            if isOpen {
                for member in folded { result += subtree(member, depth: depth + 1, in: &tree) }
            }
        }
        return result
    }

    private func subtree(_ agent: Agent, depth: Int, in tree: inout Tree) -> [SubagentEntry] {
        let own = SubagentEntry.agent(row(agent, depth: depth, tree: tree))
        // The undo row stands in for the subtree, as a session's does for its card.
        guard tree.undo[agent.id] == nil else { return [own] }
        return [own] + entries(below: agent.id, depth: depth + 1, in: &tree)
    }

    private func status(of agent: Agent) -> SubagentStatus {
        if archive.isArchived(agent.id) { return .archived }
        if session.awaitsPermission(agent.id) { return .needsPermission }
        if session.awaitsAnswer(agent.id) { return .question }
        return switch AgentDisplayState(subagent: agent, archived: false) {
        case .unassigned: .unassigned
        case .done: .done
        case .stale: .lostContact
        // A subagent does not wait for a prompt; one the source still reports
        // alive shows working.
        default: .working
        }
    }

    private func row(_ agent: Agent, depth: Int, tree: Tree) -> SubagentRow {
        let status = tree.statuses[agent.id] ?? .working
        let activity = ActivityLine(agent, waitingOn: waitingOn, archive: archive, now: now)
        let questions = status == .question ? session.openQuestions(of: agent.id) : []
        let detail: SubagentDetail? = switch status {
        case .needsPermission: .needsPermission(activity)
        case .question: .question(count: max(1, questions.count), text: questions.first?.text)
        case .working: activity.map(SubagentDetail.activity)
        case .lostContact: .lostContact(lastEvent: agent.lastActivity)
        case .done, .unassigned, .archived: nil
        }
        let type = agent.spec.type.flatMap { $0.isEmpty ? nil : $0 }
        let title = agent.spec.title.flatMap { $0.isEmpty ? nil : $0 }
        return SubagentRow(
            ref: agent.id,
            depth: depth,
            status: status,
            type: type,
            title: title,
            isBackground: agent.spec.isBackground == true,
            model: ModelLabel(knownModelOf: agent, naming: modelNaming, colorsEffort: colorsEffortLevels),
            startedAt: agent.runStartedAt,
            lastActivity: agent.lastActivity,
            position: tree.positions[agent.id] ?? 0,
            total: tree.total,
            detail: detail,
            prompt: PromptText.display(agent.spec.prompt),
            reply: status == .done
                ? ReplyItem(agent.reply, id: .agent(session.key, agent.id), previews: replyPreviews)
                : nil,
            undo: tree.undo[agent.id].map { UndoRow(id: $0, subject: .subagent(name: type ?? title)) }
        )
    }

    /// Newest first; agents that started in the same moment by id, so rows
    /// never swap places between two renders.
    static func newestFirst(_ lhs: Agent, _ rhs: Agent) -> Bool {
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
        return lhs.id.sortKey < rhs.id.sortKey
    }
}
