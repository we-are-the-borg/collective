import AppKit
import CollectiveKit
import SwiftUI

/// Shell command lines in a recessed box, one row per line, each with its own Copy button.
/// One Copy per line, because a tool's session takes pasted text as one input. Shared by the
/// setup window and a source's update group.
///
/// The setup card's terminal box adds what a run needs: a slot in front of each
/// command, a tag and output after or under it, and a footer with the button. The card's
/// session box has none of these.
struct CommandBox: View {
    typealias Slot = SetupCardModel.CommandsBox.Line.Slot
    typealias Footer = SetupCardModel.CommandsBox.Footer

    struct Entry {
        let command: String
        var slot: Slot?
        var tag: LocalizedStringResource?
        var output: String?
    }

    let entries: [Entry]
    let footer: Footer?
    let onFooterButton: (Footer.Button.Kind) -> Void
    let onToggleOutput: () -> Void
    /// The slot's step numbers: 11.5 in the setup window, 11 in a source's update group.
    var numberSize: CGFloat = 11.5

    /// How long a Copy button reads "Copied"; the popover's warning block too.
    static let copiedDuration: Duration = .milliseconds(1400)

    /// Copy-only lines.
    init(lines: [String]) {
        entries = lines.map { Entry(command: $0) }
        footer = nil
        onFooterButton = { _ in }
        onToggleOutput = {}
    }

    /// The setup card's terminal box.
    init(
        box: SetupCardModel.CommandsBox,
        numberSize: CGFloat = 11.5,
        onFooterButton: @escaping (Footer.Button.Kind) -> Void,
        onToggleOutput: @escaping () -> Void
    ) {
        self.numberSize = numberSize
        entries = box.lines.map { Entry(command: $0.command, slot: $0.slot, tag: $0.tag, output: $0.output) }
        footer = box.footer
        self.onFooterButton = onFooterButton
        self.onToggleOutput = onToggleOutput
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Keyed by text, not position, so a changed `lines` never carries "Copied" to another command.
            ForEach(entries, id: \.command) { entry in
                CommandRow(entry: entry, numberSize: numberSize)
            }
            if let footer {
                CommandBoxFooter(footer: footer, onButton: onFooterButton, onToggleOutput: onToggleOutput)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 8))
        .rowBox()
    }
}

extension CommandBox.Entry {
    init(command: String) {
        self.init(command: command, slot: nil, tag: nil, output: nil)
    }
}

/// One command with its own Copy button and its own "Copied" state.
private struct CommandRow: View {
    let entry: CommandBox.Entry
    let numberSize: CGFloat

    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    /// Slot column (14) and the gap after it (8): the output lines up with the command.
    private static let outputIndent: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let slot = entry.slot {
                    CommandSlot(slot: slot, numberSize: numberSize)
                        .frame(width: 14, height: 16)
                }
                Text(entry.command)
                    .font(.plexMono(11.5))
                    .plexLineHeight(16, size: 11.5, mono: true)
                    // A line the run skips reads as done (the marketplace is already there).
                    .foregroundStyle(.role(entry.tag == nil ? .text : .textMuted))
                    // Every line stays visible: a long command wraps onto several lines, and a multi-line Text
                    // reports a one-line minimum height, so a content-sized window (setup) truncated with "…".
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let tag = entry.tag {
                    Text(tag)
                        .font(.plexSans(11.5))
                        .foregroundStyle(.role(.textMuted))
                        .fixedSize()
                }
                CopyButton(command: entry.command, copied: copied, action: performCopy)
            }
            .frame(minHeight: 22)
            if let output = entry.output {
                CommandOutput(text: output)
                    .padding(.leading, Self.outputIndent)
                    .padding(.top, 2)
                    .padding(.bottom, 4)
            }
        }
        .onDisappear { resetTask?.cancel() }
    }

    private func performCopy() {
        copyToPasteboard(entry.command)
        copied = true
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: CommandBox.copiedDuration)
            if !Task.isCancelled { copied = false }
        }
    }
}

/// A line's output, open under it: Plex Mono 11/15 in `--text` on its own sunken box, wrapping anywhere.
private struct CommandOutput: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.plexMono(11))
            .plexLineHeight(15, size: 11, mono: true)
            .foregroundStyle(.role(.text))
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
            .rowBox()
    }
}

/// Copy, 20 high with 0/7 insets in a 1 px `--border-control` frame; after a click "Copied"
/// with Lucide `check` in `--success`, as in the popover's warning block.
private struct CopyButton: View {
    let command: String
    let copied: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if copied {
                    LucideImage(.check, size: 11).foregroundStyle(.role(.success))
                    Text("Copied", bundle: .module)
                } else {
                    Text("Copy", bundle: .module)
                }
            }
            .font(.plexSans(11.5))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .frame(height: 20)
        }
        .buttonStyle(.popoverBordered)
        .accessibilityLabel(Text("Copy \(command)", bundle: .module))
        .accessibilityValue(copied ? Text("Copied", bundle: .module) : Text(verbatim: ""))
        .fixedSize()
    }
}
