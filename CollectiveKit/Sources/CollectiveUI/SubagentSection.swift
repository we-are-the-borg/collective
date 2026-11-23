import CollectiveKit
import SwiftUI

/// "› Subagents 2 working · 1 needs you · 3 done" and, while open, the list
/// under it: the subagent part of every row, in place of the knob and "✓ n".
/// The list starts closed and opens by itself while a subagent waits for
/// permission or an answer; the user's own choice holds while the app runs.
struct SubagentSection: View {
    let toggle: SubagentToggle
    let onToggle: () -> Void
    let onToggleFold: (SubagentFoldID) -> Void
    let onArchive: (ArchiveUndo.Kind) -> Void
    let onUndo: (ArchiveUndo.ID) -> Void
    let onUndoHover: (ArchiveUndo.ID, Bool) -> Void

    init(
        toggle: SubagentToggle,
        onToggle: @escaping () -> Void,
        onToggleFold: @escaping (SubagentFoldID) -> Void,
        onArchive: @escaping (ArchiveUndo.Kind) -> Void,
        onUndo: @escaping (ArchiveUndo.ID) -> Void,
        onUndoHover: @escaping (ArchiveUndo.ID, Bool) -> Void
    ) {
        self.toggle = toggle
        self.onToggle = onToggle
        self.onToggleFold = onToggleFold
        self.onArchive = onArchive
        self.onUndo = onUndo
        self.onUndoHover = onUndoHover
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SubagentToggleView(toggle: toggle, action: onToggle)
            if toggle.isOpen {
                SubagentListView(
                    list: toggle.list, onToggleFold: onToggleFold,
                    onArchive: onArchive, onUndo: onUndo, onUndoHover: onUndoHover
                )
                .padding(.top, -SubagentListMetrics.pullUp)
                .padding(.leading, SubagentListMetrics.listInset)
            }
        }
    }
}

/// The toggle line: one button over the full width without a fill, 12 pt.
private struct SubagentToggleView: View {
    let toggle: SubagentToggle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                SubagentDisclosureChevron(isOpen: toggle.isOpen)
                    .foregroundStyle(.role(toggle.titleRole))
                Text(toggle.title)
                    .foregroundStyle(.role(toggle.titleRole))
                ForEach(Array(toggle.parts.enumerated()), id: \.offset) { _, part in
                    if part.isSeparatedBefore {
                        Text(verbatim: "·").foregroundStyle(.role(toggle.separatorRole))
                    }
                    Text(part.text).foregroundStyle(.role(part.role))
                }
            }
            .font(.plexSans(12))
            .monospacedDigit()
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: SubagentListMetrics.toggleHeight, maxHeight: SubagentListMetrics.toggleHeight, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.subagentLine)
        .accessibilityLabel(Text(toggle.accessibilityLabel))
        .accessibilityValue(toggle.isOpen ? Text("expanded", bundle: .module) : Text("collapsed", bundle: .module))
    }
}

/// Lucide `chevron-right` 11 pt, turned down while open; the caller colors it.
struct SubagentDisclosureChevron: View {
    let isOpen: Bool

    var body: some View {
        LucideImage(.chevronRight, size: 11)
            .rotationEffect(.degrees(isOpen ? 90 : 0))
            .accessibilityHidden(true)
    }
}

/// The toggle line and the fold row: square like the rows, no fill at rest,
/// hover `--surface-hover`, pressed `--surface-active`. The keyboard
/// focus is the rows' inner 2 px `--focus-ring` frame.
struct SubagentLineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SubagentLineButtonBody(configuration: configuration)
    }
}

extension ButtonStyle where Self == SubagentLineButtonStyle {
    static var subagentLine: SubagentLineButtonStyle { SubagentLineButtonStyle() }
}

/// A view rather than the style's body, so it can hold the hover and read the focus.
private struct SubagentLineButtonBody: View {
    @Environment(\.showsButtonFocusRing) private var showsFocusRing
    @State private var isHovered = false
    let configuration: ButtonStyleConfiguration

    var body: some View {
        configuration.label
            .background {
                if let fill { Rectangle().fill(.role(fill)) }
            }
            .overlay {
                if showsFocusRing {
                    Rectangle().strokeBorder(.role(.focusRing), lineWidth: 2).allowsHitTesting(false)
                }
            }
            .focusEffectDisabled()
            .onHover { isHovered = $0 }
    }

    private var fill: ThemeRole? {
        if configuration.isPressed { return .surfaceActive }
        return isHovered ? .surfaceHover : nil
    }
}

#if DEBUG
/// The section as a row embeds it: closed, and open with every state of a
/// subagent row, the fold row and an undo row.
private struct SubagentSectionPreviews: View {
    private static let sections: [(String, SessionItem)] = [
        ("closed", PreviewData.subagentBoard(.a, open: false)),
        ("working", PreviewData.subagentBoard(.a)),
        ("needs permission, has a question", PreviewData.subagentBoard(.d)),
        ("fold, working", PreviewData.subagentBoard(.c)),
        ("fold unfolded, scrolls past 220 pt", PreviewData.subagentBoard(.c, opensFold: true)),
        ("awaiting designation", PreviewData.subagentBoard(.e)),
        ("lost contact", PreviewData.subagentLostContact),
        ("undo row", PreviewData.subagentUndo),
        ("only done", PreviewData.subagentBoard(.f, open: false)),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Self.sections, id: \.0) { name, item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: name).font(.plexMono(11.5)).foregroundStyle(.role(.textSubtle))
                        if let toggle = item.subagentToggle {
                            SubagentSection(
                                toggle: toggle, onToggle: {}, onToggleFold: { _ in },
                                onArchive: { _ in }, onUndo: { _ in }, onUndoHover: { _, _ in }
                            )
                        }
                    }
                }
            }
            .frame(width: 350)
            .padding(20)
        }
        .frame(height: 1_000)
        .background(.role(.surface))
    }
}

#Preview("Subagent section · closed, open in every state, fold, undo") { SubagentSectionPreviews() }
#Preview("Subagent section · closed, open in every state, fold, undo, dark") {
    SubagentSectionPreviews().preferredColorScheme(.dark)
}
#endif
