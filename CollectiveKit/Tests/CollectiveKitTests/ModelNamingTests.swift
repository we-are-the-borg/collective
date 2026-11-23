import Foundation
import Testing
@testable import CollectiveKit

@Suite("ModelNaming")
struct ModelNamingTests {
    @Test("Claude Code display names", arguments: [
        ("claude-opus-5-5", "Opus 5.5"),
        ("claude-sonnet-5-5", "Sonnet 5.5"),
        ("claude-haiku-4-5-20251001", "Haiku 4.5"),
        ("claude-opus-5", "Opus 5"),
        ("claude-3-5-sonnet-20241022", "Sonnet 3.5"),
        ("claude-3-opus-20240229", "Opus 3"),
        ("opus", "Opus"),
        ("Sonnet", "Sonnet"),
        ("HAIKU", "Haiku"),
        ("CLAUDE-OPUS-5-5", "Opus 5.5"),
        ("  claude-opus-5-5\n", "Opus 5.5"),
        ("gpt-5-codex", "gpt-5-codex"),
        (" gpt-5-codex ", "gpt-5-codex"),
        ("claude-opus-5-5-extra", "claude-opus-5-5-extra"),
        ("claude-opus-5-20251001", "Opus 5"),
        ("claude-opus-5-5-20251001", "Opus 5.5"),
        ("claude-opus-5-123", "claude-opus-5-123"),
        ("claude-opus-5-5-2025100", "claude-opus-5-5-2025100"),
        ("claude-opus", "claude-opus"),
        ("claude-opus-05", "Opus 05"),
        ("claude-3-opus", "Opus 3"),
        ("claude-3-5-sonnetx", "Sonnet 3.5"),
        ("claude-3-55-sonnet", "claude-3-55-sonnet"),
        ("claude--opus", "claude--opus"),
        ("Claude-Opus-5-5", "Opus 5.5"),
    ])
    func claudeCode(raw: String, shown: String) {
        #expect(ClaudeCodeModelNaming().displayName(forModel: raw) == shown)
    }

    @Test("Claude Code naming matches the regex rules over a generated corpus")
    func claudeCodeMatchesRegexOracle() {
        let heads = ["claude", "Claude", "opus", "SONNET", "x"]
        let tails = ["opus", "Opus", "SONNET", "haiku", "sonnetx", "3", "5", "05", "123", "2025100", "20251001", "x", ""]
        // Five-part names (the dated current scheme) from a narrower set, to stay well under a second.
        let longTails = ["opus", "haiku", "3", "5", "123", "20251001", "2025100", "x", ""]
        var corpus: [String] = ["", " ", "\n", "opus", "Haiku", "sonnetx"]
        func build(_ parts: [String], depth: Int) {
            corpus.append(parts.joined(separator: "-"))
            guard depth > 0 else { return }
            for part in tails { build(parts + [part], depth: depth - 1) }
        }
        for head in heads { build([head], depth: 3) }
        for a in longTails { for b in longTails { for c in longTails { for d in longTails {
            corpus.append(["claude", a, b, c, d].joined(separator: "-"))
        } } } }
        // Six and seven parts (trailing junk after the old-scheme prefix or the dated current
        // scheme) from targeted bases: the full product of these lengths dominated the runtime.
        let bases = [
            "claude-opus-5-5-20251001", "claude-opus-5-20251001", "claude-SONNET-5-05-20251001",
            "claude-3-5-sonnetx-20241022", "claude-3-5-sonnetx", "claude-3-opus-20240229",
            "claude-3-05-sonnet-x", "Claude-Opus-5-5", "claude-opus-5-5-2025100", "claude-opus-5-123456789", "claude-opus-5-5-123456789",
        ]
        let trailers = ["x", "5", "20251001", "opus"]
        for base in bases {
            corpus.append(base)
            for t in trailers {
                corpus.append("\(base)-\(t)")
                for u in trailers { corpus.append("\(base)-\(t)-\(u)") }
            }
        }
        corpus += corpus.filter { $0.hasPrefix("claude-") }.prefix(300).flatMap { [" \($0)", "\($0)\n", "\t\($0) "] }

        let naming = ClaudeCodeModelNaming()
        let oracle = RegexModelNaming()
        let mismatches = corpus.filter { naming.displayName(forModel: $0) != oracle.displayName(forModel: $0) }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(10))")
    }

    @Test("Claude Code: empty names show nothing", arguments: ["", "   ", "\n"])
    func claudeCodeEmpty(raw: String) {
        #expect(ClaudeCodeModelNaming().displayName(forModel: raw) == nil)
    }

    @Test("Plain naming trims and keeps the name", arguments: [
        ("gpt-5-codex", "gpt-5-codex"),
        (" x ", "x"),
        ("claude-opus-5-5", "claude-opus-5-5"),
    ])
    func plain(raw: String, shown: String) {
        #expect(PlainModelNaming().displayName(forModel: raw) == shown)
    }

    @Test("Plain naming: empty is nil")
    func plainEmpty() {
        #expect(PlainModelNaming().displayName(forModel: "") == nil)
        #expect(PlainModelNaming().displayName(forModel: " \n") == nil)
    }
}

/// The regex rules `ClaudeCodeModelNaming` followed before it parsed by hand, kept as the
/// oracle for the corpus test. The corpus holds ASCII digits only: `\d` also matches other
/// decimal digits, which the parser rejects on purpose because no real model name has them.
private struct RegexModelNaming {
    let current = #/^claude-(opus|sonnet|haiku)-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?$/#.ignoresCase()
    let old = #/^claude-(\d+)(?:-(\d))?-(opus|sonnet|haiku)/#.ignoresCase()
    let alias = #/^(opus|sonnet|haiku)$/#.ignoresCase()

    func displayName(forModel model: String) -> String? {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = try? current.wholeMatch(in: name) { return Self.label(m.1, m.2, m.3) }
        if let m = try? old.firstMatch(in: name) { return Self.label(m.3, m.1, m.2) }
        if let m = try? alias.wholeMatch(in: name) { return Self.label(m.1, nil, nil) }
        return PlainModelNaming().displayName(forModel: name)
    }

    private static func label(_ family: Substring, _ major: Substring?, _ minor: Substring?) -> String {
        var result = family.capitalized
        if let major {
            result += " \(major)"
            if let minor { result += ".\(minor)" }
        }
        return result
    }
}
