import CollectiveKit
import SwiftUI

/// A row's subagents one by one under its toggle line: newest first, 14 pt
/// in per level, the finished ones folded. A 1 px `--border` guide
/// line on the left, no fill, no radius. At most 220 pt tall, then it
/// scrolls inside. A row with a prompt or a result opens its reply card from
/// its context menu or VoiceOver, "Show Result", through the popover's
/// `ReplyCardController`; the pointer opens nothing.
/// A subagent archived from its menu shows an undo row in its place until
/// the undo goes.
struct SubagentListView: View {
    @Environment(\.replyCard) private var replyCard
    let list: SubagentList
    let onToggleFold: (SubagentFoldID) -> Void
    let onArchive: (ArchiveUndo.Kind) -> Void
    let onUndo: (ArchiveUndo.ID) -> Void
    let onUndoHover: (ArchiveUndo.ID, Bool) -> Void

    var body: some View {
        CappedHeight(maxHeight: SubagentListMetrics.maxHeight) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(list.entries) { entry in self.entry(entry) }
                }
            }
            // A list that fits neither bounces nor keeps the popover's list from scrolling.
            .scrollBounceBehavior(.basedOnSize)
        }
        // The rows start after the guide line, as inside the design's `border-left`.
        .padding(.leading, SubagentListMetrics.guideWidth)
        .overlay(alignment: .leading) {
            Rectangle().fill(.role(.border)).frame(width: SubagentListMetrics.guideWidth)
        }
    }

    @ViewBuilder
    private func entry(_ entry: SubagentEntry) -> some View {
        switch entry {
        case let .agent(row):
            if let undo = row.undo {
                SubagentUndoRowView(undo: undo, depth: row.depth, onUndo: onUndo, onHover: onUndoHover)
            } else {
                agentRow(row)
            }
        case let .fold(fold):
            SubagentFoldRowView(fold: fold) { onToggleFold(fold.id) }
        }
    }

    private func agentRow(_ row: SubagentRow) -> some View {
        let target = row.replyCardTarget(in: list.session)
        let showsCard = target != nil && replyCard?.shown == target
        return SubagentRowView(
            row: row,
            archive: { onArchive(.subagent(list.session, row.ref)) },
            showResult: target.map { target in
                SubagentRowView.ShowResult(open: { replyCard?.open(target) }, read: { replyCard?.read(target) })
            }
        )
        .anchorPreference(key: RowPreviewRequest.Key.self, value: .bounds) { bounds in
            guard showsCard else { return nil }
            return RowPreviewRequest(content: .subagent(row, session: list.session), row: bounds, isLastOfSeveral: false)
        }
    }
}

/// One subagent on one line: its form, the type in mono (else its
/// title) with " · " and the model, the status word at the end. No time and no second line; one
/// element for VoiceOver, which still reads them. With a prompt or a result,
/// its menu and VoiceOver offer "Show Result"; while it may hang, "Archive Subagent".
struct SubagentRowView: View {
    let row: SubagentRow
    let archive: () -> Void
    /// "Show Result" in the menu and for VoiceOver; nil without a prompt or a result.
    var showResult: ShowResult? = nil

    struct ShowResult {
        /// The menu entry: the row's card opens.
        let open: () -> Void
        /// VoiceOver's action: the card opens and VoiceOver moves into it.
        let read: () -> Void
    }

