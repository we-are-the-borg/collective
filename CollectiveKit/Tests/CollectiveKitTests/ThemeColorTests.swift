import Foundation
import Testing
@testable import CollectiveKit

/// The color math of the theme derivation, ported from Unimatrix Zero's `theme/color.rs` with
/// the same cases and expected values (commit 43f1307), so the port can later match its reference roles.
@Suite struct ThemeColorTests {
    @Test func constructorsSplitHexIntoChannels() {
        #expect(ThemeColor.rgb(0x40a02b) == ThemeColor(r: 64, g: 160, b: 43, a: 255))
        #expect(ThemeColor.rgba(0x40a02b, alpha: 38) == ThemeColor(r: 64, g: 160, b: 43, a: 38))
    }

    @Test func parsesRrggbbInEitherCase() throws {
        #expect(try SRGB.parse("#FF8000") == SRGB(0xff8000))
        #expect(try SRGB.parse("#ff8000") == SRGB(r: 255, g: 128, b: 0))
        #expect(try SRGB.parse("#40A02b") == SRGB(0x40a02b))
    }

    @Test(arguments: ["#12", "123456", "#gggggg", "#f80", "red", "", "#ff80000", "#+f8000"])
    func rejectsAnythingElse(_ input: String) {
        #expect(throws: ParseColorError(input: input)) { try SRGB.parse(input) }
    }

    @Test func writesLowercaseRrggbb() {
        #expect(SRGB(0xff8000).description == "#ff8000")
        #expect(SRGB(0x0000ff).description == "#0000ff")
    }

    @Test func invalidInputIsAParseErrorBeforeAnyMath() {
        #expect(throws: ParseColorError.self) { try SRGB.parse("red") }
        #expect(throws: ParseColorError.self) { try SRGB.parse("#12") }
    }

