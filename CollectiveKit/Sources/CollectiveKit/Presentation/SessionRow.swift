import Foundation

// The parts of a restyled row, each with the theme role it is drawn in, so
// "color only from roles" is a rule the kit tests rather than the views.

/// The form at the head of a row, on a 12-point grid; sizes are the view's.
public enum StatusShape: Sendable, Equatable {
    /// A filled dot in a filled halo. `bright` marks a working session's
    /// brighter halo, a subagent's row draws the fainter one;
    /// neither moves, since a pulse redrew the whole popover every frame.
    case haloDot(bright: Bool)
    /// Filled: something needs the user.
    case diamond
    /// A faint filled halo with a ring on it, still: only a background shell runs.
    case hollowHalo
    /// Idle, or a subagent not named yet.
    case ring
    case check
    /// The process ended without a clean exit, or a subagent lost contact.
    case dashedRing
}

/// A row's shape and status word with their roles: color only at the status.
public struct StatusMark: Sendable {
    public let shape: StatusShape
    public let shapeRole: ThemeRole
    /// Replaces the pills ("Waiting for you", "Needs permission", …). Nil
    /// where the row's title already says it ("Awaiting designation…").
    public let word: LocalizedStringResource?
    public let wordRole: ThemeRole
    /// Tooltip and VoiceOver hint; only "no clean exit" explains itself.
    public let help: LocalizedStringResource?

    init(_ shape: StatusShape, _ shapeRole: ThemeRole, _ word: LocalizedStringResource?, _ wordRole: ThemeRole, help: LocalizedStringResource? = nil) {
        self.shape = shape
        self.shapeRole = shapeRole
        self.word = word
        self.wordRole = wordRole
        self.help = help
    }
}

/// What a session's row says it is doing, in every tab. A call to act wins
/// as on the card (`CardState`): permission, then a question, then the
/// orchestrator's own state.
public enum RowStatus: Sendable, Equatable {
    case working
    /// The orchestrator rests while `count` background agents work. Shows the
    /// word of `.working`; the case stays for ordering and the subagent summary.
    case backgroundAgents(count: Int)
    case needsPermission
    /// `count` open questions, the row shows the first.
    case question(count: Int)
    case waitingForYou
    /// Only a background shell runs; `several` when the last turn end listed more than one.
    case shellRunning(several: Bool)
    /// A row of the Idle tab.
    case idle
    case done
    /// Finished without a clean exit (stale).
    case noCleanExit

    public var mark: StatusMark {
        switch self {
        // Background agents read as "working": their count already sits on the subagent toggle line.
        case .working, .backgroundAgents:
            StatusMark(.haloDot(bright: true), .agentWorking, .kit("working", defaultValue: "working"), .agentWorking)
        case .needsPermission:
            StatusMark(.diamond, .agentWaiting, Self.needsPermissionText, .agentWaiting)
        case let .question(count):
            StatusMark(.diamond, .agentWaiting, Self.questionText(count), .agentWaiting)
        case .waitingForYou:
            StatusMark(.diamond, .agentWaiting, .kit("waiting for you", defaultValue: "waiting for you"), .agentWaiting)
        case let .shellRunning(several):
            StatusMark(
                .hollowHalo, .textMuted,
                Self.shellRunningText(several: several),
                .textMuted
            )
        case .idle:
            StatusMark(.ring, .agentIdle, .kit("idle", defaultValue: "idle"), .textSubtle)
        case .done:
            StatusMark(.check, .agentDone, Self.doneText, .agentDone)
        case .noCleanExit:
            StatusMark(
                .dashedRing, .textSubtle, .kit("no clean exit", defaultValue: "no clean exit"), .textSubtle,
                help: .kit("The process ended without a clean exit.", defaultValue: "The process ended without a clean exit.")
            )
        }
    }

    static var needsPermissionText: LocalizedStringResource { .kit("needs permission", defaultValue: "needs permission") }

    static func shellRunningText(several: Bool) -> LocalizedStringResource {
        several ? .kit("shells running", defaultValue: "shells running") : .kit("shell running", defaultValue: "shell running")
    }

    /// "has a question", "has 2 questions".
    static func questionText(_ count: Int) -> LocalizedStringResource {
        .kit("has %lld questions", defaultValue: "has \(count) questions")
    }

