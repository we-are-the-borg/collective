// Derives the color roles from a base16/base24 scheme, a port of Unimatrix Zero's
// `theme/derive.rs` and its `Roles` (`theme/mod.rs`), commit 43f1307; there `docs/decisions.md`
// §13 and `docs/theme-tokens.md` "Color roles" and "Syntax roles". The rules hold for every
// scheme; none gets special treatment beyond the `ThemeContrast` its caller passes. The UI reads
// only roles, never a scheme.

/// A color role of the contract, for code that walks all roles rather than naming one. `allCases`
/// is the order of the table in Unimatrix's `docs/theme-tokens.md`.
public enum ThemeRole: CaseIterable, Sendable {
    case surfaceDeep
    case surfaceSunken
    case surfacePanel
    case surface
    case surfaceRaised
    case surfaceHover
    case surfaceActive
    case text
    case textMuted
    case textSubtle
    case textDisabled
    case border
    case borderStrong
    case borderControl
    case focusRing
    case accent
    case accentOn
    case accentHover
    case accentActive
    case diffAddedFg
    case diffRemovedFg
    case diffAddedBg
    case diffRemovedBg
    case diffWordAdded
    case diffWordRemoved
    case diffGutter
    case agentWorking
    case agentWaiting
    case agentDone
    case agentIdle
    case agentError
    case classCode
    case classTest
    case classDocs
    case classConfig
    case classGenerated
    case unseen
    case warning
    case warningBg
    case danger
    case success
    case info
    case scrim
    case syntaxComment
    case syntaxVariable
    case syntaxConstant
    case syntaxType
    case syntaxString
    case syntaxSpecial
    case syntaxFunction
    case syntaxKeyword
    case syntaxEmbedded

    /// The contract name without the `--`, e.g. `surface-deep`.
    public var name: String {
        switch self {
        case .surfaceDeep: "surface-deep"
        case .surfaceSunken: "surface-sunken"
        case .surfacePanel: "surface-panel"
        case .surface: "surface"
        case .surfaceRaised: "surface-raised"
        case .surfaceHover: "surface-hover"
        case .surfaceActive: "surface-active"
        case .text: "text"
        case .textMuted: "text-muted"
        case .textSubtle: "text-subtle"
        case .textDisabled: "text-disabled"
        case .border: "border"
        case .borderStrong: "border-strong"
        case .borderControl: "border-control"
        case .focusRing: "focus-ring"
        case .accent: "accent"
        case .accentOn: "accent-on"
        case .accentHover: "accent-hover"
        case .accentActive: "accent-active"
        case .diffAddedFg: "diff-added-fg"
        case .diffRemovedFg: "diff-removed-fg"
        case .diffAddedBg: "diff-added-bg"
        case .diffRemovedBg: "diff-removed-bg"
        case .diffWordAdded: "diff-word-added"
        case .diffWordRemoved: "diff-word-removed"
        case .diffGutter: "diff-gutter"
        case .agentWorking: "agent-working"
        case .agentWaiting: "agent-waiting"
        case .agentDone: "agent-done"
        case .agentIdle: "agent-idle"
        case .agentError: "agent-error"
        case .classCode: "class-code"
        case .classTest: "class-test"
        case .classDocs: "class-docs"
        case .classConfig: "class-config"
        case .classGenerated: "class-generated"
        case .unseen: "unseen"
        case .warning: "warning"
        case .warningBg: "warning-bg"
        case .danger: "danger"
        case .success: "success"
        case .info: "info"
        case .scrim: "scrim"
        case .syntaxComment: "syntax-comment"
        case .syntaxVariable: "syntax-variable"
        case .syntaxConstant: "syntax-constant"
        case .syntaxType: "syntax-type"
        case .syntaxString: "syntax-string"
        case .syntaxSpecial: "syntax-special"
        case .syntaxFunction: "syntax-function"
        case .syntaxKeyword: "syntax-keyword"
        case .syntaxEmbedded: "syntax-embedded"
        }
    }
}

