import Foundation

// Pure color math for deriving theme roles, a port of Unimatrix Zero's `theme/color.rs`
// (commit 43f1307). Every result is quantized to 8-bit sRGB, as abnahme's hex-in, hex-out
// helpers were. The roles must match Unimatrix's reference file byte for byte, so constants,
// the order of floating-point operations and the libm functions are the Rust ones.

/// An opaque 8-bit sRGB color, as schemes store them. Every function here returns one, so
/// results compare exactly, as abnahme's hex strings did.
struct SRGB: Sendable, Hashable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Color from `0xRRGGBB`.
    init(_ hex: UInt32) {
        self.init(
            r: UInt8(truncatingIfNeeded: hex >> 16),
            g: UInt8(truncatingIfNeeded: hex >> 8),
            b: UInt8(truncatingIfNeeded: hex)
        )
    }

    /// Reads `#rrggbb` in either case; shorthand `#rgb` is rejected like anything else.
    /// Checked on UTF-8 bytes, as Rust does, so no Unicode equivalence lets anything else in.
    static func parse(_ input: String) throws(ParseColorError) -> SRGB {
        let bytes = Array(input.utf8)
        guard bytes.count == 7, bytes[0] == UInt8(ascii: "#") else {
            throw ParseColorError(input: input)
        }
        var hex: UInt32 = 0
        for byte in bytes.dropFirst() {
            guard let digit = hexDigit(byte) else { throw ParseColorError(input: input) }
            hex = hex << 4 | digit
        }
        return SRGB(hex)
    }

    private static func hexDigit(_ byte: UInt8) -> UInt32? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt32(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): UInt32(byte - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F"): UInt32(byte - UInt8(ascii: "A") + 10)
        default: nil
        }
    }
}

/// Input that is not `#rrggbb`.
struct ParseColorError: Error, Equatable {
    var input: String
}

extension SRGB: CustomStringConvertible {
    var description: String {
        String(format: "#%02x%02x%02x", r, g, b)
    }
}

extension ThemeColor {
    /// The opaque role color.
    init(_ color: SRGB) {
        self.init(r: color.r, g: color.g, b: color.b, a: 255)
    }
}

extension SRGB {
    /// The role color with `alpha` in 0–1, clamped, for backdrops over a surface.
    func withAlpha(_ alpha: Double) -> ThemeColor {
        ThemeColor(r: r, g: g, b: b, a: toByte(alpha))
    }
}

/// sRGB channels as floats, gamma-encoded or linear light depending on the step; nominally
/// 0–1, outside it before gamut mapping.
struct Channels: Equatable {
    var r: Double
    var g: Double
    var b: Double
}

extension Channels {
    init(_ color: SRGB) {
        self.init(r: Double(color.r) / 255.0, g: Double(color.g) / 255.0, b: Double(color.b) / 255.0)
    }
}

/// Gamma-encoded sRGB channel to linear light.
private func toLinear(_ channel: Double) -> Double {
    if channel <= 0.04045 {
        channel / 12.92
    } else {
        pow((channel + 0.055) / 1.055, 2.4)
    }
}

/// WCAG 2.x relative luminance, 0 (black) to 1 (white).
func relativeLuminance(_ color: SRGB) -> Double {
    let channels = Channels(color)
    return 0.2126 * toLinear(channels.r) + 0.7152 * toLinear(channels.g) + 0.0722 * toLinear(channels.b)
}

