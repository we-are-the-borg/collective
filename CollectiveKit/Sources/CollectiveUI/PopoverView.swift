import AppKit
import CollectiveKit
import SubspaceKit
import SwiftUI

/// The whole popover: title bar with the tabs, the selected tab's rows and
/// the status bar for one `PopoverModel`. Layout only; every number and
/// string comes from the model.
public struct PopoverView: View {
    private let model: PopoverModel
    private let onSelectTab: (PopoverTab) -> Void
    private let onToggleEarlierSessions: () -> Void
    private let onArchive: (ArchiveUndo.Kind) -> Void
    private let onUndo: (ArchiveUndo.ID) -> Void
    private let onUndoHover: (ArchiveUndo.ID, Bool) -> Void
    private let onUndoLast: () -> Void
    private let onToggleSubagents: (SessionKey, Bool) -> Void
    private let onToggleSubagentFold: (SubagentFoldID) -> Void
    private let onCheckAgain: () -> Void
    private let onSetUp: () -> Void
    private let onSettings: () -> Void
    private let onOpenUpdate: (SourceID) -> Void
    private let onShowTerminal: (SessionKey) -> Void
    private let onRowSeen: (SessionItem) -> Void

    /// The reply card's one flow: the host below, the list
    /// and the rows all feed it, through `\.replyCard`.
    @State private var replyCard = ReplyCardController()

    /// - Parameters:
    ///   - onSelectTab: A click on a tab, ⌘1–⌘3 or "Show n idle"; the app selects it.
    ///   - onToggleEarlierSessions: The heading the known sessions fold under while a warning shows.
    ///   - onCheckAgain: "Check Again" in the warning block; the app probes subspace again.
    ///   - onSetUp: "Set Up…" in the warning block; the app opens the setup window.
    ///   - onSettings: The settings button in the title bar or ⌘,; the app opens the settings window.
    ///   - onOpenUpdate: The status bar's update link; the app opens that source's settings pane.
    ///   - onArchive: The user archived something; the app archives it and keeps the undo.
    ///   - onUndo: The Undo button of one undo row.
    ///   - onUndoHover: The pointer entered or left an undo row; the app holds its timer meanwhile.
    ///   - onUndoLast: ⌘Z while the popover is open.
    ///   - onToggleSubagents: A row's subagent toggle line, with whether its list shows open now.
    ///   - onToggleSubagentFold: A fold row of finished subagents in a row's list.
    ///   - onShowTerminal: "Show in <App>" on a row, or ⌘↩; the app brings the
    ///     session's terminal forward and closes the popover.
    ///   - onRowSeen: A row is at least half in view, or its unread turn end
    ///     changed while it is; the app counts it read once the popover closes.
    public init(
        _ model: PopoverModel,
        onSelectTab: @escaping (PopoverTab) -> Void = { _ in },
        onToggleEarlierSessions: @escaping () -> Void = {},
        onArchive: @escaping (ArchiveUndo.Kind) -> Void = { _ in },
        onUndo: @escaping (ArchiveUndo.ID) -> Void = { _ in },
        onUndoHover: @escaping (ArchiveUndo.ID, Bool) -> Void = { _, _ in },
        onUndoLast: @escaping () -> Void = {},
        onToggleSubagents: @escaping (SessionKey, Bool) -> Void = { _, _ in },
        onToggleSubagentFold: @escaping (SubagentFoldID) -> Void = { _ in },
        onCheckAgain: @escaping () -> Void = {},
        onSetUp: @escaping () -> Void = {},
        onSettings: @escaping () -> Void = {},
        onOpenUpdate: @escaping (SourceID) -> Void = { _ in },
        onShowTerminal: @escaping (SessionKey) -> Void = { _ in },
        onRowSeen: @escaping (SessionItem) -> Void = { _ in }
    ) {
        self.model = model
        self.onSelectTab = onSelectTab
        self.onToggleEarlierSessions = onToggleEarlierSessions
        self.onArchive = onArchive
        self.onUndo = onUndo
        self.onUndoHover = onUndoHover
        self.onUndoLast = onUndoLast
        self.onToggleSubagents = onToggleSubagents
        self.onToggleSubagentFold = onToggleSubagentFold
        self.onCheckAgain = onCheckAgain
        self.onSetUp = onSetUp
        self.onSettings = onSettings
        self.onOpenUpdate = onOpenUpdate
        self.onShowTerminal = onShowTerminal
        self.onRowSeen = onRowSeen
    }