/// Every color role of the contract; components name roles, never colors.
public struct ThemeRoles: Sendable, Hashable {
    /// Deepest surface, e.g. settings navigation.
    public var surfaceDeep: ThemeColor
    /// Recessed surface: title and status bar, backdrop beside code.
    public var surfaceSunken: ThemeColor
    /// Side panels: the sidebar.
    public var surfacePanel: ThemeColor
    /// Base of the view.
    public var surface: ThemeColor
    /// Second-level surface: cards, popovers, fields.
    public var surfaceRaised: ThemeColor
    /// Surface under the pointer.
    public var surfaceHover: ThemeColor
    /// Pressed or selected surface.
    public var surfaceActive: ThemeColor
    /// Body text.
    public var text: ThemeColor
    /// Secondary text.
    public var textMuted: ThemeColor
    /// Tertiary text: metadata, hints.
    public var textSubtle: ThemeColor
    /// Disabled text.
    public var textDisabled: ThemeColor
    /// Borders and dividers.
    public var border: ThemeColor
    /// Emphasized border.
    public var borderStrong: ThemeColor
    /// Edge of controls: text fields, outline buttons, checkboxes, the search field.
    public var borderControl: ThemeColor
    /// Visible keyboard focus.
    public var focusRing: ThemeColor
    /// Accent, e.g. branch name.
    public var accent: ThemeColor
    /// Text on `accent`.
    public var accentOn: ThemeColor
    /// Filled accent control under the pointer: primary button, a switch that is on, a selected
    /// radio.
    public var accentHover: ThemeColor
    /// Filled accent control while pressed.
    public var accentActive: ThemeColor
    /// Text of added lines.
    public var diffAddedFg: ThemeColor
    /// Text of removed lines.
    public var diffRemovedFg: ThemeColor
    /// Backdrop of added lines.
    public var diffAddedBg: ThemeColor
    /// Backdrop of removed lines.
    public var diffRemovedBg: ThemeColor
    /// Added words within the line.
    public var diffWordAdded: ThemeColor
    /// Removed words within the line.
    public var diffWordRemoved: ThemeColor
    /// Line number column.
    public var diffGutter: ThemeColor
    /// Agent working.
    public var agentWorking: ThemeColor
    /// Agent waiting for you.
    public var agentWaiting: ThemeColor
    /// Agent done.
    public var agentDone: ThemeColor
    /// Agent idle.
    public var agentIdle: ThemeColor
    /// Agent with error.
    public var agentError: ThemeColor
    /// File class code.
    public var classCode: ThemeColor
    /// File class test.
    public var classTest: ThemeColor
    /// File class docs.
    public var classDocs: ThemeColor
    /// File class configuration.
    public var classConfig: ThemeColor
    /// File class generated.
    public var classGenerated: ThemeColor
    /// Unread change.
    public var unseen: ThemeColor
    /// Warning.
    public var warning: ThemeColor
    /// Backdrop of a warning.
    public var warningBg: ThemeColor
    /// Danger, destructive action.
    public var danger: ThemeColor
    /// Success.
    public var success: ThemeColor
    /// Notice.
    public var info: ThemeColor
    /// Dimming behind dialogs.
    public var scrim: ThemeColor
    /// Comments, doc comments.
    public var syntaxComment: ThemeColor
    /// Variables, properties, tags, markup link text.
    public var syntaxVariable: ThemeColor
    /// Numbers, booleans, constants, attributes.
    public var syntaxConstant: ThemeColor
    /// Types, classes, constructors, markup bold.
    public var syntaxType: ThemeColor
    /// Strings, characters, markup code.
    public var syntaxString: ThemeColor
    /// Builtins, escape characters, regular expressions, markup quotes.
    public var syntaxSpecial: ThemeColor
    /// Functions, methods, headings.
    public var syntaxFunction: ThemeColor
    /// Keywords, storage, markup italic.
    public var syntaxKeyword: ThemeColor
    /// Embedded language tags, deprecated.
    public var syntaxEmbedded: ThemeColor

    /// The color of `role`.
    public subscript(role: ThemeRole) -> ThemeColor {
        switch role {
        case .surfaceDeep: surfaceDeep
        case .surfaceSunken: surfaceSunken
        case .surfacePanel: surfacePanel
        case .surface: surface
        case .surfaceRaised: surfaceRaised
        case .surfaceHover: surfaceHover
        case .surfaceActive: surfaceActive
        case .text: text
        case .textMuted: textMuted
        case .textSubtle: textSubtle
        case .textDisabled: textDisabled
        case .border: border
        case .borderStrong: borderStrong
        case .borderControl: borderControl
        case .focusRing: focusRing
        case .accent: accent
        case .accentOn: accentOn
        case .accentHover: accentHover
        case .accentActive: accentActive
        case .diffAddedFg: diffAddedFg
        case .diffRemovedFg: diffRemovedFg
        case .diffAddedBg: diffAddedBg
        case .diffRemovedBg: diffRemovedBg
        case .diffWordAdded: diffWordAdded
        case .diffWordRemoved: diffWordRemoved
        case .diffGutter: diffGutter
        case .agentWorking: agentWorking
        case .agentWaiting: agentWaiting
        case .agentDone: agentDone
        case .agentIdle: agentIdle
        case .agentError: agentError
        case .classCode: classCode
        case .classTest: classTest
        case .classDocs: classDocs
        case .classConfig: classConfig
        case .classGenerated: classGenerated
        case .unseen: unseen
        case .warning: warning
        case .warningBg: warningBg
        case .danger: danger
        case .success: success
        case .info: info
        case .scrim: scrim
        case .syntaxComment: syntaxComment
        case .syntaxVariable: syntaxVariable
        case .syntaxConstant: syntaxConstant
        case .syntaxType: syntaxType
        case .syntaxString: syntaxString
        case .syntaxSpecial: syntaxSpecial
        case .syntaxFunction: syntaxFunction
        case .syntaxKeyword: syntaxKeyword
        case .syntaxEmbedded: syntaxEmbedded
        }
    }
}

/// A scheme turned into roles: what the views get.
public struct Theme: Sendable, Hashable {
    public var id: String
    public var name: String
    public var author: String?
    public var appearance: ThemeAppearance
    public var roles: ThemeRoles
}

/// How far a scheme sets its roles apart. A scheme file has no flag for it, so the family table
/// supplies it (`ThemeFamily`).
enum ThemeContrast: Sendable, Hashable {
    case regular
    /// A scheme meant to read more sharply: `text` from `base07` where that is further from the
    /// surface, larger surface and border mixes, a stronger control border.
    case high
}

/// Minimum contrast for text roles against `surface` (WCAG AA body text).
private let textContrast = 4.5

/// Minimum contrast for three roles that need not read as body text: disabled text against
/// `surface`, where 4.5 would erase the step below `text-subtle` (WCAG exempts disabled text);
/// the focus ring and the control border against the surfaces controls sit on, both non-text
/// contrast (WCAG 1.4.11).
private let softContrast = 3.0

/// Minimum contrast for syntax roles on the word backdrops (WCAG large text): word marks are
/// short, already emphasized spans, and 4.5 there pulls every role to nearly the same contrast.
private let syntaxWordContrast = 3.0

/// OKLCH lightness steps from `surface` to `surface-sunken` and on to `surface-deep`. About 0.02
/// is the least difference visible between adjacent panels (`minSurfaceStep`); 0.03 separates
/// them clearly without becoming a new layer.
private let surfaceLightnessStep = 0.03

/// The least OKLCH lightness a surface keeps from the one below it: about the least difference
/// visible between adjacent panels. Raised and hover keep it wherever the layering rule puts
/// them (see `surfacesAndText`); sunken and the panel keep it when they move closer for the
/// secondary text on them. Sunken, raised and the panel keep it from `surface`, hover from
/// raised, which it sits on in a popover; raised and hover keep it from the panel, which the
/// sidebar draws its selected and hovered rows on.
private let minSurfaceStep = 0.02

