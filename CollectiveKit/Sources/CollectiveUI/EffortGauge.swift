import CollectiveKit
import SwiftUI

/// How much the model thinks, as a capsule that fills from the bottom in
/// five steps. Next to the model name in a row's jump line and in the
/// setting's live preview.
struct EffortGauge: View {
    /// 1 to 5, as `EffortLabel.step`.
    let step: Int
    /// The fill, `EffortLabel.role`.
    let role: ThemeRole

    static let width: CGFloat = 4
    static let height: CGFloat = 11
    static let radius: CGFloat = 1
    /// Five steps fill the 11 pt.
    static let stepHeight: CGFloat = 2.2

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle().fill(.role(EffortLabel.emptyRole))
            Rectangle()
                .fill(.role(role))
                .frame(height: CGFloat(step) * Self.stepHeight)
        }
        .frame(width: Self.width, height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .circular))
        // A change of effort shows the new level at once.
        .animation(nil, value: step)
        // The model name's element reads the level.
        .accessibilityHidden(true)
    }
}
