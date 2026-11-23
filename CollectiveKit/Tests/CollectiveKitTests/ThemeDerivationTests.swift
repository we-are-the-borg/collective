import Testing
@testable import CollectiveKit

/// The role derivation, ported from Unimatrix Zero's `theme/derive.rs` (commit 43f1307) with the
/// same inputs and expectations. The contract tests run over every theme Unimatrix bundles (the
/// fixture schemes, a superset of the app's, see `FixtureThemes`), as Unimatrix's
/// `docs/theme-tokens.md` "Adding a theme" asks, so a dropped-in scheme is checked without a
/// code change.
///
/// derive.rs' `roles_are_exactly_the_contract_table` is not ported: it reads Unimatrix's
/// `docs/theme-tokens.md`, which this repo does not have. The coverage test against Unimatrix's
/// reference file takes its place; only its uniqueness check is kept here.
@Suite struct ThemeDerivationTests {
    // MARK: Roles

    @Test func roleNamesAreUnique() {
        let names = ThemeRole.allCases.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test func allListsEveryRoleOnceInDeclarationOrder() {
        #expect(ThemeRole.allCases.count == 52)
        #expect(ThemeRole.allCases.first == .surfaceDeep)
        #expect(ThemeRole.allCases.last == .syntaxEmbedded)
        #expect(ThemeRole.allCases.map(\.name) == [
            "surface-deep", "surface-sunken", "surface-panel", "surface", "surface-raised", "surface-hover",
            "surface-active", "text", "text-muted", "text-subtle", "text-disabled", "border",
            "border-strong", "border-control", "focus-ring", "accent", "accent-on", "accent-hover",
            "accent-active", "diff-added-fg", "diff-removed-fg",
            "diff-added-bg", "diff-removed-bg", "diff-word-added", "diff-word-removed", "diff-gutter",
            "agent-working", "agent-waiting", "agent-done", "agent-idle", "agent-error", "class-code",
            "class-test", "class-docs", "class-config", "class-generated", "unseen", "warning",
            "warning-bg", "danger", "success", "info", "scrim", "syntax-comment", "syntax-variable",
            "syntax-constant", "syntax-type", "syntax-string", "syntax-special", "syntax-function",
            "syntax-keyword", "syntax-embedded",
        ])
    }

    /// Fills every field of `ThemeRoles` by name, so a field added to `ThemeRoles` fails to
    /// compile here until it has a role.
    private func roles(from color: (ThemeRole) -> ThemeColor) -> ThemeRoles {
        ThemeRoles(
            surfaceDeep: color(.surfaceDeep),
            surfaceSunken: color(.surfaceSunken),
            surfacePanel: color(.surfacePanel),
            surface: color(.surface),
            surfaceRaised: color(.surfaceRaised),
            surfaceHover: color(.surfaceHover),
            surfaceActive: color(.surfaceActive),
            text: color(.text),
            textMuted: color(.textMuted),
            textSubtle: color(.textSubtle),
            textDisabled: color(.textDisabled),
            border: color(.border),
            borderStrong: color(.borderStrong),
            borderControl: color(.borderControl),
            focusRing: color(.focusRing),
            accent: color(.accent),
            accentOn: color(.accentOn),
            accentHover: color(.accentHover),
            accentActive: color(.accentActive),
            diffAddedFg: color(.diffAddedFg),
            diffRemovedFg: color(.diffRemovedFg),
            diffAddedBg: color(.diffAddedBg),
            diffRemovedBg: color(.diffRemovedBg),
            diffWordAdded: color(.diffWordAdded),
            diffWordRemoved: color(.diffWordRemoved),
            diffGutter: color(.diffGutter),
            agentWorking: color(.agentWorking),
            agentWaiting: color(.agentWaiting),
            agentDone: color(.agentDone),
            agentIdle: color(.agentIdle),
            agentError: color(.agentError),
            classCode: color(.classCode),
            classTest: color(.classTest),
            classDocs: color(.classDocs),
            classConfig: color(.classConfig),
            classGenerated: color(.classGenerated),
            unseen: color(.unseen),
            warning: color(.warning),
            warningBg: color(.warningBg),
            danger: color(.danger),
            success: color(.success),
            info: color(.info),
            scrim: color(.scrim),
            syntaxComment: color(.syntaxComment),
            syntaxVariable: color(.syntaxVariable),
            syntaxConstant: color(.syntaxConstant),
            syntaxType: color(.syntaxType),
            syntaxString: color(.syntaxString),
            syntaxSpecial: color(.syntaxSpecial),
            syntaxFunction: color(.syntaxFunction),
            syntaxKeyword: color(.syntaxKeyword),
            syntaxEmbedded: color(.syntaxEmbedded)
        )
    }

    @Test func everyRolesFieldHasItsOwnRole() {
        func color(_ role: ThemeRole) -> ThemeColor {
            .rgb(UInt32(ThemeRole.allCases.firstIndex(of: role)!))
        }
        let roles = roles(from: color)
        for role in ThemeRole.allCases {
            #expect(roles[role] == color(role), "\(role.name)")
        }
    }

    /// `ThemeRoles` holds only `ThemeColor` fields, so a field without a role of its own shows in
    /// its size.
    @Test func rolesHasOneFieldPerRole() {
        #expect(MemoryLayout<ThemeRoles>.size == ThemeRole.allCases.count * MemoryLayout<ThemeColor>.size)
    }

    /// `SyntaxRole.role` does not feed `deriveTheme`, so the byte-exact reference test cannot catch a
    /// swapped mapping.
    @Test func everySyntaxRoleIsAContractRoleInTableOrder() {
        let contract = ThemeRole.allCases.filter { $0.name.hasPrefix("syntax-") }
        #expect(SyntaxRole.allCases.map(\.role) == contract)
    }

    // MARK: Helpers

    private func mocha() throws -> Scheme {
        try Scheme.parse(try bundledSchemeText("catppuccin-mocha"))
    }

    private func hex(_ text: String) throws -> SRGB {
        try SRGB.parse(text)
    }

    /// `scheme` with some palette slots replaced.
    private func withColors(_ scheme: Scheme, _ overrides: [PaletteKey: SRGB]) -> Scheme {
        var changed = scheme
        changed.palette = Palette(colors: PaletteKey.all.map { overrides[$0] ?? scheme.palette[$0] })
        return changed
    }

    /// The palette with the light and dark greys swapped and no variant, so it reads as light.
    private func inverted(_ scheme: Scheme) -> Scheme {
        var swapped = withColors(scheme, [.base00: scheme.palette[.base05], .base05: scheme.palette[.base00]])
        swapped.variant = nil
        return swapped
    }

    /// An opaque role as `SRGB`, for the color math.
    private func rgb(_ color: ThemeColor, sourceLocation: SourceLocation = #_sourceLocation) -> SRGB {
        #expect(color.a == 255, "\(color) is not opaque", sourceLocation: sourceLocation)
        return SRGB(r: color.r, g: color.g, b: color.b)
    }

    private func lightness(_ color: ThemeColor) -> Double {
        toOKLCH(rgb(color)).l
    }

    private func opaque(_ color: ThemeColor) -> ThemeColor {
        ThemeColor(r: color.r, g: color.g, b: color.b, a: 255)
    }

    // MARK: Derivation

    @Test func carriesIdNameAndAuthor() throws {
        let theme = deriveTheme(id: "catppuccin-mocha", scheme: try mocha(), contrast: .regular)
        #expect(theme.id == "catppuccin-mocha")
        #expect(theme.name == "Catppuccin Mocha")
        #expect(theme.author == "https://github.com/catppuccin/catppuccin")
    }

    @Test func takesTheAppearanceFromTheVariant() throws {
        #expect(deriveTheme(id: "x", scheme: try mocha(), contrast: .regular).appearance == .dark)
        var light = try mocha()
        light.variant = .light
        #expect(deriveTheme(id: "x", scheme: light, contrast: .regular).appearance == .light)
    }

    @Test func infersTheAppearanceFromLuminanceWithoutAVariant() throws {
        var unset = try mocha()
        unset.variant = nil
        #expect(deriveTheme(id: "x", scheme: unset, contrast: .regular).appearance == .dark)
        #expect(deriveTheme(id: "x", scheme: inverted(try mocha()), contrast: .regular).appearance == .light)
    }

    /// Replaces abnahme's CSS color check: every role is a `ThemeColor` by type, so what is left
    /// to prove is that backdrops carry their alpha and everything else is opaque. Mocha's
    /// added-word alpha is below abnahme's 77, lowered for `text` (see
    /// `wordAlphaIsLoweredOnlyWhereTextNeedsIt`).
    @Test func fillsEveryRoleOpaqueExceptTheBackdrops() throws {
        let roles = deriveTheme(id: "x", scheme: try mocha(), contrast: .regular).roles
        func alpha(_ role: ThemeRole) -> UInt8 {
            switch role {
            case .diffAddedBg, .diffRemovedBg: 31
            case .diffWordAdded: 64
            case .diffWordRemoved: 77
            case .warningBg: 26
            case .scrim: 153
            default: 255
            }
        }
        for role in ThemeRole.allCases {
            #expect(roles[role].a == alpha(role), "\(role.name)")
        }
    }

    /// Only the comment role reads `base03`, as the base16 styling guidelines intend it.
    @Test func takesSurfacesAndBordersFromBase00AndBase05Alone() throws {
        let mocha = try mocha()
        let scrambled = withColors(mocha, [
            .base01: try hex("#ff0000"),
            .base02: try hex("#00ff00"),
            .base03: try hex("#0000ff"),
            .base04: try hex("#ffff00"),
            .base10: try hex("#00ffff"),
            .base11: try hex("#ff00ff"),
        ])
        let (scrambledRoles, mochaRoles) = (
            deriveTheme(id: "x", scheme: scrambled, contrast: .regular).roles,
            deriveTheme(id: "x", scheme: mocha, contrast: .regular).roles
        )
        for role in ThemeRole.allCases where role != .syntaxComment {
            #expect(scrambledRoles[role] == mochaRoles[role], "\(role.name)")
        }
        #expect(scrambledRoles.syntaxComment != mochaRoles.syntaxComment)
    }

    @Test func darkensSunkenAndDeepButLightensThemOnABlackSurface() throws {
        let dark = deriveTheme(id: "x", scheme: try mocha(), contrast: .regular).roles
        #expect(lightness(dark.surfaceSunken) < lightness(dark.surface))
        #expect(lightness(dark.surfaceDeep) < lightness(dark.surfaceSunken))

        let blackScheme = withColors(try mocha(), [.base00: try hex("#000000")])
        let black = deriveTheme(id: "x", scheme: blackScheme, contrast: .regular).roles
        #expect(lightness(black.surfaceSunken) > 0.02)
        #expect(lightness(black.surfaceDeep) > lightness(black.surfaceSunken) + 0.02)
    }

    @Test func scrimsWithTheDeepestSurfaceWhenDarkAndTheTextWhenLight() throws {
        let dark = deriveTheme(id: "x", scheme: try mocha(), contrast: .regular).roles
        let light = deriveTheme(id: "x", scheme: inverted(try mocha()), contrast: .regular).roles
        #expect(opaque(dark.scrim) == dark.surfaceDeep)
        #expect(opaque(light.scrim) == light.text)
    }

    /// Where abnahme threw, `deriveTheme` falls back to the surface; one direction always has at
    /// least 0.5 of OKLCH lightness, so no surface should get there.
    @Test func findsRoomToRecessEveryGreyAndAGridOfColors() {
        let greys = (0...255).map { UInt8($0) }.map { SRGB(r: $0, g: $0, b: $0) }
        let steps = stride(from: 0, through: 255, by: 17).map { UInt8($0) }
        let grid = steps.flatMap { r in steps.flatMap { g in steps.map { b in SRGB(r: r, g: g, b: b) } } }
        for surface in greys + grid where recessedSurfaces(surface) == nil {
            Issue.record("\(surface)")
        }
    }

    /// A sanity check against Unimatrix's reference file (`reference/roles.json`, Catppuccin
    /// Frappé), not a substitute for comparing every role there.
    @Test func derivesCatppuccinFrappeAsUnimatrixDoes() throws {
        let theme = BundledThemes.resolve(id: "catppuccin-frappe", appearance: .dark)
        #expect(theme.roles.surfaceDeep == .rgb(0x212335))
        #expect(theme.roles.surfaceRaised == .rgb(0x3e4357))
        #expect(theme.roles.accent == .rgb(0xdaaef7))
        #expect(theme.roles.diffRemovedFg == .rgb(0xf89293))
        #expect(theme.roles.diffWordRemoved == .rgba(0xe78284, alpha: 0x47))
        let scheme = try Scheme.parse(try bundledSchemeText("catppuccin-frappe"))
        #expect(pickHueWithSource(scheme.palette, .orange).source == .slot(.base09))
    }

    /// On a near-black surface sunken and deep lighten, as raised and hover do; the panel still
    /// goes darker wherever a color lies a surface step below, so the sidebar's raised and hover
    /// rows show on it from the far side of the surface. Only black itself has nothing below: its
    /// panel lightens and keeps the step from raised and hover alone. The contract's literal, not
    /// the constant.
    @Test func thePanelKeepsApartFromRaisedAndHoverOnNearBlackSurfaces() throws {
        let black = SRGB(0x000000)
        let greys = (0...48).map { UInt8($0) }.map { SRGB(r: $0, g: $0, b: $0) }
        let steps = stride(from: 0, through: 48, by: 8).map { UInt8($0) }
        let grid = steps.flatMap { r in steps.flatMap { g in steps.map { b in SRGB(r: r, g: g, b: b) } } }
        let mocha = try mocha()
        for surface in greys + grid {
            let scheme = withColors(mocha, [.base00: surface])
            for contrast in [ThemeContrast.regular, .high] {
                let roles = deriveTheme(id: "x", scheme: scheme, contrast: contrast).roles
                let (surfaceL, panel) = (lightness(roles.surface), lightness(roles.surfacePanel))
                for row in [ThemeRole.surfaceRaised, .surfaceHover] {
                    let rowL = lightness(roles[row])
                    let gap = abs(rowL - panel)
                    #expect(gap >= 0.02, "\(surface) \(contrast) \(row.name): \(gap)")
                    if surface != black {
                        #expect(
                            (panel - surfaceL) * (rowL - surfaceL) < 0.0,
                            "\(surface) \(contrast) \(row.name): panel \(panel), row \(rowL)"
                        )
                    }
                }
            }
        }
    }

    /// Near white or black a step no longer fits: the accent states end there instead of
    /// turning back towards the surface.
    @Test func accentStepsEndAtWhiteOrBlackWhereTheLightnessRangeEnds() throws {
        let white = SRGB(0xffffff)
        let black = SRGB(0x000000)
        #expect(stepAccent(try hex("#f8f6fc"), 1.0) == white)
        #expect(stepAccent(white, 1.0) == white)
        #expect(stepAccent(try hex("#010101"), -1.0) == black)
        #expect(stepAccent(black, -1.0) == black)
    }

    /// Mocha with its mauve also in the blue slot, and no other blue within the tolerance, as in
    /// Rosé Pine: the accent keeps Mocha's value, the focus ring moves its lightness away from
    /// the surface until it lies the least distance from the accent; the blue text roles keep
    /// the mauve.
    @Test func theLowerRankedRoleMovesWhereItsHueFallsTogetherWithAHigherOne() throws {
        let mauve = try hex("#cba6f7")
        let scheme = withColors(try mocha(), [.base0D: mauve])
        let roles = deriveTheme(id: "x", scheme: scheme, contrast: .regular).roles
        #expect(roles.accent == .rgb(0xcba6f7))
        #expect(roles.agentWorking == .rgb(0xcba6f7))
        let ring = rgb(roles.focusRing)
        let distance = deltaE(ring, mauve)
        #expect((0.03..<0.04).contains(distance), "\(ring): \(distance)")
        #expect(toOKLCH(ring).l > toOKLCH(mauve).l, "\(ring)")
    }

    // MARK: Contract over every fixture theme

    /// Unimatrix's `docs/theme-tokens.md` "Contrast rule": the text roles, every one but
    /// `text-disabled` and `class-generated`.
    private static let textRoles: [ThemeRole] = [
        .text, .textMuted, .textSubtle, .diffAddedFg, .diffRemovedFg, .agentWorking, .agentWaiting,
        .agentDone, .agentIdle, .agentError, .classCode, .classTest, .classDocs, .classConfig,
        .unseen, .warning, .danger, .success, .info, .accent,
    ]

    private func contrast(_ roles: ThemeRoles, _ fg: ThemeRole, _ bg: ThemeRole) -> Double {
        contrastRatio(rgb(roles[fg]), rgb(roles[bg]))
    }

    @Test(arguments: FixtureThemes.ids)
    func textRolesReach4_5To1OnTheSurface(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        #expect(Self.textRoles.count == 20)
        for role in Self.textRoles {
            let ratio = contrast(roles, role, .surface)
            #expect(ratio >= 4.5, "\(id) \(role.name): \(ratio)")
        }
    }

    @Test(arguments: FixtureThemes.ids)
    func disabledTextAndTheFocusRingReach3To1OnTheSurface(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        for role in [ThemeRole.textDisabled, .classGenerated, .focusRing] {
            let ratio = contrast(roles, role, .surface)
            #expect(ratio >= 3.0, "\(id) \(role.name): \(ratio)")
        }
    }

    /// WCAG 1.4.11: a focused field in a dialog or popover, a hovered row, the search field.
    @Test(arguments: FixtureThemes.ids)
    func theFocusRingReaches3To1OnRaisedHoverAndSunken(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        for bg in [ThemeRole.surfaceRaised, .surfaceHover, .surfaceSunken] {
            let ratio = contrast(roles, .focusRing, bg)
            #expect(ratio >= 3.0, "\(id) on \(bg.name): \(ratio)")
        }
    }

    /// WCAG 1.4.11: a control's edge against every surface a control sits on.
    @Test(arguments: FixtureThemes.ids)
    func theControlBorderReaches3To1OnSurfaceRaisedAndSunken(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        for bg in [ThemeRole.surface, .surfaceRaised, .surfaceSunken] {
            let ratio = contrast(roles, .borderControl, bg)
            #expect(ratio >= 3.0, "\(id) on \(bg.name): \(ratio)")
        }
    }

    /// 8-bit rounding turns the bundled accents by at most 0.96 degrees (Tokyo Night Light);
    /// 2 leaves room for that and is a tenth of the tolerance by which a slot counts as a hue at
    /// all. Below chroma 0.02 rounding alone can turn a near-grey by more; every bundled accent
    /// has at least 0.03.
    @Test(arguments: FixtureThemes.ids)
    func accentHoverAndActiveKeepTheAccentHue(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        let accent = toOKLCH(rgb(roles.accent))
        guard accent.c >= 0.02 else { return }
        for role in [ThemeRole.accentHover, .accentActive] {
            let drift = hueDistance(accent.h, toOKLCH(rgb(roles[role])).h)
            #expect(drift <= 2.0, "\(id) \(role.name): \(drift) degrees")
        }
    }

    private static let accentFills: [ThemeRole] = [.accent, .accentHover, .accentActive]

    @Test(arguments: FixtureThemes.ids)
    func accentOnReaches4_5To1OnTheAccentAndItsHoverAndActive(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        for bg in Self.accentFills {
            let ratio = contrast(roles, .accentOn, bg)
            #expect(ratio >= 4.5, "\(id) on \(bg.name): \(ratio)")
        }
    }

    /// WCAG 1.4.11: a filled control against the surface it sits on.
    @Test(arguments: FixtureThemes.ids)
    func accentHoverAndActiveReach3To1OnTheSurface(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        for role in [ThemeRole.accentHover, .accentActive] {
            let ratio = contrast(roles, role, .surface)
            #expect(ratio >= 3.0, "\(id) \(role.name): \(ratio)")
        }
    }

    @Test(arguments: FixtureThemes.ids)
    func accentHoverAndActiveMoveIncreasinglyFarFromTheSurface(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        let surface = lightness(roles.surface)
        let distances = Self.accentFills.map { abs(lightness(roles[$0]) - surface) }
        #expect(distances[0] < distances[1], "\(id): \(distances)")
        #expect(distances[1] < distances[2], "\(id): \(distances)")
    }

    @Test(arguments: FixtureThemes.ids)
    func raisedHoverAndActiveMoveIncreasinglyFarFromTheSurface(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        let distances = [ThemeRole.surfaceRaised, .surfaceHover, .surfaceActive].map { contrast(roles, $0, .surface) }
        #expect(1.0 < distances[0], "\(id): \(distances)")
        #expect(distances[0] < distances[1], "\(id): \(distances)")
        #expect(distances[1] < distances[2], "\(id): \(distances)")
    }

    @Test(arguments: FixtureThemes.ids)
    func sunkenAndDeepDifferFromTheSurfaceAndEachOther(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        #expect(roles.surfaceSunken != roles.surface, "\(id)")
        #expect(roles.surfaceDeep != roles.surface, "\(id)")
        #expect(roles.surfaceDeep != roles.surfaceSunken, "\(id)")
    }

    @Test(arguments: FixtureThemes.lightIDs)
    func deepLiesThreeStepsBelowRaisedAndSunkenOneAboveInLightThemes(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        let raised = lightness(roles.surfaceRaised)
        let (deep, sunken) = (lightness(roles.surfaceDeep), lightness(roles.surfaceSunken))
        // The contract's literals (Unimatrix `docs/theme-tokens.md` "Layering rule"), not the
        // code's constants, so changing one cannot loosen the test. The epsilon covers 0.09
        // against 3.0 * 0.03 differing in the last bit.
        let epsilon = 1e-9
        #expect(deep <= raised - 0.09 + epsilon, "\(id): deep \(deep), raised \(raised)")
        #expect(sunken >= raised + 0.03 - epsilon, "\(id): sunken \(sunken), raised \(raised)")
    }

    /// Tolerances sit a few times above the 8-bit rounding measured on the bundled themes (chroma
    /// 1e-4, hue 3e-3 degrees) and tight enough to catch a half-desaturated Latte (chroma about
    /// 0.006); hue is skipped below chroma 0.005, where a grey has none.
    @Test(arguments: FixtureThemes.lightIDs)
    func shiftedLightSurfacesKeepHueAndChroma(_ id: String) throws {
        let roles = FixtureThemes.theme(id).roles
        let (sunken, deep) = try #require(recessedSurfaces(rgb(roles.surface)))
        for (name, before, after) in [
            ("sunken", sunken, roles.surfaceSunken),
            ("deep", deep, roles.surfaceDeep),
        ] {
            let (before, after) = (toOKLCH(before), toOKLCH(rgb(after)))
            #expect(abs(before.c - after.c) <= 1e-3, "\(id) \(name): \(before) \(after)")
            if before.c >= 0.005 {
                let drift = hueDistance(before.h, after.h)
                #expect(drift <= 0.5, "\(id) \(name): \(drift) degrees")
            }
        }
    }

    /// The sidebar is darker than the content in light and dark themes alike (no bundled
    /// `base00` is black enough to lighten it), at least one surface step, and the gap between
    /// panels deeper still. The contract's literal, not the constant.
    @Test(arguments: FixtureThemes.ids)
    func thePanelLiesASurfaceStepBelowTheSurfaceAndAboveDeep(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        let (surface, panel, deep) = (
            lightness(roles.surface), lightness(roles.surfacePanel), lightness(roles.surfaceDeep)
        )
        #expect(panel <= surface - 0.03, "\(id): panel \(panel), surface \(surface)")
        #expect(deep < panel, "\(id): deep \(deep), panel \(panel)")
    }

    /// The sidebar's selected row is raised, its hovered row hover: both stay visible on the
    /// panel. The contract's literal, not the constant.
    @Test(arguments: FixtureThemes.ids)
    func raisedAndHoverKeepAVisibleStepFromThePanel(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        let panel = lightness(roles.surfacePanel)
        for row in [ThemeRole.surfaceRaised, .surfaceHover] {
            let gap = abs(lightness(roles[row]) - panel)
            #expect(gap >= 0.02, "\(id) \(row.name): \(gap)")
        }
    }

    /// Everything the sidebar draws on its panel, or will (the agent status, the filter field
    /// and its focus): text at 4.5:1, disabled text and the non-text roles at 3:1. The
    /// contract's literals, not the constants.
    @Test(arguments: FixtureThemes.ids)
    func rolesDrawnInTheSidebarReachTheirFloorOnThePanel(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        let text: [ThemeRole] = [
            .text, .textMuted, .textSubtle, .accent, .danger, .agentWorking, .agentWaiting,
            .agentDone, .agentIdle, .agentError,
        ]
        let soft: [ThemeRole] = [.textDisabled, .focusRing, .borderControl]
        for (role, floor) in text.map({ ($0, 4.5) }) + soft.map({ ($0, 3.0) }) {
            let ratio = contrast(roles, role, .surfacePanel)
            #expect(ratio >= floor, "\(id) \(role.name): \(ratio)")
        }
    }

    /// Catppuccin Macchiato's panel is one surface step below its surface, about Zed's mantle
    /// (`#1e2030`) for the same scheme.
    @Test func macchiatoTakesThePanelOneStepBelowItsSurface() {
        #expect(FixtureThemes.theme("catppuccin-macchiato").roles.surfacePanel == .rgb(0x1c1f31))
    }

    /// The values Unimatrix's `docs/design/durchsicht.md` hands off for the light-theme layering
    /// rules.
    @Test func lightThemesTakeTheHandedOffDeepAndSunkenSurfaces() {
        let latte = BundledThemes.resolve(id: "catppuccin-latte", appearance: .light).roles
        #expect(latte.surfaceDeep == .rgb(0xc4c6ca))
        #expect(latte.surfaceSunken == .rgb(0xedeff3))

        let github = BundledThemes.resolve(id: "github", appearance: .light).roles
        #expect(github.surfaceDeep == .rgb(0xc8c8c8))
        #expect(github.surfaceSunken == .rgb(0xf3f3f3))
    }

    @Test(arguments: FixtureThemes.ids)
    func textStaysReadableOnEverySurface(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        for (fg, bg) in [
            (ThemeRole.text, ThemeRole.surfaceRaised),
            (.text, .surfaceHover),
            (.text, .surfaceActive),
            (.textMuted, .surfaceRaised),
            (.textMuted, .surfaceHover),
            (.textMuted, .surfaceSunken),
            (.textSubtle, .surfaceRaised),
            (.textSubtle, .surfaceSunken),
        ] {
            let ratio = contrast(roles, fg, bg)
            #expect(ratio >= 4.5, "\(id) \(fg.name) on \(bg.name): \(ratio)")
        }
    }

    /// The positions a backdrop may take for the secondary text: none but the first, where the
    /// derivation put it, within 0.02 of OKLCH lightness of the surface below it (the contract's
    /// literal, not the constant). The shares are the raised and hover mixes.
    @Test func closerBackdropsKeepAVisibleStep() throws {
        func l(_ color: SRGB) -> Double { toOKLCH(color).l }
        for (id, scheme) in FixtureThemes.schemes {
            let p = scheme.palette
            let surface = p[.base00]
            let toward = { (share: Double) in mix(surface, p[.base05], share) }
            for scale in [1.0, 0.5, 0.2] {
                for (share, below) in [(0.12, surface), (0.2, toward(0.12))] {
                    for mixed in closerMixes(toward, share, scale, below).dropFirst() {
                        let gap = abs(l(mixed) - l(below))
                        #expect(gap >= 0.02, "\(id) \(share) at \(scale): \(gap)")
                    }
                }
            }
            let (sunken, _) = try #require(recessedSurfaces(surface))
            let side: Double = l(sunken) - l(surface) < 0 ? -1.0 : 1.0
            for closer in closerRecesses(surface, sunken).dropFirst() {
                let gap = side * (l(closer) - l(surface))
                #expect(gap >= 0.02, "\(id) sunken: \(gap)")
            }
        }
    }

    /// Raised and hover keep the least visible step from the surface below them wherever they
    /// sit, as the layering rule places them or as the secondary text moved them; so does a
    /// dark theme's sunken (a light theme's sits where the light-theme rules put it). The diff
    /// lines keep their least alpha. The contract's literal, not the constant.
    @Test(arguments: FixtureThemes.ids)
    func bundledBackdropsKeepAVisibleStep(_ id: String) {
        let theme = FixtureThemes.theme(id)
        let roles = theme.roles
        for line in [ThemeRole.diffAddedBg, .diffRemovedBg] {
            // 0.1 of 255, rounded.
            let alpha = roles[line].a
            #expect(alpha >= 26, "\(id) \(line.name): \(alpha)")
        }
        let surface = lightness(roles.surface)
        var gaps = [
            ("raised", lightness(roles.surfaceRaised) - surface),
            ("hover", lightness(roles.surfaceHover) - surface),
            ("hover from raised", lightness(roles.surfaceHover) - lightness(roles.surfaceRaised)),
        ]
        if theme.appearance == .dark {
            gaps.append(("sunken", lightness(roles.surfaceSunken) - surface))
        }
        for (name, gap) in gaps {
            #expect(abs(gap) >= 0.02, "\(id) \(name): \(gap)")
        }
    }

    /// Macchiato's raised comes closer for its subtle text and GitHub Light's hover for its muted
    /// text. Macchiato's subtle text keeps its mix; GitHub Light's muted text moves only for its
    /// step from the subtle text (1.094:1 at its mix), not for hover, so it lies within one fine
    /// lightness step of 1.10:1 from it (1.111). The other pairs of Unimatrix's contrast rules are
    /// met by shifting the text in every bundled scheme that falls short (see `secondaryText`).
    /// The shares are the raised and hover mixes and the subtle text mix.
    @Test func backdropsComeCloserWhereThatIsEnoughAndTheTextKeepsItsMix() {
        for (id, role, share) in [
            ("catppuccin-macchiato", ThemeRole.surfaceRaised, 0.12),
            ("github", .surfaceHover, 0.2),
        ] {
            let p = FixtureThemes.scheme(id).palette
            let roles = FixtureThemes.theme(id).roles
            let surface = p[.base00]
            let full = mix(surface, p[.base05], share)
            func toSurface(_ color: SRGB) -> Double { contrastRatio(color, surface) }
            #expect(toSurface(rgb(roles[role])) < toSurface(full), "\(id)")
        }
        let macchiato = FixtureThemes.theme("catppuccin-macchiato").roles
        let surface = FixtureThemes.scheme("catppuccin-macchiato").palette[.base00]
        let unshifted = ensureContrast(mix(rgb(macchiato.text), surface, 0.3), surface, 4.5)
        #expect(macchiato.textSubtle == ThemeColor(unshifted))

        let github = FixtureThemes.theme("github").roles
        let step = contrast(github, .textMuted, .textSubtle)
        #expect((1.10..<1.12).contains(step), "\(step)")
    }

    /// Tomorrow's subtle text would reach 4.5:1 on a raised surface 0.034 from its white
    /// surface; the light-theme rule would then lift sunken to white as well. So raised keeps
    /// its mix (0.12) and the subtle text (mix 0.3) is shifted.
    @Test func aLightThemeKeepsRaisedAndShiftsTheSubtleText() {
        let p = FixtureThemes.scheme("tomorrow").palette
        let roles = FixtureThemes.theme("tomorrow").roles
        let surface = p[.base00]
        let full = mix(surface, p[.base05], 0.12)
        #expect(roles.surfaceRaised == ThemeColor(full))
        let unshifted = ensureContrast(mix(rgb(roles.text), surface, 0.3), surface, 4.5)
        #expect(contrastRatio(unshifted, full) < 4.5)
        #expect(lightness(roles.textSubtle) < toOKLCH(unshifted).l)
    }

    /// Each quieter text role reads weaker than the one above it, so the order survives every
    /// shift of `text-muted` and `text-subtle`.
    @Test(arguments: FixtureThemes.ids)
    func textMutedSubtleAndDisabledStepDownStrictlyOnTheSurface(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        let ratios = [ThemeRole.text, .textMuted, .textSubtle, .textDisabled].map {
            contrast(roles, $0, .surface)
        }
        #expect(zip(ratios, ratios.dropFirst()).allSatisfy { $0 > $1 }, "\(id): \(ratios)")
    }

    /// Input for `secondaryText` in a dark theme on `surface`. The mixes stay on the surface,
    /// which every text clears, so only sunken and the lines can ask anything of the text.
    private func secondaryInput(
        _ surface: SRGB,
        textMuted: SRGB,
        textSubtle: SRGB,
        lineHues: [SRGB]
    ) throws -> SecondaryInput {
        let (sunken, deep) = try #require(recessedSurfaces(surface))
        return SecondaryInput(
            appearance: .dark,
            surface: surface,
            toward: { share in mix(surface, surface, share) },
            textMuted: textMuted,
            textSubtle: textSubtle,
            raisedScale: 1.0,
            hoverScale: 1.0,
            sunken: sunken,
            deep: deep,
            lineHues: lineHues
        )
    }

    /// The first color from `start` upwards in OKLCH lightness, by 0.001, that reaches 4.5:1 on
    /// `backdrop`: a text just readable there.
    private func justReadable(_ start: SRGB, _ backdrop: SRGB) throws -> SRGB {
        let lch = toOKLCH(start)
        return try #require((0..<1000).lazy
            .map { step in fromOKLCH(OKLCH(l: lch.l + Double(step) * 0.001, c: lch.c, h: lch.h)) }
            .first { contrastRatio($0, backdrop) >= 4.5 })
    }

    /// A pure green line on Mocha's surface: a muted text that reads on it at alpha 0.11 (byte
    /// 28) but not at 0.12 (31) lowers that line, keeps its value and leaves the red line.
    @Test func mutedTextLowersTheLineAlphaWhereThatIsEnough() throws {
        let surface = try mocha().palette[.base00]
        let (green, red) = (try hex("#00ff00"), try hex("#f38ba8"))
        func line(_ alpha: Double) -> SRGB { composite(green.withAlpha(alpha), surface) }
        let muted = try justReadable(try hex("#808080"), line(0.11))
        #expect(contrastRatio(muted, line(0.12)) < 4.5)

        let settled = secondaryText(try secondaryInput(
            surface, textMuted: muted, textSubtle: try hex("#ffffff"), lineHues: [green, red]
        ))
        #expect(settled.lineAlphas.map { green.withAlpha($0).a } == [28, 31])
        #expect(settled.textMuted == muted)
    }

    /// A muted text that misses 4.5:1 even at the least line alpha is shifted for the line at
    /// its full alpha, which stays.
    @Test func mutedTextShiftsWhereTheLeastLineAlphaIsNotEnough() throws {
        let surface = try mocha().palette[.base00]
        let (green, red) = (try hex("#00ff00"), try hex("#f38ba8"))
        func line(_ alpha: Double) -> SRGB { composite(green.withAlpha(alpha), surface) }
        let muted = try justReadable(try hex("#808080"), line(0.09))
        #expect(contrastRatio(muted, line(0.1)) < 4.5)

        let settled = secondaryText(try secondaryInput(
            surface, textMuted: muted, textSubtle: try hex("#ffffff"), lineHues: [green, red]
        ))
        #expect(settled.lineAlphas.map { green.withAlpha($0).a } == [31, 31])
        #expect(contrastRatio(settled.textMuted, line(0.12)) >= 4.5)
        #expect(toOKLCH(settled.textMuted).l > toOKLCH(muted).l)
    }

    /// On a near-black surface sunken is lightened, so text loses contrast there: a subtle text
    /// that reads on sunken at the least step (`#040404`; 8-bit rounding gives the step between
    /// the same `#050505` as the full one), but not where it was, brings sunken there and keeps
    /// its value.
    @Test func subtleTextBringsSunkenCloserWhereThatIsEnough() throws {
        let surface = try hex("#020202")
        let steps = closerRecesses(surface, try #require(recessedSurfaces(surface)).sunken)
        #expect(steps == [try hex("#050505"), try hex("#050505"), try hex("#040404")])
        let subtle = try justReadable(try hex("#404040"), steps[2])
        #expect(contrastRatio(subtle, steps[0]) < 4.5)

        let hues = [try hex("#a6e3a1"), try hex("#f38ba8")]
        let settled = secondaryText(try secondaryInput(
            surface, textMuted: try hex("#ffffff"), textSubtle: subtle, lineHues: hues
        ))
        #expect(settled.sunken == steps[2])
        #expect(settled.textSubtle == subtle)
    }

    /// Unimatrix's `docs/theme-tokens.md` "Distinct roles", with the contract's literal, not the
    /// constant: each group in rank order.
    @Test(arguments: FixtureThemes.ids)
    func stateRolesAndTheAccentAndFocusRingKeepApart(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        let groups: [[ThemeRole]] = [
            [.danger, .warning, .success, .info, .agentWaiting],
            [.accent, .focusRing],
        ]
        for group in groups {
            for (rank, lower) in group.enumerated() {
                for higher in group[..<rank] {
                    let (a, b) = (rgb(roles[higher]), rgb(roles[lower]))
                    let distance = deltaE(a, b)
                    #expect(distance >= 0.03, "\(id) \(higher.name) \(a) / \(lower.name) \(b): \(distance)")
                }
            }
        }
    }

    /// Unimatrix's `docs/theme-tokens.md` "Secondary text": each step from `text` to
    /// `text-muted` to `text-subtle` at least 1.10:1, the contract's literal, not the constant.
    @Test(arguments: FixtureThemes.ids)
    func mutedTextKeepsAVisibleStepFromTextAndSubtleText(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        for (a, b) in [(ThemeRole.text, ThemeRole.textMuted), (.textMuted, .textSubtle)] {
            let ratio = contrast(roles, a, b)
            #expect(ratio >= 1.10, "\(id) \(a.name) / \(b.name): \(ratio)")
        }
    }

    /// Input for `secondaryText` in a light theme on a grey `surface`, as derive.rs' panel tests
    /// build it: the lines carry the surface itself, so only raised, hover, sunken and the panel
    /// can ask anything of the text.
    private func lightSecondaryInput(
        _ surface: SRGB,
        toward: @escaping (Double) -> SRGB,
        textMuted: SRGB,
        textSubtle: SRGB,
        raisedScale: Double,
        hoverScale: Double
    ) throws -> SecondaryInput {
        let (sunken, deep) = try #require(recessedSurfaces(surface))
        return SecondaryInput(
            appearance: .light,
            surface: surface,
            toward: toward,
            textMuted: textMuted,
            textSubtle: textSubtle,
            raisedScale: raisedScale,
            hoverScale: hoverScale,
            sunken: sunken,
            deep: deep,
            lineHues: [surface, surface]
        )
    }

    /// The lightest grey that reaches 4.5:1 on the light `backdrop`: a text just readable there.
    private func lightestReadableGrey(on backdrop: SRGB) throws -> SRGB {
        try #require((0...255).reversed().lazy
            .map { UInt8($0) }
            .map { SRGB(r: $0, g: $0, b: $0) }
            .first { contrastRatio($0, backdrop) >= 4.5 })
    }

    /// The panel comes closer the way sunken does: on a light grey surface, where it lies one
    /// step below at `#e8e8e8`, a subtle text that reads on it only at the least step
    /// (`#ebebeb`) brings the panel there and keeps its value.
    @Test func subtleTextBringsThePanelCloserWhereThatIsEnough() throws {
        let surface = try hex("#f2f2f2")
        let subtle = try lightestReadableGrey(on: try hex("#ebebeb"))
        #expect(contrastRatio(subtle, try hex("#e8e8e8")) < 4.5)

        let settled = secondaryText(try lightSecondaryInput(
            surface,
            toward: { share in mix(surface, surface, share) },
            textMuted: try hex("#000000"),
            textSubtle: subtle,
            raisedScale: 1.0,
            hoverScale: 1.0
        ))
        #expect(settled.panel == (try hex("#ebebeb")))
        #expect(settled.textSubtle == subtle)
    }

    /// A light grey theme whose raised (`#e7e7e7`) lies too close to the surface for the panel
    /// one step below it: the panel goes on below raised, to `#e0e0e0`. A muted text that reads
    /// on hover only within the least visible step of the panel would bring hover up to it; hover
    /// stops a visible step short, and the muted text shifts instead.
    @Test func hoverComesCloserOnlyAsFarAsItKeepsAVisibleStepFromThePanel() throws {
        let surface = try hex("#f2f2f2")
        let black = try hex("#000000")
        let muted = try lightestReadableGrey(on: try hex("#dcdcdc"))
        #expect(contrastRatio(muted, try hex("#d9d9d9")) < 4.5)

        let settled = secondaryText(try lightSecondaryInput(
            surface,
            toward: { share in mix(surface, black, share) },
            textMuted: muted,
            textSubtle: black,
            raisedScale: 0.3,
            hoverScale: 0.8
        ))
        #expect(settled.raised == (try hex("#e7e7e7")))
        #expect(settled.panel == (try hex("#e0e0e0")))
        let gap = abs(toOKLCH(settled.hover).l - toOKLCH(settled.panel).l)
        #expect(gap >= 0.02, "\(settled.hover): \(gap)")
        #expect(toOKLCH(settled.textMuted).l < toOKLCH(muted).l)
    }

    /// A text role already a step apart from the one below it, but on its near side (`#808080`
    /// against a muted `#c0c0c0` on a dark surface, `#c0c0c0` against `#606060` on a light one,
    /// both about 2:1), still moves: beyond it and a step apart, so the order holds. The
    /// contract's literal, not the constant.
    @Test func aTextRoleOnTheNearSideOfTheOneBelowMovesBeyondIt() throws {
        for (surface, nearer, fg) in [
            (try hex("#202020"), try hex("#c0c0c0"), try hex("#808080")),
            (try hex("#f0f0f0"), try hex("#606060"), try hex("#c0c0c0")),
        ] {
            #expect(contrastRatio(fg, nearer) >= 1.10)
            let stepped = stepFrom(fg, nearer, surface)
            #expect(contrastRatio(stepped, surface) > contrastRatio(nearer, surface), "\(surface): \(stepped)")
            #expect(contrastRatio(stepped, nearer) >= 1.10, "\(surface): \(stepped)")
        }
    }

    /// The same for `text-muted` against `text-subtle`: a muted text nearer the surface than the
    /// subtle one, though a step apart from it, ends beyond it.
    @Test func mutedTextNearerTheSurfaceThanSubtleTextMovesBeyondIt() throws {
        let surface = try mocha().palette[.base00]
        let (muted, subtle) = (try hex("#9a9a9a"), try hex("#c8c8c8"))
        #expect(contrastRatio(muted, subtle) >= 1.10)

        let hues = [try hex("#a6e3a1"), try hex("#f38ba8")]
        let settled = secondaryText(try secondaryInput(surface, textMuted: muted, textSubtle: subtle, lineHues: hues))
        #expect(contrastRatio(settled.textMuted, surface) > contrastRatio(subtle, surface), "\(settled.textMuted)")
        #expect(contrastRatio(settled.textMuted, subtle) >= 1.10)
    }

    @Test(arguments: FixtureThemes.ids)
    func sameAsRolesTakeTheirSource(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        #expect(roles.diffGutter == roles.surfaceSunken, "\(id)")
        #expect(roles.agentIdle == roles.textSubtle, "\(id)")
        #expect(roles.classGenerated == roles.textDisabled, "\(id)")
    }

    /// `role` laid over `bottom`, as the view shows it.
    private func over(_ roles: ThemeRoles, _ role: ThemeRole, _ bottom: SRGB) -> SRGB {
        composite(roles[role], bottom)
    }

    /// The line backdrop of a diff side over `surface`, and the word backdrop over that.
    private func backdrops(_ roles: ThemeRoles, _ line: ThemeRole, _ word: ThemeRole) -> (line: SRGB, word: SRGB) {
        let line = over(roles, line, rgb(roles.surface))
        return (line, over(roles, word, line))
    }

    private static let diffSides: [(fg: ThemeRole, line: ThemeRole, word: ThemeRole)] = [
        (.diffAddedFg, .diffAddedBg, .diffWordAdded),
        (.diffRemovedFg, .diffRemovedBg, .diffWordRemoved),
    ]

    @Test(arguments: FixtureThemes.ids)
    func diffSignsReach4_5To1OnTheirLineBackdrop(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        for side in Self.diffSides {
            let backdrop = backdrops(roles, side.line, side.word).line
            let ratio = contrastRatio(rgb(roles[side.fg]), backdrop)
            #expect(ratio >= 4.5, "\(id) \(side.fg.name): \(ratio)")
        }
    }

    /// The branch name in the sidebar's open row on raised; a check mark in a hovered row.
    @Test(arguments: FixtureThemes.ids)
    func accentReaches4_5To1OnTheSurfaceRaisedAndHover(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        for bg in [ThemeRole.surface, .surfaceRaised, .surfaceHover] {
            let ratio = contrast(roles, .accent, bg)
            #expect(ratio >= 4.5, "\(id) on \(bg.name): \(ratio)")
        }
    }

    /// A destructive outline button on hover; an error line in a field on sunken.
    @Test(arguments: FixtureThemes.ids)
    func dangerReaches4_5To1OnTheHoverAndTheSunkenSurface(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        for bg in [ThemeRole.surfaceHover, .surfaceSunken] {
            let ratio = contrast(roles, .danger, bg)
            #expect(ratio >= 4.5, "\(id) on \(bg.name): \(ratio)")
        }
    }

    /// The waiting count on a raised tab.
    @Test(arguments: FixtureThemes.ids)
    func agentWaitingReaches4_5To1OnTheRaisedSurface(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        let ratio = contrast(roles, .agentWaiting, .surfaceRaised)
        #expect(ratio >= 4.5, "\(id): \(ratio)")
    }

    @Test(arguments: FixtureThemes.ids)
    func textReaches4_5To1OnTheWordBackdrops(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        for side in Self.diffSides {
            let backdrop = backdrops(roles, side.line, side.word).word
            let ratio = contrastRatio(rgb(roles.text), backdrop)
            #expect(ratio >= 4.5, "\(id) \(side.word.name): \(ratio)")
        }
    }

    /// Code without a syntax role on its line; line numbers, which sit on the line's tint too.
    @Test(arguments: FixtureThemes.ids)
    func textAndMutedTextReach4_5To1OnTheLineBackdrops(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        for side in Self.diffSides {
            let backdrop = backdrops(roles, side.line, side.word).line
            for fg in [ThemeRole.text, .textMuted] {
                let ratio = contrastRatio(rgb(roles[fg]), backdrop)
                #expect(ratio >= 4.5, "\(id) \(fg.name) on \(side.line.name): \(ratio)")
            }
        }
    }

    /// Latte's removed words reach 4.5:1 at alpha 0.16, above the line alpha, so its text keeps
    /// the slot. One Dark's added words miss it at the line alpha, so its text is lightened, its
    /// hue kept. One Dark's surfaces shrink too, but stay above the quarter threshold, so the
    /// raised-mix rule does not apply and only the word rule moves its text; Palenight's text is
    /// already lightened by the raised-mix rule.
    @Test func wordBackdropsShiftTheTextOnlyWhereTheLineAlphaIsNotEnough() {
        let latte = FixtureThemes.theme("catppuccin-latte").roles
        #expect(latte.text == ThemeColor(FixtureThemes.scheme("catppuccin-latte").palette[.base05]))

        let oneDark = FixtureThemes.theme("one-dark").roles
        let slot = toOKLCH(FixtureThemes.scheme("one-dark").palette[.base05])
        let text = toOKLCH(rgb(oneDark.text))
        #expect(text.l > slot.l, "\(slot) \(text)")
        #expect(hueDistance(text.h, slot.h) <= 2.0, "\(slot) \(text)")
        #expect(oneDark.text == .rgb(0xb4bbc9))
    }

    /// Roles of the four schemes whose surfaces shrink but keep more than a quarter of the raised
    /// mix (Rosé Pine Dawn the least, 0.31 of it), pinned so the threshold cannot drift onto
    /// them: deep, sunken, raised, hover, active, text, muted text. Muted text is shifted in all
    /// four, for hover, which cannot come close enough for it a visible step beyond raised.
    /// Rosé Pine Dawn's raised grows back to the least visible step from its surface (`#f3eee9`
    /// lay 0.018 from it), and its deep follows; its text and muted text clear it unchanged.
    @Test func surfacesKeepingAQuarterOfTheirMixShrinkAndLeaveTheText() {
        let expected: [(String, [UInt32])] = [
            ("catppuccin-latte", [0xc4c6ca, 0xedeff3, 0xe2e5eb, 0xcfd2db, 0xc0c2ce, 0x4c4f69, 0x54576e]),
            ("catppuccin-frappe", [0x212335, 0x292c3e, 0x3e4357, 0x484d62, 0x545970, 0xc6d0f5, 0xb6c0e3]),
            ("github-dark-dimmed", [0x13181e, 0x1a1f25, 0x2f353c, 0x383e46, 0x434a53, 0xadbac7, 0x9fabb7]),
            ("rose-pine-dawn", [0xd4cec7, 0xfff9f2, 0xf3ede8, 0xddd8da, 0xcfcad0, 0x575279, 0x5f5b7b]),
        ]
        for (id, colors) in expected {
            let roles = FixtureThemes.theme(id).roles
            let actual = [
                ThemeRole.surfaceDeep, .surfaceSunken, .surfaceRaised, .surfaceHover, .surfaceActive,
                .text, .textMuted,
            ].map { roles[$0] }
            #expect(actual == colors.map(ThemeColor.rgb), "\(id)")
        }
    }

    /// Ayu Light's raised surface would keep 0.02 of its mix and Everforest Dark's 0.04: there
    /// the mixes stay full and the text moves away from the surface instead. The shares are the
    /// contract's literals, not the code's constants.
    @Test func surfacesKeepingLessThanAQuarterOfTheirMixShiftTheTextInstead() {
        for id in ["ayu-light", "everforest-dark-medium"] {
            let p = FixtureThemes.scheme(id).palette
            let (surface, slot) = (p[.base00], p[.base05])
            let roles = FixtureThemes.theme(id).roles
            for (role, share) in [(ThemeRole.surfaceRaised, 0.12), (.surfaceHover, 0.2), (.surfaceActive, 0.3)] {
                #expect(roles[role] == ThemeColor(mix(surface, slot, share)), "\(id) \(role.name)")
            }
            let (surfaceL, slotL, textL) = (toOKLCH(surface).l, toOKLCH(slot).l, lightness(roles.text))
            #expect(abs(textL - surfaceL) > abs(slotL - surfaceL), "\(id)")
        }
    }

    /// The alphas as bytes, added and removed: 77 is the full word alpha, unchanged where `text`
    /// already passes; 41, 56 and 64 are 0.16, 0.22 and 0.25.
    @Test func wordAlphaIsLoweredOnlyWhereTextNeedsIt() {
        let expected: [(String, (UInt8, UInt8))] = [
            ("catppuccin-latte", (77, 41)),
            ("catppuccin-macchiato", (56, 77)),
            ("catppuccin-mocha", (64, 77)),
            ("github", (77, 77)),
        ]
        for (name, alphas) in expected {
            let theme = BundledThemes.resolve(id: name, appearance: .dark)
            #expect(theme.id == name)
            let roles = theme.roles
            #expect(roles.diffWordAdded.a == alphas.0, "\(name) added")
            #expect(roles.diffWordRemoved.a == alphas.1, "\(name) removed")
        }
    }

    @Test(arguments: FixtureThemes.ids)
    func wordAlphasStayAtOrAboveTheirLineAlpha(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        for side in Self.diffSides {
            let (lineAlpha, wordAlpha) = (roles[side.line].a, roles[side.word].a)
            #expect(wordAlpha >= lineAlpha, "\(id) \(side.word.name): \(wordAlpha) < \(lineAlpha)")
        }
    }

    /// With this grey, `text` passes on the bare added line (5.65:1) but not on a word at the
    /// line alpha (4.21:1): the alpha stops there instead of fading the word into the line, and
    /// the text is lightened until it clears that word.
    @Test func wordAlphaNeverDropsBelowTheLineAlpha() throws {
        let faint = withColors(try mocha(), [.base05: try hex("#b0b0b0")])
        let roles = deriveTheme(id: "x", scheme: faint, contrast: .regular).roles
        #expect(roles.diffWordAdded.a == roles.diffAddedBg.a)
    }

    /// Unimatrix's `docs/theme-tokens.md` "Syntax roles": code sits on the surface and on both
    /// line backdrops at 4.5:1, and on both word backdrops at 3:1.
    @Test(arguments: FixtureThemes.ids)
    func syntaxRolesReach4_5To1OnSurfaceAndLinesAnd3To1OnWords(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        var code = [("surface", rgb(roles.surface), 4.5)]
        for side in Self.diffSides {
            let (line, word) = backdrops(roles, side.line, side.word)
            code += [(side.line.name, line, 4.5), (side.word.name, word, 3.0)]
        }
        for role in SyntaxRole.allCases {
            for (backdrop, color, min) in code {
                let ratio = contrastRatio(rgb(roles.syntax(role)), color)
                #expect(ratio >= min, "\(id) \(role.role.name) on \(backdrop): \(ratio)")
            }
        }
    }

    /// The roles a high-contrast scheme sets further from the surface (Unimatrix's
    /// `docs/theme-tokens.md` "Contrast rule").
    private static let highContrastRoles: [ThemeRole] = [
        .text, .border, .borderStrong, .borderControl, .surfaceRaised, .surfaceHover, .surfaceActive,
    ]

    private static let highContrastIDs = ["github-light-high-contrast", "github-dark-high-contrast"]

    @Test(arguments: highContrastIDs)
    func highContrastSetsTheRolesFurtherFromTheSurfaceThanRegular(_ id: String) {
        let scheme = FixtureThemes.scheme(id)
        let regular = deriveTheme(id: id, scheme: scheme, contrast: .regular).roles
        let high = deriveTheme(id: id, scheme: scheme, contrast: .high).roles
        for role in Self.highContrastRoles {
            let (regular, high) = (contrast(regular, role, .surface), contrast(high, role, .surface))
            #expect(high > regular, "\(id) \(role.name): \(high) <= \(regular)")
        }
    }

    @Test func highContrastSchemesContrastMoreThanTheirRegularCounterparts() {
        for (regular, high) in [
            ("github", "github-light-high-contrast"),
            ("github-dark", "github-dark-high-contrast"),
        ] {
            let (regularRoles, highRoles) = (FixtureThemes.theme(regular).roles, FixtureThemes.theme(high).roles)
            for role in Self.highContrastRoles {
                let (regularRatio, highRatio) = (
                    contrast(regularRoles, role, .surface),
                    contrast(highRoles, role, .surface)
                )
                #expect(
                    highRatio > regularRatio,
                    "\(high) \(role.name): \(highRatio) <= \(regular) \(regularRatio)"
                )
            }
        }
    }

    @Test(arguments: highContrastIDs)
    func highContrastControlBorderReaches4_5To1OnSurfaceRaisedSunkenAndPanel(_ id: String) {
        let roles = FixtureThemes.theme(id).roles
        for bg in [ThemeRole.surface, .surfaceRaised, .surfaceSunken, .surfacePanel] {
            let ratio = contrast(roles, .borderControl, bg)
            #expect(ratio >= 4.5, "\(id) on \(bg.name): \(ratio)")
        }
    }

    /// Light High Contrast's `base05` is a dark grey (`#343b43`), its `base07` near black; Dark
    /// High Contrast's `base07` is white. Mocha's `base07` is a lavender darker than its `base05`,
    /// so it keeps `base05`.
    @Test func highContrastTakesTheTextFromBase07OnlyWhereItIsFurtherFromTheSurface() throws {
        #expect(FixtureThemes.theme("github-light-high-contrast").roles.text == .rgb(0x0e1116))
        #expect(FixtureThemes.theme("github-dark-high-contrast").roles.text == .rgb(0xffffff))

        let mocha = deriveTheme(id: "x", scheme: try mocha(), contrast: .high).roles
        #expect(mocha.text == .rgb(0xcdd6f4))
    }

    /// GitHub's `base08` and `base0B`, Macchiato's `base0A` and `base0D` clear every code
    /// backdrop, so the scheme's look is kept exactly; `base0D` only because the word backdrops
    /// ask for 3:1, not 4.5:1. Macchiato's `base03` comments sit at about 1.8:1 on the surface
    /// and are lightened, their hue kept.
    @Test func syntaxRolesKeepAReadableSlotAndShiftOnlyWhatFallsShort() throws {
        let github = BundledThemes.resolve(id: "github", appearance: .light).roles
        #expect(github.syntax(.variable) == .rgb(0x953800))
        #expect(github.syntax(.string) == .rgb(0x0a3069))

        let macchiato = BundledThemes.resolve(id: "catppuccin-macchiato", appearance: .dark).roles
        #expect(macchiato.syntax(.type) == .rgb(0xeed49f))
        #expect(macchiato.syntax(.function) == .rgb(0x8aadf4))
        let slot = toOKLCH(try hex("#494d64"))
        let comment = toOKLCH(rgb(macchiato.syntax(.comment)))
        #expect(comment.l > slot.l)
        #expect(hueDistance(comment.h, slot.h) <= 1.0)
    }
}