/// Surface steps `surface-deep` keeps below `surface-raised` in a light theme: there raised sits
/// below `surface`, and two steps below `surface` left the gap between file sections about as
/// light as the file header.
private let deepBelowRaisedSteps = 3.0

/// Shares of `base05` mixed into `base00` for the raised, hover and active surfaces. Each step is
/// clearly apart from the last; they are scaled down together where text would lose its contrast
/// (see `surfaceScale`), unless raised would keep less than `minRaisedShare`; there the text is
/// shifted instead (see `surfacesAndText`).
private let raisedMix = 0.12
private let hoverMix = 0.2
private let activeMix = 0.3

/// The least share of `base05` the raised surface keeps when the mixes shrink for the text: a
/// quarter of `raisedMix`. Below it raised is barely apart from the surface (Ayu Light's would
/// keep 0.002), so the text is shifted instead. A quarter leaves the schemes that shrink only a
/// little as they are; Rosé Pine Dawn keeps the least of them, 0.037.
private let minRaisedShare = raisedMix / 4.0

/// Shares of `base05` mixed into `base00` for the borders: plain lines stay quiet, the strong
/// border reads as an edge. Borders carry no text.
private let borderMix = 0.25
private let borderStrongMix = 0.4

/// Share of `base05` the control border starts from before its lightness is shifted to
/// `softContrast`: that of the strong border, so a control's edge is never weaker than a heavy
/// divider and moves only as far as the floor asks.
private let borderControlMix = borderStrongMix

/// Factor on every surface and border share of `base05` in a high-contrast scheme: half as far
/// again, so raised, hover, active and the borders stand clearly apart while active (0.45) stays
/// nearer the surface than `base05` and text keeps ample contrast on it.
private let highContrastMixFactor = 1.5

/// Minimum contrast for the control border in a high-contrast scheme: the text floor instead of
/// `softContrast`, so a control's edge reads as firmly as its label.
private let highContrastControl = textContrast

/// Step by which `surfaceScale` lowers the surface shares and `wordBackdrop` the word alpha.
private let scaleStep = 0.01

/// The least contrast between `text-muted` and the text roles beside it, `text` and
/// `text-subtle`, so the three read as three steps. Met by moving muted towards `text`, then
/// `text` away from muted, which only Material Lighter needs: its panel lies beyond its hover,
/// and the muted text that reads there would pass `text`. 1.15 would move `text` in Catppuccin
/// Latte and Rosé Pine Dawn too, whose muted text sits 1.128 and 1.132 from it, held by hover.
private let minTextStep = 1.10

/// Shares of `base00` mixed into the text color for the quieter text roles.
private let textMutedMix = 0.15
private let textSubtleMix = 0.3
private let textDisabledMix = 0.5

/// Alpha of whole diff lines: a tint that leaves syntax colors readable.
private let diffLineAlpha = 0.12

/// The least alpha a diff line keeps when it is lowered for `text-muted` on it. At 0.1 the
/// faintest bundled line, Solarized Dark's removed one, still lies ΔE OK 0.0205 from its surface,
/// so it reads as tinted; at 0.09 it would lie 0.018. A tint differs mostly in hue and chroma,
/// so this is the full OKLab distance, held against `minSurfaceStep` as the distance a step of
/// that much lightness alone would give; the line's lightness differs by only 0.012.
private let minDiffLineAlpha = 0.1

/// Alpha of changed words inside a diff line: clearly above the line tint. Lowered towards
/// `diffLineAlpha` where `text` would lose its contrast (see `wordBackdrop`); where even that is
/// not enough, `text` is shifted (see `surfacesAndText`).
private let diffWordAlpha = 0.3

/// Alpha of the warning background, as quiet as a diff line.
private let warningBgAlpha = 0.1

/// Alpha of the scrim behind dialogs. A dark theme darkens with its deepest surface and needs
/// more cover; a light one tints with its text color.
private let scrimDarkAlpha = 0.6
private let scrimLightAlpha = 0.35

/// OKLCH lightness step from `accent` to `accent-hover` and on to `accent-active`: the surface
/// step, clearly visible. Larger steps drain the light accents of dark themes against the sRGB
/// edge (Ayu Mirage's active at 0.05 keeps 0.03 of its 0.09 chroma, at 0.03 still 0.05).
private let accentLightnessStep = surfaceLightnessStep

/// Fine search step in OKLCH lightness; 8-bit channels are coarse near black.
private let lightnessSearchStep = 0.005

