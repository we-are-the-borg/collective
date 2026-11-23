import AppKit
import CollectiveKit
import SwiftUI

/// One session as a full-width row, the same in every tab: a head with the
/// status form, the name, the status word and the time; under it, indented to
/// the name, the detail lines, the actions, the subagents and the jump line.
/// Color only at the status; every part comes with its role from
/// the kit (`SessionItem.rowStatus`, `rowDetail`, `rowActions`, `subagentToggle`,
/// `jumpLine`). A reply that does not fit gets "Show more", which opens its
/// card through the popover's `ReplyCardController`; so do the menus, Space
/// and Return, and VoiceOver. The row is no button, since it holds buttons of
/// its own: with a target its jump line is one, which shows the session in its
/// app.
struct SessionRowView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let item: SessionItem
    private let tab: PopoverTab
    private let isLastOfSeveral: Bool
    private let onArchive: (ArchiveUndo.Kind) -> Void
    private let onArchiveAllFinished: () -> Void
    private let onUndo: (ArchiveUndo.ID) -> Void
    private let onUndoHover: (ArchiveUndo.ID, Bool) -> Void
    private let onToggleSubagents: (SessionKey, Bool) -> Void
    private let onToggleSubagentFold: (SubagentFoldID) -> Void
    private let onShowTerminal: (SessionKey) -> Void

    @Environment(\.replyCard) private var replyCard
    @State private var isHovered = false
    /// The reply is cut at its lines, which only its layout tells: then "Show
    /// more", the menus, the keys and VoiceOver open its card.
    @State private var replyIsCut = false
    /// Previews and snapshots only: draws the row as under the pointer.
    private var forcesHover = false
    @State private var previousState: AgentDisplayState?
    @State private var previouslyRanShell = false

    /// - Parameters:
    ///   - tab: The tab the row is listed in; a finished row archives as such and offers "Archive All Finished".
    ///   - isLastOfSeveral: The last of several rows; its reply card opens upward.
    ///   - onArchiveAllFinished: The finished rows' menu item; the list knows which rows it covers.
    ///   - onToggleSubagents: The subagent toggle line, with whether the list shows open now.
    ///   - onToggleSubagentFold: A fold row of finished subagents in the list.
    ///   - onShowTerminal: "Show in <App>" (the jump button, menu, VoiceOver); the app brings the terminal forward.
    init(
        _ item: SessionItem,
        tab: PopoverTab,
        isLastOfSeveral: Bool = false,
        onArchive: @escaping (ArchiveUndo.Kind) -> Void = { _ in },
        onArchiveAllFinished: @escaping () -> Void = {},
        onUndo: @escaping (ArchiveUndo.ID) -> Void = { _ in },
        onUndoHover: @escaping (ArchiveUndo.ID, Bool) -> Void = { _, _ in },
        onToggleSubagents: @escaping (SessionKey, Bool) -> Void = { _, _ in },
        onToggleSubagentFold: @escaping (SubagentFoldID) -> Void = { _ in },
        onShowTerminal: @escaping (SessionKey) -> Void = { _ in }
    ) {
        self.item = item
        self.tab = tab
        self.isLastOfSeveral = isLastOfSeveral
        self.onArchive = onArchive
        self.onArchiveAllFinished = onArchiveAllFinished
        self.onUndo = onUndo
        self.onUndoHover = onUndoHover
        self.onToggleSubagents = onToggleSubagents
        self.onToggleSubagentFold = onToggleSubagentFold
        self.onShowTerminal = onShowTerminal
    }

    func hovered() -> Self {
        var copy = self
        copy.forcesHover = true
        return copy
    }

    var body: some View {
        Group {
            if let undo = item.undo {
                UndoRowView(row: undo, onUndo: onUndo, onHover: onUndoHover)
                    .transition(.opacity)
            } else if let status = item.rowStatus {
                row(status).transition(.opacity)
            }
        }
        // The swap cross-fades over 0.2 s and the height follows in the same animation.
        .animation(.easeOut(duration: 0.2), value: item.undo?.id)
        .onAppear {
            previousState = item.state
            previouslyRanShell = item.shellPill != nil
        }
        .onChange(of: item.state) { _, new in previousState = new }
        .onChange(of: item.shellPill != nil) { _, new in previouslyRanShell = new }
    }

    /// The row keeps its hover while its card shows, wherever the pointer is.
    private var showsHover: Bool { isHovered || forcesHover || showsCard }

    /// Its reply card shows; a subagent's card leaves the row its own hover.
    private var showsCard: Bool {
        guard let target = item.replyCardTarget else { return false }
        return replyCard?.shown == target
    }

    /// The row's card while its reply does not fit; one that fits opens nothing.
    private var openableCard: ReplyCardTarget? {
        replyIsCut ? item.replyCardTarget : nil
    }

    private func replyCutChanged(_ isCut: Bool) {
        replyIsCut = isCut
        if let target = item.replyCardTarget { replyCard?.replyCutChanged(isCut, for: target) }
    }

    private func showTerminal() { onShowTerminal(item.key) }

    /// "Show Reply" in the menus, only while the reply does not fit.
    private var showReply: (() -> Void)? {
        openableCard.map { target in { replyCard?.open(target) } }
    }

    private func archive() {
        onArchive(tab == .finished ? .finishedSession(item.key) : .session(item.key))
    }

    /// The reply the row shows; the detail decides whether there is one.
    private var reply: ReplyItem? {
        if case let .reply(reply, _) = item.rowDetail { reply } else { nil }
    }

    // MARK: Status fade

    /// Background work (agents or a shell) ending in a wait: form, word and
    /// detail cross-fade, 0.2 s, opacity only; every other change stays
    /// immediate. `previousState` still holds the old state while the body
    /// re-evaluates for the new one.
    private var stateFade: Animation? {
        guard item.state == .waiting, let previousState, [.backgroundWorking, .backgroundShell].contains(previousState)
        else { return nil }
        // Under Reduce Motion nothing fades once a shell ended.
        if reduceMotion, previousState == .backgroundShell || previouslyRanShell { return nil }
        return .easeOut(duration: 0.2)
    }

    // MARK: Row

    private func row(_ status: RowStatus) -> some View {
        let actions = item.rowActions
        let detail = item.rowDetail
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: RowMetrics.headGap) {
                head(status.mark, kind: status.kind)
                if detail != nil || actions != nil {
                    VStack(alignment: .leading, spacing: RowMetrics.partGap) {
                        if let detail {
                            ZStack(alignment: .topLeading) {
                                detailView(detail).id(detail.kind).transition(.opacity)
                            }
                            .animation(stateFade, value: item.state)
                        }
                        if let actions { actionsView(actions) }
                    }
                    .font(.plexSans(12))
                    .padding(.leading, RowMetrics.contentInset)
                }
            }
            // One element: VoiceOver names the row before its parts, the status word included.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(counting: item.timeCountsFrom, item.idleSince, quietSince(detail), label: accessibilityLabel, value: accessibilityValue)
            .modifier(OptionalAccessibilityHint(text: accessibilityHint(status)))
            .readReplyAccessibilityAction(openableCard) { replyCard?.read($0) }
            .sessionAccessibilityActions(item, showTerminal: showTerminal, archive: archive)
            VStack(alignment: .leading, spacing: RowMetrics.partGap) {
                // The subagents are VoiceOver elements of their own, after the row's.
                if let toggle = item.subagentToggle {
                    SubagentSection(
                        toggle: toggle,
                        onToggle: { onToggleSubagents(toggle.session, toggle.isOpen) },
                        onToggleFold: onToggleSubagentFold, onArchive: onArchive, onUndo: onUndo, onUndoHover: onUndoHover
                    )
                }
                JumpLineView(line: item.jumpLine, onJump: showTerminal)
            }
            .padding(.leading, RowMetrics.contentInset)
            .padding(.top, detail != nil || actions != nil ? RowMetrics.partGap : RowMetrics.headGap)
        }
        .padding(RowMetrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(.role(.border)).frame(height: 1) }
        // The gaps too: the menu and the hover cover the whole row.
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: showsHover)
        // The request comes from an overlay as large as the card, the one place
        // that sees both the card's bounds and its reply text's anchor.
        .overlayPreferenceValue(RowPreviewRequest.ReplyKey.self) { [showsCard, reply] replyText in
            Color.clear
                .anchorPreference(key: RowPreviewRequest.Key.self, value: .bounds) { bounds in
                    guard showsCard, let reply else { return nil }
                    return RowPreviewRequest(
                        content: .session(item, reply), row: bounds, reply: replyText, isLastOfSeveral: isLastOfSeveral
                    )
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .modifier(RowMenu(item: item, tab: tab, showReply: showReply, showTerminal: showTerminal, archive: archive, archiveAllFinished: onArchiveAllFinished))
        .accessibilityElement(children: .contain)
    }

    // MARK: Head

    /// Grid 14 | rest | auto | auto, spacing 8, 18 high, centred.
    private func head(_ mark: StatusMark, kind: Int) -> some View {
        HStack(spacing: RowMetrics.columnGap) {
            ZStack {
                StatusShapeView(mark, size: RowMetrics.shapeSize)
                    .modifier(OptionalHelp(text: mark.help.map { Text($0) }))
                    .id(kind)
                    .transition(.opacity)
            }
            .animation(stateFade, value: item.state)
            .frame(width: RowMetrics.shapeColumn)
            // The dot keeps its size and place after the name; a long name shrinks instead.
            HStack(spacing: RowMetrics.unreadDotGap) {
                Text(item.name)
                    .font(.plexSans(13, weight: .medium))
                    .foregroundStyle(.role(.text))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if item.isUnread { UnreadDot(size: RowMetrics.unreadDotSize) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let word = mark.word {
                ZStack {
                    Text(word)
                        .foregroundStyle(.role(mark.wordRole))
                        .id(kind)
                        .transition(.opacity)
                }
                .animation(stateFade, value: item.state)
                .lineLimit(1)
                .fixedSize()
            }
            // The "⋯" button takes the time's place while hovered; both stay laid
            // out, so the name never reflows.
            ZStack(alignment: .trailing) {
                time
                    .opacity(showsHover ? 0 : 1)
                moreButton
            }
            .frame(minWidth: RowMetrics.timeMinWidth, alignment: .trailing)
            .fixedSize()
        }
        .font(.plexSans(12))
        .frame(height: RowMetrics.headHeight)
    }

    /// "31 min", "12 min", "2 min ago": the status word beside it names the
    /// state, so the time leaves it out; VoiceOver still says it in full.
    private var time: some View {
        DurationClock(since: item.rowTimeCountsFrom) { now in Text(item.rowTimeText(at: now)) }
            .foregroundStyle(.role(.textSubtle))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }

    /// Opens the row's menu, the context menu's entries drawn by the system;
    /// it always has room for one more entry.
    private var moreButton: some View {
        DurationClock(since: item.menuCountsFrom(tab)) { now in
            Menu {
                RowMenuItems(item: item, tab: tab, now: now, showReply: showReply, showTerminal: showTerminal, archive: archive, archiveAllFinished: onArchiveAllFinished)
            } label: {
                LucideImage(.ellipsis, size: 12)
                    .frame(width: RowMetrics.moreSize.width, height: RowMetrics.moreSize.height)
            }
        }
        // The button menu style draws the label through the button style, without the system's bezel.
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.popoverBordered)
        .fixedSize()
        .help(Text("More", bundle: .module))
        .accessibilityLabel(Text("More", bundle: .module))
        .opacity(showsHover ? 1 : 0)
        .allowsHitTesting(showsHover)
        // Hidden, it stays out of the accessibility tree and the focus order; the
        // row's own actions carry the menu's entries for VoiceOver.
        .accessibilityHidden(!showsHover)
    }

    // MARK: Detail

    @ViewBuilder
    private func detailView(_ detail: RowDetail) -> some View {
        switch detail {
        case let .tool(tool):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(tool.name)
                    .foregroundStyle(.role(RowDetail.toolNameRole))
                    .lineLimit(1)
                    .fixedSize()
                if let detail = tool.detail, !detail.isEmpty {
                    // In the middle: the kit cannot tell a path from a command.
                    Text(verbatim: detail)
                        .font(.plexMono(11.5))
                        .foregroundStyle(.role(RowDetail.toolDetailRole))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        case .thinking:
            Text(RowDetail.thinkingText)
                .foregroundStyle(.role(RowDetail.quietRole))
                .lineLimit(1)
        case let .noActivity(since):
            DurationClock(since: since) { now in
                Text(ActivityLine.noActivityText(since: since, at: now))
                    .foregroundStyle(.role(RowDetail.quietRole))
                    .lineLimit(1)
            }
        case let .reply(reply, lineLimit):
            RowReplyView(reply: reply, lineLimit: lineLimit, onCutChange: replyCutChanged) {
                if let target = item.replyCardTarget { replyCard?.toggle(target) }
            }
        case let .prompt(prompt):
            // Inert: the row's hover and menu work over it; no icon.
            Text(verbatim: Self.firstLine(of: prompt))
                .foregroundStyle(.role(RowDetail.textRole))
                .lineLimit(1)
                .truncationMode(.tail)
        case let .permission(command):
            PermissionBox(command: command)
        case let .question(question):
            QuestionBox(question: question)
        case let .shell(line):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ShellLine.labelText)
                    .foregroundStyle(.role(line.labelRole))
                    .fixedSize()
                if let command = line.command {
                    Text(verbatim: command)
                        .font(.plexMono(11.5))
                        .foregroundStyle(.role(line.commandRole))
                        .truncationMode(.tail)
                }
            }
            .lineLimit(1)
            .modifier(OptionalHelp(text: line.tooltip?.text))
        }
    }

    /// A leading blank line must not hide the first line.
    private static func firstLine(of text: String) -> String {
        text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? text
    }

    // MARK: Actions

    /// Where to answer, as its own line; the jump line below shows the terminal.
    /// Only permission and question have one.
    private func actionsView(_ actions: RowActions) -> some View {
        Text(actions.hint)
            .foregroundStyle(.role(actions.hintRole))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Accessibility

    private func quietSince(_ detail: RowDetail?) -> Date? {
        if case let .noActivity(since)? = detail { since } else { nil }
    }

    /// "agent-collective, Opus 5.5, effort high, Claude Code, needs permission,
    /// 4 min, 2 subagents working": today's parts with the status word in
    /// place of the pill, followed by the shell while one runs. Idle and
    /// finished rows say it in their time ("idle for 48 min", "Done 2 min ago").
    private func accessibilityLabel(at now: Date) -> Text {
        var parts = [Text(item.name)]
        let meta = item.jumpLine
        if let model = meta.model { parts.append(Text(model.accessibilityLabel)) }
        parts.append(Text(verbatim: meta.toolName))
        // "unread" right after whatever says the status: the status word
        // on Active, the time on Idle and Finished.
        let unread = item.unreadAccessibilityText.map { Text($0) }
        switch tab {
        case .active:
            if let status = item.statusAccessibilityText { parts.append(Text(status)) }
            if let unread { parts.append(unread) }
            parts.append(Text(item.timeText(at: now)))
            if let subagents = item.subagentsAccessibilityText { parts.append(Text(subagents)) }
        case .idle:
            if let idle = item.idleAccessibilityText(at: now) { parts.append(Text(idle)) }
            if let unread { parts.append(unread) }
            if let done = item.doneSubagentsAccessibilityText { parts.append(Text(done)) }
        case .finished:
            parts.append(Text(item.timeText(at: now)))
            if let unread { parts.append(unread) }
            if let done = item.doneSubagentsAccessibilityText { parts.append(Text(done)) }
        }
        return parts.dropFirst().reduce(parts[0]) { $0 + Text(verbatim: ", ") + $1 }
    }

    /// What the row shows beyond its label, in its order: the activity, the
    /// question, the reply or the prompt.
    private func accessibilityValue(at now: Date) -> Text {
        var parts: [Text] = []
        switch item.rowDetail {
        case let .tool(tool)?:
            parts.append(tool.detail.flatMap { $0.isEmpty ? nil : Text(tool.name) + Text(verbatim: " ") + Text(verbatim: $0) } ?? Text(tool.name))
        case .thinking?: parts.append(Text(RowDetail.thinkingText))
        case let .noActivity(since)?: parts.append(Text(ActivityLine.noActivityText(since: since, at: now)))
        case let .permission(command)?: parts.append(Text(verbatim: command.prefix + (command.command ?? "")))
        case let .question(question)?: parts.append(Text(question.accessibilityText))
        case .reply?:
            if let text = item.lastReplyAccessibilityText { parts.append(Text(text)) }
        case let .prompt(prompt)?: parts.append(Text(verbatim: Self.firstLine(of: prompt)))
        case .shell?, nil: break
        }
        guard let first = parts.first else { return Text(verbatim: "") }
        return parts.dropFirst().reduce(first) { $0 + Text(verbatim: ", ") + $1 }
    }

    /// The shell listing's tooltip, or why a session ended without a clean exit.
    private func accessibilityHint(_ status: RowStatus) -> Text? {
        item.shellPill?.tooltip?.text ?? status.mark.help.map { Text($0) }
    }
}

/// The unread sign, filled `--info`, after a row's name and a tab's count.
/// The labels say "unread", so VoiceOver skips it.
struct UnreadDot: View {
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(.role(.info))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The design's numbers of a row.
enum RowMetrics {
    static let padding = EdgeInsets(top: 9, leading: 14, bottom: 10, trailing: 14)
    /// Between the head and what follows.
    static let headGap: CGFloat = 5
    /// Between the parts under the head.
    static let partGap: CGFloat = 6
    static let headHeight: CGFloat = 18
    static let shapeColumn: CGFloat = 14
    static let shapeSize: CGFloat = 12
    static let columnGap: CGFloat = 8
    static let timeMinWidth: CGFloat = 46
    static let moreSize = CGSize(width: 24, height: 22)
    /// The unread dot after the name.
    static let unreadDotSize: CGFloat = 6
    static let unreadDotGap: CGFloat = 7
    /// The text under the head starts under the name: the form's column and the gap.
    static var contentInset: CGFloat { shapeColumn + columnGap }
}

private extension RowStatus {
    /// Identity of the status for its fade, ignoring the counts in its word.
    var kind: Int {
        switch self {
        case .working: 0
        case .backgroundAgents: 1
        case .needsPermission: 2
        case .question: 3
        case .waitingForYou: 4
        case .shellRunning: 5
        case .idle: 6
        case .done: 7
        case .noCleanExit: 8
        }
    }
}

private extension RowDetail {
    /// Identity of the detail for the status fade.
    var kind: Int {
        switch self {
        case .tool: 0
        case .thinking: 1
        case .noActivity: 2
        case .reply: 3
        case .prompt: 4
        case .permission: 5
        case .question: 6
        case .shell: 7
        }
    }
}

// MARK: Parts

/// The last reply, 12 pt at line height 17, at most the kit's lines, cut at
/// its end. Only a reply that does not fit gets "Show more" below it, and only
/// that line opens its card, not a click on the text or the row; nothing
/// expands in the row. The card hangs off this text, not off the line below it.
private struct RowReplyView: View {
    let reply: ReplyItem
    let lineLimit: Int
    /// The text was measured cut at `lineLimit`, or not.
    let onCutChange: (Bool) -> Void
    let onShowMore: () -> Void

    /// Whether the text is cut at `lineLimit`; nil until measured.
    @State private var isTruncated: Bool?
    @State private var shownHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: ShowMoreLine.gap) {
            shownText
            if isTruncated == true { ShowMoreLine(action: onShowMore) }
        }
        .onChange(of: isTruncated) { _, cut in onCutChange(cut == true) }
    }

    private var text: Text {
        Text(verbatim: lineLimit > 1 ? reply.preview.multiline : reply.preview.singleLine)
    }

    private var shownText: some View {
        text
            .foregroundStyle(.role(RowDetail.textRole))
            .plexLineHeight(17, size: 12)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownHeight = $0; measure() }
            .anchorPreference(key: RowPreviewRequest.ReplyKey.self, value: .bounds) { $0 }
            .background(alignment: .topLeading) {
                text
                    .plexLineHeight(17, size: 12)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hidden()
                    .accessibilityHidden(true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0; measure() }
            }
    }

    private func measure() {
        guard shownHeight > 0, fullHeight > 0 else { return }
        isTruncated = fullHeight > shownHeight + 0.5
    }
}

