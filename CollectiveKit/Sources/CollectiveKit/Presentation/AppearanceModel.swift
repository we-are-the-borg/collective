import Foundation

/// Whether the scheme follows the macOS appearance or stays one scheme; the raw
/// values are what the app stores.
public enum ThemeMode: String, Sendable, Hashable {
    /// A light and a dark slot, the system appearance picks one.
    case system
    /// `ThemeChoice.fixed`, light or dark, whatever the system shows.
    case fixed
}

/// The scheme chosen for each macOS appearance, or the one scheme always used; ids of a
/// `ThemeCatalog`, bundled or `custom:`. The slots outlive fixed mode, so switching back restores
/// them.
public struct ThemeChoice: Sendable, Hashable {
    public var light: String
    public var dark: String
    public var mode: ThemeMode
    public var fixed: String
    /// What each slot knew of its custom theme when it was chosen, so the fallback notice can
    /// still name it once the file is gone; `nil` for a bundled id. Set by `choosing`.
    public var lightRemembered: RememberedCustomTheme?
    public var darkRemembered: RememberedCustomTheme?
    public var fixedRemembered: RememberedCustomTheme?

    public init(
        light: String, dark: String, mode: ThemeMode = .system, fixed: String = BundledThemes.defaultLight,
        lightRemembered: RememberedCustomTheme? = nil, darkRemembered: RememberedCustomTheme? = nil,
        fixedRemembered: RememberedCustomTheme? = nil
    ) {
        self.light = light
        self.dark = dark
        self.mode = mode
        self.fixed = fixed
        self.lightRemembered = lightRemembered
        self.darkRemembered = darkRemembered
        self.fixedRemembered = fixedRemembered
    }

    /// The slot the windows show while macOS shows `system`.
    public func slot(system: ThemeAppearance) -> ThemeSlot {
        switch mode {
        case .system: system == .light ? .light : .dark
        case .fixed: .fixed
        }
    }

    /// The theme the windows show while macOS shows `system`. Resolves only the slot in use, so
    /// the launch derives one bundled theme, not all.
    public func activeTheme(system: ThemeAppearance, catalog: ThemeCatalog) -> Theme {
        resolve(slot(system: system), system: system, catalog: catalog).theme
    }

    /// The active scheme's variant, which decides the windows' appearance: in fixed mode a dark
    /// scheme stays dark in light mode.
    public func activeAppearance(system: ThemeAppearance, catalog: ThemeCatalog) -> ThemeAppearance {
        activeTheme(system: system, catalog: catalog).appearance
    }

    /// The choice after picking `mode`: one scheme starts as the scheme shown right now, matching
    /// the system again keeps the slots as they were. A custom slot hands over its id and what it
    /// remembers even while its file is missing, so the notice stays and the theme comes back
    /// with the file, as it would have in the slot; an unknown bundled id hands over the default
    /// shown in its place.
    public func switching(to mode: ThemeMode, system: ThemeAppearance, catalog: ThemeCatalog) -> ThemeChoice {
        guard mode != self.mode else { return self }
        var next = self
        if mode == .fixed {
            let slot = slot(system: system)
            let id = id(of: slot)
            if CustomThemeID.isCustom(id) {
                next.fixed = id
                next.fixedRemembered = catalog.customTheme(id).map(RememberedCustomTheme.init) ?? remembered(slot)
            } else {
                next.fixed = resolve(slot, system: system, catalog: catalog).theme.id
                next.fixedRemembered = nil
            }
        }
        next.mode = mode
        return next
    }
}

/// The Appearance pane, variant C: a slot per macOS appearance, or the one slot of fixed mode,
/// each with a preview of its scheme; under the expanded slot a browser with a search field and
/// the sections Custom and Built-in. A value of what the pane shows, the view only draws it.
public struct AppearanceModel: Sendable, Equatable {
    public struct Slot: Sendable, Equatable, Identifiable {
        public let id: ThemeSlot
        /// "Light Mode" or "Dark Mode", the macOS terms; "Scheme" in fixed mode.
        public let title: String
        /// The slot macOS shows right now, marked with `inUseMarker`; never in fixed mode.
        public let isInUse: Bool
        /// What the slot shows, for its preview: the chosen scheme, or the default standing in
        /// for a missing custom theme.
        public let theme: Theme
        /// The full name under the slot's title, e.g. "Catppuccin Latte".
        public let themeName: String
        /// Why a default stands in for the chosen custom theme, shown under the slot.
        public let notice: String?
        public let isExpanded: Bool
        /// The title.
        public let accessibilityLabel: String
        /// "Catppuccin Latte, Default, in use, collapsed": SwiftUI gives a button no expanded
        /// state of its own, so the value says it.
        public let accessibilityValue: String
    }