/// Derives every role of the contract from `scheme`, as the theme `id`, at `contrast`.
func deriveTheme(id: String, scheme: Scheme, contrast: ThemeContrast) -> Theme {
    let p = scheme.palette
    let appearance = scheme.appearance

    let surface = p[.base00]
    // One direction always has at least 0.5 of OKLCH lightness, far more than two steps need,
    // so the fallback is never reached (see the test sweeping every grey); the surface itself
    // keeps the theme usable should it ever be.
    let (initialSunken, initialDeep) = recessedSurfaces(surface) ?? (surface, surface)
    let (textSource, mixFactor, controlContrast) = switch contrast {
    case .regular: (p[.base05], 1.0, softContrast)
    case .high: (
            highContrastText(surface, p[.base05], p[.base07]),
            highContrastMixFactor,
            highContrastControl
        )
    }
    // Every surface and border share passes through here, so the factor reaches all of them and
    // the quarter rule, which compares shares of the same `toward`, keeps its meaning. The mixes
    // stay toward `base05` even where the text comes from `base07`: the factor is the decided
    // gain, and `base07` on top made Light High Contrast's active surface a mid grey (3.5:1).
    let toward = { (share: Double) in mix(surface, p[.base05], share * mixFactor) }

    func readable(_ color: SRGB) -> SRGB {
        ensureContrast(color, surface, textContrast)
    }
    // Text that sits on backdrops other than the surface clears all of them: readable on the
    // surface first, so it keeps its value wherever the other backdrops ask for nothing more.
    func readableOn(_ color: SRGB, _ backdrops: [SRGB]) -> SRGB {
        ensureContrastOn(readable(color), backdrops.map { (bg: $0, min: textContrast) })
    }

    let hues = pickHues(p)
    let (red, orange, yellow) = (hues.red.color, hues.orange.color, hues.yellow.color)
    let (green, cyan, blue, violet) = (hues.green.color, hues.cyan.color, hues.blue.color, hues.violet.color)

    // `text` is settled on the full line alpha; `secondaryText` lowering that alpha for
    // `text-muted` only brings the lines and their words closer to the surface.
    let wordFloors = [green, red].map { hue in
        let line = hue.withAlpha(diffLineAlpha)
        return composite(line, composite(line, surface))
    }
    let settled = surfacesAndText(
        surface: surface,
        toward: toward,
        text: readable(textSource),
        wordFloors: wordFloors
    )
    let secondary = secondaryText(SecondaryInput(
        appearance: appearance,
        surface: surface,
        toward: toward,
        textMuted: settled.textMuted,
        textSubtle: readable(mix(settled.text, surface, textSubtleMix)),
        raisedScale: settled.raisedScale,
        hoverScale: settled.hoverScale,
        sunken: initialSunken,
        deep: initialDeep,
        lineHues: [green, red]
    ))
    let (textMuted, textSubtle) = (secondary.textMuted, secondary.textSubtle)
    let (raised, hover, sunken, deep) = (secondary.raised, secondary.hover, secondary.sunken, secondary.deep)
    let panel = secondary.panel
    // Last, so it keeps every pair it cleared: Material Lighter's panel lies beyond its hover,
    // and the muted text that reads there would pass `text`.
    let text = stepFrom(settled.text, textMuted, surface)
    // On the surface first, then on the panel, where a disabled row of the sidebar sits.
    let textDisabled = ensureContrastOn(
        ensureContrast(mix(text, surface, textDisabledMix), surface, softContrast),
        [(bg: panel, min: softContrast)]
    )
    let active = toward(activeMix * settled.scale)
    let addedBg = green.withAlpha(secondary.lineAlphas[0])
    let removedBg = red.withAlpha(secondary.lineAlphas[1])
    let addedLine = composite(addedBg, surface)
    let removedLine = composite(removedBg, surface)
    // After the light-theme rules, which move `sunken`.
    let borderControl = ensureContrastOn(
        toward(borderControlMix),
        [surface, raised, sunken, panel].map { (bg: $0, min: controlContrast) }
    )

    let accent = readableOn(violet, [raised, hover, panel])
    // Away from the surface, as every contrast shift moves: darker in a light theme, lighter in
    // a dark one.
    let away = toOKLCH(accent).l >= toOKLCH(surface).l ? 1.0 : -1.0
    let accentHover = stepAccent(accent, away)
    let accentActive = stepAccent(accentHover, away)
    let accentOn = ensureContrastOn(
        p[.base00],
        [accent, accentHover, accentActive].map { (bg: $0, min: textContrast) }
    )
    let yellowText = ThemeColor(readable(yellow))
    let cyanText = ThemeColor(readable(cyan))
    let blueText = ThemeColor(readable(blue))
    let orangeText = ThemeColor(readable(orange))
    // Ranked as `pickHues` ranks their hues, which keeps them apart where another candidate
    // fits; this moves what is still too close: a hue that found none, or a contrast shift.
    let states = keepApart(surface, [
        readableOn(red, [hover, sunken, panel]),
        readable(yellow),
        readable(green),
        readable(cyan),
        readableOn(orange, [raised, panel]),
    ])
    let (danger, warning, success, info, agentWaiting) = (states[0], states[1], states[2], states[3], states[4])
    // On every surface a focusable control sits on; `class-code` keeps the plain blue text,
    // `agent-working` its own shift for the panel.
    let focusRing = keepApart(surface, [
        accent,
        ensureContrastOn(blue, [surface, raised, hover, sunken, panel].map { (bg: $0, min: softContrast) }),
    ])[1]

    // Code sits on the surface and on every diff backdrop. The slots apply as the scheme fills
    // them (Unimatrix v1 §28 "Syntax colors") and move only where one of the backdrops needs it.
    let wordAdded = wordBackdrop(green, addedLine, text)
    let wordRemoved = wordBackdrop(red, removedLine, text)
    let codeBackdrops: [(bg: SRGB, min: Double)] = [
        (surface, textContrast),
        (addedLine, textContrast),
        (removedLine, textContrast),
        (composite(wordAdded, addedLine), syntaxWordContrast),
        (composite(wordRemoved, removedLine), syntaxWordContrast),
    ]
    func syntax(_ role: SyntaxRole) -> ThemeColor {
        ThemeColor(ensureContrastOn(p[role.slot], codeBackdrops))
    }

    let scrim = switch appearance {
    case .dark: deep.withAlpha(scrimDarkAlpha)
    case .light: text.withAlpha(scrimLightAlpha)
    }

    return Theme(
        id: id,
        name: scheme.name,
        author: scheme.author,
        appearance: appearance,
        roles: ThemeRoles(
            surfaceDeep: ThemeColor(deep),
            surfaceSunken: ThemeColor(sunken),
            surfacePanel: ThemeColor(panel),
            surface: ThemeColor(surface),
            surfaceRaised: ThemeColor(raised),
            surfaceHover: ThemeColor(hover),
            surfaceActive: ThemeColor(active),
            text: ThemeColor(text),
            textMuted: ThemeColor(textMuted),
            textSubtle: ThemeColor(textSubtle),
            textDisabled: ThemeColor(textDisabled),
            border: ThemeColor(toward(borderMix)),
            borderStrong: ThemeColor(toward(borderStrongMix)),
            borderControl: ThemeColor(borderControl),
            focusRing: ThemeColor(focusRing),
            accent: ThemeColor(accent),
            accentOn: ThemeColor(accentOn),
            accentHover: ThemeColor(accentHover),
            accentActive: ThemeColor(accentActive),
            diffAddedFg: ThemeColor(readableOn(green, [addedLine])),
            diffRemovedFg: ThemeColor(readableOn(red, [removedLine])),
            diffAddedBg: addedBg,
            diffRemovedBg: removedBg,
            diffWordAdded: wordAdded,
            diffWordRemoved: wordRemoved,
            diffGutter: ThemeColor(sunken),
            // The agent states sit in the sidebar, so they read on the panel; the file classes and
            // `success` keep the plain text of their hues, `danger` its own shift.
            agentWorking: ThemeColor(readableOn(blue, [panel])),
            // Not in abnahme, which had no waiting state; derived like `class-config`, but also
            // readable on raised, where the waiting count sits on a tab.
            agentWaiting: ThemeColor(agentWaiting),
            agentDone: ThemeColor(readableOn(green, [panel])),
            agentIdle: ThemeColor(textSubtle),
            agentError: ThemeColor(readableOn(red, [panel])),
            classCode: blueText,
            classTest: cyanText,
            classDocs: yellowText,
            classConfig: orangeText,
            classGenerated: ThemeColor(textDisabled),
            unseen: yellowText,
            warning: ThemeColor(warning),
            warningBg: yellow.withAlpha(warningBgAlpha),
            // Only `danger` sits on hover and sunken; `agent-error` reads on the panel alone.
            danger: ThemeColor(danger),
            success: ThemeColor(success),
            info: ThemeColor(info),
            scrim: scrim,
            syntaxComment: syntax(.comment),
            syntaxVariable: syntax(.variable),
            syntaxConstant: syntax(.constant),
            syntaxType: syntax(.type),
            syntaxString: syntax(.string),
            syntaxSpecial: syntax(.special),
            syntaxFunction: syntax(.function),
            syntaxKeyword: syntax(.keyword),
            syntaxEmbedded: syntax(.embedded)
        )
    )
}