/// "⌄ Show more" under a reply that does not fit: opens its card, and closes
/// it again while it shows. Like the subagent toggle line, without its counts.
private struct ShowMoreLine: View {
    let action: () -> Void

    /// Extra room between the reply and the line, which would otherwise sit flush.
    static let gap: CGFloat = 4

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                LucideImage(.chevronDown, size: 11)
                    .accessibilityHidden(true)
                Text("Show more", bundle: .module)
            }
            .font(.plexSans(12))
            .foregroundStyle(.role(.textMuted))
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: SubagentListMetrics.toggleHeight, maxHeight: SubagentListMetrics.toggleHeight, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.subagentLine)
        .accessibilityLabel(Text("Show more", bundle: .module))
    }
}

/// The permission request's command box: the tool's name as a prefix, then the
/// command, wrapping anywhere a word does not fit, at most four lines.
private struct PermissionBox: View {
    let command: PermissionCommand

    var body: some View {
        (Text(verbatim: command.prefix).foregroundStyle(.role(command.prefixRole))
            + Text(verbatim: command.command ?? "").foregroundStyle(.role(command.commandRole)))
            .font(.plexMono(11.5))
            .plexLineHeight(16, size: 11.5, mono: true)
            .lineLimit(PermissionCommand.lineLimit)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 6, leading: 9, bottom: 7, trailing: 9))
            .rowBox()
    }
}

