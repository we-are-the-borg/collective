import CollectiveKit
import SwiftUI

/// The model's name with its tooltip and, when known, its effort gauge 6 to
/// its right, vertically centred: the end of a row's jump line. Font and
/// color come from the line.
struct ModelText: View {
    let model: ModelLabel

    var body: some View {
        if let effort = model.effort {
            HStack(spacing: 6) {
                text
                EffortGauge(step: effort.step, role: effort.role)
                    .fixedSize()
            }
            // Name and gauge are one hover area and one element.
            .contentShape(Rectangle())
            .help(tooltip)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(model.accessibilityLabel))
        } else {
            text
                .help(tooltip)
        }
    }

    @ViewBuilder
    private var text: some View {
        let label = Text(verbatim: model.name).lineLimit(1)
        if model.isRawName {
            // Raw names have no fixed form, so the width is capped.
            WidthCap(maxWidth: 120) { label.truncationMode(.middle) }
        } else {
            label.fixedSize()
        }
    }

    /// Line 1 is the name as the source writes it, the rest say where it comes from and the effort.
    private var tooltip: String {
        ([model.rawName] + model.helpLines.map { String(localized: $0) }).joined(separator: "\n")
    }
}

/// Offers its content at most `maxWidth` and takes the content's size, so a
/// short name stays as narrow as its text; `frame(maxWidth:)` would grow to the cap.
struct WidthCap: Layout {
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(capped(proposal)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: capped(proposal))
    }

    private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: min(proposal.width ?? maxWidth, maxWidth), height: proposal.height)
    }
}