    static var doneText: LocalizedStringResource { .kit("done", defaultValue: "done") }
}

/// What a row shows under its head, before its actions.
public enum RowDetail: Sendable, Equatable {
    /// The running tool's name (`toolNameRole`), then its detail in mono (`toolDetailRole`).
    case tool(ToolActivity)
    /// `thinkingText` in `quietRole`.
    case thinking
    /// `ActivityLine.noActivityText(since:at:)` at the view's clock, in `quietRole`.
    case noActivity(since: Date)
    /// The last reply in `textRole`, at most `lineLimit` lines: two while it
    /// waits for the user, one on an idle or a finished row.
    case reply(ReplyItem, lineLimit: Int)
    /// A finished row without a reply: its prompt, one line in `textRole`, no icon.
    case prompt(String)
    /// The command box of a permission request.
    case permission(PermissionCommand)
    /// The question box; options only, without descriptions and "Other".
    case question(QuestionPrompt)
    /// "Shell" and the shell's command.
    case shell(ShellLine)

    public static let toolNameRole: ThemeRole = .text
    public static let toolDetailRole: ThemeRole = .textMuted
    /// "Thinking…" and "No activity for …".
    public static let quietRole: ThemeRole = .textSubtle
    /// Reply and prompt.
    public static let textRole: ThemeRole = .textMuted
    /// The surface of the command and the question box.
    public static let boxSurfaceRole: ThemeRole = .surfaceSunken
    public static let boxBorderRole: ThemeRole = .border

    public static var thinkingText: LocalizedStringResource { .kit("Thinking…", defaultValue: "Thinking…") }
}

/// What a permission request asks to run: the tool's name as a prefix, any
/// tool's, then the whole detail the adapter gives, one line for
/// Claude Code until subspace delivers `command`.
public struct PermissionCommand: Sendable, Equatable {
    public let toolName: String
    /// Nil when the tool call has no detail; the box shows the prefix alone.
    public let command: String?

    /// The box shows at most this many lines.
    public static let lineLimit = 4

    init(toolName: String, command: String?) {
        self.toolName = toolName
        self.command = command
    }

