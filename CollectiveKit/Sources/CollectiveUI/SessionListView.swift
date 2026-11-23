import AppKit
import CollectiveKit
import SwiftUI

/// Everything between the popover's title bar and status bar: the warning block,
/// the loading and dormant states, and the selected tab's rows. Layout only;
/// every number and string comes from the model.
public struct SessionListView: View {
    private let model: PopoverModel
    private let maxHeight: CGFloat
    private let onSelectTab: (PopoverTab) -> Void
    private let onToggleEarlierSessions: () -> Void
    private let onArchive: (ArchiveUndo.Kind) -> Void
    private let onUndo: (ArchiveUndo.ID) -> Void
    private let onUndoHover: (ArchiveUndo.ID, Bool) -> Void
    private let onToggleSubagents: (SessionKey, Bool) -> Void
    private let onToggleSubagentFold: (SubagentFoldID) -> Void
    private let onCheckAgain: () -> Void
    private let onSetUp: () -> Void
    private let onShowTerminal: (SessionKey) -> Void
    private let onRowSeen: (SessionItem) -> Void

    @State private var contentHeight: CGFloat = 0
    /// The reply card's flow, from `PopoverView`: the list reports its keys
    /// and the rows that leave.
    @Environment(\.replyCard) private var replyCard
    /// The row with keyboard focus.
    @FocusState private var focus: SessionKey?
    /// The ring shows only after a key press, like `:focus-visible`.
    @Environment(\.isKeyboardFocusVisible) private var showsFocusRing

