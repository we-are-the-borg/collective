/// An sRGB color with alpha, 0–255 per channel: what a theme role resolves to (Unimatrix Zero's
/// `theme::Color`). Named apart from SwiftUI's `Color`, which every view imports beside the kit.
public struct ThemeColor: Sendable, Hashable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// Opaque color from `0xRRGGBB`.
    public static func rgb(_ hex: UInt32) -> ThemeColor {
        rgba(hex, alpha: 255)
    }

    /// Color from `0xRRGGBB` with an alpha of 0–255.
    public static func rgba(_ hex: UInt32, alpha: UInt8) -> ThemeColor {
        ThemeColor(
            r: UInt8(truncatingIfNeeded: hex >> 16),
            g: UInt8(truncatingIfNeeded: hex >> 8),
            b: UInt8(truncatingIfNeeded: hex),
            a: alpha
        )
    }
}

/// The system appearance that selects the default theme.
public enum ThemeAppearance: Sendable {
    case light
    case dark
}
