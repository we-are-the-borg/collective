import Combine
import CollectiveKit
import SwiftUI

/// The popover's clock: builds its model at the current time and draws the
/// content from it, again whenever what the build reads changes and at the
/// moment the model says the clock alone changes it (`nextChange`), never
/// once a second. The times that count keep clocks of their own at the
/// leaves (`DurationClock`), so between those moments nothing of the popover
/// is built or compared.
public struct ModelClock<Model: TimedPresentation, Content: View>: View {
    private let build: (Date) -> Model
    private let content: (Model) -> Content
    @State private var turn = ClockTurn(turnedAt: Date())

    public init(build: @escaping (Date) -> Model, @ViewBuilder content: @escaping (Model) -> Content) {
        self.build = build
        self.content = content
    }

    public var body: some View {
        let now = Date()
        let model = build(now)
        let next = ClockTurn.wait(for: model.nextChange, builtAt: now)
        content(model)
            // A new turn restarts the wait even when the model still names the
            // same moment, so a wake a little early waits again.
            .task(id: Wait(next: next, after: turn.turnedAt)) {
                guard let next else { return }
                do { try await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow))) } catch { return }
                turnNow()
            }
            // Set by hand, the clock moves the moments waited for, and the
            // time zone the times the views write ("at 14:02"): turn now and
            // wait anew.
            .onReceive(clockChanges) { _ in turnNow() }
    }

    private func turnNow() {
        turn = ClockTurn(turnedAt: Date())
    }

    private var clockChanges: some Publisher<Notification, Never> {
        Publishers.Merge(
            NotificationCenter.default.publisher(for: .NSSystemClockDidChange),
            NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)
        )
        // Posted on whichever thread noticed the change.
        .receive(on: DispatchQueue.main)
    }

    private struct Wait: Equatable {
        let next: Date?
        let after: Date
    }
}

/// When the popover's clock last turned, and what follows from it for the next
/// build: the rules of `ModelClock` apart from the view.
struct ClockTurn: Equatable {
    let turnedAt: Date

    /// The moment to wait for of a model's `nextChange`: nil for one not
    /// after the build. That one is in the model already; waiting for it
    /// would turn the clock over and over (`TimedPresentation`).
    static func wait(for nextChange: Date?, builtAt now: Date) -> Date? {
        guard let nextChange, nextChange > now else { return nil }
        return nextChange
    }
}
