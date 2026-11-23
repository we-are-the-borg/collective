import Foundation
import Testing
@testable import CollectiveKit

/// The browser's list box: which lines separate its items, and which headers stick at its top
/// while it scrolls, like the design's `position: sticky` (section headers at 0, the variant
/// headers of fixed mode 24 below). Headers are 24 high, rows and error rows 32, lines inside.
@Suite struct AppearanceListLayoutTests {
    private let match = ThemeChoice(light: BundledThemes.defaultLight, dark: BundledThemes.defaultDark)
    private let fixed = ThemeChoice(
        light: BundledThemes.defaultLight, dark: BundledThemes.defaultDark, mode: .fixed, fixed: "nord"
    )

    private func browser(_ choice: ThemeChoice, _ slot: ThemeSlot, catalog: ThemeCatalog = .bundled) throws -> AppearanceModel.Browser {
        try #require(AppearanceModel(catalog: catalog, choice: choice, inUse: .light, expanded: slot, query: "").browser)
    }

    /// One dark custom theme in a fresh folder, from the real fixture.
    private func horizonDark() throws -> ThemeCatalog {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("appearance-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/custom-themes/horizon-dark.yaml"),
            to: url.appendingPathComponent("horizon-dark.yaml")
        )
        return ThemeCatalog(custom: CustomThemeFolder.entries(in: url))
    }

    private func pinned(_ browser: AppearanceModel.Browser, at offset: Double) -> [String] {
        browser.pinnedHeaders(scrollOffset: offset).map { "\($0.title)@\($0.y)" }
    }

    private var lightCount: Double {
        Double(BundledThemes.all.filter { $0.appearance == .light }.count)
    }

    // MARK: lines

    /// A line above every item but the first of its section and one right under a header,
    /// which draws its own line below.
    @Test func aLineSeparatesRowsButNotFromTheHeaderAbove() throws {
        let builtIn = try #require(try browser(fixed, .fixed).sections.last)
        let lines = builtIn.items.indices.map { builtIn.drawsTopLine(at: $0) }
        let darkHeader = try #require(builtIn.items.firstIndex(of: .header("Dark")))
        #expect(lines[0] == false) // "Light", first
        #expect(lines[1] == false) // under "Light"
        #expect(lines[2] == true)
        #expect(lines[darkHeader] == true)
        #expect(lines[darkHeader + 1] == false)
    }

    /// `Built-in` draws a line above its header only under a row: an empty `Custom` ends in its
    /// own header's line.
    @Test func builtInDrawsALineAboveItsHeaderUnderCustomRows() throws {
        let empty = try browser(match, .dark)
        #expect([0, 1].map { empty.drawsTopLine(ofSection: $0) } == [false, false])
        let withRow = try browser(match, .dark, catalog: horizonDark())
        #expect([0, 1].map { withRow.drawsTopLine(ofSection: $0) } == [false, true])
    }

    /// The box is only as high as its items, up to its maximum.
    @Test func theContentHeightAddsUpHeadersAndRows() throws {
        // Typed sums: Swift 6.3 gives up type-checking them inside `#expect`.
        let withCustomRow: Double = 24 + 32 + 24 + (38 - lightCount) * 32
        let allSections: Double = 24 + 24 + 24 + 24 + 38 * 32
        #expect(try browser(match, .dark, catalog: horizonDark()).contentHeight == withCustomRow)
        #expect(try browser(fixed, .fixed).contentHeight == allSections)
    }

    // MARK: pinned headers

    @Test func unscrolledNothingIsPinned() throws {
        #expect(pinned(try browser(fixed, .fixed), at: 0).isEmpty)
    }

    /// Custom holds only its header (24), so Built-in starts at 24 and pins once scrolled past.
    @Test func theSectionScrolledIntoSticksAtTheTop() throws {
        #expect(pinned(try browser(match, .dark), at: 100) == ["Built-in@0.0"])
    }

    /// Custom with one row ends at 56; at 40 Built-in's header pushes it 8 up.
    @Test func theNextSectionPushesTheHeaderOut() throws {
        let browser = try browser(match, .dark, catalog: horizonDark())
        #expect(pinned(browser, at: 40) == ["Custom@-8.0"])
        #expect(pinned(browser, at: 20) == ["Custom@0.0"])
    }

    /// Fixed mode, bundled only: Built-in from 24, `Light` from 48, `Dark` 24 + 12 light rows lower.
    @Test func aVariantHeaderSticks24BelowItsSection() throws {
        let browser = try browser(fixed, .fixed)
        let dark = 72 + lightCount * 32
        #expect(pinned(browser, at: dark + 100) == ["Dark@24.0", "Built-in@0.0"])
        #expect(pinned(browser, at: 200) == ["Light@24.0", "Built-in@0.0"])
    }

    /// The next variant header slides over the stuck one, as the later sticky element paints on top.
    @Test func theNextVariantHeaderSlidesOverTheStuckOne() throws {
        let browser = try browser(fixed, .fixed)
        let dark = 72 + lightCount * 32
        #expect(pinned(browser, at: dark - 40) == ["Light@24.0", "Dark@40.0", "Built-in@0.0"])
    }

    // MARK: keyboard

    /// Page Up / Down move a box's height: 200 holds 6 rows, 262 holds 8.
    @Test func aPageIsTheRowsTheBoxHolds() throws {
        #expect(try browser(match, .dark).maxBoxHeight == 200)
        #expect(try browser(match, .dark).pageRowCount == 6)
        #expect(try browser(fixed, .fixed).maxBoxHeight == 262)
        #expect(try browser(fixed, .fixed).pageRowCount == 8)
    }

    /// Match, bundled dark: Custom's header 0–24, Built-in's 24–48, rows from 48, 32 each; the
    /// box shows 198 (200 inside its line).
    @Test func aRowInViewNeedsNoScroll() throws {
        let browser = try browser(match, .dark)
        #expect(browser.scrollOffset(revealing: "ayu-dark", from: 0, viewport: 198) == nil)
        // The 4th row: 48 + 3 × 32 = 144 to 176.
        #expect(browser.scrollOffset(revealing: "catppuccin-macchiato", from: 0, viewport: 198) == nil)
    }

    /// Below the box: scrolled until its bottom edge is the box's.
    @Test func aRowBelowScrollsUpToTheBottomEdge() throws {
        let browser = try browser(match, .dark)
        // "dracula" is the 6th row: 48 + 5 × 32 = 208 to 240, so 240 - 198.
        #expect(browser.scrollOffset(revealing: "dracula", from: 0, viewport: 198) == 42.0)
    }

    /// Above the box: scrolled until it stands under the stuck section header.
    @Test func aRowAboveScrollsDownUnderTheStuckHeader() throws {
        let browser = try browser(match, .dark)
        // "ayu-mirage" at 80, under Built-in's header stuck over 0–24: 80 - 24.
        #expect(browser.scrollOffset(revealing: "ayu-mirage", from: 300, viewport: 198) == 56.0)
        // The first row: back to where its header stands in place.
        #expect(browser.scrollOffset(revealing: "ayu-dark", from: 300, viewport: 198) == 24)
    }

    /// Under a variant header in fixed mode two headers stick, 48 high.
    @Test func inFixedModeARowStandsUnderBothStuckHeaders() throws {
        let browser = try browser(fixed, .fixed)
        // Built-in from 24, `Light` 48–72, "catppuccin-latte" the second light row at 104: 104 - 48.
        #expect(browser.scrollOffset(revealing: "catppuccin-latte", from: 500, viewport: 260) == 56.0)
        #expect(browser.scrollOffset(revealing: "nord", from: 0, viewport: 260) != nil)
        #expect(browser.scrollOffset(revealing: "no-such-row", from: 0, viewport: 260) == nil)
    }
}
