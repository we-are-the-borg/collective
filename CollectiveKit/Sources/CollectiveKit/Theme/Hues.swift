// Picks the seven tones the roles need from a scheme's accents, a port of Unimatrix Zero's
// `theme/hues.rs` (commit 43f1307). Chosen by hue, not by slot: schemes fill base08–base0F as
// syntax roles, so the slot is only a preference.

/// A tone the roles need; `allCases` keeps the reference order (red to violet).
enum Hue: CaseIterable, Sendable {
    case red, orange, yellow, green, cyan, blue, violet

    /// Target hue in OKLCH degrees, near the hue of the pure sRGB tone (orange 53, green 143,
    /// cyan 195). Red sits at 15, below pure red's 29, so the pink-leaning reds of pastel schemes
    /// still count while a burnt orange around 43 does not; yellow at 90 spans amber through
    /// pure yellow (110); blue at 255 and violet at 305 split the gap between blue and magenta.
    var target: Double {
        switch self {
        case .red: 15.0
        case .orange: 55.0
        case .yellow: 90.0
        case .green: 145.0
        case .cyan: 195.0
        case .blue: 255.0
        case .violet: 305.0
        }
    }

    /// The slots base16/base24 intend for the tone, first one preferred.
    var usualPlaces: [PaletteKey] {
        switch self {
        case .red: [.base08, .base12]
        case .orange: [.base09]
        case .yellow: [.base0A, .base13]
        case .green: [.base0B, .base14]
        case .cyan: [.base0C, .base15]
        case .blue: [.base0D, .base16]
        case .violet: [.base0E, .base17]
        }
    }
}

/// How far in degrees a hue may lie from its target and still count.
/// Half the 40° between red and orange, the closest pair, so a color between them does not take
/// the usual place of the wrong one.
private let hueTolerance = 20.0

/// Below this OKLCH chroma a color reads as grey and cannot stand for a tone.
private let minChroma = 0.05

/// The accent colors of base16/base24; base00–base07 and base10/base11 are greys and
/// backgrounds.
private let candidates: [PaletteKey] = [
    .base08, .base09, .base0A, .base0B, .base0C, .base0D, .base0E, .base0F,
    .base12, .base13, .base14, .base15, .base16, .base17,
]

/// Where a picked hue came from.
enum HueSource: Sendable, Equatable {
    /// A palette slot, taken as is.
    case slot(PaletteKey)
    /// Orange mixed from the picked red and yellow.
    case mixed
}

/// A picked hue with its source, for the reference file the port is tested against.
struct PickedHue: Sendable, Equatable {
    var color: SRGB
    var source: HueSource
}

/// The least OKLab distance (ΔE OK) between two roles that must read as different states: the
/// surface step in lightness, which sets panels clearly apart, and below the closest pair a
/// bundled scheme draws from two different slots (Kanagawa Dragon's green and aqua, 0.037).
let minDistinctDeltaE = 0.03

/// The seven hues of a scheme as `pickHues` picks them.
struct PickedHues: Sendable, Equatable {
    var red, orange, yellow, green, cyan, blue, violet: PickedHue

    subscript(hue: Hue) -> PickedHue {
        switch hue {
        case .red: red
        case .orange: orange
        case .yellow: yellow
        case .green: green
        case .cyan: cyan
        case .blue: blue
        case .violet: violet
        }
    }
}

/// Returns the palette color for `hue`: a usual place within the tolerance, else the candidate
/// with the nearest hue within the tolerance (the first on a tie), else a mix of red and yellow
/// for orange and the first usual place for the others. It picks one hue on its own, without the
/// ranking of `pickHues`, as abnahme's spec does; only tests call it (Rust keeps it `cfg(test)`).
func pickHue(_ palette: Palette, _ hue: Hue) -> SRGB {
    pickHueWithSource(palette, hue).color
}

/// `pickHue`, also naming the slot it took or that it mixed.
func pickHueWithSource(_ palette: Palette, _ hue: Hue) -> PickedHue {
    if let fitting = fitting(palette, hue, avoiding: []) {
        return fitting
    }
    switch hue {
    case .orange: return mixed(pickHue(palette, .red), pickHue(palette, .yellow))
    default: return usualPlace(palette, hue)
    }
}

/// Every hue as `pickHue` picks it, except that the hues of roles that must read as different
/// states keep apart, ranked: red (`danger`), yellow (`warning`), green (`success`), cyan
/// (`info`), orange (`agent-waiting`); violet (`accent`) over blue (`focus-ring`). A
/// lower-ranked hue passes over candidates within `minDistinctDeltaE` of one ranked above it.
/// Where none is left it falls back as `pickHue` does and may still coincide with one above;
/// the derivation then shifts its role instead (Unimatrix `docs/theme-tokens.md` "Distinct
/// roles").
func pickHues(_ palette: Palette) -> PickedHues {
    func pick(_ hue: Hue, _ above: [PickedHue]) -> PickedHue? {
        fitting(palette, hue, avoiding: above.map(\.color))
    }
    func orUsual(_ hue: Hue, _ above: [PickedHue]) -> PickedHue {
        pick(hue, above) ?? usualPlace(palette, hue)
    }
    let red = orUsual(.red, [])
    let yellow = orUsual(.yellow, [red])
    let green = orUsual(.green, [red, yellow])
    let cyan = orUsual(.cyan, [red, yellow, green])
    let orange = pick(.orange, [red, yellow, green, cyan]) ?? mixed(red.color, yellow.color)
    let violet = orUsual(.violet, [])
    let blue = orUsual(.blue, [violet])
    return PickedHues(red: red, orange: orange, yellow: yellow, green: green, cyan: cyan, blue: blue, violet: violet)
}

/// A usual place for `hue` within the tolerance, else the candidate with the nearest hue within
/// it (the first on a tie); either at least `minDistinctDeltaE` from every color in `avoid`.
private func fitting(_ palette: Palette, _ hue: Hue, avoiding avoid: [SRGB]) -> PickedHue? {
    func distance(_ key: PaletteKey) -> Double {
        hueDistance(toOKLCH(palette[key]).h, hue.target)
    }
    func fits(_ key: PaletteKey) -> Bool {
        let color = palette[key]
        return toOKLCH(color).c >= minChroma
            && distance(key) <= hueTolerance
            && avoid.allSatisfy { deltaE(color, $0) >= minDistinctDeltaE }
    }
    // `min(by:)` replaces only on a strictly smaller distance, so it keeps the first of equal
    // minima, as Rust's `min_by` (and abnahme's stable sort) did. Plain `<` orders as Rust's
    // `total_cmp` here: `fits` lets no NaN through, and `hueDistance` never returns -0.
    guard let key = hue.usualPlaces.first(where: fits)
        ?? candidates.filter(fits).min(by: { distance($0) < distance($1) })
    else {
        return nil
    }
    return PickedHue(color: palette[key], source: .slot(key))
}

/// Orange where no candidate fits: mixed from `red` and `yellow`.
private func mixed(_ red: SRGB, _ yellow: SRGB) -> PickedHue {
    PickedHue(color: mix(red, yellow, 0.5), source: .mixed)
}

/// Any hue but orange where no candidate fits: its first usual place.
private func usualPlace(_ palette: Palette, _ hue: Hue) -> PickedHue {
    let key = hue.usualPlaces[0]
    return PickedHue(color: palette[key], source: .slot(key))
}
