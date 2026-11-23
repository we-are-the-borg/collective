import Foundation

/// An installed app as the system knows it.
public struct TerminalApp: Sendable, Equatable {
    public let bundleID: String
    /// What the system calls the app, e.g. "Warp"; nil when it knows none.
    public let name: String?

    public init(bundleID: String, name: String?) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// Which app the system would bring to the front: a system boundary, so the
/// kit stays free of AppKit and tests decide what is installed.
public protocol TerminalApps: Sendable {
    /// The installed app with this bundle ID; nil if there is none.
    func app(bundleID: String) -> TerminalApp?
    /// The app that opens `url`; nil if none does.
    func app(opening url: URL) -> TerminalApp?
}

/// Resolves nothing, so nothing offers to show a terminal: for a model built
/// without the system, e.g. in a preview.
public struct NoTerminalApps: TerminalApps {
    public init() {}
    public func app(bundleID: String) -> TerminalApp? { nil }
    public func app(opening url: URL) -> TerminalApp? { nil }
}

/// "Show in <App>": brings the session's terminal to the front, only when
/// both the target and its app are known.
public struct TerminalAction: Sendable, Equatable {
    public let target: TerminalTarget
    /// The app that comes to the front; the view loads its icon from it.
    public let bundleID: String
    /// What the system calls the app; nil when it knows none, and the texts
    /// say "Terminal".
    public let appName: String?

    /// Nil without a target or without an installed app for it.
    public init?(session: Session, apps: some TerminalApps) {
        guard let target = session.terminalTarget else { return nil }
        let app: TerminalApp? = switch target {
        case let .url(_, bundleID?): apps.app(bundleID: bundleID)
        case let .url(url, nil): apps.app(opening: url)
        case let .app(bundleID): apps.app(bundleID: bundleID)
        case let .appHandling(url): apps.app(opening: url)
        }
        guard let app else { return nil }
        self.target = target
        bundleID = app.bundleID
        appName = app.name
    }

    /// Whether the session's own tab comes forward, not only its app.
    public var selectsTab: Bool {
        if case .url = target { true } else { false }
    }

    /// The jump button's VoiceOver label, the menu's text.
    public var title: LocalizedStringResource {
        appName.map { .kit("Show in %@", defaultValue: "Show in \($0)") }
            ?? .kit("Show Terminal", defaultValue: "Show Terminal")
    }

    /// The tooltip: the shortcut, or that only the app comes forward.
    public var help: LocalizedStringResource {
        guard let appName else { return .kit("Show Terminal ⌘↩", defaultValue: "Show Terminal ⌘↩") }
        return selectsTab
            ? .kit("Show in %@ ⌘↩", defaultValue: "Show in \(appName) ⌘↩")
            : .kit("Brings %@ to the front. It can’t select the session’s tab.",
                   defaultValue: "Brings \(appName) to the front. It can’t select the session’s tab.")
    }
}