/// The slot `text` starts from in a high-contrast scheme: `base07` where it lies further from
/// `surface` than `base05`, which some keep a dark grey (GitHub Light High Contrast's `#343b43`
/// against `#0e1116`); otherwise `base05`.
private func highContrastText(_ surface: SRGB, _ base05: SRGB, _ base07: SRGB) -> SRGB {
    contrastRatio(base07, surface) > contrastRatio(base05, surface) ? base07 : base05
}

/// `ranked`, highest rank first, with each role that lies within `minDistinctDeltaE` of one
/// ranked above it moved away from `surface` in OKLCH lightness, hue and chroma kept as far as
/// sRGB allows, until it clears all of them; away, so it keeps every contrast it had. White or
/// black where the lightness range ends first.
private func keepApart(_ surface: SRGB, _ ranked: [SRGB]) -> [SRGB] {
    var ranked = ranked
    for rank in ranked.indices.dropFirst() {
        let above = ranked[..<rank]
        func apart(_ color: SRGB) -> Bool {
            above.allSatisfy { deltaE(color, $0) >= minDistinctDeltaE }
        }
        let role = ranked[rank]
        if apart(role) {
            continue
        }
        let away = toOKLCH(role).l >= toOKLCH(surface).l ? 1.0 : -1.0
        ranked[rank] = lightnessSteps(role, away, first: lightnessSearchStep).first(where: apart)
            ?? (away > 0.0 ? SRGB(0xffffff) : SRGB(0x000000))
    }
    return ranked
}

/// `surface-sunken` and `surface-deep`: darker than `surface` by `surfaceLightnessStep` each, as
/// the contract asks; lighter only when the surface is too dark to leave room below. `nil` where
/// abnahme threw: neither direction had room.
func recessedSurfaces(_ surface: SRGB) -> (sunken: SRGB, deep: SRGB)? {
    for direction in [-1.0, 1.0] {
        if let sunken = stepLightness(surface, direction, surfaceLightnessStep),
           let deep = stepLightness(sunken, direction, surfaceLightnessStep) {
            return (sunken, deep)
        }
    }
    return nil
}

/// `sunken`, then the positions closer to `surface` it may take for the text on it: stepped from
/// `surface` the way `sunken` lies, by each `lightnessSearchStep` less than
/// `surfaceLightnessStep`, down to `minSurfaceStep`.
func closerRecesses(_ surface: SRGB, _ sunken: SRGB) -> [SRGB] {
    let direction = toOKLCH(sunken).l < toOKLCH(surface).l ? -1.0 : 1.0
    let steps = UInt32(((surfaceLightnessStep - minSurfaceStep) / lightnessSearchStep).rounded())
    // Counted up from the floor, so the last step is exactly `minSurfaceStep`.
    let closer = (0..<steps).reversed().compactMap { step in
        stepLightness(surface, direction, minSurfaceStep + Double(step) * lightnessSearchStep)
    }
    return [sunken] + closer
}