/// The question box: the question, "Choose any" for a multi-select one, the
/// numbered options without descriptions and "Other", then "+N more".
private struct QuestionBox: View {
    let question: QuestionPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(question.text)
                .foregroundStyle(.role(question.textRole))
                .lineLimit(QuestionPrompt.questionLineLimit)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 2)
            if let hint = question.multiSelectHint {
                Text(hint).foregroundStyle(.role(question.hintRole))
            }
            ForEach(question.listedOptions, id: \.number) { choice in
                (Text(verbatim: "\(choice.number) ").font(.plexMono(11.5)).foregroundStyle(.role(question.numberRole))
                    + Text(verbatim: choice.label.text).foregroundStyle(.role(question.labelRole)))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let more = question.moreLine {
                Text(more).foregroundStyle(.role(question.moreRole))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 7, leading: 9, bottom: 8, trailing: 9))
        .rowBox()
    }
}

private extension QuestionChoice.Label {
    var text: String {
        switch self {
        case let .option(label): label
        case .other: String(localized: QuestionChoice.otherText)
        }
    }
}

/// "[>_ Warp | ✳ Opus 5.5 ▮]", the row's last line: with a target
/// the jump button, which does what the menu's "Show in <App>" and ⌘↩ do; the
/// popover then closes as with ⌘↩. Without one the same line without symbol,
/// destination, pipe and frame, receding and no button.
struct JumpLineView: View {
    let line: JumpLine
    let onJump: () -> Void