    public var body: some View {
        VStack(spacing: 0) {
            titleBar
            SessionListView(
                model,
                maxHeight: maxListHeight,
                onSelectTab: onSelectTab,
                onToggleEarlierSessions: onToggleEarlierSessions,
                onArchive: onArchive,
                onUndo: onUndo,
                onUndoHover: onUndoHover,
                onToggleSubagents: onToggleSubagents,
                onToggleSubagentFold: onToggleSubagentFold,
                onCheckAgain: onCheckAgain,
                onSetUp: onSetUp,
                onShowTerminal: onShowTerminal,
                onRowSeen: onRowSeen
            )
            statusBar
        }
        .frame(width: 400)
        .tracksKeyboardUse()
        .font(.plexSans(13))
        .foregroundStyle(.role(.text))
        // Square, as in Unimatrix: no material, no rounded corners and no frame;
        // the panel's shadow carries the edge.
        .background(.role(.surface))
        // Over everything, so a row's reply card stays inside the window.
        .rowPreviewHost()
        .replyCardSupport(replyCard)
        .background {
            // ⌘Z has no visible control; a zero-size button carries the
            // shortcut. The panel has no menu bar of its own that would.
            Button(action: onUndoLast) { EmptyView() }
                .keyboardShortcut("z", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .environment(\.replyCard, replyCard)
    }

    /// 70 % of the screen's visible height; the list is sized to its content below that.
    private var maxListHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) * 0.7
    }

    /// The parts of a line with " · " between each two, in the line's style.
    private static func dotJoined(_ parts: [LocalizedStringResource]) -> Text {
        guard let first = parts.first else { return Text(verbatim: "") }
        return parts.dropFirst().reduce(Text(first)) { text, part in text + Text(verbatim: " · ") + Text(part) }
    }

    // MARK: Title bar

