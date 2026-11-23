import Foundation

/// The line under the version in About: a form, a status word in the form's
/// role and a detail in `textSubtle`, a second line after a failed `Check Now`,
/// and which button leads the row (`Check Now` or `Update…`).
public struct AppUpdateStatusLine: Sendable, Equatable {
    public let mark: SourceStatusMark
    /// In `mark.role`.
    public let status: LocalizedStringResource
    /// After the status, with its leading " · "; nil when there is none.
    public let detail: LocalizedStringResource?
    /// Under the line, only after a failed `Check Now`.
    public let explanation: LocalizedStringResource?
    public let button: Button

    public enum Button: Sendable, Equatable {
        /// `Check Now`, disabled while a check runs.
        case checkNow(enabled: Bool)
        /// `Update…`, which opens the updater's window.
        case update
    }

    /// - Parameters:
    ///   - checksAutomatically: The switch in General › Updates.
    ///   - pluginsChecking: The subspace lookup that `Check Now` starts with the app's runs;
    ///     the line reads as checking until both are done.
    ///   - now: Decides "today" and "yesterday" for the last check.
    ///   - timeZone: The time zone of those days and the time shown.
    @MainActor
    public init(_ state: AppUpdateState, checksAutomatically: Bool, pluginsChecking: Bool = false, now: Date,
                timeZone: TimeZone = .autoupdatingCurrent) {
        if state.checking != nil || pluginsChecking {
            self.init(mark: .unknown, status: .kit("Checking for updates…", defaultValue: "Checking for updates…"),
                      button: .checkNow(enabled: false))
        } else if state.failed {
            self.init(mark: .failed,
                      status: .kit("Couldn’t check for updates", defaultValue: "Couldn’t check for updates"),
                      explanation: .kit("GitHub didn’t answer. Check your connection, then try again.",
                                        defaultValue: "GitHub didn’t answer. Check your connection, then try again."),
                      button: .checkNow(enabled: true))
        } else if let latest = state.available {
            let installed = state.installed?.description ?? "?"
            self.init(mark: .updateAvailable,
                      status: .kit("%@ is available", defaultValue: "\(latest.description) is available"),
                      detail: .kit("· you have %@", defaultValue: "· you have \(installed)"),
                      button: .update)
        } else {
            let detail: LocalizedStringResource? = if !checksAutomatically {
                .kit("· automatic checks are off", defaultValue: "· automatic checks are off")
            } else if let lastCheck = state.lastCheck {
                Self.checked(lastCheck, now: now, timeZone: timeZone)
            } else {
                nil
            }
            self.init(mark: .connected, status: .kit("Up to date", defaultValue: "Up to date"), detail: detail,
                      button: .checkNow(enabled: true))
        }
    }

    private init(mark: SourceStatusMark, status: LocalizedStringResource, detail: LocalizedStringResource? = nil,
                 explanation: LocalizedStringResource? = nil, button: Button) {
        self.mark = mark
        self.status = status
        self.detail = detail
        self.explanation = explanation
        self.button = button
    }

    /// "· checked today at 14:02", "· checked yesterday at 9:15", else the day
    /// alone, with the year when it isn't this year's. A check in the future
    /// (a clock set back) reads as today.
    static func checked(_ date: Date, now: Date, timeZone: TimeZone) -> LocalizedStringResource {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let time = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now).map { calendar.isDate(date, inSameDayAs: $0) } ?? false
        if calendar.isDate(date, inSameDayAs: now) || date > now {
            return .kit("· checked today at %@", defaultValue: "· checked today at \(date, format: time)")
        }
        if yesterday {
            return .kit("· checked yesterday at %@", defaultValue: "· checked yesterday at \(date, format: time)")
        }
        var day = Date.FormatStyle(timeZone: timeZone).day().month(.abbreviated)
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { day = day.year() }
        return .kit("· checked on %@", defaultValue: "· checked on \(date, format: day)")
    }
}