/// `surface-panel`, then the positions closer to `surface` it may take for the text on it. It
/// starts one surface step below `surface` wherever a color lies there, so on the far side of
/// the surface from raised and hover; unlike sunken and deep, which need room for two steps, it
/// lightens only on black. From there it moves further in `lightnessSearchStep`s until it lies
/// `minSurfaceStep` of OKLCH lightness from each of `others`, the surfaces drawn on it; it keeps
/// its start should the range end first. The closer positions step from `surface` by each
/// `lightnessSearchStep` less than that, down to `minSurfaceStep`, leaving out those within the
/// step of one of `others`.
private func panelSteps(_ surface: SRGB, _ others: [SRGB]) -> [SRGB] {
    // One direction always has at least 0.5 of OKLCH lightness, so the surface is never taken.
    let start = [-1.0, 1.0].lazy.compactMap { direction in
        stepLightness(surface, direction, surfaceLightnessStep).map { (direction: direction, panel: $0) }
    }.first
    guard let (direction, panel) = start else {
        return [surface]
    }
    // The start, then the steps beyond it, counted so `moved` is 0 for the start itself.
    let further = visiblyApart(panel, others)
        ? (offset: 0, element: panel)
        : lightnessSteps(panel, direction, first: lightnessSearchStep)
            .enumerated()
            .first { visiblyApart($0.element, others) }
            .map { (offset: $0.offset + 1, element: $0.element) }
    guard let (moved, placed) = further else {
        return [panel]
    }
    let steps = UInt32(moved)
        + UInt32(((surfaceLightnessStep - minSurfaceStep) / lightnessSearchStep).rounded())
    // Counted up from the floor, so the last step is exactly `minSurfaceStep`.
    let closer = (0..<steps).reversed()
        .compactMap { step in stepLightness(surface, direction, minSurfaceStep + Double(step) * lightnessSearchStep) }
        .filter { visiblyApart($0, others) }
    return [placed] + closer
}

/// Whether `color` lies at least `minSurfaceStep` of OKLCH lightness from each of `others`.
private func visiblyApart(_ color: SRGB, _ others: [SRGB]) -> Bool {
    let l = toOKLCH(color).l
    return others.allSatisfy { abs(l - toOKLCH($0).l) >= minSurfaceStep }
}

/// The surface mixed `share * scale` toward `base05`, then at each `scaleStep` less of `scale`,
/// for as long as it keeps `minSurfaceStep` of OKLCH lightness from `below`; the first is always
/// there, wherever it lies.
func closerMixes(_ toward: (Double) -> SRGB, _ share: Double, _ scale: Double, _ below: SRGB) -> [SRGB] {
    let below = toOKLCH(below).l
    let steps = UInt32((scale / scaleStep).rounded())
    var mixes: [SRGB] = []
    for step in 0...steps {
        let mixed = toward(share * (scale - Double(step) * scaleStep))
        guard step == 0 || abs(toOKLCH(mixed).l - below) >= minSurfaceStep else { break }
        mixes.append(mixed)
    }
    return mixes
}

/// The light-theme layering rules: `sunken` raised to one surface step above `raised`, `deep`
/// lowered to `deepBelowRaisedSteps` below it, each only where it is not there yet. Either keeps
/// its value should the lightness range end first.
private func lightRecessedSurfaces(_ sunken: SRGB, _ deep: SRGB, _ raised: SRGB) -> (sunken: SRGB, deep: SRGB) {
    let raised = toOKLCH(raised).l
    let floor = raised + surfaceLightnessStep
    let ceiling = raised - deepBelowRaisedSteps * surfaceLightnessStep
    func reach(_ color: SRGB, _ direction: Double, _ bound: Double) -> SRGB {
        if direction * (toOKLCH(color).l - bound) >= 0.0 {
            return color
        }
        let hue = toOKLCH(color).h
        func drift(_ candidate: SRGB) -> Double {
            hueDistance(toOKLCH(candidate).h, hue)
        }
        var reaching = lightnessSteps(color, direction, first: lightnessSearchStep)
            .lazy
            .filter { direction * (toOKLCH($0).l - bound) >= 0.0 }
            .makeIterator()
        // On a pale, lightly tinted surface 8-bit rounding turns the hue by about a degree on
        // one step and not on the next (Everforest Light's deep: 0.87 against 0.02 degrees), so
        // the next step that also reaches wins where it keeps the hue better.
        guard let first = reaching.next() else {
            return color
        }
        if let next = reaching.next(), drift(next) < drift(first) {
            return next
        }
        return first
    }
    return (reach(sunken, 1.0, floor), reach(deep, -1.0, ceiling))
}

/// The nearest color whose 8-bit value lies at least `step` from `color` in `direction` (-1 or
/// 1), hue and chroma kept; `nil` if the lightness range ends first.
func stepLightness(_ color: SRGB, _ direction: Double, _ step: Double) -> SRGB? {
    let l = toOKLCH(color).l
    return shiftLightness(color, direction, first: step) {
        direction * ($0 - l) >= step
    }
}

/// `color` moved `accentLightnessStep` in `direction` (-1 or 1), hue and chroma kept as far as
/// sRGB allows; white or black where the lightness range ends first, as close as it gets, so
/// near the end hover and active may coincide but never turn back towards the surface.
func stepAccent(_ color: SRGB, _ direction: Double) -> SRGB {
    let l = toOKLCH(color).l
    return shiftLightness(color, direction, first: accentLightnessStep) {
        direction * ($0 - l) >= accentLightnessStep
    } ?? (direction > 0.0 ? SRGB(0xffffff) : SRGB(0x000000))
}

/// The first color, moving from `color` in `direction` (-1 or 1) by `first` and then by
/// `lightnessSearchStep`, whose 8-bit lightness is `reached`; hue and chroma kept. `nil` if the
/// lightness range ends first. Private, so it stays apart from ColorMath's contrast search of
/// the same name.
private func shiftLightness(
    _ color: SRGB,
    _ direction: Double,
    first: Double,
    reached: (Double) -> Bool
) -> SRGB? {
    lightnessSteps(color, direction, first: first).first { reached(toOKLCH($0).l) }
}

/// The colors from `color` in `direction` (-1 or 1), first by `first` and then by
/// `lightnessSearchStep`, until the lightness range ends; hue and chroma kept. Lazy, so a search
/// derives only the steps it looks at.
private func lightnessSteps(
    _ color: SRGB,
    _ direction: Double,
    first: Double
) -> some Sequence<SRGB> {
    let lch = toOKLCH(color)
    // Accumulated like abnahme's loop, so the float steps and thus the bytes match.
    return sequence(first: first) { $0 + lightnessSearchStep }
        .lazy
        .map { lch.l + direction * $0 }
        .prefix(while: { (0.0...1.0).contains($0) })
        .map { fromOKLCH(OKLCH(l: $0, c: lch.c, h: lch.h)) }
}