    /// - Parameters:
    ///   - maxHeight: The list is as tall as its content up to this, then it scrolls.
    ///   - onSelectTab: "Show n idle" in the empty Active tab; the app selects Idle.
    ///   - onToggleEarlierSessions: The heading the known sessions fold under while a warning shows.
    ///   - onCheckAgain: "Check Again" in the warning block; the app probes subspace again.
    ///   - onSetUp: "Set Up…" in the warning block; the app opens the setup window.
    ///   - onArchive: The user archived something; the app archives it and keeps the undo.
    ///   - onUndo: The Undo button of one undo row.
    ///   - onUndoHover: The pointer entered or left an undo row; the app holds its timer meanwhile.
    ///   - onToggleSubagents: A row's subagent toggle line, with whether its list shows open now;
    ///     the app opens or closes it.
    ///   - onToggleSubagentFold: A fold row of finished subagents in a row's list.
    ///   - onShowTerminal: "Show in <App>" on a row, and ⌘↩ on the focused one;
    ///     the app brings the session's terminal forward.
    ///   - onRowSeen: A row is at least half in view, or its unread turn end
    ///     changed while it is; the app counts it read once the popover closes.
    public init(
        _ model: PopoverModel,
        maxHeight: CGFloat,
        onSelectTab: @escaping (PopoverTab) -> Void = { _ in },
        onToggleEarlierSessions: @escaping () -> Void = {},
        onArchive: @escaping (ArchiveUndo.Kind) -> Void = { _ in },
        onUndo: @escaping (ArchiveUndo.ID) -> Void = { _ in },
        onUndoHover: @escaping (ArchiveUndo.ID, Bool) -> Void = { _, _ in },
        onToggleSubagents: @escaping (SessionKey, Bool) -> Void = { _, _ in },
        onToggleSubagentFold: @escaping (SubagentFoldID) -> Void = { _ in },
        onCheckAgain: @escaping () -> Void = {},
        onSetUp: @escaping () -> Void = {},
        onShowTerminal: @escaping (SessionKey) -> Void = { _ in },
        onRowSeen: @escaping (SessionItem) -> Void = { _ in }
    ) {
        self.model = model
        self.maxHeight = maxHeight
        self.onSelectTab = onSelectTab
        self.onToggleEarlierSessions = onToggleEarlierSessions
        self.onArchive = onArchive
        self.onUndo = onUndo
        self.onUndoHover = onUndoHover
        self.onToggleSubagents = onToggleSubagents
        self.onToggleSubagentFold = onToggleSubagentFold
        self.onCheckAgain = onCheckAgain
        self.onSetUp = onSetUp
        self.onShowTerminal = onShowTerminal
        self.onRowSeen = onRowSeen
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let warning = model.warning {
                WarningBlockView(warning: warning, onCheckAgain: onCheckAgain, onSetUp: onSetUp)
            }
            switch model.content {
            case let .loading(indicatorVisible): LoadingState(indicatorVisible: indicatorVisible)
            case .dormant: if model.warning == nil { dormant }
            case .list: list
            // Folded under a warning, only the earlier sessions' line shows.
            case .allQuiet, .nothingIdle, .nothingFinished:
                list
                if model.earlierSessions?.isExpanded != false { emptyTab }
            }
        }
        // Here rather than at the list, which goes with the last row; a tab change,
        // archiving or a reply ending all take a card's row away.
        .onChange(of: model.replyCardTargets) { old, new in replyCard?.targetsChanged(from: old, to: new) }
    }

    // MARK: Empty states

    /// No session at all, not even a resting one: no button, so never "Show 0 idle".
    private var dormant: some View {
        EmptyStateView(mark: .check) {
            Text("The Collective is dormant.", bundle: .module)
        } message: {
            Text("No agents are running. Sessions appear here as soon as one starts.", bundle: .module)
        }
    }

    /// "All quiet" with "Show n idle", "Nothing idle", "Nothing finished".
    @ViewBuilder private var emptyTab: some View {
        let content = model.content
        if let title = content.title {
            EmptyStateView(mark: content == .nothingIdle ? .ring : .check) {
                Text(title)
            } message: {
                if let message = content.message { Text(message) }
            } button: {
                if let showIdle = content.showIdleText {
                    Button { onSelectTab(.idle) } label: {
                        Text(showIdle)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                    }
                    .buttonStyle(.popoverBordered)
                    .padding(.top, 6)
                }
            }
        }
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let header = model.earlierSessions { earlierSessionsHeader(header) }
                // Folded under a warning, only the heading shows; rows and their undo rows go with it.
                if model.earlierSessions?.isExpanded != false { rows }
            }
            .onKeyPress(.upArrow) { arrow(.upArrow) }
            .onKeyPress(.downArrow) { arrow(.downArrow) }
            .onChange(of: model.focusOrder) { _, order in
                // Archiving or a tab change removes the focused row; land on the item above it.
                if let current = focus, !order.contains(current) { focus = order.last }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        // Below `maxHeight` the list is sized to its content.
        .frame(height: min(contentHeight, maxHeight))
    }

    /// The selected tab's rows, no group headings: the tabs replace them.
    /// "Archive All Finished" leaves one undo row on top of Finished.
    @ViewBuilder private var rows: some View {
        let tab = model.selectedTab
        let rows = model.rows
        if tab == .finished, let bulk = model.finishedBulkUndo {
            UndoRowView(row: bulk, onUndo: onUndo, onHover: onUndoHover)
        }
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
            row(item, tab: tab, isLastOfSeveral: rows.count > 1 && index == rows.count - 1)
        }
    }

    private func row(_ item: SessionItem, tab: PopoverTab, isLastOfSeveral: Bool) -> some View {
        SessionRowView(
            item,
            tab: tab,
            isLastOfSeveral: isLastOfSeveral,
            onArchive: onArchive,
            onArchiveAllFinished: archiveAllFinished,
            onUndo: onUndo,
            onUndoHover: onUndoHover,
            onToggleSubagents: onToggleSubagents,
            onToggleSubagentFold: onToggleSubagentFold,
            onShowTerminal: onShowTerminal
        )
        // ⌫ and ⌘⌫ do nothing on a working row: its next tool start would bring it back.
        .focusRing(for: item, focus: $focus, showsRing: showsFocusRing, archive: {
            guard item.isArchivable else { return }
            onArchive(tab == .finished ? .finishedSession(item.key) : .session(item.key))
        })
        .handlesReplyKeys(item, replyCard: replyCard, showTerminal: onShowTerminal)
        .reportsSeen(item, onSeen: onRowSeen)
    }

    /// ↑ ↓ scroll a shown card, else move the focus as before.
    private func arrow(_ key: ReplyCardKey) -> KeyPress.Result {
        let focusedReply = replyCard?.openable(model.rows.first { $0.key == focus }?.replyCardTarget)
        let action = replyCard?.action(for: key, focusedReply: focusedReply) ?? (key == .upArrow ? .moveFocusUp : .moveFocusDown)
        switch action {
        case .scrollCardUp: replyCard?.scrollCard(by: -1)
        case .scrollCardDown: replyCard?.scrollCard(by: 1)
        case .moveFocusUp: return moveFocus(by: -1)
        case .moveFocusDown: return moveFocus(by: 1)
        case .pass, .open, .closeCard, .showInApp: return .ignored
        }
        return .handled
    }

    private func moveFocus(by step: Int) -> KeyPress.Result {
        let order = model.focusOrder
        guard let current = focus, let index = order.firstIndex(of: current) else { return .ignored }
        let next = index + step
        guard order.indices.contains(next) else { return .handled }
        focus = order[next]
        return .handled
    }

    /// What "Archive All Finished" covers: the rows listed now, not the ones already archived.
    private var archiveAllFinished: () -> Void {
        let keys = model.finished.filter { $0.undo == nil }.map(\.key)
        return { if !keys.isEmpty { onArchive(.allFinished(keys)) } }
    }

    /// "› 3 earlier sessions" under the warning block: a toggle line like the
    /// subagents', its chevron in the rows' form column.
    private func earlierSessionsHeader(_ header: EarlierSessionsHeader) -> some View {
        Button(action: onToggleEarlierSessions) {
            HStack(spacing: RowMetrics.columnGap) {
                SubagentDisclosureChevron(isOpen: header.isExpanded)
                    .frame(width: RowMetrics.shapeColumn)
                Text(header.title)
                    .lineLimit(1)
            }
            .font(.plexSans(12))
            .foregroundStyle(.role(.textMuted))
            .padding(.horizontal, RowMetrics.padding.leading)
            .frame(maxWidth: .infinity, minHeight: SubagentListMetrics.toggleHeight, maxHeight: SubagentListMetrics.toggleHeight, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.subagentLine)
        .accessibilityHint(header.isExpanded ? Text("Hides the earlier sessions", bundle: .module) : Text("Shows the earlier sessions", bundle: .module))
        .overlay(alignment: .bottom) { Rectangle().fill(.role(.border)).frame(height: 1) }
    }
}