    /// The request of the agent that asks, not archived: the orchestrator's
    /// first, else the subagent's that asked last, as for a question. Nil
    /// while no agent asks.
    init?(_ session: Session, archive: SessionArchive) {
        let asking = session.permissionRequests
            .filter { ref, _ in session.awaitsPermission(ref) && !archive.isArchived(ref) }
            .sorted { lhs, rhs in
                if (lhs.key == .root) != (rhs.key == .root) { return lhs.key == .root }
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key.sortKey < rhs.key.sortKey
            }
        guard let ref = asking.first?.key, let tool = session.permissionTools[ref] else { return nil }
        self.init(toolName: tool.name, command: (tool.fullDetail ?? tool.detail).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// "Bash ": the name and the space before the command.
    public var prefix: String { toolName + " " }
    public var prefixRole: ThemeRole { .textSubtle }
    public var commandRole: ThemeRole { .text }
}

/// "Shell npm run dev -- --port 5173": the row of a session where only a
/// background shell runs. The listing's tooltip hangs on it.
public struct ShellLine: Sendable, Equatable {
    /// The only listed shell's command, else its description; nil with none
    /// or several listed, which shows "Shell" alone.
    public let command: String?
    public let tooltip: ShellPill.Tooltip?

    init(_ pill: ShellPill) {
        command = pill.shellText
        tooltip = pill.tooltip
    }

    public static var labelText: LocalizedStringResource { .kit("Shell", defaultValue: "Shell") }
    public var labelRole: ThemeRole { .textMuted }
    /// In mono.
    public var commandRole: ThemeRole { .textMuted }
}

/// The line under a box: where to answer. Only while the session asks the
/// user; the jump line below shows the terminal, so this line has no
/// button.
public struct RowActions: Sendable, Equatable {
    /// The jump line is a button (`SessionItem.jumpAction`).
    private let hasJumpButton: Bool
    private let kind: Kind

    enum Kind: Sendable, Equatable {
        case permission
        case question(QuestionPrompt)
    }

    init(hasJumpButton: Bool, kind: Kind) {
        self.hasJumpButton = hasJumpButton
        self.kind = kind
    }

    /// "Allow or deny there." or "Answer there." when the jump button leads
    /// there; otherwise the sentence says where.
    public var hint: LocalizedStringResource {
        switch kind {
        case .permission:
            hasJumpButton
                ? .kit("Allow or deny there.", defaultValue: "Allow or deny there.")
                : .kit("Allow or deny in the terminal.", defaultValue: "Allow or deny in the terminal.")
        case let .question(question):
            hasJumpButton ? .kit("Answer there.", defaultValue: "Answer there.") : question.answerHint
        }
    }

    public var hintRole: ThemeRole { .textSubtle }
}

/// "› Subagents 2 working · 1 needs you · 3 done": the one button for a
/// session's subagents on every row, in place of the knob and "✓ n".
/// Archived ones don't count, every depth does; lost contact ones do, as the list shows them.
public struct SubagentToggle: Sendable, Equatable {
    /// What it opens; closed by default, open by itself while one needs the
    /// user.
    public let list: SubagentList
    /// Working, needs you, done, lost contact; parts with 0 left out.
    public let parts: [SubagentTogglePart]

    /// Nil while nothing is left to count and no undo row is up: archiving
    /// the last counted one must not take its Undo out of reach, so the line reads "Subagents" alone until the row goes.
    /// - Parameter showsUndoRows: A subagent's undo row is up in `list`.
    init?(list: SubagentList, summary: SessionItem.Summary, showsUndoRows: Bool) {
        let counts: [(SubagentTogglePart.Kind, Int)] = [
            // Those waiting for a type work too.
            (.working, summary.busyCount + summary.unassignedCount),
            (.needYou, summary.needYouCount),
            (.done, summary.doneCount),
            (.lostContact, summary.staleCount),
        ]
        let shown = counts.filter { $0.1 > 0 }
        guard !shown.isEmpty || showsUndoRows else { return nil }
        self.list = list
        parts = shown.enumerated().map { index, part in
            // "Subagents · 3 done": the parts in `textSubtle` always follow a separator.
            SubagentTogglePart(kind: part.0, count: part.1, isSeparatedBefore: index > 0 || part.0 == .done || part.0 == .lostContact)
        }
    }

    public var session: SessionKey { list.session }
    public var isOpen: Bool { list.isOpen }

    public static var title: LocalizedStringResource { .kit("Subagents", defaultValue: "Subagents") }
    public var title: LocalizedStringResource { Self.title }
    /// The title and the chevron.
    public var titleRole: ThemeRole { .textMuted }
    /// The "·" between the parts.
    public var separatorRole: ThemeRole { .textSubtle }

    /// "Subagents, 2 working, 1 needs you, 3 done"; the view adds expanded or collapsed.
    public var accessibilityLabel: LocalizedStringResource {
        AccessibilityParts.joined([.text(title)] + parts.map { .text($0.text) })
    }
}

public struct SubagentTogglePart: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case working, needYou, done, lostContact
    }

    public let kind: Kind
    public let count: Int
    /// A "·" in `SubagentToggle.separatorRole` goes before it.
    public let isSeparatedBefore: Bool

    public var text: LocalizedStringResource {
        switch kind {
        case .working: SubagentStatusPart(kind: .working, count: count).text
        case .needYou: SubagentStatusPart(kind: .needYou, count: count).text
        case .done: SubagentStatusPart(kind: .done, count: count).text
        case .lostContact: SubagentStatusPart(kind: .lostContact, count: count).text
        }
    }

    public var role: ThemeRole {
        switch kind {
        case .working: .agentWorking
        case .needYou: .agentWaiting
        case .done, .lostContact: .textSubtle
        }
    }
}

/// "[>_ Warp | ✳ Opus 5.5 ▮]": the last line of every row. With
/// a target it is the jump button, else the same line without symbol,
/// destination and pipe, receding.
public struct JumpLine: Sendable, Equatable {
    /// Nil: the form without target, no button, on a finished row
    /// always.
    public let target: JumpTarget?
    public let tool: Tool
    /// The adapter's display name, else the raw source id: what tooltip and
    /// VoiceOver say for the tool.
    public let toolName: String
    /// Nil while unknown: only the tool shows, without a gauge.
    /// On a finished row without its effort, so no gauge either.
    public let model: ModelLabel?