    private var titleBar: some View {
        HStack(spacing: 2) {
            HStack(spacing: 2) {
                ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                    TabButton(tab: tab, shortcut: KeyEquivalent(Character("\(index + 1)"))) { onSelectTab(tab.tab) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isTabBar)
            .accessibilityLabel(Text("Sessions", bundle: .module))
            Spacer(minLength: 0)
            Button(action: onSettings) {
                LucideImage(.settings, size: 15)
                    .foregroundStyle(.role(.textMuted))
                    .frame(width: 28, height: 26)
            }
            .buttonStyle(.popoverIcon)
            .keyboardShortcut(",", modifiers: .command)
            .help(Text("Settings  ⌘,", bundle: .module))
            .accessibilityLabel(Text("Settings", bundle: .module))
        }
        .padding(.leading, 7)
        .padding(.trailing, 6)
        .frame(height: 40)
        .background(.role(.surfaceSunken))
        .overlay(alignment: .bottom) { BorderLine() }
    }

    // MARK: Status bar

    /// No line above it: the last row carries its own.
    private var statusBar: some View {
        HStack(spacing: 7) {
            HStack(spacing: 7) {
                Circle()
                    .fill(.role(model.footerIsWarning ? .warning : .success))
                    .frame(width: 6, height: 6)
                DurationClock(since: model.footerCountsFrom) { now in
                    Self.dotJoined(model.footerParts(at: now))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            // The status is the only part that gives way when the row gets tight.
            .layoutPriority(-1)
            Spacer(minLength: 0)
            if let link = model.footerLink {
                Button { onOpenUpdate(link.source) } label: { UpdateLinkLabel(link: link) }
                    .buttonStyle(.popoverIcon)
                    .help(Text(link.text))
                    .accessibilityLabel(Text(link.text))
            }
        }
        .font(.plexSans(11.5))
        .foregroundStyle(.role(.textSubtle))
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(.role(.surfaceSunken))
    }
}

/// The 1 px `--border` line under the title bar.
private struct BorderLine: View {
    var body: some View {
        Rectangle().fill(.role(.border)).frame(height: 1)
    }
}

/// One tab: its name, how many rows it holds and, on Active, "◆ n"; Idle and
/// Finished say their rule in the tooltip and show a dot while one of their
/// rows is unread.
private struct TabButton: View {
    let tab: TabItem
    let shortcut: KeyEquivalent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(tab.title)
                    .font(.plexSans(12.5, weight: tab.isSelected ? .medium : .regular))
                    .foregroundStyle(.role(tab.isSelected ? .text : .textMuted))
                Text(verbatim: "\(tab.count)")
                    .font(.plexMono(11.5))
                    .foregroundStyle(.role(.textSubtle))
                if tab.hasUnread { UnreadDot(size: 5) }
                if let needYou = tab.needYouText {
                    HStack(spacing: 3) {
                        StatusShapeView(.diamond, role: .agentWaiting, size: 8)
                        Text(verbatim: "\(tab.needYouCount)")
                    }
                    .font(.plexMono(11.5))
                    .foregroundStyle(.role(.agentWaiting))
                    .help(Text(needYou))
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: 26)
        }
        // The selected tab stands on `--surface-raised` with a 1 px `--border` frame (inside the
        // 26 pt height, so nothing shifts); the others have no fill until hovered.
        .buttonStyle(PopoverIconButtonStyle(restingFill: tab.isSelected ? .surfaceRaised : nil, framed: tab.isSelected))
        .keyboardShortcut(shortcut, modifiers: .command)
        .modifier(OptionalHelp(text: tab.help.map { Text($0) }))
        .accessibilityLabel(Text(tab.accessibilityLabel))
        .accessibilityAddTraits(tab.isSelected ? .isSelected : [])
    }
}

/// The status bar's update link: Lucide `circle-arrow-up` and the text, both
/// in the link's role.
private struct UpdateLinkLabel: View {
    let link: UpdateFooterLink

    var body: some View {
        HStack(spacing: 4) {
            LucideImage(.circleArrowUp, size: 12)
            Text(link.text)
                .lineLimit(1)
        }
        .foregroundStyle(.role(link.role))
        .padding(.horizontal, 4)
        .frame(height: 20)
    }
}

#if DEBUG
private struct PopoverPreview: View {
    let model: PopoverModel

    var body: some View {
        PopoverView(model)
            .environment(\.pinnedClock, PreviewData.now)
    }
}

#Preview("Tabs · Active") { PopoverPreview(model: PreviewData.tabs(.active)) }
#Preview("Tabs · Active, dark") { PopoverPreview(model: PreviewData.tabs(.active)).preferredColorScheme(.dark) }
#Preview("Tabs · Idle") { PopoverPreview(model: PreviewData.tabs(.idle)) }
#Preview("Tabs · Finished, dark") { PopoverPreview(model: PreviewData.tabs(.finished)).preferredColorScheme(.dark) }
#Preview("Tabs · Active, GitHub") {
    PopoverPreview(model: PreviewData.tabs(.active)).themeSelection(light: "github", dark: "github-dark")
}

#Preview("Warning, missing, no sessions") { PopoverPreview(model: PreviewData.warning(.missing, sessions: false)) }
#Preview("Warning, missing, no sessions, dark") {
    PopoverPreview(model: PreviewData.warning(.missing, sessions: false)).preferredColorScheme(.dark)
}
#Preview("Warning, disabled, with sessions") { PopoverPreview(model: PreviewData.warning(.disabled, sessions: true)) }
#Preview("Warning, disabled, earlier sessions open") {
    PopoverPreview(model: PreviewData.warning(.disabled, sessions: true, earlierOpen: true))
}
#Preview("Warning, disabled, with sessions, dark") {
    PopoverPreview(model: PreviewData.warning(.disabled, sessions: true)).preferredColorScheme(.dark)
}

