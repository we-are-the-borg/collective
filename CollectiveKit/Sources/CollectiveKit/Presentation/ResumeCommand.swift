import Foundation

/// How a tool takes up one of its sessions again in a terminal; the popover's
/// "Copy Resume Command" copies it. A value, not an adapter call: the adapters
/// belong to the spool reader, while the popover builds on the main actor.
public struct ResumeCommand: Sendable {
    private let words: @Sendable (_ sessionID: String) -> [String]

    /// - Parameter words: The command's words for a session ID, unquoted.
    public init(_ words: @escaping @Sendable (_ sessionID: String) -> [String]) {
        self.words = words
    }

    public func arguments(sessionID: String) -> [String] {
        words(sessionID)
    }

    /// The line to paste into a terminal: inside the session's folder when it
    /// is known, since a tool may find its sessions per project folder.
    public func commandLine(sessionID: String, cwd: String?) -> String {
        let command = arguments(sessionID: sessionID).map(ShellQuoting.quoted).joined(separator: " ")
        return cwd.map { "cd \(ShellQuoting.quoted($0)) && \(command)" } ?? command
    }
}