    /// What stands for the tool on the line.
    public enum Tool: Sendable, Equatable {
        /// An image in `ToolLogo.bundle`, drawn in one color.
        case logo(name: String)
        /// A tool without logo: its raw id as text in the logo's place.
        case sourceID(String)
    }

    /// The gauge behind the model; it hangs on the model name.
    public var effort: EffortLabel? { model?.effort }
    /// The logo, or the raw id in its place.
    public var toolRole: ThemeRole { target == nil ? .textSubtle : .textMuted }
    public var modelRole: ThemeRole { target == nil ? .textSubtle : .textMuted }
}

/// The button part of a jump line: where it leads (the envelope's `terminal`, under subspace `docs/contract.md` §6) and how it says so.
/// Frame and fills come from the shared bordered button style, not from roles here.
public struct JumpTarget: Sendable, Equatable {
    /// Lucide `terminal` or `app-window` in front of the destination.
    public enum Symbol: Sendable, Equatable {
        /// The session's own tab comes forward.
        case terminal
        /// Only its app comes forward: other terminals, `claude --bg`, Codex.
        case appWindow
    }

    public let action: TerminalAction

    public var symbol: Symbol { action.selectsTab ? .terminal : .appWindow }
    /// The app's name as the system knows it; shown as it is, never translated.
    public var appName: String? { action.appName }
    /// Stands in when the system knows no name for the app.
    public var fallbackDestination: LocalizedStringResource { .kit("Terminal", defaultValue: "Terminal") }
    /// The button's VoiceOver label, "Show in Warp".
    public var title: LocalizedStringResource { action.title }
    /// The system tooltip: the shortcut, or that only the app comes forward.
    public var help: LocalizedStringResource { action.help }

    public var symbolRole: ThemeRole { .textMuted }
    public var hoverSymbolRole: ThemeRole { .text }
    /// 11.5 pt medium.
    public var destinationRole: ThemeRole { .text }
    /// The "|" between destination and tool, in place of "·".
    public var separatorRole: ThemeRole { .borderStrong }
}

/// The tools' logos the adapters name (`PushAdapter.logoName`).
public enum ToolLogo {
    /// The kit's asset catalog of tool logos.
    public static var bundle: Bundle { .module }
}

extension SessionItem {
    /// Nil only on an undo row, which shows what it takes back instead.
    public var rowStatus: RowStatus? {
        guard undo == nil else { return nil }
        if endedAt != nil { return state == .stale ? .noCleanExit : .done }
        if idleSince != nil { return .idle }
        return switch cardState {
        case .needsPermission: .needsPermission
        case .question: .question(count: question?.count ?? 1)
        case .waiting: .waitingForYou
        case .background: .shellRunning(several: shellPill?.listsSeveral ?? false)
        case .working: state == .backgroundWorking ? .backgroundAgents(count: backgroundWorkingCount) : .working
        case nil: nil
        }
    }

    /// The line or box under the head; nil with nothing to show, e.g. a
    /// waiting row without a reply.
    public var rowDetail: RowDetail? {
        switch rowStatus {
        case nil: nil
        case .working:
            switch activity {
            case let .tool(tool)?: .tool(tool)
            case let .noActivity(since)?: .noActivity(since: since)
            case .thinking?, .subagentsWorking?, nil: .thinking
            }
        case .backgroundAgents: .thinking
        case .needsPermission: permissionCommand.map(RowDetail.permission)
        case .question: question.map(RowDetail.question)
        case .waitingForYou: reply.map { .reply($0, lineLimit: 2) }
        case .shellRunning: shellPill.map { .shell(ShellLine($0)) }
        case .idle: reply.map { .reply($0, lineLimit: 1) }
        case .done, .noCleanExit: reply.map { .reply($0, lineLimit: 1) } ?? prompt.map(RowDetail.prompt)
        }
    }

    /// Only while the session asks the user, with or without a terminal
    /// target; every other row offers the terminal on its jump line or in its "⋯" menu.
    public var rowActions: RowActions? {
        switch rowStatus {
        case .needsPermission: RowActions(hasJumpButton: jumpAction != nil, kind: .permission)
        case .question: question.map { RowActions(hasJumpButton: jumpAction != nil, kind: .question($0)) }
        case nil, .working, .backgroundAgents, .waitingForYou, .shellRunning, .idle, .done, .noCleanExit: nil
        }
    }