/// `text` and `text-muted` with the factors for the surface mixes: `scale` for active,
/// `raisedScale` for raised, `hoverScale` for hover.
private struct SurfacesAndText {
    var text: SRGB
    var textMuted: SRGB
    var scale: Double
    var raisedScale: Double
    var hoverScale: Double
}

/// Settles `text` and `text-muted` before anything derives from them, in this order:
/// 1. Whether the surfaces would collapse: raised keeping less than `minRaisedShare` for the
///    scheme's own `text` (already readable on `surface`). Decided before the word floors move
///    the text, so it rests on `base00` and `base05` alone, not on the diff hues.
/// 2. If so, `text` is shifted to clear the full raised, hover and active mixes.
/// 3. `text` is shifted until it clears the `wordFloors` (the word backdrops at
///    `diffLineAlpha`), where lowering the word alpha alone cannot get it there.
/// 4. After a collapse the mixes stay full, otherwise they are scaled down for both texts as
///    before.
/// 5. Raised and hover keep the least visible step (`minSurfaceStep`) from what lies below
///    them: where the scaled mix, or even the full one, leaves less, the mix grows by
///    `scaleStep` until it does (raised at most to its full mix, hover to short of active).
/// 6. `text-muted` is mixed from the final `text` and shifted to clear the resulting raised.
///
/// Every shift moves away from the surface, so it keeps what an earlier one reached; a mix that
/// grows stays nearer the surface than active, which `text` clears.
/// `text-subtle`, `text-disabled`, the word alphas and the syntax backdrops follow from the
/// final `text`.
private func surfacesAndText(
    surface: SRGB,
    toward: (Double) -> SRGB,
    text: SRGB,
    wordFloors: [SRGB]
) -> SurfacesAndText {
    func muted(_ text: SRGB) -> SRGB {
        ensureContrast(mix(text, surface, textMutedMix), surface, textContrast)
    }
    func scales(_ text: SRGB) -> (scale: Double, raised: Double) {
        let scale = surfaceScale(toward, activeMix, text)
        return (scale, min(scale, surfaceScale(toward, raisedMix, muted(text))))
    }
    let collapses = raisedMix * scales(text).raised < minRaisedShare
    let full = [raisedMix, hoverMix, activeMix].map { (bg: toward($0), min: textContrast) }
    var text = collapses ? ensureContrastOn(text, full) : text
    text = ensureContrastOn(text, wordFloors.map { (bg: $0, min: textContrast) })
    let (scale, scaledRaised) = collapses ? (1.0, 1.0) : scales(text)
    let raisedScale = visibleScale(toward, raisedMix, scaledRaised, below: surface, limit: 1.0)
    let raised = toward(raisedMix * raisedScale)
    // One step short of active's share, so hover stays nearer the surface than active.
    let hoverLimit = activeMix * scale / hoverMix - scaleStep
    let hoverScale = visibleScale(toward, hoverMix, scale, below: raised, limit: hoverLimit)
    return SurfacesAndText(
        text: text,
        textMuted: ensureContrast(muted(text), raised, textContrast),
        scale: scale,
        raisedScale: raisedScale,
        hoverScale: hoverScale
    )
}

/// `scale`, grown by `scaleStep` for as long as the surface mixed `share * scale` toward
/// `base05` lies less than `minSurfaceStep` of OKLCH lightness from `below`, up to `limit`.
private func visibleScale(
    _ toward: (Double) -> SRGB,
    _ share: Double,
    _ scale: Double,
    below: SRGB,
    limit: Double
) -> Double {
    let below = toOKLCH(below).l
    var scale = scale
    // The epsilon lets float steps reach `limit` itself.
    while abs(toOKLCH(toward(share * scale)).l - below) < minSurfaceStep && scale + scaleStep <= limit + 1e-9 {
        scale += scaleStep
    }
    return scale
}

/// What `secondaryText` settles from.
struct SecondaryInput {
    var appearance: ThemeAppearance
    var surface: SRGB
    var toward: (Double) -> SRGB
    /// As `surfacesAndText` and the surface contrast leave them.
    var textMuted: SRGB
    var textSubtle: SRGB
    /// The factors of `surfacesAndText`.
    var raisedScale: Double
    var hoverScale: Double
    /// As `recessedSurfaces` steps them.
    var sunken: SRGB
    var deep: SRGB
    /// Green and red, the hues of the added and removed lines.
    var lineHues: [SRGB]
}

/// `text-muted` and `text-subtle` with the backdrops they sit on besides `surface`.
struct SecondaryText {
    var textMuted: SRGB
    var textSubtle: SRGB
    var raised: SRGB
    var hover: SRGB
    var sunken: SRGB
    var deep: SRGB
    var panel: SRGB
    /// Of the added and removed lines.
    var lineAlphas: [Double]
}