/// WCAG 2.x contrast ratio, 1 to 21; the order of the arguments does not matter.
func contrastRatio(_ a: SRGB, _ b: SRGB) -> Double {
    let la = relativeLuminance(a)
    let lb = relativeLuminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

/// Channels clamped to 0–1 and rounded to bytes, as abnahme's `toHex` wrote them.
func quantize(_ channels: Channels) -> SRGB {
    SRGB(r: toByte(channels.r), g: toByte(channels.g), b: toByte(channels.b))
}

/// A value in 0–1, clamped, as 0–255. Clamped first, so `rounded()` (half away from zero)
/// rounds half up like JavaScript's `Math.round`.
func toByte(_ value: Double) -> UInt8 {
    // Rust's `clamp`, which passes NaN through …
    let clamped = value < 0.0 ? 0.0 : value > 1.0 ? 1.0 : value
    let scaled = (clamped * 255.0).rounded()
    // … and its saturating `as u8`, which turns NaN into 0 where Swift's conversion would trap.
    return scaled.isNaN ? 0 : UInt8(scaled)
}

/// A color in OKLCH: lightness `l` 0–1, chroma `c` ≥ 0, hue `h` in degrees 0–360 (0 for
/// greys). Hue-preserving shifts of lightness or chroma happen here.
struct OKLCH: Equatable {
    var l: Double
    var c: Double
    var h: Double
}

/// A color in OKLab (Björn Ottosson), where straight-line mixing looks even.
struct OKLab: Equatable {
    var l: Double
    var a: Double
    var b: Double
}

/// Chroma below this counts as grey; its hue is meaningless and set to 0.
private let achromatic = 1e-4

/// Tolerance for linear channels when deciding whether a color is in sRGB.
private let gamutEpsilon = 1e-6

/// Bisection steps when bringing chroma into sRGB; halves the chroma range each time.
private let gamutSteps = 32

private func toGamma(_ channel: Double) -> Double {
    if channel <= 0.0031308 {
        channel * 12.92
    } else {
        1.055 * pow(channel, 1.0 / 2.4) - 0.055
    }
}

private func rgbToOKLab(_ color: SRGB) -> OKLab {
    let channels = Channels(color)
    let (lr, lg, lb) = (toLinear(channels.r), toLinear(channels.g), toLinear(channels.b))
    let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
    let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
    let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
    return OKLab(
        l: 0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
        a: 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
        b: 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s
    )
}

/// Rust's `powi(3)`, which LLVM expands to `x * (x * x)`; the same value as `x * x * x`.
private func cubed(_ x: Double) -> Double {
    x * x * x
}

/// OKLab to linear-light sRGB; channels may fall outside 0–1.
private func oklabToLinear(_ color: OKLab) -> Channels {
    let lightness = color.l, a = color.a, b = color.b
    let l = cubed(lightness + 0.3963377774 * a + 0.2158037573 * b)
    let m = cubed(lightness - 0.1055613458 * a - 0.0638541728 * b)
    let s = cubed(lightness - 0.0894841775 * a - 1.291485548 * b)
    return Channels(
        r: 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        g: -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        b: -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s
    )
}

private func linearToRGB(_ channels: Channels) -> SRGB {
    quantize(Channels(r: toGamma(channels.r), g: toGamma(channels.g), b: toGamma(channels.b)))
}

private func inGamut(_ channels: Channels) -> Bool {
    [channels.r, channels.g, channels.b].allSatisfy { (-gamutEpsilon...1.0 + gamutEpsilon).contains($0) }
}

private func lchToLab(_ color: OKLCH) -> OKLab {
    let radians = color.h * Double.pi / 180.0
    return OKLab(l: color.l, a: color.c * cos(radians), b: color.c * sin(radians))
}

/// The color in OKLCH, via OKLab.
func toOKLCH(_ color: SRGB) -> OKLCH {
    let lab = rgbToOKLab(color)
    let c = hypot(lab.a, lab.b)
    if c < achromatic {
        return OKLCH(l: lab.l, c: 0.0, h: 0.0)
    }
    let h = atan2(lab.b, lab.a) * 180.0 / Double.pi
    return OKLCH(l: lab.l, c: c, h: h < 0.0 ? h + 360.0 : h)
}

/// The OKLCH color in sRGB. A color outside sRGB keeps its lightness and hue and loses chroma
/// until it fits; lightness beyond 0–1 gives black or white.
func fromOKLCH(_ color: OKLCH) -> SRGB {
    let l = color.l, c = color.c, h = color.h
    if l <= 0.0 {
        return SRGB(0x000000)
    }
    if l >= 1.0 {
        return SRGB(0xffffff)
    }
    let exact = oklabToLinear(lchToLab(color))
    if inGamut(exact) {
        return linearToRGB(exact)
    }
    var (low, high) = (0.0, c)
    for _ in 0..<gamutSteps {
        let mid = (low + high) / 2.0
        if inGamut(oklabToLinear(lchToLab(OKLCH(l: l, c: mid, h: h)))) {
            low = mid
        } else {
            high = mid
        }
    }
    return linearToRGB(oklabToLinear(lchToLab(OKLCH(l: l, c: low, h: h))))
}

/// Shortest angle between two hues in degrees, 0–180.
func hueDistance(_ a: Double, _ b: Double) -> Double {
    // Rust's `%` on floats is C's `fmod`, as is `truncatingRemainder`.
    let d = abs(a - b).truncatingRemainder(dividingBy: 360.0)
    return d > 180.0 ? 360.0 - d : d
}

/// How far apart two colors look: their straight-line distance in OKLab (ΔE OK), lightness and
/// both color axes alike, 0 for the same color, about 1 from black to white.
func deltaE(_ a: SRGB, _ b: SRGB) -> Double {
    let (a, b) = (rgbToOKLab(a), rgbToOKLab(b))
    // Nested as Rust's `(dl).hypot(da).hypot(db)`, so the bits match.
    return hypot(hypot(a.l - b.l, a.a - b.a), a.b - b.b)
}

/// Mixes two colors in OKLab; `t` is the share of `b` (0 gives `a`, 1 gives `b`).
func mix(_ a: SRGB, _ b: SRGB, _ t: Double) -> SRGB {
    let from = rgbToOKLab(a)
    let to = rgbToOKLab(b)
    func lerp(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
    return linearToRGB(oklabToLinear(OKLab(l: lerp(from.l, to.l), a: lerp(from.a, to.a), b: lerp(from.b, to.b))))
}

/// `top` with its alpha laid over the opaque `bottom`, as the view shows it.
/// Blends gamma-encoded sRGB per channel by `a/255`, as CSS and the design canvas composite.
func composite(_ top: ThemeColor, _ bottom: SRGB) -> SRGB {
    let alpha = Double(top.a) / 255.0
    let upper = Channels(SRGB(r: top.r, g: top.g, b: top.b))
    let lower = Channels(bottom)
    func blend(_ t: Double, _ b: Double) -> Double { alpha * t + (1.0 - alpha) * b }
    return quantize(Channels(r: blend(upper.r, lower.r), g: blend(upper.g, lower.g), b: blend(upper.b, lower.b)))
}

/// Lightness step for `ensureContrast`; at most 1 / step tries.
private let lightnessStep = 0.01

/// Returns `fg` unchanged if it reaches `min` contrast against `bg`. Otherwise shifts its OKLCH
/// lightness step by step away from `bg` (darker on a light background, lighter on a dark one),
/// keeping hue and chroma as far as sRGB allows, and returns the first color that reaches `min`.
/// If none does, returns the one with the highest contrast.
func ensureContrast(_ fg: SRGB, _ bg: SRGB, _ min: Double) -> SRGB {
    shiftLightness(fg, { contrastRatio($0, bg) }, min)
}

/// `ensureContrast` against several backdrops at once, each with its own minimum, for text that
/// sits on each of them: what counts is the backdrop that falls shortest of its minimum, and the
/// direction is the one where black or white clears all of them better.
func ensureContrastOn(_ fg: SRGB, _ backdrops: [(bg: SRGB, min: Double)]) -> SRGB {
    // Folded from infinity in backdrop order, like Rust's `fold(f64::INFINITY, f64::min)`.
    let score = { (color: SRGB) in
        backdrops.reduce(Double.infinity) { Swift.min($0, contrastRatio(color, $1.bg) / $1.min) }
    }
    return shiftLightness(fg, score, 1.0)
}

/// The search behind `ensureContrast`: `score` is the contrast, `target` the score to reach.
private func shiftLightness(_ fg: SRGB, _ score: (SRGB) -> Double, _ target: Double) -> SRGB {
    var bestScore = score(fg)
    if bestScore >= target {
        return fg
    }
    let darken = score(SRGB(0x000000)) >= score(SRGB(0xffffff))
    let (end, direction) = darken ? (0.0, -1.0) : (1.0, 1.0)
    let start = toOKLCH(fg)
    let (l, c, h) = (start.l, start.c, start.h)
    let steps = UInt32((abs(end - l) / lightnessStep).rounded(.up))
    var best = fg
    // `stride`, not `1...steps`: like Rust's `1..=steps` it is empty for 0, where a closed range would trap.
    for step in stride(from: UInt32(1), through: steps, by: 1) {
        // The last step lands exactly on the end, so black or white is always tried.
        let lightness = step == steps ? end : l + direction * Double(step) * lightnessStep
        let candidate = fromOKLCH(OKLCH(l: lightness, c: c, h: h))
        let candidateScore = score(candidate)
        if candidateScore >= target {
            return candidate
        }
        if candidateScore > bestScore {
            best = candidate
            bestScore = candidateScore
        }
    }
    return best
}
