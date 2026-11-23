import CollectiveKit
import SwiftUI

/// Draws its content again whenever a duration counted from one of `since`
/// reads differently (`DurationText.nextChange`): each second in its first
/// minute, then each minute. The leaves that write times keep this clock of
/// their own, so the views around them, the popover's whole model above all,
/// stay as they are from one second to the next. With nothing to count it
/// draws once. Always a `TimelineView`, so a count that starts or stops
/// keeps the content's identity.
struct DurationClock<Content: View>: View {
    @Environment(\.pinnedClock) private var pinnedClock
    private let since: [Date]
    private let content: (Date) -> Content

    init(since: Date?..., @ViewBuilder content: @escaping (Date) -> Content) {
        self.since = since.compactMap { $0 }
        self.content = content
    }

    var body: some View {
        if let pinnedClock {
            content(pinnedClock)
        } else {
            TimelineView(DurationSchedule(since: since)) { context in content(context.date) }
        }
    }
}

extension EnvironmentValues {
    /// Previews and snapshots set the moment their sample data was built at, so the
    /// times read as in the design instead of counting from the real clock.
    @Entry var pinnedClock: Date?
}

/// The moments a duration's text turns over, of every count at once.
struct DurationSchedule: TimelineSchedule {
    let since: [Date]

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(upcoming: startDate, since: since)
    }

    struct Entries: Sequence, IteratorProtocol {
        var upcoming: Date?
        let since: [Date]

        mutating func next() -> Date? {
            guard let current = upcoming else { return nil }
            upcoming = since.map { DurationText.nextChange(after: current, countingFrom: $0) }.min()
            return current
        }
    }
}

extension View {
    /// A context menu that names a time ("Last event 2 min ago"), kept
    /// current by a clock of its own: only the menu is written again as the
    /// time turns over, not the view it belongs to.
    func contextMenu<Menu: View>(counting since: Date?, @ViewBuilder menu: @escaping (Date) -> Menu) -> some View {
        modifier(CountingContextMenu(since: since, menu: menu))
    }

    /// VoiceOver's label and value when they name times, kept current as
    /// `contextMenu(counting:menu:)` is.
    func accessibilityLabel(counting since: Date?..., label: @escaping (Date) -> Text, value: ((Date) -> Text)? = nil) -> some View {
        modifier(CountingAccessibility(since: since.compactMap { $0 }, label: label, value: value))
    }
}

private struct CountingContextMenu<Menu: View>: ViewModifier {
    let since: Date?
    let menu: (Date) -> Menu

    func body(content: Content) -> some View {
        DurationClock(since: since) { now in content.contextMenu { menu(now) } }
    }
}

private struct CountingAccessibility: ViewModifier {
    let since: [Date]
    let label: (Date) -> Text
    let value: ((Date) -> Text)?

    func body(content: Content) -> some View {
        TimelineView(DurationSchedule(since: since)) { context in
            if let value {
                content.accessibilityLabel(label(context.date)).accessibilityValue(value(context.date))
            } else {
                content.accessibilityLabel(label(context.date))
            }
        }
    }
}
