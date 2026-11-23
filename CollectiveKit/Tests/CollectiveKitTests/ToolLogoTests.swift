import AppKit
import Testing
@testable import CollectiveKit

/// Each adapter names its Lobe Icons logo, and the kit bundles it.
@Suite struct ToolLogoTests {
    @Test func theAdaptersNameTheirLogos() {
        // Through the existentials, so a property that only shadows the protocol default fails.
        let claude: any PushAdapter = ClaudeCodeAdapter()
        let codex: any PushAdapter = CodexAdapter()
        let status: any PullSource = ClaudeCodeSessionStatusSource(chosenRoot: nil)
        #expect(claude.logoName == "claude-code")
        #expect(codex.logoName == "codex")
        #expect(status.logoName == "claude-code")
    }

    @Test(arguments: ["claude-code", "codex"])
    func eachLogoLoadsAsATemplate(name: String) throws {
        let image = try #require(ToolLogo.bundle.image(forResource: name))
        #expect(image.isTemplate)
        #expect(image.size.width > 0)
    }

    /// CoreSVG (asset catalog, `NSImage`) rejects arc flags glued to each other or to the
    /// next number (`a6 6 0 013 -.4`, valid per the SVG grammar) and draws a blob.
    @Test(arguments: ["claude-code/claude", "codex/codex"])
    func arcFlagsAreSeparateNumbers(path: String) throws {
        let parts = path.split(separator: "/").map(String.init)
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CollectiveKit/Resources/SourceIcons.xcassets/\(parts[0]).imageset/\(parts[1]).svg")
        let svg = try String(contentsOf: url, encoding: .utf8)
        let paths = svg.matches(of: /\sd="([^"]*)"/).map { String($0.1) }
        #expect(!paths.isEmpty)
        for d in paths {
            #expect(Self.packedArcFlags(in: d).isEmpty, "packed arc flags near: \(Self.packedArcFlags(in: d))")
        }
    }

    @Test func theCheckSeesPackedFlags() {
        #expect(!Self.packedArcFlags(in: "M0 0a6.105 6.105 0 013.046-.415z").isEmpty)
        #expect(!Self.packedArcFlags(in: "M0 0a.117.117 0 00.107.029z").isEmpty)
        #expect(Self.packedArcFlags(in: "M0 0a6.105 6.105 0 0 1 3.046-.415z").isEmpty)
    }

    /// Returns snippets of arcs whose flag is not set off by a separator on both sides.
    static func packedArcFlags(in d: String) -> [String] {
        let chars = Array(d)
        let isSeparator: (Character) -> Bool = { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" }
        var bad: [String] = []
        var i = 0
        var inArc = false
        var param = 0
        func skipSeparators() { while i < chars.count, isSeparator(chars[i]) { i += 1 } }
        func skipNumber() {
            if i < chars.count, chars[i] == "+" || chars[i] == "-" { i += 1 }
            var seenDot = false
            while i < chars.count {
                if chars[i].isNumber { i += 1 } else if chars[i] == ".", !seenDot { seenDot = true; i += 1 } else { break }
            }
        }
        while i < chars.count {
            let c = chars[i]
            if c.isLetter {
                inArc = c == "A" || c == "a"
                param = 0
                i += 1
                continue
            }
            skipSeparators()
            guard i < chars.count, !chars[i].isLetter else { continue }
            if inArc, param % 7 == 3 || param % 7 == 4 {
                let start = i
                i += 1
                if i < chars.count, !isSeparator(chars[i]) { bad.append(String(chars[max(0, start - 8)..<min(chars.count, start + 8)])) }
            } else {
                skipNumber()
            }
            param += 1
        }
        return bad
    }
}
