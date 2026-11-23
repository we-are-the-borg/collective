/// A strict release version, `X.Y.Z`: a released subspace plugin's, and the app's own when
/// the bundled release notes are bounded by it.
///
/// Parsing is strict on purpose: only a plain release may count as an update,
/// so a pre-release tag, a build suffix or a stray character reads as no
/// version rather than as a newer one.
public struct SubspaceVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// `nil` unless the text is exactly three dot-separated decimal numbers.
    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            // `Int(_:)` alone would accept a sign ("+1"); only ASCII digits are a version.
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    /// Numeric per part, so 1.10.0 is newer than 1.9.0 (a string compare would say otherwise).
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// The newest release among tag names of the form `<prefix>X.Y.Z`.
    ///
    /// One repo can carry tags for several plugins, so only the given prefix
    /// counts; the prefix is a parameter because each adapter knows its own.
    /// Pre-release and malformed tags are skipped instead of failing the lookup.
    public static func latest(in tags: some Sequence<String>, prefix: String) -> SubspaceVersion? {
        tags.compactMap { tag in
            tag.hasPrefix(prefix) ? SubspaceVersion(String(tag.dropFirst(prefix.count))) : nil
        }.max()
    }
}
