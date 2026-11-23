import CollectiveKit
import SwiftUI

/// "Undo" as a link in `--accent`, underlined under the pointer;
/// every undo row's.
struct UndoLink: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text("Undo", bundle: .module)
                .underline(isHovered)
                .foregroundStyle(.role(.accent))
                .contentShape(.rect)
        }
        .buttonStyle(UndoLinkButtonStyle())
        .onHover { isHovered = $0 }
    }
}

/// Plain, but with the theme's focus ring instead of the system's; a style, so the
/// focus read is the button's own, gated like the other popover buttons
/// (`showsButtonFocusRing`).
private struct UndoLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        UndoLinkButtonBody(configuration: configuration)
    }
}

private struct UndoLinkButtonBody: View {
    @Environment(\.showsButtonFocusRing) private var showsFocusRing
    let configuration: ButtonStyleConfiguration

    var body: some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .overlay {
                if showsFocusRing {
                    RoundedRectangle(cornerRadius: 3, style: .circular)
                        .strokeBorder(.role(.focusRing), lineWidth: 2)
                        .padding(-3)
                        .allowsHitTesting(false)
                }
            }
            .focusEffectDisabled()
    }
}

/// What an archived session turns into for a few seconds, and the one row of
/// "Archive All Finished": "alpha archived", then Undo, one line as high as a
/// row's head with the row's insets and bottom line. The text starts
/// where the name did, as in the subagent list. The pointer on it holds the countdown.
struct UndoRowView: View {
    let row: UndoRow
    let onUndo: (ArchiveUndo.ID) -> Void
    let onHover: (ArchiveUndo.ID, Bool) -> Void

    var body: some View {
        HStack(spacing: RowMetrics.columnGap) {
            Text(row.text)
                .foregroundStyle(.role(.textMuted))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            UndoLink { onUndo(row.id) }
        }
        .font(.plexSans(12))
        .frame(height: RowMetrics.headHeight)
        .padding(.leading, RowMetrics.contentInset)
        .padding(RowMetrics.padding)
        .overlay(alignment: .bottom) { Rectangle().fill(.role(.border)).frame(height: 1) }
        .contentShape(.rect)
        .onHover { onHover(row.id, $0) }
    }
}

/// A context-menu entry with the archivebox symbol; `shortcut` shows ⌘⌫.
struct ArchiveMenuButton: View {
    let title: LocalizedStringKey
    var shortcut = false
    let action: () -> Void

    var body: some View {
        if shortcut {
            button.keyboardShortcut(.delete, modifiers: .command)
        } else {
            button
        }
    }

    private var button: some View {
        Button(action: action) {
            Label { Text(title, bundle: .module) } icon: { Image(systemName: "archivebox") }
        }
    }
}

/// ⌫ and ⌘⌫ archive the focused item.
extension View {
    func archivesOnDelete(_ archive: @escaping () -> Void) -> some View {
        onKeyPress(.delete) {
            archive()
            return .handled
        }
        .onKeyPress(.deleteForward) {
            archive()
            return .handled
        }
    }
}
