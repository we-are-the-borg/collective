import CollectiveKit
import SwiftUI

/// The column in front of a command of the setup card's terminal box: its
/// place in the run, then its state while and after the run. No
/// spinner: the running line carries a working session's halo.
struct CommandSlot: View {
    let slot: SetupCardModel.CommandsBox.Line.Slot
    var numberSize: CGFloat = 11.5

    var body: some View {
        // One element per slot whatever draws it: the forms hide themselves
        // from VoiceOver, so the element is a container around them.
        mark
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(isStep ? .isStaticText : .isImage)
    }

    @ViewBuilder private var mark: some View {
        switch slot {
        case .number(let number):
            // `--text-muted`, not `--text-subtle`: on `--surface-sunken` that stays under 4.5:1 in light schemes.
            Text(verbatim: "\(number)")
                .font(.plexMono(numberSize))
                .foregroundStyle(.role(.textMuted))
        case .done:
            StatusShapeView(.check, role: .success)
        case .running:
            StatusShapeView(.haloDot(bright: true), role: .info)
        case .todo:
            StatusShapeView(.ring, role: .textSubtle)
        case .failed:
            LucideImage(.circleX, size: 12)
                .foregroundStyle(.role(.danger))
        }
    }

    /// The design shows the number as plain readable text, so VoiceOver reads it as the step.
    private var isStep: Bool {
        if case .number = slot { true } else { false }
    }

    private var label: Text {
        switch slot {
        case .number(let number): Text("Step \(String(number))", bundle: .module)
        case .done: Text("Done", bundle: .module)
        case .running: Text("Running", bundle: .module)
        case .todo: Text("Not run yet", bundle: .module)
        case .failed: Text("Failed", bundle: .module)
        }
    }
}
