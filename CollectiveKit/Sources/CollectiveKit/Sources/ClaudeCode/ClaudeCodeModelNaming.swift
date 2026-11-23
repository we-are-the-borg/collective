import Foundation

/// Claude Code model names ("claude-opus-5-5", "claude-3-5-sonnet-20241022",
/// alias "opus") as "Opus 5.5". Family names stay English, never localized.
///
/// Parsed by hand: every popover rebuild names each subagent, and compiling regular
/// expressions per call (they cannot be shared statically) cost a measurable share of the main thread.
public struct ClaudeCodeModelNaming: ModelNaming {
    public init() {}

    public func displayName(forModel model: String) -> String? {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count >= 3, parts[0].lowercased() == "claude" {
            if let label = Self.current(parts) ?? Self.old(parts) { return label }
        }
        // Alias resolved inside the tool: no version, borrowing one would be a guess.
        if Self.families.contains(name.lowercased()) {
            return Self.label(family: name[...], major: nil, minor: nil)
        }
        return PlainModelNaming().displayName(forModel: name)
    }

    private static let families = ["opus", "sonnet", "haiku"]

    // Whole-name match: anything after the date is a name the rules don't know, so it is shown
    // raw rather than guessed at.
    private static func current(_ parts: [Substring]) -> String? {
        guard parts.count <= 5, families.contains(parts[1].lowercased()), isNumber(parts[2]) else { return nil }
        let rest = parts.dropFirst(3)
        var minor: Substring?
        if let first = rest.first, isNumber(first, digits: 1...2) {
            minor = first
        }
        let date = rest.dropFirst(minor == nil ? 0 : 1)
        guard date.isEmpty || (date.count == 1 && isNumber(date[date.startIndex], digits: 8...8)) else { return nil }
        return label(family: parts[1], major: parts[2], minor: minor)
    }

    // Prefix match only: old names carry a date suffix after the family (and the family token
    // may be glued to it), which must not block the label.
    private static func old(_ parts: [Substring]) -> String? {
        guard isNumber(parts[1]) else { return nil }
        if let family = familyPrefix(parts[2]) {
            return label(family: family, major: parts[1], minor: nil)
        }
        if parts.count >= 4, isNumber(parts[2], digits: 1...1), let family = familyPrefix(parts[3]) {
            return label(family: family, major: parts[1], minor: parts[2])
        }
        return nil
    }

    private static func familyPrefix(_ part: Substring) -> Substring? {
        let lowered = part.lowercased()
        guard let family = families.first(where: { lowered.hasPrefix($0) }) else { return nil }
        return part.prefix(family.count)
    }

    /// ASCII digits only: no model name carries other scripts' digits.
    private static func isNumber(_ part: Substring, digits: ClosedRange<Int> = 1...Int.max) -> Bool {
        digits.contains(part.count) && part.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func label(family: Substring, major: Substring?, minor: Substring?) -> String {
        var result = family.capitalized
        if let major {
            result += " \(major)"
            if let minor { result += ".\(minor)" }
        }
        return result
    }
}