/// Settles the secondary text on its backdrops: `text-subtle` on raised, sunken and the panel,
/// `text-muted` on hover, sunken, the panel and both lines (raised it already clears). Each
/// backdrop moves closer to the surface only as far as the text needs, never past its floor
/// (`minSurfaceStep`, `minDiffLineAlpha`), raised only in a dark theme. Where even the floor is
/// not enough, the text is shifted until it clears that backdrop where it was, and the backdrops
/// then move only as far as the shifted text still needs, so none moves for a text that shifts
/// anyway. Subtle comes first: raised decides the light-theme sunken and the floor of hover.
/// Deep follows raised in a light theme and carries no text.
func secondaryText(_ input: SecondaryInput) -> SecondaryText {
    let (surface, toward) = (input.surface, input.toward)
    func lightRules(_ sunken: SRGB, _ raised: SRGB) -> (sunken: SRGB, deep: SRGB) {
        switch input.appearance {
        case .dark: (sunken, input.deep)
        case .light: lightRecessedSurfaces(sunken, input.deep, raised)
        }
    }
    func sunkenStepsOn(_ raised: SRGB) -> [SRGB] {
        closerRecesses(surface, input.sunken).map { lightRules($0, raised).sunken }
    }

    // In a light theme the light-theme rules place sunken and deep from raised, so raised stays
    // there: closer, it would take both along (Tomorrow's sunken would reach its white surface).
    let raisedSteps = switch input.appearance {
    case .dark: closerMixes(toward, raisedMix, input.raisedScale, surface)
    case .light: [toward(raisedMix * input.raisedScale)]
    }
    // The panel keeps the least visible step from every place raised may take and from hover
    // where the layering rule puts it, so the sidebar's selected and hovered rows show on it;
    // hover then comes closer only as far as it keeps that step from every place of the panel.
    let panelSteps = panelSteps(surface, raisedSteps + [toward(hoverMix * input.hoverScale)])
    let textSubtle = shiftForUnreachable(
        input.textSubtle,
        [raisedSteps, sunkenStepsOn(raisedSteps[0]), panelSteps]
    )
    let raised = raisedSteps[firstReadable(raisedSteps, [textSubtle])]

    let sunkenSteps = sunkenStepsOn(raised)
    let hoverSteps = closerMixes(toward, hoverMix, input.hoverScale, raised)
        .enumerated()
        .prefix { step, hover in step == 0 || visiblyApart(hover, panelSteps) }
        .map(\.element)
    let alphaSteps = UInt32(((diffLineAlpha - minDiffLineAlpha) / scaleStep).rounded())
    // Clamped, so float steps cannot take the last below the floor.
    let alphas = (0...alphaSteps).map { max(diffLineAlpha - Double($0) * scaleStep, minDiffLineAlpha) }
    let lineSteps = input.lineHues.map { hue in alphas.map { composite(hue.withAlpha($0), surface) } }
    let reachable = shiftForUnreachable(input.textMuted, [hoverSteps, sunkenSteps, panelSteps] + lineSteps)
    // Away from the surface, so it keeps every backdrop it clears and may only let them stay
    // further out.
    let textMuted = stepFrom(reachable, textSubtle, surface)

    return SecondaryText(
        textMuted: textMuted,
        textSubtle: textSubtle,
        raised: raised,
        hover: hoverSteps[firstReadable(hoverSteps, [textMuted])],
        sunken: sunkenSteps[firstReadable(sunkenSteps, [textSubtle, textMuted])],
        deep: lightRules(input.sunken, raised).deep,
        panel: panelSteps[firstReadable(panelSteps, [textSubtle, textMuted])],
        lineAlphas: lineSteps.map { alphas[firstReadable($0, [textMuted])] }
    )
}

/// `fg` where it lies beyond `nearer`, the text role below it (more contrast on `surface`), and
/// reaches `minTextStep` against it, else moved away from `surface` in OKLCH lightness, hue and
/// chroma kept as far as sRGB allows, until it does: muted from subtle, towards `text`, and
/// `text` from muted. A step apart on the near side would turn the order of the two around.
func stepFrom(_ fg: SRGB, _ nearer: SRGB, _ surface: SRGB) -> SRGB {
    func beyond(_ color: SRGB) -> Bool {
        contrastRatio(color, surface) > contrastRatio(nearer, surface)
            && contrastRatio(color, nearer) >= minTextStep
    }
    if beyond(fg) {
        return fg
    }
    let away = toOKLCH(fg).l >= toOKLCH(surface).l ? 1.0 : -1.0
    return lightnessSteps(fg, away, first: lightnessSearchStep).first(where: beyond) ?? fg
}

/// `fg` shifted for each backdrop on which it misses `textContrast` even at the closest of its
/// `steps` (its positions from where the derivation puts it towards the surface): until it clears
/// every such backdrop where the derivation put it.
private func shiftForUnreachable(_ fg: SRGB, _ steps: [[SRGB]]) -> SRGB {
    let unreachable = steps
        .filter { steps in steps.last.map { contrastRatio(fg, $0) < textContrast } ?? false }
        .map { (bg: $0[0], min: textContrast) }
    return ensureContrastOn(fg, unreachable)
}

/// The index of the first of `steps` on which every one of `fgs` reaches `textContrast`; the last
/// should none, which `shiftForUnreachable` is there to rule out.
private func firstReadable(_ steps: [SRGB], _ fgs: [SRGB]) -> Int {
    steps.firstIndex { bg in fgs.allSatisfy { contrastRatio($0, bg) >= textContrast } } ?? steps.count - 1
}

/// The largest factor, at most 1, by which `share` may be scaled so that `text` keeps
/// `textContrast` on the mixed surface. Factor 0 is the surface itself, which every text role
/// already clears.
func surfaceScale(_ toward: (Double) -> SRGB, _ share: Double, _ text: SRGB) -> Double {
    var scale = 1.0
    while scale > 0.0 {
        if contrastRatio(text, toward(share * scale)) >= textContrast {
            return scale
        }
        scale -= scaleStep
    }
    return 0.0
}

/// The word backdrop in `hue` over its composited `line`: `diffWordAlpha`, lowered by
/// `scaleStep` until `text` keeps `textContrast`, as the surfaces are for the layering rule;
/// never below `diffLineAlpha`, where it would no longer stand out from the line. The fallback is
/// reached only where `surfacesAndText` cannot shift `text` far enough to clear that floor.
func wordBackdrop(_ hue: SRGB, _ line: SRGB, _ text: SRGB) -> ThemeColor {
    let steps = UInt32(((diffWordAlpha - diffLineAlpha) / scaleStep).rounded())
    for step in 0...steps {
        let word = hue.withAlpha(diffWordAlpha - Double(step) * scaleStep)
        if contrastRatio(text, composite(word, line)) >= textContrast {
            return word
        }
    }
    return hue.withAlpha(diffLineAlpha)
}