    /// The schemes for the expanded slot, filtered by the query.
    public struct Browser: Sendable, Equatable {
        public let slot: ThemeSlot
        /// The search field's text.
        public let query: String
        /// The area's VoiceOver name, also the list's: "Light Mode schemes", "All schemes".
        public let accessibilityLabel: String
        /// The list's VoiceOver name with the count, "Dark Mode schemes, 26 schemes": VoiceOver
        /// reads no value on a group.
        public let listAccessibilityLabel: String
        /// Custom, then Built-in; empty while nothing selectable matches, the list is gone then.
        public let sections: [Section]
        /// "No dark schemes match “xyz”." in place of the list.
        public let emptyText: String?
        /// What VoiceOver hears 0.5 s after the last keystroke, also the list's value:
        /// "3 schemes", or `emptyText`.
        public let countAnnouncement: String
        /// How long `countAnnouncement` waits after a keystroke: the count 0.5 s, the
        /// sentence without matches none.
        public let announcementDelay: Duration
        /// The selectable rows in list order, across both sections: the arrow keys' path,
        /// which skips headers and error rows.
        public let rowIDs: [String]
        /// Where the list focus lands on entering: the checked row if it matches, else the
        /// first; `nil` without rows.
        public let entryRowID: String?
    }

    public struct Section: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable {
            case custom
            case builtIn
        }