/// A row tells when at least half of it came into the scroll view's view, and
/// again when its unread turn end changes while it stays there: a turn that
/// ends under the user's eyes is seen too. Undo rows tell nothing.
private struct ReportsSeen: ViewModifier {
    let item: SessionItem
    let onSeen: (SessionItem) -> Void
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .onScrollVisibilityChange(threshold: 0.5) { visible in
                isVisible = visible
                if visible { report() }
            }
            .onChange(of: item.unreadTurnEndedAt) { if isVisible { report() } }
    }

    private func report() {
        if item.undo == nil { onSeen(item) }
    }
}

private extension View {
    func reportsSeen(_ item: SessionItem, onSeen: @escaping (SessionItem) -> Void) -> some View {
        modifier(ReportsSeen(item: item, onSeen: onSeen))
    }
}

/// Keyboard focus for one row: ↑ ↓ and the focus frame come from the list,
/// ⌫ and ⌘⌫ archive the focused row. Undo rows take no focus.
/// `.edit` keeps clicks reaching the row's buttons; the default would focus the row instead.
private extension View {
    func focusRing(
        for item: SessionItem, focus: FocusState<SessionKey?>.Binding, showsRing: Bool, archive: @escaping () -> Void
    ) -> some View {
        modifier(FocusRing(key: item.key, isFocusable: item.undo == nil, focus: focus, showsRing: showsRing, archive: archive))
    }
}

/// An inner 2 px `--focus-ring` frame over the whole row, square (restyle-popover.md, "Tastaturfokus").
private struct FocusRing: ViewModifier {
    let key: SessionKey
    let isFocusable: Bool
    var focus: FocusState<SessionKey?>.Binding
    let showsRing: Bool
    let archive: () -> Void

