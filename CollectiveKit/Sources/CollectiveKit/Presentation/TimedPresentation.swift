import Foundation

/// A popover model that changes by the clock only at known moments. Its
/// counting times are the views' (`SessionItem.timeText(at:)` and the like),
/// so the owner builds it again on a change of the state and at
/// `nextChange`, not every second.
public protocol TimedPresentation: Equatable {
    /// When a model built later would differ without any event; nil while nothing waits.
    /// Always after the moment it was built for. The owner neither waits nor
    /// builds for one that is not: that change is in the model already, and
    /// a model naming its own moment would otherwise keep it building.
    var nextChange: Date? { get }
}

extension PopoverModel: TimedPresentation {}