        public let id: Kind
        /// "Custom" or "Built-in".
        public let title: String
        /// The section's radio group for VoiceOver: "Dark Mode, custom themes".
        public let accessibilityLabel: String
        public let items: [Item]
    }

    public enum Item: Sendable, Equatable, Identifiable {
        /// "Light" or "Dark" above a variant's rows in fixed mode; for display only, hidden from
        /// VoiceOver.
        case header(String)
        case row(Row)
        case error(ErrorRow)

        public var id: String {
            switch self {
            case .header(let title): "header:\(title)"
            case .row(let row): row.id
            case .error(let row): "error:\(row.fileName)"
            }
        }
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public let id: String
        /// The row's scheme, for its color strip.
        public let theme: Theme
        /// The short name, "Latte"; a custom theme's name from its file.
        public let name: String
        /// The family, "Catppuccin", with ` · Default` in Match; a custom theme's file name.
        public let secondaryText: String
        /// The check; none during a fallback.
        public let isSelected: Bool
        /// "Catppuccin Latte, Default", "Catppuccin Macchiato, Dark",
        /// "Horizon Dark, custom, horizon-dark.yaml"; the view adds "selected".
        public let accessibilityLabel: String
        /// A custom theme's file, for the context menu; `nil` for a bundled scheme.
        public let fileURL: URL?

        public var appearance: ThemeAppearance { theme.appearance }
    }

    /// A custom file that does not read; never selectable.
    public struct ErrorRow: Sendable, Equatable {
        public let fileName: String
        public let url: URL
        /// "same file name as ocean.yaml".
        public let problem: String
        /// The whole file name and problem, for the truncated row.
        public let tooltip: String
        /// "Error, ocean.yml, same file name as ocean.yaml", read as text.
        public let accessibilityLabel: String
    }

    public let slots: [Slot]
    /// The expanded slot's browser; `nil` while every slot is closed.
    public let browser: Browser?
    private let catalog: ThemeCatalog
    private let choice: ThemeChoice

    public static let inUseMarker: LocalizedStringResource = .kit(" · in use", defaultValue: " · in use")
    public static let defaultMarker: LocalizedStringResource = .kit(" · Default", defaultValue: " · Default")
    /// The two modes.
    public static let matchSystemLabel: LocalizedStringResource = .kit("Match the macOS appearance", defaultValue: "Match the macOS appearance")
    public static let fixedLabel: LocalizedStringResource = .kit("Always use one scheme", defaultValue: "Always use one scheme")
    /// The browser's search field: placeholder and VoiceOver label.
    public static let searchPlaceholder: LocalizedStringResource = .kit("Search schemes", defaultValue: "Search schemes")
    /// The x in the search field.
    public static let clearSearch: LocalizedStringResource = .kit("Clear search", defaultValue: "Clear search")
    /// Closes the browser.
    public static let done: LocalizedStringResource = .kit("Done", defaultValue: "Done")
    /// Under the open browser's list: opens the system's open panel for YAML files.
    public static let importTheme: LocalizedStringResource = .kit("Import Theme…", defaultValue: "Import Theme…")
    /// The button under the list opens the folder; the context menu of a custom or error row
    /// selects the row's file.
    public static let showInFinder: LocalizedStringResource = .kit("Show in Finder", defaultValue: "Show in Finder")
    /// The context menu of a custom or error row, without asking: the Trash gives it back.
    public static let moveToTrash: LocalizedStringResource = .kit("Move to Trash", defaultValue: "Move to Trash")
    public static let tintedThemingURL = URL(string: "https://github.com/tinted-theming/schemes")!

    /// The format of custom themes, with `tinted-theming ↗` as a link to `tintedThemingURL`; the
    /// link's space does not break, so ↗ stays with its word.
    public static var customThemesFootnote: AttributedString {
        let link = String(localized: .kit("tinted-theming ↗", defaultValue: "tinted-theming ↗"))
            .replacingOccurrences(of: " ", with: "\u{00A0}")
        var text = AttributedString(String(localized: .kit(
            "Custom themes are base16 or base24 YAML files, like those from %@.",
            defaultValue: "Custom themes are base16 or base24 YAML files, like those from \(link)."
        )))
        if let range = text.range(of: link) { text[range].link = tintedThemingURL }
        return text
    }

    /// The folder as the footnote shows it: under the home folder as `~/…`, always with the
    /// closing slash of a folder.
    public static func folderPath(
        _ folder: URL = CustomThemeFolder.location,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        let path = folder.standardizedFileURL.path
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        let shown = path.hasPrefix(homePrefix) ? "~/" + path.dropFirst(homePrefix.count) : path
        return shown.hasSuffix("/") ? shown : shown + "/"
    }

    /// - Parameters:
    ///   - inUse: The appearance macOS shows now.
    ///   - expanded: The slot whose browser is open; a slot the mode does not show opens none.
    ///   - query: The search field's text.
    public init(catalog: ThemeCatalog, choice: ThemeChoice, inUse: ThemeAppearance, expanded: ThemeSlot?, query: String) {
        self.catalog = catalog
        self.choice = choice
        let ids: [ThemeSlot] = choice.mode == .system ? [.light, .dark] : [.fixed]
        let open = expanded.flatMap { ids.contains($0) ? $0 : nil }
        slots = ids.map { slot in
            Self.slot(slot, choice: choice, catalog: catalog, inUse: inUse, isExpanded: slot == open)
        }
        browser = open.map { Browser(slot: $0, catalog: catalog, choice: choice, inUse: inUse, query: query) }
    }

    /// The choice after a click on row `id` of the open browser, for that browser's slot;
    /// anything else, an error row included, changes nothing. A pick for the slot macOS does not
    /// show changes only that slot's check and preview.
    public func selecting(_ id: String) -> ThemeChoice {
        guard let browser, browser.rowIDs.contains(id) else { return choice }
        return choice.choosing(id, for: browser.slot, catalog: catalog)
    }

    private static func slot(
        _ slot: ThemeSlot, choice: ThemeChoice, catalog: ThemeCatalog, inUse: ThemeAppearance, isExpanded: Bool
    ) -> Slot {
        let resolved = choice.resolve(slot, system: inUse, catalog: catalog)
        let name = resolved.theme.displayName
        let isInUse = choice.mode == .system && choice.slot(system: inUse) == slot
        let isDefault = resolved.notice == nil && Self.isDefault(resolved.theme.id, in: slot)
        let scheme: String = switch (isDefault, isInUse) {
        case (true, true): String(localized: .kit("%@, Default, in use", defaultValue: "\(name), Default, in use"))
        case (true, false): String(localized: .kit("%@, Default", defaultValue: "\(name), Default"))
        case (false, true): String(localized: .kit("%@, in use", defaultValue: "\(name), in use"))
        case (false, false): name
        }
        let value = isExpanded
            ? String(localized: .kit("%@, expanded", defaultValue: "\(scheme), expanded"))
            : String(localized: .kit("%@, collapsed", defaultValue: "\(scheme), collapsed"))
        let title = String(localized: title(of: slot))
        return Slot(
            id: slot,
            title: title,
            isInUse: isInUse,
            theme: resolved.theme,
            themeName: name,
            notice: resolved.notice.map { String(localized: $0.text) },
            isExpanded: isExpanded,
            accessibilityLabel: title,
            accessibilityValue: value
        )
    }

    static func title(of slot: ThemeSlot) -> LocalizedStringResource {
        switch slot {
        case .light: .kit("Light Mode", defaultValue: "Light Mode")
        case .dark: .kit("Dark Mode", defaultValue: "Dark Mode")
        case .fixed: .kit("Scheme", defaultValue: "Scheme")
        }
    }

    /// The family table's order; a scheme the table does not know follows, by name.
    static func listOrder(_ a: Theme, _ b: Theme) -> Bool {
        switch (ThemeFamily.displayRank[a.id], ThemeFamily.displayRank[b.id]) {
        case let (x?, y?): x < y
        case (_?, nil): true
        case (nil, _?): false
        case (nil, nil): a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }
    }

    /// The Default marker belongs to the slots of Match; one scheme has no default.
    static func isDefault(_ id: String, in slot: ThemeSlot) -> Bool {
        switch slot {
        case .light: id == BundledThemes.defaultLight
        case .dark: id == BundledThemes.defaultDark
        case .fixed: false
        }
    }
}

