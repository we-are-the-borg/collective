import Foundation

/// Elapsed time as the popover writes it: "5 s", "4 min", "1 h 12 min".
/// Each unit is a catalog key, so a translation can change the units; the
/// shape stays the design's rather than `Duration.formatted`'s "1 hr 12 min".
public enum DurationText {
    /// Rounds down, so a runtime never shows a unit it hasn't reached; negative
    /// intervals (clock skew between event and now) read as "0 s".
    public static func format(_ interval: TimeInterval) -> LocalizedStringResource {
        let seconds = max(0, Int(interval.rounded(.down)))
        if seconds < 60 { return .kit("%lld s", defaultValue: "\(seconds) s") }
        let minutes = seconds / 60
        if minutes < 60 { return .kit("%lld min", defaultValue: "\(minutes) min") }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0
            ? .kit("%lld h", defaultValue: "\(hours) h")
            : .kit("%lld h %lld min", defaultValue: "\(hours) h \(rest) min")
    }

    /// When `format` of the time since `start` next reads differently: each
    /// second in the first minute, then each minute. A millisecond past the
    /// turn, so the subtraction that writes the text never rounds below it.
    /// The leaves that write such times wake only then.
    public static func nextChange(after now: Date, countingFrom start: Date) -> Date {
        let elapsed = max(0, now.timeIntervalSince(start))
        let step: TimeInterval = elapsed < 59 ? 1 : 60
        return start.addingTimeInterval(((elapsed / step).rounded(.down) + 1) * step + 0.001)
    }
}
