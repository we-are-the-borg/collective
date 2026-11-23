import CollectiveKit
import SwiftUI

/// The popover's warning above the list: what is wrong, the commands that
/// fix it and the buttons to check again or set up. A section
/// over the full width on the row grid, no fill and no frame, closed by the
/// rows' 1 px `--border` line. Texts come from the model.
struct WarningBlockView: View {
    let warning: WarningBlock
    let onCheckAgain: () -> Void
    let onSetUp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RowMetrics.headGap) {
            HStack(spacing: RowMetrics.columnGap) {
                WarningTriangle()
                    .fill(.role(.warning))
                    .frame(width: RowMetrics.shapeSize, height: RowMetrics.shapeSize)
                    .frame(width: RowMetrics.shapeColumn)
                    .accessibilityHidden(true)
                Text(warning.title)
                    .font(.plexSans(13, weight: .medium))
                    .foregroundStyle(.role(.text))
                    .lineLimit(1)
            }
            .frame(height: RowMetrics.headHeight)
            VStack(alignment: .leading, spacing: RowMetrics.partGap) {
                Text(warning.text)
                    .foregroundStyle(.role(.textMuted))
                    .plexLineHeight(17, size: 12)
                    .fixedSize(horizontal: false, vertical: true)
                if !warning.commands.isEmpty { WarningCommandBox(lines: warning.commands) }
                Text(warning.hint)
                    .foregroundStyle(.role(.textSubtle))
                    .plexLineHeight(17, size: 12)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    button(Text("Check Again", bundle: .module), action: onCheckAgain)
                    if warning.showsSetUp { button(Text("Set Up…", bundle: .module), action: onSetUp) }
                }
            }
            .padding(.leading, RowMetrics.contentInset)
        }
        .font(.plexSans(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RowMetrics.padding)
        .overlay(alignment: .bottom) { Rectangle().fill(.role(.border)).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }

    /// Like "Show n idle": 24 high, 0/9 in.
    private func button(_ title: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            title
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .frame(height: 24)
        }
        .buttonStyle(.popoverBordered)
    }
}

/// The commands in the row boxes' style (`rowBox()`), one line each with its
/// own Copy, as the setup window's box: a tool's
/// session takes pasted text as one input. Inset as the permission box,
/// 4 between lines.
private struct WarningCommandBox: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                WarningCommandLine(command: line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 6, leading: 9, bottom: 7, trailing: 9))
        .rowBox()
    }
}

/// One command, Plex Mono 11.5/16 in `--text`, wrapping anywhere, then Copy;
/// after a click "Copied" with a check in `--success` for a moment.
private struct WarningCommandLine: View {
    let command: String

    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: command)
                .font(.plexMono(11.5))
                .plexLineHeight(16, size: 11.5, mono: true)
                .foregroundStyle(.role(.text))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: copy) {
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
        }
        .frame(minHeight: 22)
        .onDisappear { resetTask?.cancel() }
    }

    private func copy() {
        copyToPasteboard(command)
        copied = true
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: CommandBox.copiedDuration)
            if !Task.isCancelled { copied = false }
        }
    }
}
