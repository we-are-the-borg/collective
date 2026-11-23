import Foundation

/// A plain HTTP GET, so the release lookup is tested without the network.
public protocol HTTPGetting: Sendable {
    /// Throws only when no response arrived; any status code is a response.
    func get(_ url: URL, headers: [String: String]) async throws -> (status: Int, data: Data)
}

/// `URLSession` without cookies, cache or credentials: the lookup reads public
/// data and should leave nothing behind. A short timeout, because nobody waits
/// for the answer and a hanging lookup would only hold the next one back.
public struct URLSessionHTTPGetting: HTTPGetting {
    private let session: URLSession

    public init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