#Preview("Footer, update available") { PopoverPreview(model: PreviewData.updateFooter(.available)) }
#Preview("Footer, update available, dark") {
    PopoverPreview(model: PreviewData.updateFooter(.available)).preferredColorScheme(.dark)
}
#Preview("Footer, update required") { PopoverPreview(model: PreviewData.updateFooter(.required)) }
#Preview("Footer, restart hint") { PopoverPreview(model: PreviewData.updateFooter(.restart)) }

#Preview("Idle · mixed") { PopoverPreview(model: PreviewData.idle(.mixed)) }
#Preview("Idle · mixed, dark") { PopoverPreview(model: PreviewData.idle(.mixed)).preferredColorScheme(.dark) }
#Preview("Idle · everything idle") { PopoverPreview(model: PreviewData.idle(.allIdle)) }
#Preview("Idle · everything idle, dark") { PopoverPreview(model: PreviewData.idle(.allIdle)).preferredColorScheme(.dark) }
#Preview("Idle · collapsed") { PopoverPreview(model: PreviewData.idle(.collapsed)) }
#Preview("Idle · collapsed, dark") { PopoverPreview(model: PreviewData.idle(.collapsed)).preferredColorScheme(.dark) }

#Preview("Effort · levels 1–5") { PopoverPreview(model: PreviewData.effort()) }
#Preview("Effort · levels 1–5, dark") { PopoverPreview(model: PreviewData.effort()).preferredColorScheme(.dark) }
#Preview("Effort · colors off") { PopoverPreview(model: PreviewData.effort(colors: false)) }
#Preview("Effort · colors off, dark") { PopoverPreview(model: PreviewData.effort(colors: false)).preferredColorScheme(.dark) }

#Preview("Show in Warp") { PopoverPreview(model: PreviewData.terminal(.warp)) }
#Preview("Show in Warp, dark") { PopoverPreview(model: PreviewData.terminal(.warp)).preferredColorScheme(.dark) }
#Preview("Show in Terminal, app only") { PopoverPreview(model: PreviewData.terminal(.appOnly)) }

#Preview("Empty") { PopoverPreview(model: PreviewData.scenario(.empty)) }
#Preview("Loading") { PopoverPreview(model: PreviewData.scenario(.loading)) }
#Preview("Single") { PopoverPreview(model: PreviewData.scenario(.single)) }
#Preview("Five") { PopoverPreview(model: PreviewData.scenario(.five)) }
#Preview("Unassigned") { PopoverPreview(model: PreviewData.scenario(.unassigned)) }
#Preview("Background") { PopoverPreview(model: PreviewData.scenario(.background)) }
#Preview("Nested") { PopoverPreview(model: PreviewData.scenario(.nested)) }
#Preview("Finished collapsed") { PopoverPreview(model: PreviewData.scenario(.finished)) }
#Preview("Finished expanded") { PopoverPreview(model: PreviewData.scenario(.finishedOpen)) }
#Preview("Five, dark") {
    PopoverPreview(model: PreviewData.scenario(.five)).preferredColorScheme(.dark)
}
#Preview("Finished collapsed, dark") {
    PopoverPreview(model: PreviewData.scenario(.finished)).preferredColorScheme(.dark)
}
#Preview("Finished expanded, dark") {
    PopoverPreview(model: PreviewData.scenario(.finishedOpen)).preferredColorScheme(.dark)
}
#Preview("Empty, dark") {
    PopoverPreview(model: PreviewData.scenario(.empty)).preferredColorScheme(.dark)
}

