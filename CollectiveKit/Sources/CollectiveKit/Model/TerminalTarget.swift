import Foundation

/// The environment variables a session's terminal identifies itself by, keyed
/// by name, as the source passes them on (subspace contract §4, "Terminal
/// identifiers"). They name the terminal, not the agent tool, so the core may
/// read them; whose terminal they are is the source's to say
/// (`AgentEvent.Kind.terminalReported`).
public struct TerminalIdentifiers: Sendable, Equatable {
    public var variables: [String: String]

    public init(_ variables: [String: String]) {
        self.variables = variables
    }

    /// Where to bring the terminal to the front: Warp's tab by its focus URL,
    /// else the app that started the shell. The focus URL is not in Warp's
    /// documented URI scheme, so only its captured shape counts. A host's
    /// identifiers name the host's tab, never the session's, so they only
    /// tell the app.
    func target(_ ownership: TerminalOwnership) -> TerminalTarget? {
        let bundleID = variables["__CFBundleIdentifier"].flatMap { $0.isEmpty ? nil : $0 }
        let focus = variables["WARP_FOCUS_URL"].flatMap { focus in
            focus.wholeMatch(of: /warp:\/\/session\/[0-9a-fA-F]{32}/) != nil ? URL(string: focus) : nil
        }
        switch ownership {
        case .session:
            if let focus { return .url(focus, bundleID: bundleID) }
            return bundleID.map { .app(bundleID: $0) }
        case .host:
            if let bundleID { return .app(bundleID: bundleID) }
            return focus.map { .appHandling($0) }
        case .unusable:
            return nil
        }
    }
}

/// Whose terminal the identifiers of a session's process are, as its source
/// knows.
public enum TerminalOwnership: Sendable, Equatable {
    /// The session's own: its tab may come to the front.
    case session
    /// A process's that hosts the session, e.g. a daemon's: they name the
    /// app, but the tab is the host's, so only the app may come forward.
    case host
    /// Not to be used: the source knows they are no help, or can't tell
    /// anymore. Also how a source takes back what it reported.
    case unusable
}

/// How to bring a session's terminal to the front.
public enum TerminalTarget: Sendable, Equatable {
    /// A URL that opens the session's own tab or pane; `bundleID` is the app
    /// that handles it, if known.
    case url(URL, bundleID: String?)
    /// Only the app is known, not the tab: bring the app to the front.
    case app(bundleID: String)
    /// Only the app that handles this URL is known: bring it to the front,
    /// but never open the URL, which leads to another tab than the session's.
    case appHandling(URL)
}
