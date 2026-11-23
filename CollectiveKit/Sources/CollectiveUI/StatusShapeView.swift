import CollectiveKit
import SwiftUI

/// The form at the head of a row (`StatusShape`), drawn on the design's 12-unit grid at `size`
/// points: 12 in a session row, 10 in a subagent row. The halo reaches past the frame, as the
/// design's `overflow: visible` lets it.
public struct StatusShapeView: View {
    private let shape: StatusShape
    private let role: ThemeRole
    private let size: CGFloat

    public init(_ mark: StatusMark, size: CGFloat = 12) {
        self.init(mark.shape, role: mark.shapeRole, size: size)
    }

    public init(_ shape: StatusShape, role: ThemeRole, size: CGFloat = 12) {
        self.shape = shape
        self.role = role
        self.size = size
    }

    public var body: some View {
        let unit = size / 12
        ZStack {
            switch shape {
            case let .haloDot(bright):
                if bright {
                    // Stands still: the old pulse redrew the whole popover every frame.
                    Halo(role: role, unit: unit, radius: StatusShapeMetrics.brightHaloRadius, opacity: StatusShapeMetrics.brightHaloOpacity)
                    circle(radius: StatusShapeMetrics.dotRadius, unit: unit).fill(.role(role))
                } else {
                    Halo(role: role, unit: unit, radius: StatusShapeMetrics.haloRadius, opacity: StatusShapeMetrics.haloOpacity)
                    circle(radius: StatusShapeMetrics.dotRadius, unit: unit).fill(.role(role))
                }
            case .diamond:
                StatusDiamond().fill(.role(role))
            case .hollowHalo:
                Halo(role: role, unit: unit, radius: StatusShapeMetrics.haloRadius, opacity: StatusShapeMetrics.hollowHaloOpacity)
                circle(radius: StatusShapeMetrics.hollowRingRadius, unit: unit)
                    .stroke(.role(role), lineWidth: StatusShapeMetrics.lineWidth * unit)
            case .ring:
                circle(radius: StatusShapeMetrics.ringRadius, unit: unit)
                    .stroke(.role(role), lineWidth: StatusShapeMetrics.lineWidth * unit)
            case .dashedRing:
                circle(radius: StatusShapeMetrics.ringRadius, unit: unit)
                    .stroke(.role(role), style: StrokeStyle(
                        lineWidth: StatusShapeMetrics.lineWidth * unit,
                        dash: StatusShapeMetrics.ringDash.map { $0 * unit }
                    ))
            case .check:
                StatusCheck()
                    .stroke(.role(role), style: StrokeStyle(
                        lineWidth: StatusShapeMetrics.checkLineWidth * unit, lineCap: .round, lineJoin: .round
                    ))
            }
        }
        .frame(width: size, height: size)
        // The status word next to it says the same.
        .accessibilityHidden(true)
    }

    /// A circle of `radius` grid units around the center; strokes sit on its line, as in SVG.
    private func circle(radius: CGFloat, unit: CGFloat) -> some Shape {
        Circle().size(width: radius * 2 * unit, height: radius * 2 * unit)
            .offset(x: (6 - radius) * unit, y: (6 - radius) * unit)
    }
}

/// The design's numbers, in units of the 12 grid.
enum StatusShapeMetrics {
    static let dotRadius: CGFloat = 3.5
    /// The halo at rest: a subagent row.
    static let haloRadius: CGFloat = 5.75
    static let haloOpacity = 0.28
    static let hollowHaloOpacity = 0.22
    static let hollowRingRadius: CGFloat = 3
    static let ringRadius: CGFloat = 3.75
    static let lineWidth: CGFloat = 1.5
    static let checkLineWidth: CGFloat = 2
    /// The design draws no dashed ring; seven even dashes around the ring keep it closed-looking
    /// at 10 and 12 pt.
    static var ringDash: [CGFloat] {
        let period = 2 * .pi * ringRadius / 7
        return [period * 0.6, period * 0.4]
    }

    /// A working row's halo, also a background agent's, the setup window's running command line
    /// and a source's running update. It stands still: its pulse cost 40–50 % CPU with the
    /// popover open, because every frame redrew the popover's texts and symbols. These are
    /// the values Reduce Motion drew: brighter than a subagent row's still halo, so a working dot
    /// still reads as working. The dot stays at `dotRadius`.
    static let brightHaloRadius: CGFloat = 6.25
    static let brightHaloOpacity = 0.38
}

/// A filled circle of `radius` grid units at `opacity`, centred: the halo, and at full opacity
/// the dot.
private struct Halo: View {
    let role: ThemeRole
    let unit: CGFloat
    let radius: CGFloat
    let opacity: Double

    var body: some View {
        Circle()
            .fill(.role(role))
            .opacity(opacity)
            .frame(width: radius * 2 * unit, height: radius * 2 * unit)
    }
}

/// Points at 0.8 and 11.2 on the 12 grid.
private struct StatusDiamond: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = rect.width / 12
        var path = Path()
        path.move(to: CGPoint(x: 6 * unit, y: 0.8 * unit))
        path.addLine(to: CGPoint(x: 11.2 * unit, y: 6 * unit))
        path.addLine(to: CGPoint(x: 6 * unit, y: 11.2 * unit))
        path.addLine(to: CGPoint(x: 0.8 * unit, y: 6 * unit))
        path.closeSubpath()
        return path
    }
}

/// The design's `m2.2 6.4 2.5 2.5 5.1-5.6`; also the empty states' check.
struct StatusCheck: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = rect.width / 12
        var path = Path()
        path.move(to: CGPoint(x: 2.2 * unit, y: 6.4 * unit))
        path.addLine(to: CGPoint(x: 4.7 * unit, y: 8.9 * unit))
        path.addLine(to: CGPoint(x: 9.8 * unit, y: 3.3 * unit))
        return path
    }
}

/// The warning block's triangle, `M6 .9 11.4 10.8H.6z`, filled. No `StatusShape`: no row shows it.
struct WarningTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = rect.width / 12
        var path = Path()
        path.move(to: CGPoint(x: 6 * unit, y: 0.9 * unit))
        path.addLine(to: CGPoint(x: 11.4 * unit, y: 10.8 * unit))
        path.addLine(to: CGPoint(x: 0.6 * unit, y: 10.8 * unit))
        path.closeSubpath()
        return path
    }
}

#if DEBUG
private struct StatusShapePreviews: View {
    private static let marks: [(String, StatusShape, ThemeRole)] = [
        ("working", .haloDot(bright: true), .agentWorking),
        ("subagent working", .haloDot(bright: false), .agentWorking),
        ("needs you", .diamond, .agentWaiting),
        ("shell", .hollowHalo, .textMuted),
        ("idle", .ring, .agentIdle),
        ("done", .check, .agentDone),
        ("no clean exit", .dashedRing, .textSubtle),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.marks, id: \.0) { name, shape, role in
                HStack(spacing: 12) {
                    StatusShapeView(shape, role: role, size: 12).frame(width: 14)
                    StatusShapeView(shape, role: role, size: 10).frame(width: 14)
                    Text(verbatim: name).font(.plexSans(12)).foregroundStyle(.role(.text))
                }
            }
        }
        .padding(20)
        .background(.role(.surface))
    }
}

#Preview("Status shapes") { StatusShapePreviews() }
#Preview("Status shapes, dark") { StatusShapePreviews().preferredColorScheme(.dark) }
#endif