    var body: some View {
        if let target = line.target {
            JumpButton(target: target, line: line, action: onJump)
        } else {
            JumpToolAndModel(line: line)
                .font(.plexSans(JumpButtonMetrics.textSize))
                // The row's label reads model, effort and tool already.
                .accessibilityHidden(true)
        }
    }
}

/// The design's numbers of the jump button.
enum JumpButtonMetrics {
    /// The plain line without target keeps the text's own height.
    static let height: CGFloat = 22
    static let leadingInset: CGFloat = 6
    static let trailingInset: CGFloat = 8
    /// Between the target group, the pipe and the tool and model group.
    static let groupGap: CGFloat = 7
    /// Within a group: symbol and destination, logo and model.
    static let partGap: CGFloat = 5
    static let symbolSize: CGFloat = 12
    static let logoSize: CGFloat = 12
    static let textSize: CGFloat = 11.5
}

/// Framed like the popover's other bordered buttons, without accent in any state: the
/// accent is for states that need the user. Out of the list's keyboard order: the focused
/// row's ⌘↩ and its named action "Show in <App>" do the same; VoiceOver still finds it as a button.
private struct JumpButton: View {
    let target: JumpTarget
    let line: JumpLine
    let action: () -> Void
    @State private var isHovered = false

    /// Verbatim: the system's own app name needs no translation.
    private var destinationText: Text {
        target.appName.map { Text(verbatim: $0) } ?? Text(target.fallbackDestination)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: JumpButtonMetrics.groupGap) {
                HStack(spacing: JumpButtonMetrics.groupGap) {
                    HStack(spacing: JumpButtonMetrics.partGap) {
                        LucideImage(symbol, size: JumpButtonMetrics.symbolSize)
                            .foregroundStyle(.role(isHovered ? target.hoverSymbolRole : target.symbolRole))
                        destinationText
                            .font(.plexSans(JumpButtonMetrics.textSize, weight: .medium))
                            .foregroundStyle(.role(target.destinationRole))
                            .lineLimit(1)
                    }
                    Text(verbatim: "|")
                        .foregroundStyle(.role(target.separatorRole))
                }
                // Over these parts too: they hide the background's tooltip below them.
                .help(Text(target.help))
                JumpToolAndModel(line: line)
            }
            .font(.plexSans(JumpButtonMetrics.textSize))
            .padding(.leading, JumpButtonMetrics.leadingInset)
            .padding(.trailing, JumpButtonMetrics.trailingInset)
            .frame(height: JumpButtonMetrics.height)
            // The button's tooltip in its gaps and insets. Not on the button itself: an outer
            // `.help` hides the inner ones, and logo and model keep their own.
            .background { Color.clear.contentShape(.rect).help(Text(target.help)) }
            .contentShape(.rect)
        }
        .buttonStyle(.popoverBordered)
        .focusable(false)
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text(target.title))
    }

    private var symbol: LucideIcon {
        switch target.symbol {
        case .terminal: .terminal
        case .appWindow: .appWindow
        }
    }
}

