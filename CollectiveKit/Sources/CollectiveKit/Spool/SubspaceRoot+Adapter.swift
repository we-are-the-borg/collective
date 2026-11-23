import Foundation
import SubspaceKit

public extension SubspaceRoot {
    /// The root `adapter`'s events and mapping come from. With no chosen folder
    /// this is the source's default, e.g. what a settings window marks "(default)".
    static func resolve(
        adapter: any PushAdapter,
        chosen: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        resolve(adapter.spoolRoot(environment: environment, home: home), chosen: chosen, environment: environment)
    }
}
