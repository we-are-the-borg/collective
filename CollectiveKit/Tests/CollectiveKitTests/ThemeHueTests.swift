import Testing
@testable import CollectiveKit

/// Picking the seven tones from a scheme's accents, ported from Unimatrix Zero's
/// `theme/hues.rs` (commit 43f1307) with the same inputs and expectations.
@Suite struct ThemeHueTests {
    private func palette(_ name: String) throws -> Palette {
        try Scheme.parse(try bundledSchemeText(name)).palette
    }

    private func mocha() throws -> Palette {
        try palette("catppuccin-mocha")
    }

    private func githubLight() throws -> Palette {
        try palette("github")
    }

    private func hex(_ text: String) throws -> SRGB {
        try SRGB.parse(text)
    }

    /// A palette of plain grey with the given slots overridden.
    private func greyPalette(_ overrides: [PaletteKey: String]) throws -> Palette {
        let grey = try hex("#808080")
        return Palette(colors: try PaletteKey.all.map { key in try overrides[key].map(hex) ?? grey })
    }

    @Test func takesTheUsualPlacesWhenTheirHueFitsCatppuccinMocha() throws {
        let mocha = try mocha()
        #expect(pickHue(mocha, .red) == mocha[.base08])
        #expect(pickHue(mocha, .yellow) == mocha[.base0A])
        #expect(pickHue(mocha, .green) == mocha[.base0B])
        #expect(pickHue(mocha, .blue) == mocha[.base0D])
        #expect(pickHue(mocha, .violet) == mocha[.base0E])
    }

    @Test func choosesByHueWhereTheUsualPlacesHoldOtherTonesGithubLight() throws {
        let github = try githubLight()
        let red = pickHue(github, .red)
        let green = pickHue(github, .green)
        let blue = pickHue(github, .blue)
        #expect(red != github[.base08])
        #expect(green != github[.base0B])
        #expect(blue != github[.base0D])
        #expect(hueDistance(toOKLCH(red).h, 25.0) < 15.0)
        #expect(hueDistance(toOKLCH(green).h, 145.0) < 15.0)
        #expect(hueDistance(toOKLCH(blue).h, 255.0) < 15.0)
    }

    @Test func takesTheNearestCandidateWhenNoUsualPlaceFits() throws {
        let github = try githubLight()
        #expect(pickHue(github, .orange) == github[.base08])
    }

    @Test func prefersTheNearerHueAmongFittingCandidates() throws {
        let palette = try greyPalette([.base0F: "#54aeff", .base13: "#0550ae"])
        #expect(pickHue(palette, .blue) == (try hex("#0550ae")))
    }

    @Test func ignoresCandidatesWithoutEnoughChroma() throws {
        let palette = try greyPalette([.base0D: "#8a8f99", .base16: "#3070e0"])
        #expect(pickHue(palette, .blue) == (try hex("#3070e0")))
    }

    @Test func mixesOrangeFromRedAndYellowWhenNoCandidateFits() throws {
        let palette = try greyPalette([.base08: "#e03030", .base0A: "#d0c000"])
        #expect(pickHue(palette, .orange) == mix(try hex("#e03030"), try hex("#d0c000"), 0.5))
    }

    @Test func namesTheSourceOfThePickedColor() throws {
        func source(_ palette: Palette, _ hue: Hue) -> HueSource {
            pickHueWithSource(palette, hue).source
        }
        #expect(source(try mocha(), .red) == .slot(.base08))
        #expect(source(try githubLight(), .orange) == .slot(.base08))
        let palette = try greyPalette([.base08: "#e03030", .base0A: "#d0c000"])
        #expect(source(palette, .orange) == .mixed)
    }

    /// Yellow and orange both find the same gold in their usual places, as in Rosé Pine.
    @Test func aLowerRankedHueTakesTheNextCandidateWhereItFallsTogetherWithAHigherOne() throws {
        let palette = try greyPalette([.base09: "#f6c177", .base0A: "#f6c177", .base0F: "#f08040"])
        let hues = pickHues(palette)
        #expect(hues[.yellow] == PickedHue(color: try hex("#f6c177"), source: .slot(.base0A)))
        #expect(hues[.orange] == PickedHue(color: try hex("#f08040"), source: .slot(.base0F)))
    }

    /// Rosé Pine's case: no other candidate fits orange, so it is mixed as where none fits.
    @Test func aLowerRankedOrangeWithoutAnotherCandidateIsMixed() throws {
        let palette = try greyPalette([.base08: "#eb6f92", .base09: "#f6c177", .base0A: "#f6c177"])
        #expect(pickHues(palette)[.orange] == PickedHue(
            color: mix(try hex("#eb6f92"), try hex("#f6c177"), 0.5),
            source: .mixed
        ))
        #expect(pickHue(palette, .orange) == (try hex("#f6c177")))
    }

    @Test func allCasesListsEveryHueOnceInReferenceOrder() {
        #expect(Hue.allCases.map { String(describing: $0) } == ["red", "orange", "yellow", "green", "cyan", "blue", "violet"])
    }

    @Test func fallsBackToTheUsualPlaceWhenNoCandidateFits() throws {
        let palette = try greyPalette([.base0C: "#8a9999"])
        #expect(pickHue(palette, .cyan) == (try hex("#8a9999")))
        #expect(pickHue(palette, .green) == (try hex("#808080")))
    }

    /// Not in hues.rs: pins the tie rule the comment there names. Two candidates with the same
    /// color are equally near; the first in candidate order wins, as Rust's `min_by` keeps it.
    @Test func takesTheFirstCandidateOnATie() throws {
        let palette = try greyPalette([.base0F: "#3070e0", .base13: "#3070e0"])
        #expect(pickHueWithSource(palette, .blue).source == .slot(.base0F))
    }
}
