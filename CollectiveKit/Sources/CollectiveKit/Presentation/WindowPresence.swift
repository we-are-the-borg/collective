import Foundation

/// Which of the app's own windows are open, for the ones that make it a
/// regular app (Dock icon, ⌘Tab, menu bar) while they are: setup and settings,
/// so one that slips behind other windows stays reachable. Ids are the
/// scenes' ids; anything outside `counting`, the popover for one, is
/// ignored. A window is open or not, so a repeated open is not counted twice.
public struct WindowPresence: Sendable, Equatable {
    private let counted: Set<String>
    public private(set) var open: Set<String> = []

    public init(counting ids: Set<String>) {
        counted = ids
    }

    public mutating func opened(_ id: String) {
        if counted.contains(id) { open.insert(id) }
    }

    public mutating func closed(_ id: String) {
        open.remove(id)
    }

    /// The activation policy: `.regular` while true, `.accessory` otherwise.
    public var showsInDock: Bool { !open.isEmpty }
}