/// The tool's logo, or its raw id in its place, then the model and its effort gauge;
/// without a model the logo alone. The font comes from the line.
private struct JumpToolAndModel: View {
    let line: JumpLine

    var body: some View {
        HStack(spacing: JumpButtonMetrics.partGap) {
            tool
                .foregroundStyle(.role(line.toolRole))
                .help(Text(verbatim: line.toolName))
            if let model = line.model {
                ModelText(model: model)
                    .foregroundStyle(.role(line.modelRole))
            }
        }
    }

    @ViewBuilder
    private var tool: some View {
        switch line.tool {
        case let .logo(name):
            Image(name, bundle: ToolLogo.bundle)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: JumpButtonMetrics.logoSize, height: JumpButtonMetrics.logoSize)
                .accessibilityLabel(Text(verbatim: line.toolName))
        case let .sourceID(id):
            Text(verbatim: id)
                .lineLimit(1)
        }
    }
}

extension View {
    /// The command and the question box, and a reply's code block: `--surface-sunken` in a 1 px `--border` frame, square.
    func rowBox() -> some View {
        background(.role(RowDetail.boxSurfaceRole))
            .overlay(Rectangle().strokeBorder(.role(RowDetail.boxBorderRole), lineWidth: 1))
    }
}

extension View {
    /// The design's CSS line height for Plex at `size`: the spacing beyond the
    /// face's own height goes between the lines and half of it above and below
    /// the text, as CSS's half-leading does.
    func plexLineHeight(_ lineHeight: CGFloat, size: CGFloat, mono: Bool = false) -> some View {
        let extra = max(0, lineHeight - PlexMetrics.naturalLineHeight(size: size, mono: mono))
        return lineSpacing(extra).padding(.vertical, extra / 2)
    }
}

