import Foundation

extension Session {
    /// What names the session to the user, on its card and in its
    /// notifications: the tool's name for it, else its project folder, else
    /// the start of its id.
    public var title: String {
        name
            ?? cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? String(key.sessionID.prefix(8))
    }
}
