import Foundation

/// An RFC 6901 JSON Pointer, as mapping documents use it to address a field.
public struct JSONPointer: Sendable, Equatable {
    /// The unescaped reference tokens; empty for the whole document.
    public let tokens: [String]

    /// Nil for a string that is not a pointer: anything non-empty must start with `/`.
    public init?(_ pointer: String) {
        // Split and unescape by code points, like apply.py; `String` would glue
        // a combining mark onto a preceding `/` or `~1` into one `Character`.
        let scalars = pointer.unicodeScalars
        if scalars.isEmpty {
            tokens = []
            return
        }
        guard scalars.first == "/" else { return nil }
        // `~1` before `~0`, so `~01` decodes to `~1` and not to `/`.
        tokens = Array(scalars.dropFirst()).split(separator: "/", omittingEmptySubsequences: false).map {
            String(String.UnicodeScalarView(Self.unescape(Self.unescape(Array($0), "1", as: "/"), "0", as: "~")))
        }
    }

    /// Replaces each `~<code>` with `replacement`, left to right like Python's `str.replace`.
    private static func unescape(_ scalars: [Unicode.Scalar], _ code: Unicode.Scalar, as replacement: Unicode.Scalar) -> [Unicode.Scalar] {
        var result: [Unicode.Scalar] = []
        var index = 0
        while index < scalars.count {
            if scalars[index] == "~", index + 1 < scalars.count, scalars[index + 1] == code {
                result.append(replacement)
                index += 2
            } else {
                result.append(scalars[index])
                index += 1
            }
        }
        return result
    }

    /// The value the pointer leads to, or nil if it leads nowhere. A key
    /// holding `null` exists and yields `.null`.
    public func resolve(in document: JSONValue) -> JSONValue? {
        var value = document
        for token in tokens {
            switch value {
            case let .object(object):
                guard let next = object[JSONKey(token)] else { return nil }
                value = next
            case let .array(array):
                // Plain decimal without leading zeros; `-` (past the end) never exists.
                // Differs from apply.py: only ASCII digits count, while its `str.isdigit`
                // also accepts other Unicode digits (`/٣` is index 3 there, nothing here;
                // `/²` raises in its `int()`). A token over 4300 digits also raises
                // there; here it leads nowhere.
                guard !token.isEmpty, token.allSatisfy({ $0.isASCII && $0.isNumber }),
                      token == "0" || !token.hasPrefix("0"),
                      let index = Int(token), index < array.count else { return nil }
                value = array[index]
            default:
                return nil
            }
        }
        return value
    }
}