extension AppearanceModel.Browser {
    init(slot: ThemeSlot, catalog: ThemeCatalog, choice: ThemeChoice, inUse: ThemeAppearance, query: String) {
        let search = SchemeSearch(query)
        self.slot = slot
        self.query = query
        let slotTitle = String(localized: AppearanceModel.title(of: slot))
        let area: LocalizedStringResource = switch slot {
        case .light: .kit("Light Mode schemes", defaultValue: "Light Mode schemes")
        case .dark: .kit("Dark Mode schemes", defaultValue: "Dark Mode schemes")
        case .fixed: .kit("All schemes", defaultValue: "All schemes")
        }
        accessibilityLabel = String(localized: area)
        let resolved = choice.resolve(slot, system: inUse, catalog: catalog)
        // During a fallback the default stands in, but it is not what was chosen.
        let checked = resolved.notice == nil ? resolved.theme.id : nil
        let variant: ThemeAppearance? = switch slot {
        case .light: .light
        case .dark: .dark
        case .fixed: nil
        }

        let bundled = catalog.bundledThemes
            .filter { variant == nil || $0.appearance == variant }
            .filter { search.matches(builtIn: $0) }
            .sorted(by: AppearanceModel.listOrder)
        let builtInRows = bundled.map { theme in
            AppearanceModel.Row(builtIn: theme, slot: slot, isSelected: theme.id == checked)
        }

        // By name, as the catalog lists them.
        let customRows = catalog.customThemes
            .filter { variant == nil || $0.appearance == variant }
            .filter { search.matches(custom: $0) }
            .map { AppearanceModel.Row(custom: $0, slot: slot, isSelected: $0.id == checked) }
        // In every browser: a broken file's variant is unknown.
        let errorItems = catalog.brokenThemes
            .filter { search.matches(broken: $0) }
            .map { AppearanceModel.Item.error(AppearanceModel.ErrorRow($0)) }
        // Match: after the custom rows; fixed mode: before the variant headers.
        let customItems = variant == nil
            ? errorItems + Self.items(customRows, withHeaders: true)
            : customRows.map(AppearanceModel.Item.row) + errorItems

        let selectable = customRows + builtInRows
        // Error rows are no schemes and cannot be selected: alone they keep no list, which
        // would have no row to focus.
        guard !selectable.isEmpty else {
            let empty: LocalizedStringResource = switch variant {
            case .light: .kit("No light schemes match “%@”.", defaultValue: "No light schemes match “\(query)”.")
            case .dark: .kit("No dark schemes match “%@”.", defaultValue: "No dark schemes match “\(query)”.")
            case nil: .kit("No schemes match “%@”.", defaultValue: "No schemes match “\(query)”.")
            }
            sections = []
            rowIDs = []
            entryRowID = nil
            emptyText = String(localized: empty)
            countAnnouncement = String(localized: empty)
            listAccessibilityLabel = accessibilityLabel
            announcementDelay = .zero
            return
        }
        emptyText = nil
        countAnnouncement = String(localized: .kit("%lld schemes", defaultValue: "\(selectable.count) schemes"))
        listAccessibilityLabel = String(localized: .kit("%@, %@", defaultValue: "\(accessibilityLabel), \(countAnnouncement)"))
        announcementDelay = .milliseconds(500)

        sections = [
            AppearanceModel.Section(
                id: .custom,
                title: String(localized: .kit("Custom", defaultValue: "Custom")),
                accessibilityLabel: String(localized: .kit("%@, custom themes", defaultValue: "\(slotTitle), custom themes")),
                items: customItems
            ),
            AppearanceModel.Section(
                id: .builtIn,
                title: String(localized: .kit("Built-in", defaultValue: "Built-in")),
                accessibilityLabel: String(localized: .kit("%@, built-in schemes", defaultValue: "\(slotTitle), built-in schemes")),
                items: Self.items(builtInRows, withHeaders: variant == nil)
            ),
        ]
        // In the order shown: fixed mode puts each section's light rows first.
        let ids = sections.flatMap(\.items).compactMap { if case .row(let row) = $0 { row.id } else { nil } }
        rowIDs = ids
        entryRowID = checked.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
    }

