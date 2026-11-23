import CollectiveKit
import SwiftUI

/// The form in front of a source's status (`SourceStatusShape`): in the settings sidebar, the
/// source's pane and the setup window. Own paths on the design's 12-unit grid at `size` points;
/// the update arrow and the failure cross are Lucide, at 13 on that grid, and reach a little past
/// the frame like the design's.
public struct SourceStatusShapeView: View {
    private let shape: SourceStatusShape
    private let role: ThemeRole
    private let size: CGFloat

    public init(_ mark: SourceStatusMark, size: CGFloat = 12) {
        self.init(mark.shape, role: mark.role, size: size)
    }

    public init(_ shape: SourceStatusShape, role: ThemeRole, size: CGFloat = 12) {
        self.shape = shape
        self.role = role
        self.size = size
    }

    public var body: some View {
        let unit = size / 12
        ZStack {
            switch shape {
            case .dot:
                circle(radius: SourceStatusShapeMetrics.dotRadius, unit: unit).fill(.role(role))
            case .ringWithDot:
                circle(radius: SourceStatusShapeMetrics.waitingRingRadius, unit: unit)
                    .stroke(.role(role), lineWidth: SourceStatusShapeMetrics.lineWidth * unit)
                circle(radius: SourceStatusShapeMetrics.waitingDotRadius, unit: unit).fill(.role(role))
            case .triangle:
                WarningTriangle().fill(.role(role))
            case .hollowRing:
                circle(radius: SourceStatusShapeMetrics.hollowRingRadius, unit: unit)
                    .stroke(.role(role), lineWidth: SourceStatusShapeMetrics.lineWidth * unit)
            case .haloDot:
                // As the design draws it; the setup window's running line has the brighter working halo.
                Circle()
                    .fill(.role(role))
                    .opacity(StatusShapeMetrics.haloOpacity)
                    .frame(width: StatusShapeMetrics.haloRadius * 2 * unit, height: StatusShapeMetrics.haloRadius * 2 * unit)
                circle(radius: SourceStatusShapeMetrics.dotRadius, unit: unit).fill(.role(role))
            case .circleArrowUp:
                LucideImage(.circleArrowUp, size: SourceStatusShapeMetrics.iconSize * unit).foregroundStyle(.role(role))
            case .circleX:
                LucideImage(.circleX, size: SourceStatusShapeMetrics.iconSize * unit).foregroundStyle(.role(role))
            }
        }
        .frame(width: size, height: size)
        // The status word or the row's label says the same.
        .accessibilityHidden(true)
    }

    /// A circle of `radius` grid units around the center; strokes sit on its line, as in SVG.
    private func circle(radius: CGFloat, unit: CGFloat) -> some Shape {
        Circle().size(width: radius * 2 * unit, height: radius * 2 * unit)
            .offset(x: (6 - radius) * unit, y: (6 - radius) * unit)
    }
}

/// The design's numbers, in units of the 12 grid.
enum SourceStatusShapeMetrics {
    static let dotRadius: CGFloat = 3.5
    static let waitingRingRadius: CGFloat = 4.25
    static let waitingDotRadius: CGFloat = 1.5
    static let hollowRingRadius: CGFloat = 3.75
    static let lineWidth: CGFloat = 1.5
    /// Lucide's arrow and cross are drawn at 13 pt next to the 12 pt forms.
    static let iconSize: CGFloat = 13
}

#if DEBUG
private struct SourceStatusShapePreviews: View {
    private static let marks: [(String, SourceStatusShape, ThemeRole)] = [
        ("Connected", .dot, .success),
        ("Waiting for a session", .ringWithDot, .info),
        ("Disabled", .triangle, .warning),
        ("Update available", .circleArrowUp, .info),
        ("Update failed", .circleX, .danger),
        ("Updating", .haloDot, .info),
        ("Not set up", .hollowRing, .textSubtle),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.marks, id: \.0) { name, shape, role in
                HStack(spacing: 8) {
                    SourceStatusShapeView(shape, role: role).frame(width: 16, height: 16)
                    Text(verbatim: name).font(.plexSans(13)).foregroundStyle(.role(role))
                }
            }
        }
        .padding(20)
        .background(.role(.surface))
    }
}

#Preview("Source status shapes") { SourceStatusShapePreviews() }
#Preview("Source status shapes, dark") { SourceStatusShapePreviews().preferredColorScheme(.dark) }
#endif
