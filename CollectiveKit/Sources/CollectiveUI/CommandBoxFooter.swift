import AppKit
import CollectiveKit
import SwiftUI

/// The footer of the terminal box of a setup card or a source's update
/// group: what the button will do or is doing, a link to the source or
/// the changes, the output toggle and the button. No spinner: the running
/// line's halo carries the run.
struct CommandBoxFooter: View {
    typealias Footer = SetupCardModel.CommandsBox.Footer

    let footer: Footer
    let onButton: (Footer.Button.Kind) -> Void
    let onToggleOutput: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(.role(.border)).frame(height: 1)
            HStack(alignment: .center, spacing: 10) {
                paragraph
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let toggle = footer.outputToggle { OutputToggleButton(toggle: toggle, action: onToggleOutput) }
                if let button = footer.button {
                    Button(action: { onButton(button.kind) }) { Text(button.title) }
                        .buttonStyle(.settingsPrimary)
                        .fixedSize()
                        .disabled(!button.isEnabled)
                        .accessibilityLabel(Text(button.accessibilityLabel))
                }
            }
        }
    }

    /// The text and the link flow as one paragraph, so the link follows the
    /// last word. The link's words stay together; it wraps as a whole. A failed
    /// run's sentence stays `--danger` on the sunken box.
    private var paragraph: some View {
        var text = Text(footer.text)
            .foregroundStyle(.role(footer.isWarning ? .danger : .textMuted))
        if let link = footer.link {
            text = text + Text(verbatim: " ") + Text(Self.attributed(link))
        }
        return text
            .font(.plexSans(11.5))
            .plexLineHeight(16, size: 11.5)
            .tint(RoleStyle(.accent))
            .fixedSize(horizontal: false, vertical: true)
            // A run of a Text cannot carry its own label, so the link is also an action of the paragraph.
            .accessibilityAction(named: actionName) {
                if let url = footer.link?.url { NSWorkspace.shared.open(url) }
            }
    }

    private var actionName: Text {
        switch footer.link?.kind {
        case .changes: Text("subspace changes on GitHub", bundle: .module)
        case .source, nil: Text("subspace source code on GitHub", bundle: .module)
        }
    }

    private static func attributed(_ link: Footer.Link) -> AttributedString {
        nonBreakingLink(String(localized: link.title), to: link.url)
    }
}

/// A link run for a `Text` paragraph whose words stay on one line.
func nonBreakingLink(_ title: String, to url: URL) -> AttributedString {
    var text = AttributedString(title.replacingOccurrences(of: " ", with: "\u{00A0}"))
    text.link = url
    return text
}

/// Show Output / Hide Output: a link button in `--accent` with Lucide `chevron-right`, turned down while open.
private struct OutputToggleButton: View {
    let toggle: SetupCardModel.CommandsBox.Footer.OutputToggle
    let action: () -> Void

    private var showing: Bool { toggle == .showing }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                LucideImage(.chevronRight, size: 11)
                    .rotationEffect(.degrees(showing ? 90 : 0))
                if showing { Text("Hide Output", bundle: .module) } else { Text("Show Output", bundle: .module) }
            }
            .padding(.horizontal, 2)
            .frame(height: 20)
        }
        .buttonStyle(SettingsLinkStyle(size: 11.5))
        .fixedSize()
        .accessibilityValue(showing ? Text("expanded", bundle: .module) : Text("collapsed", bundle: .module))
    }
}