    /// Finished rows name the model without a gauge, as the design draws them.
    public var jumpLine: JumpLine {
        JumpLine(
            target: jumpAction.map(JumpTarget.init),
            tool: logoName.map { .logo(name: $0) } ?? .sourceID(key.source.rawValue),
            toolName: sourceName,
            model: endedAt != nil ? model?.withoutEffort : model
        )
    }

    /// What an active row's VoiceOver label says of its state: the status
    /// word once, then, while a background shell runs, what a shell's row
    /// says of it ("shell running, npm run dev", "working, shells running"):
    /// the label keeps naming the shell where the row draws no shell line,
    /// as it did beside the pill. Nil on an undo row.
    public var statusAccessibilityText: LocalizedStringResource? {
        guard let status = rowStatus, let word = status.mark.word else { return nil }
        guard let pill = shellPill, cardState != nil else { return word }
        var parts: [AccessibilityParts.Part] = []
        if case .shellRunning = status {} else { parts.append(.text(word)) }
        parts.append(.text(RowStatus.shellRunningText(several: pill.listsSeveral)))
        if let shell = pill.shellText { parts.append(.verbatim(shell)) }
        return AccessibilityParts.joined(parts)
    }

    /// What an active row's VoiceOver label says of its subagents: "2
    /// subagents working, 14 done", "14 subagents done"; nil while none works
    /// and none is done. A resting orchestrator's background agents count here too:
    /// the status word is only "working".
    public var subagentsAccessibilityText: LocalizedStringResource? {
        let working = summary.busyCount + summary.unassignedCount
        switch (working, doneSubagentsCount) {
        case (0, 0): return nil
        case (0, _): return doneSubagentsAccessibilityText
        case let (working, 0): return Self.subagentsWorkingText(working)
        case let (working, done):
            return AccessibilityParts.joined([
                .text(Self.subagentsWorkingText(working)),
                .text(SubagentStatusPart(kind: .done, count: done).text),
            ])
        }
    }

    /// "14 subagents done", what an idle or a finished row's VoiceOver label
    /// says of its subagents; nil while none is done. Archived ones don't count.
    public var doneSubagentsAccessibilityText: LocalizedStringResource? {
        let count = doneSubagentsCount
        return count > 0 ? .kit("%lld subagents done", defaultValue: "\(count) subagents done") : nil
    }

    /// Nothing on an undo row, whose label is the undo row's.
    private var doneSubagentsCount: Int { undo == nil ? summary.doneCount : 0 }

    private static func subagentsWorkingText(_ count: Int) -> LocalizedStringResource {
        .kit("%lld subagents working", defaultValue: "\(count) subagents working")
    }
}

extension SubagentRow {
    /// Subagent rows draw the fainter halo of a working one.
    public var statusMark: StatusMark {
        switch status {
        case .working:
            StatusMark(.haloDot(bright: false), .agentWorking, .kit("working", defaultValue: "working"), .agentWorking)
        case .needsPermission:
            StatusMark(.diamond, .agentWaiting, RowStatus.needsPermissionText, .agentWaiting)
        case .question:
            // The detail's count: a subagent can ask several at once.
            if case let .question(count, _) = detail {
                StatusMark(.diamond, .agentWaiting, RowStatus.questionText(count), .agentWaiting)
            } else {
                StatusMark(.diamond, .agentWaiting, RowStatus.questionText(1), .agentWaiting)
            }
        case .done:
            StatusMark(.check, .agentDone, RowStatus.doneText, .agentDone)
        case .lostContact:
            StatusMark(.dashedRing, .textSubtle, .kit("lost contact", defaultValue: "lost contact"), .textSubtle)
        case .unassigned:
            StatusMark(.ring, .textSubtle, nil, .textSubtle)
        case .archived:
            // Only among an open fold row's members, beside the done ones.
            StatusMark(.check, .textSubtle, .kit("archived", defaultValue: "archived"), .textSubtle)
        }
    }

    /// Only "Awaiting designation…" recedes; a type or a title is the name.
    public var titleRole: ThemeRole { titleKind == .awaitingDesignation ? .textSubtle : .text }
    /// " · " and the model behind the title.
    public var modelRole: ThemeRole { .textSubtle }
}

extension SubagentFoldRow {
    /// "33 done · 1 archived", the separator included.
    public var textRole: ThemeRole { .textSubtle }
}
