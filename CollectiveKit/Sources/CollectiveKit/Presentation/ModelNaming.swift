import Foundation

/// Maps a raw model name of one source to the short name the popover shows;
/// nil when nothing should be shown.
public protocol ModelNaming: Sendable {
    func displayName(forModel model: String) -> String?
}

/// Default for sources without own rules: the trimmed name as delivered.
public struct PlainModelNaming: ModelNaming {
    public init() {}

    public func displayName(forModel model: String) -> String? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