    var body: some View {
        let mark = row.statusMark
        HStack(spacing: SubagentListMetrics.columnGap) {
            StatusShapeView(mark, size: SubagentListMetrics.shapeSize)
                .frame(width: SubagentListMetrics.shapeColumn)
            title
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let word = mark.word {
                Text(word)
                    .foregroundStyle(.role(mark.wordRole))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .font(.plexSans(12))
        .frame(height: SubagentListMetrics.rowHeight)
        .padding(.leading, SubagentListMetrics.leadingInset(depth: row.depth))
        .contentShape(.rect)
        .modifier(SubagentRowMenu(row: row, archive: archive, showResult: showResult?.open))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(counting: row.runningSince, row.detail?.countsFrom) { Text(row.accessibilityText(at: $0)) }
        .accessibilityActions {
            if let read = showResult?.read {
                Button(action: read) { Text("Show Result", bundle: .module) }
            }
            if row.isArchivable {
                Button(action: archive) { Text("Archive Subagent", bundle: .module) }
            }
        }
    }

    /// "plugin:implementer · Sonnet 5.5", cut at its end as one line; only a
    /// type is mono, a stand-in title keeps the row's Sans.
    private var title: Text {
        var name = Text(row.titleText).foregroundStyle(.role(row.titleRole))
        if row.titleKind == .type { name = name.font(.plexMono(11.5)) }
        guard let model = row.titleModel else { return name }
        return name + Text(verbatim: " · \(model.name)").foregroundStyle(.role(row.modelRole))
    }
}

/// "Show Result" on a row with a prompt or a result; "Last event 2 min ago",
/// then "Archive Subagent", on a row that may hang. Any other row keeps the
/// row's menu. No ⌘⌫: the rows take no focus.
private struct SubagentRowMenu: ViewModifier {
    let row: SubagentRow
    let archive: () -> Void
    let showResult: (() -> Void)?

    func body(content: Content) -> some View {
        if row.isArchivable || showResult != nil {
            content.contextMenu(counting: row.isArchivable ? row.lastActivity : nil) { now in
                if let showResult {
                    Button(action: showResult) { Text("Show Result", bundle: .module) }
                    if row.isArchivable { Divider() }
                }
                if row.isArchivable {
                    Button {} label: { Text(row.lastEventText(at: now)) }
                        .disabled(true)
                    Divider()
                    ArchiveMenuButton(title: "Archive Subagent", action: archive)
                }
            }
        } else {
            content
        }
    }
}

/// "Explore archived", then the Undo link, in place of the row it took back,
/// at its indent and height, so the list does not jump. The text starts
/// where the type did. The pointer on it holds the countdown.
struct SubagentUndoRowView: View {
    let undo: UndoRow
    let depth: Int
    let onUndo: (ArchiveUndo.ID) -> Void
    let onHover: (ArchiveUndo.ID, Bool) -> Void

    var body: some View {
        HStack(spacing: SubagentListMetrics.columnGap) {
            Color.clear.frame(width: SubagentListMetrics.shapeColumn, height: 1)
            Text(undo.text)
                .foregroundStyle(.role(.textMuted))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            UndoLink { onUndo(undo.id) }
        }
        .font(.plexSans(12))
        .frame(height: SubagentListMetrics.rowHeight)
        .padding(.leading, SubagentListMetrics.leadingInset(depth: depth))
        .contentShape(.rect)
        .onHover { onHover(undo.id, $0) }
    }
}

/// "› 33 done · 1 archived" in `--text-subtle`: the finished subagents of a
/// level in one row; a click opens it, its members then follow one level
/// deeper. No right side.
struct SubagentFoldRowView: View {
    let fold: SubagentFoldRow
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: SubagentListMetrics.columnGap) {
                SubagentDisclosureChevron(isOpen: fold.isOpen)
                    .frame(width: SubagentListMetrics.shapeColumn)
                text
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.plexSans(12))
            .monospacedDigit()
            .foregroundStyle(.role(fold.textRole))
            .frame(height: SubagentListMetrics.rowHeight)
            .padding(.leading, SubagentListMetrics.leadingInset(depth: fold.depth))
            .contentShape(.rect)
        }
        .buttonStyle(.subagentLine)
        .accessibilityLabel(Text(fold.accessibilityText))
        .accessibilityValue(fold.isOpen ? Text("expanded", bundle: .module) : Text("collapsed", bundle: .module))
    }

    private var text: Text {
        guard let first = fold.textParts.first else { return Text(verbatim: "") }
        return fold.textParts.dropFirst().reduce(Text(first)) { $0 + Text(verbatim: " · ") + Text($1) }
    }
}

/// 0.5 pt in `--border` above the reply in a subagent row's preview and above
/// the idle preview's footer.
struct SubagentHairline: View {
    var body: some View {
        Rectangle()
            .fill(.role(.border))
            .frame(height: 0.5)
    }
}

/// Takes its content's height up to `maxHeight`; the scroll view inside
/// scrolls past it. Measured in the layout pass, so the list never shows at
/// zero height for a frame first, as a height read back from geometry would.
struct CappedHeight: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        // Unbounded in height, a scroll view asks for the height of what it holds.
        let ideal = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(
            width: proposal.width ?? ideal.width,
            height: SubagentListMetrics.visibleHeight(content: ideal.height, maxHeight: maxHeight)
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// The design numbers of a row's subagent section, so the spec can be asserted.
enum SubagentListMetrics {
    static let toggleHeight: CGFloat = 22
    /// The open list's top over the toggle line's bottom.
    static let pullUp: CGFloat = 2
    /// The open list's guide line in from the toggle line's leading edge.
    static let listInset: CGFloat = 4
    static let guideWidth: CGFloat = 1
    /// Taller than this, the list scrolls inside.
    static let maxHeight: CGFloat = 220
    static let rowHeight: CGFloat = 24
    /// A row's padding after the guide line, before its indent.
    static let rowLeading: CGFloat = 10
    /// Per level below the orchestrator's own subagents.
    static let indentPerLevel: CGFloat = 14
    /// The grid `12px minmax(0, 1fr) auto` with `column-gap: 8px`.
    static let shapeColumn: CGFloat = 12
    static let shapeSize: CGFloat = 10
    static let columnGap: CGFloat = 8

    /// Level 1 (the orchestrator's own) sits at the row's padding, each deeper one 14 further in.
    static func leadingInset(depth: Int) -> CGFloat {
        rowLeading + CGFloat(max(0, depth - 1)) * indentPerLevel
    }

    /// The list as tall as its rows up to `maxHeight`.
    static func visibleHeight(content: CGFloat, maxHeight: CGFloat = maxHeight) -> CGFloat {
        min(content, maxHeight)
    }
}

private extension SubagentDetail {
    /// The other time VoiceOver's label counts: "No activity for …", "last event … ago".
    var countsFrom: Date? {
        switch self {
        case let .lostContact(lastEvent): lastEvent
        case let .activity(.noActivity(since)), let .needsPermission(.noActivity(since)?): since
        case .activity, .needsPermission, .question: nil
        }
    }
}

#if DEBUG
/// 35 rows unfolded: the list stops at 220 pt and scrolls inside.
private struct SubagentScrollPreview: View {
    private let list = PreviewData.subagentBoard(.c, opensFold: true).subagentToggle?.list

    var body: some View {
        if let list {
            SubagentListView(
                list: list, onToggleFold: { _ in },
                onArchive: { _ in }, onUndo: { _ in }, onUndoHover: { _, _ in }
            )
            .frame(width: 350)
            .padding()
            .background(.role(.surface))
        }
    }
}

#Preview("Subagent list · c unfolded, scrolls past 220 pt") { SubagentScrollPreview() }
#Preview("Subagent list · c unfolded, scrolls past 220 pt, dark") { SubagentScrollPreview().preferredColorScheme(.dark) }
#endif