#Preview("Undo row · finished") {
    PopoverPreview(model: PreviewData.archived(.finishedSession(SessionKey(source: "claude-code", sessionID: "docs-site")), in: .finished))
}
#Preview("Undo row · Archive All Finished") { PopoverPreview(model: PreviewData.bulkUndo) }
#Preview("Undo row · Archive All Finished, dark") { PopoverPreview(model: PreviewData.bulkUndo).preferredColorScheme(.dark) }
#Preview("Undo row · card") {
    PopoverPreview(model: PreviewData.archived(.session(SessionKey(source: "claude-code", sessionID: "contract-tests"))))
}
#Preview("Undo row · card, dark") {
    PopoverPreview(model: PreviewData.archived(.session(SessionKey(source: "claude-code", sessionID: "contract-tests"))))
        .preferredColorScheme(.dark)
}

#Preview("Card states · mixed") { PopoverPreview(model: PreviewData.cardStates()) }
#Preview("Card states · mixed, dark") { PopoverPreview(model: PreviewData.cardStates()).preferredColorScheme(.dark) }
#Preview("Long list · 13 done") { PopoverPreview(model: PreviewData.scenario(.long0)) }
#Preview("Long list · 13 done, dark") {
    PopoverPreview(model: PreviewData.scenario(.long0)).preferredColorScheme(.dark)
}
#Preview("Long list · 13 done, 2 running, waiting") { PopoverPreview(model: PreviewData.scenario(.long2)) }
#Preview("Long list · 13 done, 2 running, waiting, dark") {
    PopoverPreview(model: PreviewData.scenario(.long2)).preferredColorScheme(.dark)
}
#Preview("Three subagents") { PopoverPreview(model: PreviewData.scenario(.three)) }
#Preview("Three subagents, dark") {
    PopoverPreview(model: PreviewData.scenario(.three)).preferredColorScheme(.dark)
}
#Preview("Waiting, one tool") { PopoverPreview(model: PreviewData.scenario(.background)) }
#Preview("Waiting, one tool, dark") {
    PopoverPreview(model: PreviewData.scenario(.background)).preferredColorScheme(.dark)
}
#Preview("Loading, dark") {
    PopoverPreview(model: PreviewData.scenario(.loading)).preferredColorScheme(.dark)
}
#Preview("Orchestrator model") { PopoverPreview(model: PreviewData.scenario(.modelOrchestrator)) }
#Preview("Orchestrator model, dark") {
    PopoverPreview(model: PreviewData.scenario(.modelOrchestrator)).preferredColorScheme(.dark)
}
#Preview("Codex model, tool name") { PopoverPreview(model: PreviewData.scenario(.modelCodex)) }

#Preview("Short reply") { PopoverPreview(model: PreviewData.replies(.short)) }
#Preview("Short reply, dark") { PopoverPreview(model: PreviewData.replies(.short)).preferredColorScheme(.dark) }
#Preview("Long reply closed") { PopoverPreview(model: PreviewData.replies(.longClosed)) }
#Preview("Long reply closed, dark") {
    PopoverPreview(model: PreviewData.replies(.longClosed)).preferredColorScheme(.dark)
}
#Preview("Working again") { PopoverPreview(model: PreviewData.replies(.workingAgain)) }
#Preview("Working again, dark") {
    PopoverPreview(model: PreviewData.replies(.workingAgain)).preferredColorScheme(.dark)
}
#Preview("Background working") { PopoverPreview(model: PreviewData.replies(.background)) }
#Preview("Background working, dark") {
    PopoverPreview(model: PreviewData.replies(.background)).preferredColorScheme(.dark)
}
#Preview("No and blank reply") { PopoverPreview(model: PreviewData.replies(.noReply)) }
#Preview("No and blank reply, dark") {
    PopoverPreview(model: PreviewData.replies(.noReply)).preferredColorScheme(.dark)
}
#Preview("Finished replies, one open, one stale") { PopoverPreview(model: PreviewData.replies(.finished)) }
#Preview("Finished replies, one open, one stale, dark") {
    PopoverPreview(model: PreviewData.replies(.finished)).preferredColorScheme(.dark)
}
#Preview("Claude Code and Codex, code-only reply") { PopoverPreview(model: PreviewData.replies(.codex)) }
#Preview("Claude Code and Codex, code-only reply, dark") {
    PopoverPreview(model: PreviewData.replies(.codex)).preferredColorScheme(.dark)
}
#endif