    func body(content: Content) -> some View {
        content
            .focusable(isFocusable, interactions: .edit)
            .focused(focus, equals: key)
            .focusEffectDisabled()
            .overlay {
                if showsRing, focus.wrappedValue == key {
                    Rectangle()
                        .strokeBorder(.role(.focusRing), lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .archivesOnDelete(archive)
    }
}

private extension View {
    /// Space and Return while the row has the keyboard focus, which undo rows
    /// never get: a row whose reply does not fit opens its reply card, as its
    /// "Show more" does; any other lets the key pass.
    /// ⌘↩ brings the row's terminal forward; a row without a terminal
    /// lets it pass. Focus alone opens no card.
    func handlesReplyKeys(
        _ item: SessionItem, replyCard: ReplyCardController?, showTerminal: @escaping (SessionKey) -> Void
    ) -> some View {
        onKeyPress(keys: [.return, .space], phases: [.down, .repeat]) { press in
            let key: ReplyCardKey = press.key == .space ? .space : press.modifiers.contains(.command) ? .commandReturn : .return
            let focusedReply = replyCard?.openable(item.replyCardTarget)
            let action = replyCard?.action(for: key, focusedReply: focusedReply) ?? (key == .commandReturn ? .showInApp : .pass)
            switch action {
            case .showInApp:
                guard item.terminalAction != nil else { return .ignored }
                if press.phase == .down { showTerminal(item.key) }
            case let .open(target):
                if press.phase == .down { replyCard?.open(target) }
            case .pass, .scrollCardUp, .scrollCardDown, .moveFocusUp, .moveFocusDown, .closeCard:
                return .ignored
            }
            return .handled
        }
    }
}

/// While the backlog is read, so a busy spool never looks dormant.
/// The empty states' layout without a form and without a spinner; before the
/// indicator is due the texts only turn invisible, so nothing jumps when it appears.
struct LoadingState: View {
    let indicatorVisible: Bool

    var body: some View {
        EmptyStateView(mark: nil) {
            Text("Reading recent sessions…", bundle: .module)
        } message: {
            Text("Running sessions appear here as soon as they are found.", bundle: .module)
        }
        .opacity(indicatorVisible ? 1 : 0)
    }
}

/// A tab with nothing to list: the form, the title, a line under it and
/// maybe a button, centred (restyle-popover.md, "Leeres Active").
struct EmptyStateView<Message: View, Action: View>: View {
    enum Mark {
        /// `--agent-done`, the design's check at stroke 1.8.
        case check
        /// `--agent-idle`, the idle row's ring.
        case ring
    }

    /// Nil keeps the form's place empty, so the texts stand where the next state's do.
    let mark: Mark?
    let title: Text
    let message: Message
    let action: Action

    static var markSize: CGFloat { 14 }
    static var checkLineWidth: CGFloat { 1.8 }

    init(
        mark: Mark?, @ViewBuilder title: () -> Text, @ViewBuilder message: () -> Message,
        @ViewBuilder button: () -> Action
    ) {
        self.mark = mark
        self.title = title()
        self.message = message()
        action = button()
    }

    var body: some View {
        VStack(spacing: 6) {
            markView
                .frame(width: Self.markSize, height: Self.markSize)
                .accessibilityHidden(true)
            title
                .font(.plexSans(13, weight: .medium))
                .foregroundStyle(.role(.text))
            message
                .font(.plexSans(12))
                .foregroundStyle(.role(.textMuted))
            action
                .font(.plexSans(12))
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(EdgeInsets(top: 40, leading: 24, bottom: 44, trailing: 24))
    }

    @ViewBuilder private var markView: some View {
        switch mark {
        case .check:
            StatusCheck()
                .stroke(.role(.agentDone), style: StrokeStyle(
                    lineWidth: Self.checkLineWidth * Self.markSize / 12, lineCap: .round, lineJoin: .round
                ))
        case .ring:
            StatusShapeView(.ring, role: .agentIdle, size: Self.markSize)
        case nil:
            Color.clear
        }
    }
}

extension EmptyStateView where Action == EmptyView {
    init(mark: Mark?, @ViewBuilder title: () -> Text, @ViewBuilder message: () -> Message) {
        self.init(mark: mark, title: title, message: message, button: { EmptyView() })
    }
}