enum PlexMetrics {
    /// The face's own line height at `size`, as Text lays out one line.
    static func naturalLineHeight(size: CGFloat, mono: Bool) -> CGFloat {
        _ = Font.plexSans(size)
        let face = mono ? PlexFace.monoRegular : PlexFace.sansRegular
        guard let font = NSFont(name: face.postScriptName, size: size) else { return size * 1.3 }
        return (font.ascender - font.descender + font.leading).rounded(.up)
    }
}

// MARK: Menu and accessibility

/// The row's context menu, drawn by the system.
private struct RowMenu: ViewModifier {
    let item: SessionItem
    let tab: PopoverTab
    let showReply: (() -> Void)?
    let showTerminal: () -> Void
    let archive: () -> Void
    let archiveAllFinished: () -> Void

    func body(content: Content) -> some View {
        content.contextMenu(counting: item.menuCountsFrom(tab)) { now in
            RowMenuItems(item: item, tab: tab, now: now, showReply: showReply, showTerminal: showTerminal, archive: archive, archiveAllFinished: archiveAllFinished)
        }
    }
}

private extension SessionItem {
    /// What the row's menu counts "Last event" from; finished rows name no event.
    func menuCountsFrom(_ tab: PopoverTab) -> Date? {
        tab == .finished ? nil : lastActivity
    }
}

