// Syntax roles, a port of Unimatrix Zero's `theme/syntax.rs` (commit 5175da8; there
// `docs/theme-tokens.md` "Syntax roles"): base16 slots applied as the scheme fills them. Its
// capture table is not ported, nothing here highlights code yet.

/// What a highlighted span is colored as; a span without one is drawn in `text`.
enum SyntaxRole: CaseIterable, Sendable {
    case comment
    case variable
    case constant
    case type
    case string
    case special
    case function
    case keyword
    case embedded

    /// The slot the role takes its color from, per the base16 styling guidelines.
    var slot: PaletteKey {
        switch self {
        case .comment: .base03
        case .variable: .base08
        case .constant: .base09
        case .type: .base0A
        case .string: .base0B
        case .special: .base0C
        case .function: .base0D
        case .keyword: .base0E
        case .embedded: .base0F
        }
    }

    /// The contract role, e.g. `syntax-comment`.
    var role: ThemeRole {
        switch self {
        case .comment: .syntaxComment
        case .variable: .syntaxVariable
        case .constant: .syntaxConstant
        case .type: .syntaxType
        case .string: .syntaxString
        case .special: .syntaxSpecial
        case .function: .syntaxFunction
        case .keyword: .syntaxKeyword
        case .embedded: .syntaxEmbedded
        }
    }
}

extension ThemeRoles {
    /// The color of a highlighted span's role.
    func syntax(_ role: SyntaxRole) -> ThemeColor {
        self[role.role]
    }
}
