import Foundation

/// The form in front of a source's status: in the settings sidebar, the
/// source's pane and the setup window's section header, on the design's
/// 12-point grid.
public enum SourceStatusShape: Sendable, Equatable {
    /// Filled: connected.
    case dot
    /// A ring with a small dot inside: enabled, waiting for its first session.
    case ringWithDot
    /// Filled: disabled, or an update the app needs.
    case triangle
    /// Lucide `circle-arrow-up`: an update on offer.
    case circleArrowUp
    /// Lucide `circle-x`: a run that failed.
    case circleX
    /// A dot in a halo instead of a spinner: an update under way.
    case haloDot
    /// Nothing to claim: not set up, not found, or not checked yet.
    case hollowRing
}

/// A source's status form with the role it and the status word are drawn in.
public struct SourceStatusMark: Sendable, Equatable {
    public let shape: SourceStatusShape
    public let role: ThemeRole

    public init(shape: SourceStatusShape, role: ThemeRole) {
        self.shape = shape
        self.role = role
    }

    static let connected = SourceStatusMark(shape: .dot, role: .success)
    static let waiting = SourceStatusMark(shape: .ringWithDot, role: .info)
    static let warning = SourceStatusMark(shape: .triangle, role: .warning)
    static let updateAvailable = SourceStatusMark(shape: .circleArrowUp, role: .info)
    static let failed = SourceStatusMark(shape: .circleX, role: .danger)
    static let updating = SourceStatusMark(shape: .haloDot, role: .info)
    static let unknown = SourceStatusMark(shape: .hollowRing, role: .textSubtle)
}