    /// `toBeCloseTo(expected, digits)` of the abnahme tests.
    private func expectClose(
        _ actual: Double, _ expected: Double, digits: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            abs(actual - expected) < pow(10, -Double(digits)) / 2,
            "\(actual) is not close to \(expected) at \(digits) digits",
            sourceLocation: sourceLocation
        )
    }

    @Test func contrastIs21ForBlackOnWhiteAnd1ForAColorOnItself() {
        expectClose(contrastRatio(SRGB(0x000000), SRGB(0xffffff)), 21, digits: 5)
        #expect(contrastRatio(SRGB(0x40a02b), SRGB(0x40a02b)) == 1)
    }

    @Test func contrastIsSymmetric() {
        #expect(
            contrastRatio(SRGB(0xeff1f5), SRGB(0x40a02b))
                == contrastRatio(SRGB(0x40a02b), SRGB(0xeff1f5))
        )
    }

    @Test func contrastMatchesAKnownPair() {
        expectClose(contrastRatio(SRGB(0x40a02b), SRGB(0xeff1f5)), 2.96, digits: 2)
    }

    @Test func quantizesLowercaseAndClampsChannels() {
        let exact = Channels(r: 1.0, g: 128.0 / 255.0, b: 0.0)
        #expect(quantize(exact) == SRGB(0xff8000))
        let outside = Channels(r: 1.5, g: -0.2, b: 0.5)
        #expect(quantize(outside) == SRGB(0xff0080))
    }

    @Test func withAlphaGivesARoleColorWithByteAlpha() {
        #expect(SRGB(0x40a02b).withAlpha(0.15) == ThemeColor(r: 64, g: 160, b: 43, a: 38))
        #expect(SRGB(0xffffff).withAlpha(1.0) == ThemeColor.rgb(0xffffff))
    }

    @Test func withAlphaClampsAlpha() {
        #expect(SRGB(0xffffff).withAlpha(1.5).a == 255)
        #expect(SRGB(0xffffff).withAlpha(-0.5).a == 0)
    }

    @Test(arguments: [
        0x40a02b, 0xeff1f5, 0x1e1e2e, 0xd20f39, 0x8839ef, 0x000000, 0xffffff, 0x808080,
        0xff0000, 0x0000ff,
    ] as [UInt32])
    func roundTripsThroughOKLCHUnchanged(_ hex: UInt32) {
        let color = SRGB(hex)
        #expect(fromOKLCH(toOKLCH(color)) == color, "\(color)")
    }

    @Test func greysHaveNoChromaAndHue0() {
        let grey = toOKLCH(SRGB(0x808080))
        #expect(grey.c < 1e-6, "\(grey.c)")
        #expect(grey.h == 0)
    }

    @Test func oklchMatchesReferenceValues() {
        let red = toOKLCH(SRGB(0xff0000))
        expectClose(red.l, 0.628, digits: 3)
        expectClose(red.c, 0.2577, digits: 3)
        expectClose(red.h, 29.23, digits: 1)
    }

    @Test func hueStaysIn0To360Past180Degrees() {
        let blue = toOKLCH(SRGB(0x0000ff))
        expectClose(blue.h, 264.05, digits: 1)
    }

    @Test(arguments: [30.0, 140.0, 200.0, 265.0, 330.0])
    func bringsOutOfGamutChromaIntoSRGBKeepingTheHue(_ h: Double) {
        let back = toOKLCH(fromOKLCH(OKLCH(l: 0.6, c: 0.5, h: h)))
        #expect(hueDistance(back.h, h) <= 1.0, "\(h): \(back.h)")
        expectClose(back.l, 0.6, digits: 2)
    }

    @Test func mapsLightnessBeyondTheEndsToBlackAndWhite() {
        let below = OKLCH(l: -0.1, c: 0.2, h: 30.0)
        let above = OKLCH(l: 1.2, c: 0.2, h: 30.0)
        #expect(fromOKLCH(below) == SRGB(0x000000))
        #expect(fromOKLCH(above) == SRGB(0xffffff))
    }

    @Test func hueDistanceTakesTheShorterWayRoundTheCircle() {
        #expect(hueDistance(350.0, 10.0) == 20.0)
        #expect(hueDistance(10.0, 350.0) == 20.0)
        #expect(hueDistance(0.0, 180.0) == 180.0)
        #expect(hueDistance(90.0, 90.0) == 0.0)
    }

    /// Pure red and blue from Björn Ottosson's OKLab table: (0.628, 0.225, 0.126) and
    /// (0.452, -0.032, -0.312).
    @Test func deltaEIsTheStraightOKLabDistance() {
        let (red, blue) = (SRGB(0xff0000), SRGB(0x0000ff))
        expectClose(deltaE(red, blue), 0.5371, digits: 3)
        #expect(deltaE(blue, red) == deltaE(red, blue))
        expectClose(deltaE(SRGB(0x000000), SRGB(0xffffff)), 1.0, digits: 3)
        #expect(deltaE(red, red) == 0.0)
    }

    @Test func mixReturnsTheEndPointsAt0And1() {
        let (a, b) = (SRGB(0x40a02b), SRGB(0x1e1e2e))
        #expect(mix(a, b, 0.0) == a)
        #expect(mix(a, b, 1.0) == b)
    }

    @Test func mixLandsHalfwayInOKLabLightness() {
        let middle = toOKLCH(mix(SRGB(0x000000), SRGB(0xffffff), 0.5))
        expectClose(middle.l, 0.5, digits: 2)
        #expect(middle.c == 0.0)
    }

    @Test func compositeWithAlpha0GivesTheBottom() {
        let bottom = SRGB(0xeff1f5)
        #expect(composite(SRGB(0x40a02b).withAlpha(0.0), bottom) == bottom)
    }

    @Test func compositeWithAlpha255GivesTheTop() {
        let top = SRGB(0x40a02b)
        #expect(composite(ThemeColor(top), SRGB(0xeff1f5)) == top)
    }

    @Test func compositeBlendsEachGammaEncodedChannelByTheByteAlpha() {
        // 128/255 of #40a02b over white: 64·128/255 + 127 = 159.13, 160·128/255 + 127 = 207.31,
        // 43·128/255 + 127 = 148.58.
        var top = ThemeColor(SRGB(0x40a02b))
        top.a = 128
        #expect(composite(top, SRGB(0xffffff)) == SRGB(0x9fcf95))
    }

    private static let latteBase = SRGB(0xeff1f5)
    private static let latteGreen = SRGB(0x40a02b)
    private static let mochaBase = SRGB(0x1e1e2e)
    private static let latteMauve = SRGB(0x8839ef)

    @Test func ensureContrastReturnsAPassingColorUnchanged() {
        let text = SRGB(0x4c4f69)
        #expect(ensureContrast(text, Self.latteBase, 4.5) == text)
    }

    @Test func ensureContrastDarkensOnALightBackgroundKeepingTheHue() {
        let result = ensureContrast(Self.latteGreen, Self.latteBase, 4.5)
        #expect(contrastRatio(result, Self.latteBase) >= 4.5)
        #expect(toOKLCH(result).l < toOKLCH(Self.latteGreen).l)
        #expect(hueDistance(toOKLCH(result).h, toOKLCH(Self.latteGreen).h) <= 1.0)
    }

    @Test func ensureContrastLightensOnADarkBackgroundKeepingTheHue() {
        let result = ensureContrast(Self.latteMauve, Self.mochaBase, 4.5)
        #expect(contrastRatio(result, Self.mochaBase) >= 4.5)
        #expect(toOKLCH(result).l > toOKLCH(Self.latteMauve).l)
        #expect(hueDistance(toOKLCH(result).h, toOKLCH(Self.latteMauve).h) <= 1.0)
    }

    @Test func ensureContrastMovesNoFurtherThanNeeded() {
        let result = ensureContrast(Self.latteGreen, Self.latteBase, 4.5)
        #expect(contrastRatio(result, Self.latteBase) < 5.0)
    }

    @Test func ensureContrastEndsAtBlackOrWhiteWhenTheMinimumIsOutOfReach() {
        #expect(ensureContrast(Self.latteGreen, Self.latteBase, 30.0) == SRGB(0x000000))
        #expect(ensureContrast(Self.latteMauve, Self.mochaBase, 30.0) == SRGB(0xffffff))
    }

    /// Latte's base and its green at alpha 77 over it: green that clears the base alone (see
    /// `ensureContrastMovesNoFurtherThanNeeded`) falls short on the tint, so it moves on.
    @Test func ensureContrastOnClearsEveryBackdrop() {
        let tint = SRGB(0xbad9b8)
        let alone = ensureContrast(Self.latteGreen, Self.latteBase, 4.5)
        #expect(contrastRatio(alone, tint) < 4.5)

        let result = ensureContrastOn(Self.latteGreen, [(Self.latteBase, 4.5), (tint, 4.5)])
        #expect(contrastRatio(result, Self.latteBase) >= 4.5)
        #expect(contrastRatio(result, tint) >= 4.5)
        #expect(contrastRatio(result, tint) < 5.0)
        #expect(hueDistance(toOKLCH(result).h, toOKLCH(Self.latteGreen).h) <= 1.0)
    }

    @Test func ensureContrastOnReturnsAColorPassingEverywhereUnchanged() {
        let text = SRGB(0x4c4f69)
        let tint = SRGB(0xbad9b8)
        #expect(ensureContrastOn(text, [(Self.latteBase, 4.5), (tint, 4.5)]) == text)
    }

    /// The same green and tint: held to 3:1 only, the tint asks for nothing beyond the base.
    @Test func ensureContrastOnHoldsEachBackdropToItsOwnMinimum() {
        let tint = SRGB(0xbad9b8)
        let result = ensureContrastOn(Self.latteGreen, [(Self.latteBase, 4.5), (tint, 3.0)])
        #expect(result == ensureContrast(Self.latteGreen, Self.latteBase, 4.5))
        #expect(contrastRatio(result, tint) < 4.5)
    }

    /// Latte's green at alpha 120 over the base: green that clears the base still falls short of
    /// 3:1 on this tint, so the lower minimum decides, and the shift stops once it is met.
    @Test func ensureContrastOnMovesOnForALowerMinimumThatFallsShort() {
        let tint = SRGB(0x9dcb96)
        let alone = ensureContrast(Self.latteGreen, Self.latteBase, 4.5)
        #expect(contrastRatio(alone, tint) < 3.0)

        let result = ensureContrastOn(Self.latteGreen, [(Self.latteBase, 4.5), (tint, 3.0)])
        #expect(contrastRatio(result, tint) >= 3.0)
        #expect(contrastRatio(result, tint) < 3.3)
        #expect(contrastRatio(result, Self.latteBase) > 4.5)
    }
}
