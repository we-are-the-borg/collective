import Foundation

/// A word as a shell takes it, for pasting into a terminal: the folder and
/// the command words of a copied resume command.
public enum ShellQuoting {
    /// The word unchanged if a shell reads it as one word, else in single
    /// quotes: inside them nothing is special but the quote itself, which
    /// closes them, goes in escaped and opens them again (`'\''`). Letters and
    /// digits of any script are plain; a leading `~` would expand to the home
    /// folder, so it is not.
    public static func quoted(_ word: String) -> String {
        let isPlain = !word.isEmpty && !word.hasPrefix("~") && word.allSatisfy { $0.isLetter || $0.isNumber || Self.punctuation.contains($0) }
        return isPlain ? word : singleQuoted(word)
    }

    /// The word in single quotes whether it needs them or not, escaped as
    /// `quoted(_:)` describes.
    public static func singleQuoted(_ word: String) -> String {
        "'" + word.replacing("'", with: #"'\''"#) + "'"
    }

    private static let punctuation: Set<Character> = ["/", ".", "_", "-", "+", "@", ":", ",", "~"]
}
