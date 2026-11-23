import Testing
@testable import SubspaceKit

/// The rewritten text, or nil when `JSONReader` would leave the input alone.
private func rewritten(_ text: String) -> String? {
    let input = Array(text.utf8)
    let output = input.withUnsafeBytes { JSONReader.replacingLoneSurrogates(in: $0) }
    guard let output else { return nil }
    // Same length, so an error offset from the second read fits the input.
    #expect(output.count == input.count)
    return String(decoding: output, as: UTF8.self)
}

@Suite struct LoneSurrogateRewriteTests {
    @Test func loneHalvesBecomeReplacementCharacterEscapes() {
        #expect(rewritten(#""\ud83d""#) == #""\ufffd""#)
        #expect(rewritten(#""\uD83D""#) == #""\ufffd""#)
        #expect(rewritten(#""\ude00""#) == #""\ufffd""#)
    }

    @Test func loneHalvesAtStartEndAndSideBySide() {
        #expect(rewritten(#"\ud83d"x""#) == #"\ufffd"x""#)
        #expect(rewritten(#""x\ud83d"#) == #""x\ufffd"#)
        #expect(rewritten(#""\ude00\ud83d""#) == #""\ufffd\ufffd""#)
        #expect(rewritten(#""\ud83d\ud83d""#) == #""\ufffd\ufffd""#)
    }

    @Test func pairsStayUntouched() {
        #expect(rewritten(#""\ud83d\ude00""#) == nil)
        #expect(rewritten(#""\uD83D\uDE00 \udbff\udfff""#) == nil)
        #expect(rewritten(#""\ud83d\ud83d\ude00""#) == #""\ufffd\ud83d\ude00""#)
        #expect(rewritten(#""\ud83d\ude00\ude00""#) == #""\ud83d\ude00\ufffd""#)
    }

    @Test func escapedBackslashIsNotTheStartOfAnEscape() {
        #expect(rewritten(#""\\ud83d""#) == nil)
        #expect(rewritten(#""\\\ud83d""#) == #""\\\ufffd""#)
        #expect(rewritten(#""\"\ud83d""#) == #""\"\ufffd""#)
    }

    @Test func keysAreRewrittenToo() {
        #expect(rewritten(#"{"\ud83d": "\ude00"}"#) == #"{"\ufffd": "\ufffd"}"#)
    }

    /// The second read still rejects what follows the replaced half.
    @Test func highHalfBeforeAnInvalidEscapeIsReplacedAlone() {
        #expect(rewritten(#""\ud83d\uzzzz""#) == #""\ufffd\uzzzz""#)
        #expect(rewritten(#""\ud83d\u0041""#) == #""\ufffd\u0041""#)
    }

    @Test func inputWithoutLoneHalvesIsLeftAlone() {
        #expect(rewritten("") == nil)
        #expect(rewritten("[1,]") == nil)
        #expect(rewritten(#""a\n\u0041\u00e9\uFFFF""#) == nil)
        #expect(rewritten(#""\ud8"#) == nil)
        #expect(rewritten(#""\"#) == nil)
    }
}