    /// The row `offset` selectable rows from `id`, held at either end: ↑ ↓ (±1) and Page Up /
    /// Down (± the rows the box holds); `nil` for an id that is no selectable row. Home and End
    /// are `rowIDs.first` and `.last`; ↑ on the first row goes back to the search field,
    /// which the view decides.
    public func rowID(from id: String, by offset: Int) -> String? {
        rowIDs.arrowKeyStep(from: id, by: offset)
    }

    /// The rows as they stand, or in fixed mode light first, then dark, each under its header;
    /// a sort that keeps the family order within each variant.
    private static func items(_ rows: [AppearanceModel.Row], withHeaders: Bool) -> [AppearanceModel.Item] {
        guard withHeaders else { return rows.map(AppearanceModel.Item.row) }
        return [ThemeAppearance.light, .dark].flatMap { appearance -> [AppearanceModel.Item] in
            let members = rows.filter { $0.appearance == appearance }
            guard !members.isEmpty else { return [] }
            return [.header(AppearanceModel.variantTitle(appearance))] + members.map(AppearanceModel.Item.row)
        }
    }
}

extension AppearanceModel.Section {
    /// What VoiceOver reads of the section under its heading.
    public enum AccessibilityPart: Sendable, Equatable {
        /// The section's rows as one radio group named `accessibilityLabel`.
        case radioGroup([AppearanceModel.Row])
        /// An error row, read as text, with Show in Finder and Move to Trash.
        case error(AppearanceModel.ErrorRow)
    }

    /// The error rows where they stand, around the rows as one radio group; the variant headers
    /// are left out. Error rows stand together, before the rows in fixed mode and after
    /// them in Match.
    public var accessibilityParts: [AccessibilityPart] {
        let rows = items.compactMap { if case .row(let row) = $0 { row } else { nil } }
        let firstRow = items.firstIndex { if case .row = $0 { true } else { false } } ?? items.endIndex
        let errors = items.enumerated().compactMap { index, item -> (Int, AppearanceModel.ErrorRow)? in
            if case .error(let row) = item { (index, row) } else { nil }
        }
        let group: [AccessibilityPart] = rows.isEmpty ? [] : [.radioGroup(rows)]
        return errors.filter { $0.0 < firstRow }.map { .error($0.1) } + group
            + errors.filter { $0.0 > firstRow }.map { .error($0.1) }
    }
}