/// The entries of the row's context menu and of its "⋯" button. A reply that
/// does not fit adds "Show Reply". Active and idle rows name the last event; a
/// working session keeps Archive, disabled: its next tool start would bring it back.
/// Finished rows add "Archive All Finished".
private struct RowMenuItems: View {
    let item: SessionItem
    let tab: PopoverTab
    /// The moment "Last event" counts to; finished rows don't name it.
    let now: Date
    /// Nil while the reply fits or there is none.
    let showReply: (() -> Void)?
    let showTerminal: () -> Void
    let archive: () -> Void
    let archiveAllFinished: () -> Void

    var body: some View {
        TerminalMenuItems(action: item.terminalAction, onShow: showTerminal)
        if let showReply {
            Button(action: showReply) { Text("Show Reply", bundle: .module) }
            Divider()
        }
        if tab == .finished {
            SessionCopyButtons(sessionID: item.sessionID, path: item.quotedPath, resumeCommand: item.resumeCommand)
            Divider()
            ArchiveMenuButton(title: "Archive", shortcut: true, action: archive)
            Divider()
            Button(action: archiveAllFinished) { Text("Archive All Finished", bundle: .module) }
        } else {
            Button {} label: { Text(item.lastEventText(at: now)) }
                .disabled(true)
            Divider()
            SessionCopyButtons(sessionID: item.sessionID, path: item.quotedPath, resumeCommand: item.resumeCommand)
            Divider()
            ArchiveMenuButton(title: "Archive", shortcut: true, action: archive)
                .disabled(!item.isArchivable)
        }
    }
}

/// A hint only when there is text; without one the element carries no hint modifier at all.
private struct OptionalAccessibilityHint: ViewModifier {
    let text: Text?

    func body(content: Content) -> some View {
        if let text { content.accessibilityHint(text) } else { content }
    }
}

/// A tooltip only when there is text.
struct OptionalHelp: ViewModifier {
    let text: Text?

    func body(content: Content) -> some View {
        if let text { content.help(text) } else { content }
    }
}

extension ShellPill.Tooltip {
    /// The tooltip's lines joined. A native tooltip is plain text, so its head
    /// line is not set apart as in the design.
    var text: Text {
        let lines = [Text(head)] + shells.map { Text(verbatim: $0) } + (foot.map { [Text($0)] } ?? [])
        return lines.dropFirst().reduce(lines[0]) { $0 + Text(verbatim: "\n") + $1 }
    }
}

extension View {
    /// VoiceOver's "Read Reply": the row's reply card opens and VoiceOver
    /// reads it. Nothing on a row whose reply fits or that has none.
    func readReplyAccessibilityAction(_ target: ReplyCardTarget?, read: @escaping (ReplyCardTarget) -> Void) -> some View {
        accessibilityActions {
            if let target {
                Button { read(target) } label: { Text("Read Reply", bundle: .module) }
            }
        }
    }

