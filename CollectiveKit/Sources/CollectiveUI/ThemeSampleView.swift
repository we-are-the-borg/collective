#if DEBUG
import CollectiveKit
import SwiftUI

private extension ThemeAppearance {
    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
}

/// A preview-only board of everything the restyling draws with: roles, type ladder and icons,
/// with buttons over the bundled schemes. It is the one place to check a new scheme or a font
/// or icon change without launching the app.
struct ThemeSampleView: View {
    @State private var themeID: String

    init(themeID: String = BundledThemes.defaultLight) {
        _themeID = State(initialValue: themeID)
    }

    var body: some View {
        ThemeSampleContent(themeID: themeID) {
            HStack(alignment: .top, spacing: 12) {
                Text(verbatim: "Scheme")
                    .font(.plexSans(12.5))
                    .foregroundStyle(.role(.textMuted))
                    .frame(height: 24)
                // Plain buttons instead of a pop-up: the preview agent cannot present a system
                // menu window and crashes the canvas on click.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(schemeRows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 6) {
                            ForEach(row, id: \.id) { theme in
                                schemeButton(theme)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Two rows keep all scheme buttons inside the 720 pt board.
    private var schemeRows: [[Theme]] {
        let all = BundledThemes.all
        let split = (all.count + 1) / 2
        return [Array(all.prefix(split)), Array(all.dropFirst(split))].filter { !$0.isEmpty }
    }

    private func schemeButton(_ theme: Theme) -> some View {
        let selected = theme.id == themeID
        return Button { themeID = theme.id } label: {
            Text(verbatim: theme.name)
                .font(.plexSans(12.5))
                .foregroundStyle(selected ? .role(.text) : .role(.textMuted))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background { if selected { RoundedRectangle(cornerRadius: 5).fill(.role(.surfaceRaised)) } }
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.role(.border), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The board itself, without state, so a test or snapshot can render any scheme directly.
struct ThemeSampleContent<Header: View>: View {
    let themeID: String
    @ViewBuilder var header: Header

    private var theme: Theme {
        BundledThemes.resolve(id: themeID, appearance: .light)
    }

    private static var typeLadder: [(spec: String, font: Font)] {
        [
            ("Sans 18 semibold", .plexSans(18, weight: .semibold)),
            ("Sans 15 semibold", .plexSans(15, weight: .semibold)),
            ("Sans 13 medium", .plexSans(13, weight: .medium)),
            ("Sans 13 regular", .plexSans(13)),
            ("Sans 12.5 medium", .plexSans(12.5, weight: .medium)),
            ("Sans 12.5 regular", .plexSans(12.5)),
            ("Sans 12 regular", .plexSans(12)),
            ("Sans 11.5 regular", .plexSans(11.5)),
            ("Mono 11.5 regular", .plexMono(11.5)),
            ("Mono 11.5 medium", .plexMono(11.5, weight: .medium)),
            ("Mono 11 regular", .plexMono(11)),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            section("Roles") { roles }
            section("Fonts") { fonts }
            section("Icons") { icons }
        }
        .padding(20)
        .frame(width: 720, alignment: .leading)
        .background(.role(.surface))
        .themeSelection(light: themeID, dark: themeID)
        .environment(\.colorScheme, theme.appearance.colorScheme)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: title)
                .font(.plexSans(13, weight: .medium))
                .foregroundStyle(.role(.text))
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.role(.surfaceSunken))
        .overlay(Rectangle().strokeBorder(.role(.border), lineWidth: 1))
    }

    private var roles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
            ForEach(ThemeRole.allCases, id: \.self) { role in
                VStack(alignment: .leading, spacing: 4) {
                    Rectangle()
                        .fill(.role(role))
                        .frame(height: 24)
                        .overlay(Rectangle().strokeBorder(.role(.border), lineWidth: 1))
                    Text(verbatim: role.name)
                        .font(.plexMono(11))
                        .foregroundStyle(.role(.textMuted))
                        .lineLimit(1)
                }
            }
        }
    }

    private var fonts: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.typeLadder, id: \.spec) { line in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(verbatim: line.spec)
                        .font(.plexMono(11))
                        .foregroundStyle(.role(.textSubtle))
                        .frame(width: 140, alignment: .leading)
                    Text(verbatim: "Regroup the agents, fix 0123 Rag")
                        .font(line.font)
                        .foregroundStyle(.role(.text))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: "Tabular digits")
                    .font(.plexMono(11))
                    .foregroundStyle(.role(.textSubtle))
                    .frame(width: 140, alignment: .leading)
                Text(verbatim: "0:01:11 · 1.0.0 · 12:58")
                    .font(.plexSans(12))
                    .monospacedDigit()
                    .foregroundStyle(.role(.text))
            }
        }
    }

    private var icons: some View {
        VStack(alignment: .leading, spacing: 14) {
            iconRow(LucideIcon.allCases.map { ($0, 16, .role(.text)) })
            iconRow([
                (.settings, 12, .role(.textMuted)),
                (.bell, 12, .role(.textMuted)),
                (.terminal, 12, .role(.accent)),
                (.palette, 12, .role(.accent)),
                (.circleAlert, 12, .role(.warning)),
                (.circleCheck, 12, .role(.success)),
                (.circleArrowUp, 12, .role(.info)),
                (.circleX, 12, .role(.danger)),
            ])
        }
    }

    private func iconRow(_ items: [(icon: LucideIcon, size: CGFloat, style: RoleStyle)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 136), spacing: 8, alignment: .top)], alignment: .leading, spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(spacing: 5) {
                    LucideImage(item.icon, size: item.size)
                        .foregroundStyle(item.style)
                        .frame(height: 16)
                    Text(verbatim: item.icon.rawValue)
                        .font(.plexMono(11))
                        .foregroundStyle(.role(.textMuted))
                        .lineLimit(1)
                }
            }
        }
    }
}

/// Scrolls the board over a surface fill, so a frame taller than the board shows the scheme
/// instead of the system window background.
private struct ThemePreviewScroll: View {
    let themeID: String

    var body: some View {
        ScrollView { ThemeSampleView(themeID: themeID) }
            .frame(width: 720, height: 800)
            .background(ThemeSurface(themeID: themeID))
    }
}

/// Fills with the `surface` role of the chosen scheme, resolved inside its own environment.
private struct ThemeSurface: View {
    let themeID: String

    var body: some View {
        Rectangle().fill(.role(.surface))
            .themeSelection(light: themeID, dark: themeID)
            .environment(\.colorScheme, BundledThemes.resolve(id: themeID, appearance: .light).appearance.colorScheme)
    }
}

#Preview("Catppuccin Latte") {
    ThemePreviewScroll(themeID: "catppuccin-latte")
}

#Preview("Catppuccin Macchiato") {
    ThemePreviewScroll(themeID: "catppuccin-macchiato")
}

#Preview("GitHub Light") {
    ThemePreviewScroll(themeID: "github")
}

#Preview("GitHub Dark") {
    ThemePreviewScroll(themeID: "github-dark")
}
#endif