extension AppearanceModel {
    /// "Light" or "Dark": the headers in fixed mode, the variant VoiceOver adds to a row there.
    static func variantTitle(_ appearance: ThemeAppearance) -> String {
        let title: LocalizedStringResource = switch appearance {
        case .light: .kit("Light", defaultValue: "Light")
        case .dark: .kit("Dark", defaultValue: "Dark")
        }
        return String(localized: title)
    }

    /// "Catppuccin Macchiato, Dark": in fixed mode a row's label carries its variant.
    static func withVariant(_ label: String, _ appearance: ThemeAppearance) -> String {
        switch appearance {
        case .light: String(localized: .kit("%@, Light", defaultValue: "\(label), Light"))
        case .dark: String(localized: .kit("%@, Dark", defaultValue: "\(label), Dark"))
        }
    }
}

extension AppearanceModel.Row {
    /// Names from the family table, not the scheme's file; the family in every row.
    init(builtIn theme: Theme, slot: ThemeSlot, isSelected: Bool) {
        let fullName = theme.displayName
        let family = theme.family ?? ""
        let isDefault = AppearanceModel.isDefault(theme.id, in: slot)
        id = theme.id
        self.theme = theme
        name = theme.shortName ?? fullName
        secondaryText = isDefault ? family + String(localized: AppearanceModel.defaultMarker) : family
        self.isSelected = isSelected
        accessibilityLabel = if isDefault {
            String(localized: .kit("%@, Default", defaultValue: "\(fullName), Default"))
        } else if slot == .fixed {
            AppearanceModel.withVariant(fullName, theme.appearance)
        } else {
            fullName
        }
        fileURL = nil
    }
}

extension AppearanceModel.Row {
    /// The name as the file writes it, the file name in place of the family.
    init(custom: CustomTheme, slot: ThemeSlot, isSelected: Bool) {
        id = custom.id
        theme = custom.theme
        name = custom.name
        secondaryText = custom.fileName
        self.isSelected = isSelected
        let label = String(localized: .kit("%@, custom, %@", defaultValue: "\(custom.name), custom, \(custom.fileName)"))
        accessibilityLabel = slot == .fixed ? AppearanceModel.withVariant(label, custom.appearance) : label
        fileURL = custom.url
    }
}

extension AppearanceModel.ErrorRow {
    init(_ file: BrokenCustomTheme) {
        let problem = String(localized: file.problem.text)
        fileName = file.fileName
        url = file.url
        self.problem = problem
        tooltip = String(localized: .kit("%@ · %@", defaultValue: "\(file.fileName) · \(problem)"))
        accessibilityLabel = String(localized: .kit("Error, %@, %@", defaultValue: "Error, \(file.fileName), \(problem)"))
    }
}

/// The search field's words: each must be found in one of a row's fields, ignoring case
/// and accents, so "rose" finds Rosé Pine and "frappe" Frappé.
private struct SchemeSearch {
    private let words: [String]

    init(_ query: String) {
        words = query.split(whereSeparator: \.isWhitespace).map { Self.fold(String($0)) }
    }

    /// Full name, family, short name and variant: "dark" finds Mocha and Dracula.
    func matches(builtIn theme: Theme) -> Bool {
        matches([theme.displayName, theme.family ?? "", theme.shortName ?? "", AppearanceModel.variantTitle(theme.appearance)])
    }

    func matches(custom theme: CustomTheme) -> Bool {
        matches([theme.name, theme.fileName, AppearanceModel.variantTitle(theme.appearance)])
    }

    /// Only the file name: a broken file has nothing else to show.
    func matches(broken file: BrokenCustomTheme) -> Bool {
        matches([file.fileName])
    }

    private func matches(_ fields: [String]) -> Bool {
        let folded = fields.map(Self.fold)
        return words.allSatisfy { word in folded.contains { $0.contains(word) } }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
