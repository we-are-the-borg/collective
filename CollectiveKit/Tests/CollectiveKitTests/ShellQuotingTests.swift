import Testing
@testable import CollectiveKit

@Suite struct ShellQuotingTests {
    @Test func aPlainPathStaysAsItIs() {
        #expect(ShellQuoting.quoted("/Users/user/Developer/git/my-app_2.0+x@host:1,2") == "/Users/user/Developer/git/my-app_2.0+x@host:1,2")
    }

    @Test func spacesGetSingleQuotes() {
        #expect(ShellQuoting.quoted("/Users/user/My Projects/app") == "'/Users/user/My Projects/app'")
    }

    @Test func anEmbeddedQuoteIsEscapedOutsideTheQuotes() {
        #expect(ShellQuoting.quoted("/tmp/it's here") == #"'/tmp/it'\''s here'"#)
        #expect(ShellQuoting.quoted("/tmp/'") == #"'/tmp/'\'''"#)
    }

    @Test(arguments: ["/tmp/$HOME", "/tmp/a!b", "/tmp/*", "/tmp/a&b", "/tmp/a;b", "/tmp/(x)", "/tmp/a\"b", "/tmp/a\\b", "/tmp/a`b`", "/tmp/a#b", "/tmp/a\tb", "/tmp/a\nb"])
    func shellSpecialCharactersAreQuoted(path: String) {
        #expect(ShellQuoting.quoted(path) == "'\(path)'")
    }

    /// Letters of any script are plain to a shell; the quotes would only be noise.
    @Test func unicodeLettersStayUnquoted() {
        #expect(ShellQuoting.quoted("/Users/user/Prüfung/Projekte/日本語") == "/Users/user/Prüfung/Projekte/日本語")
    }

    /// Finder hands out decomposed names ("e" and a combining accent).
    @Test func decomposedLettersStayUnquoted() {
        #expect(ShellQuoting.quoted("/tmp/cafe\u{0301}") == "/tmp/cafe\u{0301}")
    }

    @Test func unicodeSpacesAndSymbolsAreQuoted() {
        #expect(ShellQuoting.quoted("/tmp/a\u{00A0}b") == "'/tmp/a\u{00A0}b'")
        #expect(ShellQuoting.quoted("/tmp/😀") == "'/tmp/😀'")
    }

    /// A leading tilde would expand to the home folder.
    @Test func aLeadingTildeIsQuoted() {
        #expect(ShellQuoting.quoted("~backup/x") == "'~backup/x'")
        #expect(ShellQuoting.quoted("/tmp/~backup") == "/tmp/~backup")
    }

    @Test func anEmptyPathIsAnEmptyArgument() {
        #expect(ShellQuoting.quoted("") == "''")
    }
}