    /// VoiceOver's "Show in <App>" and "Archive" on a row, a working session
    /// has no "Archive"; then the menu's copy entries.
    func sessionAccessibilityActions(
        _ item: SessionItem, showTerminal: @escaping () -> Void, archive: @escaping () -> Void
    ) -> some View {
        terminalAccessibilityAction(item.terminalAction, show: showTerminal)
            .accessibilityActions {
                if item.isArchivable {
                    Button(action: archive) { Text("Archive", bundle: .module) }
                }
            }
            .sessionCopyAccessibilityActions(item)
    }

    /// VoiceOver's copy entries of the context menu; "Copy Path" only with a
    /// known folder, "Copy Resume Command" only for a tool that has one.
    func sessionCopyAccessibilityActions(_ item: SessionItem) -> some View {
        accessibilityActions {
            Button { copyToPasteboard(item.sessionID) } label: { Text("Copy Session ID", bundle: .module) }
            if let path = item.quotedPath {
                Button { copyToPasteboard(path) } label: { Text("Copy Path", bundle: .module) }
            }
            if let command = item.resumeCommand {
                Button { copyToPasteboard(command) } label: { Text("Copy Resume Command", bundle: .module) }
            }
        }
    }
}

#if DEBUG
/// The rows of the design per tab, at the popover's width, the first one hovered.
private struct SessionRowPreviews: View {
    let tab: PopoverTab

    var body: some View {
        let rows = PreviewData.tabs(tab).rows
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                if index == 0 {
                    SessionRowView(item, tab: tab).hovered()
                } else {
                    SessionRowView(item, tab: tab)
                }
            }
        }
        .frame(width: 400)
        .background(.role(.surface))
        .environment(\.pinnedClock, PreviewData.now)
    }
}

/// Every kind of row the design doesn't draw: tools, no activity, background
/// agents and shells, permission and question in Warp, jump buttons to a tab
/// (the first under the pointer) and to an app only, subagents, tools without
/// a model, a name or a logo, finished prompts, lost contact and undo rows.
struct SessionRowStatesPreview: View {
    private static let active: [SessionItem] = [
        PreviewData.strip("strip-edit"), PreviewData.strip("strip-mcp"), PreviewData.strip("strip-quiet"),
        PreviewData.backgroundWorking(count: 1), PreviewData.backgroundShell(listed: 1), PreviewData.backgroundShell(listed: 3),
        PreviewData.permission, PreviewData.question,
        PreviewData.terminalItem(.warp, "needs-permission"), PreviewData.terminalItem(.warp, "open-question"),
        PreviewData.terminalItem(.appOnly, "show-waiting"), PreviewData.terminalItem(.nameless, "show-working"),
        PreviewData.crowded(done: 9, running: 2, needYou: 1), PreviewData.subagentsSample,
        PreviewData.otherToolItem, PreviewData.unknownItem, PreviewData.undoItem("contract-tests"),
    ]
    private static let finished: [SessionItem] = [
        PreviewData.finishedItem("long-prompt", prompt: PreviewData.longPrompt),
        PreviewData.finishedItem("with-subagents", prompt: "Port the fixtures", doneSubagents: 14),
        PreviewData.finishedDone, PreviewData.finishedStale, PreviewData.finishedUndoItem("docs-site"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // A jump button to Warp's tab, the row under the pointer: "⋯" in the time's place.
                SessionRowView(PreviewData.terminalItem(.warp, "show-waiting"), tab: .active).hovered()
                // By place: the terminal items share their sessions' keys with the plain ones.
                ForEach(Array(Self.active.enumerated()), id: \.offset) { SessionRowView($0.element, tab: .active) }
                ForEach(Array(Self.finished.enumerated()), id: \.offset) { SessionRowView($0.element, tab: .finished) }
            }
        }
        .frame(width: 400, height: 1_400)
        .background(.role(.surface))
        .environment(\.pinnedClock, PreviewData.now)
    }
}

#Preview("SessionRowView · Active") { SessionRowPreviews(tab: .active) }
#Preview("SessionRowView · Active, dark") { SessionRowPreviews(tab: .active).preferredColorScheme(.dark) }
#Preview("SessionRowView · Idle") { SessionRowPreviews(tab: .idle) }
#Preview("SessionRowView · Finished, dark") { SessionRowPreviews(tab: .finished).preferredColorScheme(.dark) }
#Preview("SessionRowView · states") { SessionRowStatesPreview() }
#Preview("SessionRowView · states, dark") { SessionRowStatesPreview().preferredColorScheme(.dark) }
#endif
