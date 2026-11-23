import CollectiveKit
import SwiftUI

/// Appearance: on top whether the scheme matches the macOS appearance or stays one (decision
/// 82), then the slots with their scheme, each opening a browser with a search field and the
/// sections Custom and Built-in. A click applies at once, without saving and without a
/// transition. The keys follow the kit's `AppearanceModel.action(for:focus:focusedRowID:)`;
/// one handler for the whole pane sees them before the search field's editor does.
struct AppearancePane: View {
    @Binding var choice: ThemeChoice
    var customThemes = CustomThemeActions()
    // Not `colorScheme`: the window takes the active scheme's variant, which in fixed mode
    // need not be the system's.
    @Environment(\.resolvedSystemAppearance) private var systemAppearance
    @Environment(\.themeCatalog) private var catalog
    // No slot is open when the pane opens, nor after a change of mode; one that is open
    // stays open when the system appearance flips.
    @State private var expanded: ThemeSlot?
    @State private var query = ""
    @FocusState private var focus: AppearanceFocus?
    /// The list's row with the ring while the list has the focus; `nil` puts it where the focus
    /// enters.
    @State private var focusedRowID: String?
    /// The search field's caret, set where a key puts it.
    @State private var searchSelection: TextSelection?
    /// A caret asked for while the field takes the focus, for `placeCaret(_:)`.
    @State private var pendingCaret: TextSelection?
    /// Back on the slot once its browser closes, so VoiceOver reads the slot with its new scheme.
    @AccessibilityFocusState private var voiceOverSlot: ThemeSlot?

    var body: some View {
        let model = AppearanceModel(
            catalog: catalog, choice: choice, inUse: systemAppearance, expanded: expanded, query: query
        )
        SettingsPaneScaffold(
            title: Text(SettingsText.appearance),
            description: Text(SettingsText.appearanceDescription),
            descriptionSpacing: 18
        ) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsGroup {
                    SettingsRadioGroup(
                        selection: Binding(
                            get: { choice.mode },
                            set: {
                                collapse()
                                apply(choice.switching(to: $0, system: systemAppearance, catalog: catalog))
                            }
                        ),
                        options: [ThemeMode.system, .fixed],
                        // The group has no header; VoiceOver names it after the pane.
                        title: Text(SettingsText.appearance)
                    ) { mode in
                        SettingsLabel(Text(mode == .system ? AppearanceModel.matchSystemLabel : AppearanceModel.fixedLabel))
                    }
                }
                SettingsGroup {
                    ForEach(model.slots) { slot in
                        VStack(alignment: .leading, spacing: 0) {
                            AppearanceSlotRow(slot: slot) { toggle(slot.id) }
                                .focused($focus, equals: .slot(slot.id))
                                .accessibilityFocused($voiceOverSlot, equals: slot.id)
                            if let notice = slot.notice {
                                FallbackNotice(text: notice)
                            }
                            if slot.isExpanded, let browser = model.browser {
                                AppearanceBrowser(
                                    browser: browser, query: $query, searchSelection: $searchSelection, focus: $focus,
                                    focusedRowID: $focusedRowID, customThemes: customThemes,
                                    onDone: { collapse(focusingSlot: true) }
                                ) { id in
                                    apply(model.selecting(id))
                                    focusedRowID = id
                                    focus = .list
                                }
                            }
                        }
                    }
                }
            }
            // Before the search field's editor, which would take ↓, Return, Esc, Home and End.
            .onKeyPress(phases: [.down, .repeat]) { press in
                // A caret not placed by now is the field's own business.
                pendingCaret = nil
                guard let key = Self.key(press) else { return .ignored }
                return perform(model.action(for: key, focus: focus, focusedRowID: focusedRowID), in: model)
            }
            .background {
                // ⌘F also while nothing in the pane has the focus, where no key press reaches the
                // handler above (keyboard navigation off, after a click); a zero-size button
                // carries the shortcut.
                Button {
                    _ = perform(model.action(for: .find, focus: focus, focusedRowID: focusedRowID), in: model)
                } label: { EmptyView() }
                    .keyboardShortcut("f", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .focusable(false)
                    .accessibilityHidden(true)
            }
        }
        // Leaving the list forgets its ring: Tab back in lands on the entry row again.
        .onChange(of: focus) { _, focus in
            if focus != .list { focusedRowID = nil }
        }
        .onChange(of: searchSelection) { _, selection in
            guard let pendingCaret, selection != pendingCaret else { return }
            self.pendingCaret = nil
            searchSelection = pendingCaret
        }
    }

    /// The key table's keys, from a press: ⌘F, the named keys and typed text; nothing with ⌃
    /// or with ⌘ otherwise, and Home and End with ⇧ stay the field editor's selection keys.
    private static func key(_ press: KeyPress) -> AppearanceKey? {
        let modifiers = press.modifiers.subtracting([.capsLock, .numericPad])
        if modifiers.contains(.command) {
            return modifiers == .command && press.key == KeyEquivalent("f") ? .find : nil
        }
        guard !modifiers.contains(.control) else { return nil }
        switch press.key {
        case .upArrow: return .upArrow
        case .downArrow: return .downArrow
        case .leftArrow: return .leftArrow
        case .rightArrow: return .rightArrow
        case .home: return modifiers.contains(.shift) ? nil : .home
        case .end: return modifiers.contains(.shift) ? nil : .end
        case .pageUp: return .pageUp
        case .pageDown: return .pageDown
        case .space: return .space
        case .return: return .return
        case .escape: return .escape
        // ⌫ types U+007F, which `.delete` (U+0008) does not name.
        case .delete, KeyEquivalent("\u{7F}"): return .deleteBackward
        default: return AppearanceKey.typed(press.characters)
        }
    }

    private func perform(_ action: AppearanceKeyAction, in model: AppearanceModel) -> KeyPress.Result {
        switch action {
        case .pass:
            return .ignored
        case .swallow:
            break
        case .toggle(let slot):
            toggle(slot)
        case .focusRow(let id):
            focusedRowID = id
            focus = .list
        case .selectRow(let id):
            apply(model.selecting(id))
            focusedRowID = id
            // Only the new row is read; the window's new colors are not.
            if let row = model.browser?.row(id) {
                AccessibilityNotification.Announcement(row.accessibilityLabel).post()
            }
        case .selectAndCollapse(let id):
            apply(model.selecting(id))
            collapse(focusingSlot: true)
        case .editSearch(let text):
            query = text
            focus = .search
            placeCaret(TextSelection(insertionPoint: text.endIndex))
        case .caretToStart:
            searchSelection = TextSelection(insertionPoint: query.startIndex)
        case .caretToEnd:
            searchSelection = TextSelection(insertionPoint: query.endIndex)
        case .clearSearch:
            query = ""
        case .collapse:
            collapse(focusingSlot: true)
        case .find(let slot):
            if expanded != slot { open(slot) }
            // Taking the focus marks the field's text; one that has it marks it here.
            if focus == .search {
                searchSelection = TextSelection(range: query.startIndex..<query.endIndex)
            } else {
                focus = .search
            }
        }
        return .handled
    }

    /// Sets the caret of a field taking the focus: a field editor that becomes first responder
    /// marks all of its text, so the caret is set again once it did.
    private func placeCaret(_ selection: TextSelection) {
        pendingCaret = selection
        searchSelection = selection
    }

    /// Only one browser is open: opening one closes the other, a second click closes it.
    private func toggle(_ slot: ThemeSlot) {
        if expanded == slot {
            collapse(focusingSlot: true)
        } else {
            open(slot)
        }
    }

    /// Opens with an empty search; the browser takes the focus into its field.
    private func open(_ slot: ThemeSlot) {
        query = ""
        searchSelection = nil
        focusedRowID = nil
        expanded = slot
    }

    /// Closing a browser clears its search; from the browser the focus goes back to the slot,
    /// where VoiceOver reads it with the scheme just chosen.
    private func collapse(focusingSlot: Bool = false) {
        let slot = expanded
        expanded = nil
        query = ""
        searchSelection = nil
        focusedRowID = nil
        if focusingSlot, let slot {
            focus = .slot(slot)
            voiceOverSlot = slot
        }
    }

    private func apply(_ next: ThemeChoice) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { choice = next }
    }
}

/// What the pane asks the app to do with the folder of custom themes: the open panel, the
/// alerts and Finder are AppKit's and stay in the app.
struct CustomThemeActions {
    /// `Import Theme…`: the open panel, "Replace?" per taken name, then the copy.
    var importThemes: () -> Void = {}
    /// The button `Show in Finder`: the folder, created if it is missing.
    var showFolder: () -> Void = {}
    /// `Show in Finder` of a custom or error row: its file, selected.
    var showFile: (URL) -> Void = { _ in }
    /// `Move to Trash` of a custom or error row, without asking.
    var moveToTrash: (URL) -> Void = { _ in }
}

// MARK: Slot

/// The slot: its scheme's preview, the slot's name with ` · in use`, the scheme's full name,
/// and the chevron; at least 72 high.
private struct AppearanceSlotRow: View {
    let slot: AppearanceModel.Slot
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                MiniPopover()
                    .frame(width: 88, height: 52)
                    .themeFixed(slot.theme)
                    // Outside the preview, in the window's scheme, like the design's box-shadow.
                    .overlay { Rectangle().stroke(.role(.border), lineWidth: 1).padding(-0.5) }
                VStack(alignment: .leading, spacing: 2) {
                    (Text(verbatim: slot.title)
                        + (slot.isInUse ? Text(AppearanceModel.inUseMarker).foregroundStyle(.role(.textSubtle)) : Text(verbatim: "")))
                        .font(.plexSans(13))
                        .plexLineHeight(18, size: 13)
                        .foregroundStyle(.role(.text))
                    Text(verbatim: slot.themeName)
                        .font(.plexSans(12))
                        .plexLineHeight(17, size: 12)
                        .foregroundStyle(.role(.textMuted))
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                LucideImage(slot.isExpanded ? .chevronUp : .chevronDown, size: 14)
                    .foregroundStyle(.role(slot.isExpanded ? .text : .textMuted))
            }
            .settingsRowInsets()
            .frame(minHeight: 72)
        }
        .buttonStyle(SlotRowStyle())
        .accessibilityLabel(Text(verbatim: slot.accessibilityLabel))
        .accessibilityValue(Text(verbatim: slot.accessibilityValue))
    }
}

/// Hover `--surface-hover`, pressed `--surface-active`, the keyboard focus a 2 px ring inside.
private struct SlotRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SlotRowBody(configuration: configuration)
    }
}

private struct SlotRowBody: View {
    @Environment(\.showsButtonFocusRing) private var showsFocusRing
    @State private var isHovered = false
    let configuration: ButtonStyleConfiguration

    var body: some View {
        configuration.label
            .background(fill.map { AnyShapeStyle(.role($0)) } ?? AnyShapeStyle(.clear))
            .overlay { if showsFocusRing { InsideFocusRing() } }
            .contentShape(Rectangle())
            .focusEffectDisabled()
            .onHover { isHovered = $0 }
    }

    private var fill: ThemeRole? {
        if configuration.isPressed { return .surfaceActive }
        return isHovered ? .surfaceHover : nil
    }
}

/// The 2 px `--focus-ring` frame inside a slot or row, square, so it stays clear of the lines
/// of its neighbors.
private struct InsideFocusRing: View {
    var body: some View {
        Rectangle()
            .strokeBorder(.role(.focusRing), lineWidth: 2)
            .allowsHitTesting(false)
    }
}

/// Why a default stands in for the chosen custom theme, right under the slot row; no
/// close button, it goes when the choice reads again or another one is made.
private struct FallbackNotice: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            LucideImage(.triangleAlert, size: 14)
                .foregroundStyle(.role(.warning))
                .padding(.top, 1.5)
            Text(verbatim: text)
                .font(.plexSans(12))
                .plexLineHeight(17, size: 12)
                .foregroundStyle(.role(.textMuted))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The design's -2 pulls it up into the slot row's bottom inset.
        .padding(EdgeInsets(top: -2, leading: 14, bottom: 12, trailing: 14))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Browser

/// Under the open slot: the search field with Done, pinned, then the list box, or the
/// sentence when nothing matches.
private struct AppearanceBrowser: View {
    let browser: AppearanceModel.Browser
    @Binding var query: String
    @Binding var searchSelection: TextSelection?
    var focus: FocusState<AppearanceFocus?>.Binding
    @Binding var focusedRowID: String?
    let customThemes: CustomThemeActions
    let onDone: () -> Void
    let onSelect: @MainActor (String) -> Void
    @State private var announcement: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SchemeSearchField(query: $query, selection: $searchSelection, focus: focus)
                Button(action: onDone) { Text(AppearanceModel.done) }
                    .buttonStyle(.settings)
                    .focused(focus, equals: .done)
            }
            if let empty = browser.emptyText {
                Text(verbatim: empty)
                    .font(.plexSans(12.5))
                    .plexLineHeight(18, size: 12.5)
                    .foregroundStyle(.role(.textMuted))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 26)
                    .padding(.bottom, 10)
            } else {
                SchemeList(
                    browser: browser, focus: focus, focusedRowID: $focusedRowID, customThemes: customThemes, onSelect: onSelect
                )
                .padding(.top, 8)
            }
            // Also while nothing matches: the way in for a theme the list lacks.
            CustomThemeControls(actions: customThemes)
                .padding(.top, 10)
        }
        .padding(EdgeInsets(top: 2, leading: 14, bottom: 14, trailing: 14))
        // Into the search field on opening, without a word from VoiceOver.
        .onAppear { focus.wrappedValue = .search }
        // The count once typing pauses, the sentence without matches at once; after
        // clearing the full count again. Not on opening: the query starts empty.
        .onChange(of: query) {
            announcement?.cancel()
            let text = browser.countAnnouncement
            let delay = browser.announcementDelay
            announcement = Task { @MainActor in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                AccessibilityNotification.Announcement(text).post()
            }
        }
        .onDisappear { announcement?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: browser.accessibilityLabel))
    }
}

/// 28 high on `--surface-sunken` in a 1 px `--border-control` frame with the magnifier, the
/// placeholder in `--text-muted` and, with text, `Clear search`; its focus ring outside with 1 px
/// gap, as for any text field whenever it has the focus.
struct SchemeSearchField: View {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var query: String
    @Binding var selection: TextSelection?
    var focus: FocusState<AppearanceFocus?>.Binding

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsControlMetrics.radius, style: .circular)
        HStack(spacing: 6) {
            LucideImage(.search, size: 14)
                .foregroundStyle(.role(.textMuted))
            // The placeholder is drawn here: the system's would take its own gray.
            TextField(text: $query, selection: $selection, prompt: Text(verbatim: "")) { Text(AppearanceModel.searchPlaceholder) }
                .textFieldStyle(.plain)
                .font(.plexSans(13))
                .foregroundStyle(.role(.text))
                .focused(focus, equals: .search)
                .focusEffectDisabled()
                // The label stays unread with an empty prompt.
                .accessibilityLabel(Text(AppearanceModel.searchPlaceholder))
                .accessibilityAddTraits(.isSearchField)
                .background(alignment: .leading) {
                    if query.isEmpty {
                        Text(AppearanceModel.searchPlaceholder)
                            .font(.plexSans(13))
                            .foregroundStyle(.role(.textMuted))
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            if !query.isEmpty {
                Button { query = "" } label: { LucideImage(.x, size: 12) }
                    .buttonStyle(ClearSearchStyle())
                    // Not a Tab stop: Esc clears too.
                    .focusable(false)
                    .accessibilityLabel(Text(AppearanceModel.clearSearch))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .frame(height: 28)
        .background(.role(.surfaceSunken), in: shape)
        .overlay { shape.strokeBorder(.role(Self.border(isEnabled: isEnabled)), lineWidth: 1) }
        .outsideFocusRing(focus.wrappedValue == .search)
    }
}

extension SchemeSearchField {
    nonisolated static func border(isEnabled: Bool) -> ThemeRole { isEnabled ? .borderControl : .border }
}

/// The x in the search field: 20 × 20, radius 5, `--text-muted`, hover and pressed fills.
private struct ClearSearchStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ClearSearchBody(configuration: configuration)
    }
}

private struct ClearSearchBody: View {
    @State private var isHovered = false
    let configuration: ButtonStyleConfiguration

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsControlMetrics.radius, style: .circular)
        configuration.label
            .foregroundStyle(.role(.textMuted))
            .frame(width: 20, height: 20)
            .background(fill.map { AnyShapeStyle(.role($0)) } ?? AnyShapeStyle(.clear), in: shape)
            .contentShape(shape)
            .onHover { isHovered = $0 }
    }

    private var fill: ThemeRole? {
        if configuration.isPressed { return .surfaceActive }
        return isHovered ? .surfaceHover : nil
    }
}

/// `Import Theme…` and `Show in Finder`, then the footnote with the format and the folder.
private struct CustomThemeControls: View {
    let actions: CustomThemeActions

    var body: some View {
        let path = AppearanceModel.folderPath()
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: actions.importThemes) { Text(AppearanceModel.importTheme) }
                    .buttonStyle(.settings)
                Button(action: actions.showFolder) { Text(AppearanceModel.showInFinder) }
                    .buttonStyle(.settings)
            }
            Text(AppearanceModel.customThemesFootnote)
                .font(.plexSans(11.5))
                .plexLineHeight(16, size: 11.5)
                .foregroundStyle(.role(.textSubtle))
                .tint(RoleStyle(.accent))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            // Breaks anywhere, like the design's `overflow-wrap: anywhere`, not only at its spaces.
            Text(verbatim: path.map(String.init).joined(separator: "\u{200B}"))
                .font(.plexMono(11.5))
                .plexLineHeight(16, size: 11.5)
                .foregroundStyle(.role(.textMuted))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Text(verbatim: path))
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `Show in Finder` and `Move to Trash` for a custom file, as the system's context menu.
private struct CustomFileMenu: View {
    let url: URL
    let actions: CustomThemeActions

    var body: some View {
        Button { actions.showFile(url) } label: { Text(AppearanceModel.showInFinder) }
        Button { actions.moveToTrash(url) } label: { Text(AppearanceModel.moveToTrash) }
    }
}

extension View {
    /// The context menu's two items as VoiceOver actions, for a custom file only; built-in
    /// schemes have neither.
    @ViewBuilder fileprivate func customFileActions(_ url: URL?, _ actions: CustomThemeActions) -> some View {
        if let url {
            accessibilityActions { CustomFileMenu(url: url, actions: actions) }
        } else {
            self
        }
    }

    /// The system's context menu with `CustomFileMenu`, for a custom file only.
    @ViewBuilder fileprivate func customFileMenu(_ url: URL?, _ actions: CustomThemeActions) -> some View {
        if let url {
            contextMenu { CustomFileMenu(url: url, actions: actions) }
        } else {
            self
        }
    }
}

// MARK: List

/// The box: its own scroll view, as high as its items up to its maximum, drawing only
/// the rows in view; the headers that stick at its top are drawn over it from the kit's layout.
/// One focus stop for all rows; the pane moves the ring with the keys, and the box scrolls
/// the row with the ring into view, below the stuck headers. VoiceOver gets the sections from
/// the kit instead of the drawn rows: headings, the rows as radio groups, error rows as text.
private struct SchemeList: View {
    /// What the box shows of its content, for scrolling a row into view.
    private struct Viewport: Equatable {
        var offset: Double = 0
        var height: Double = 0
    }

    let browser: AppearanceModel.Browser
    var focus: FocusState<AppearanceFocus?>.Binding
    @Binding var focusedRowID: String?
    let customThemes: CustomThemeActions
    let onSelect: @MainActor (String) -> Void
    @Environment(\.isKeyboardFocusVisible) private var isKeyboardFocusVisible
    @State private var pinned: [AppearanceModel.Browser.PinnedHeader] = []
    @State private var position = ScrollPosition(edge: .top)
    @State private var viewport = Viewport()

    var body: some View {
        let focusedRow = focus.wrappedValue == .list ? browser.focusedRow(focusedRowID) : nil
        let ringRow = isKeyboardFocusVisible ? focusedRow : nil
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(browser.sections.enumerated()), id: \.element.id) { sectionIndex, section in
                    ListHeader(level: .section, title: section.title, drawsTopLine: browser.drawsTopLine(ofSection: sectionIndex))
                    ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                        ListItem(
                            item: item, drawsTopLine: section.drawsTopLine(at: index),
                            showsFocusRing: item.id == ringRow, customThemes: customThemes, onSelect: onSelect
                        )
                    }
                }
            }
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: [AppearanceModel.Browser.PinnedHeader].self) { geometry in
            browser.pinnedHeaders(scrollOffset: geometry.contentOffset.y + geometry.contentInsets.top)
        } action: { _, headers in
            pinned = headers
        }
        .onScrollGeometryChange(for: Viewport.self) { geometry in
            Viewport(offset: geometry.contentOffset.y + geometry.contentInsets.top, height: geometry.containerSize.height)
        } action: { _, new in
            viewport = new
        }
        .onChange(of: focusedRow) { _, id in
            guard let id, let y = browser.scrollOffset(revealing: id, from: viewport.offset, viewport: viewport.height) else { return }
            position.scrollTo(y: y)
        }
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(pinned) { header in
                    ListHeader(level: header.level, title: header.title, drawsTopLine: header.drawsTopLine)
                        .offset(y: header.y)
                }
            }
            // The box's height, so a variant header 24 down is not clipped away with the first.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .accessibilityHidden(true)
        }
        // Inside the 1 px frame, as the design's box is border-box.
        .frame(height: min(browser.contentHeight, browser.maxBoxHeight - 2))
        .padding(1)
        .overlay { Rectangle().strokeBorder(.role(.border), lineWidth: 1) }
        // `.edit`: a Tab stop also with keyboard navigation off, like the search field.
        .focusable(interactions: .edit)
        .focused(focus, equals: .list)
        .focusEffectDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: browser.listAccessibilityLabel))
        .accessibilityChildren {
            ForEach(browser.sections) { section in
                SectionAccessibility(section: section, customThemes: customThemes, onSelect: onSelect)
            }
        }
    }
}

/// A section as VoiceOver reads it: its header as a heading, then its error rows as text where
/// they stand and its rows as one radio group named after the slot; the variant
/// headers and the color strips are left out.
private struct SectionAccessibility: View {
    let section: AppearanceModel.Section
    let customThemes: CustomThemeActions
    let onSelect: @MainActor (String) -> Void

    var body: some View {
        Text(verbatim: section.title)
            .accessibilityAddTraits(.isHeader)
        ForEach(Array(section.accessibilityParts.enumerated()), id: \.offset) { _, part in
            switch part {
            case .radioGroup(let rows):
                Picker(selection: Binding(
                    get: { rows.first(where: \.isSelected)?.id },
                    set: { id in if let id { onSelect(id) } }
                )) {
                    ForEach(rows) { row in
                        Text(verbatim: row.accessibilityLabel)
                            .customFileActions(row.fileURL, customThemes)
                            .tag(Optional(row.id))
                    }
                } label: { Text(verbatim: section.accessibilityLabel) }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
            case .error(let row):
                Text(verbatim: row.accessibilityLabel)
                    .customFileActions(row.url, customThemes)
            }
        }
    }
}

/// `Custom` / `Built-in` (12/16 on `--surface-sunken`) or, in fixed mode, `Light` / `Dark`
/// (11.5/15 on `--surface`): 24 high with 0/10 insets and their lines inside.
private struct ListHeader: View {
    let level: AppearanceModel.Browser.PinnedHeader.Level
    let title: String
    let drawsTopLine: Bool

    var body: some View {
        Text(verbatim: title)
            .font(.plexSans(level == .section ? 12 : 11.5, weight: .semibold))
            .foregroundStyle(.role(.textMuted))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: AppearanceModel.Browser.headerHeight)
            .background(.role(level == .section ? .surfaceSunken : .surface))
            .overlay(alignment: .top) { if drawsTopLine { SettingsDivider() } }
            .overlay(alignment: .bottom) { SettingsDivider() }
            // Covers the rows scrolling under it, so a click there hits nothing.
            .contentShape(Rectangle())
    }
}

private struct ListItem: View {
    let item: AppearanceModel.Item
    let drawsTopLine: Bool
    let showsFocusRing: Bool
    let customThemes: CustomThemeActions
    let onSelect: (String) -> Void

    var body: some View {
        switch item {
        case .header(let title):
            ListHeader(level: .variant, title: title, drawsTopLine: drawsTopLine)
        case .row(let row):
            SchemeRow(row: row, drawsTopLine: drawsTopLine, showsFocusRing: showsFocusRing) { onSelect(row.id) }
                .customFileMenu(row.fileURL, customThemes)
        case .error(let row):
            ErrorRow(row: row, drawsTopLine: drawsTopLine)
                .customFileMenu(row.url, customThemes)
        }
    }
}

/// A scheme: color strip, short name 128 wide, family or file name, the check when chosen.
private struct SchemeRow: View {
    let row: AppearanceModel.Row
    let drawsTopLine: Bool
    let showsFocusRing: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                ColorStrip(theme: row.theme)
                Text(verbatim: row.name)
                    .font(.plexSans(13))
                    .foregroundStyle(.role(.text))
                    .lineLimit(1)
                    .frame(width: 128, alignment: .leading)
                Text(verbatim: row.secondaryText)
                    .font(.plexSans(12))
                    .foregroundStyle(.role(.textMuted))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SelectionCheck()
                    .foregroundStyle(.role(.accent))
                    .frame(width: 14, height: 14)
                    .opacity(row.isSelected ? 1 : 0)
            }
            .padding(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 12))
            .frame(height: AppearanceModel.Browser.rowHeight)
        }
        .buttonStyle(SchemeRowStyle(isSelected: row.isSelected, drawsTopLine: drawsTopLine, showsFocusRing: showsFocusRing))
        // The list is the stop, not each row.
        .focusable(false)
    }
}

/// Hover and pressed only on rows not chosen; the chosen one stays as it is.
private struct SchemeRowStyle: ButtonStyle {
    let isSelected: Bool
    let drawsTopLine: Bool
    let showsFocusRing: Bool

    func makeBody(configuration: Configuration) -> some View {
        SchemeRowBody(
            configuration: configuration, isSelected: isSelected, drawsTopLine: drawsTopLine, showsFocusRing: showsFocusRing
        )
    }
}

private struct SchemeRowBody: View {
    @State private var isHovered = false
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    let drawsTopLine: Bool
    let showsFocusRing: Bool

    var body: some View {
        configuration.label
            .background(fill.map { AnyShapeStyle(.role($0)) } ?? AnyShapeStyle(.clear))
            .overlay(alignment: .top) { if drawsTopLine { SettingsDivider() } }
            .overlay { if showsFocusRing { InsideFocusRing() } }
            .contentShape(Rectangle())
            .focusEffectDisabled()
            .onHover { isHovered = $0 }
    }

    private var fill: ThemeRole? {
        guard !isSelected else { return nil }
        if configuration.isPressed { return .surfaceActive }
        return isHovered ? .surfaceHover : nil
    }
}

/// A custom file that does not read: `circle-x` in the strip's column, the file name and the
/// problem on one line; not selectable, the whole text as a tooltip.
private struct ErrorRow: View {
    let row: AppearanceModel.ErrorRow
    let drawsTopLine: Bool

    var body: some View {
        HStack(spacing: 8) {
            LucideImage(.circleX, size: 14)
                .foregroundStyle(.role(.danger))
                .frame(width: ColorStrip.size.width)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: row.fileName)
                    .font(.plexSans(13))
                    .foregroundStyle(.role(.text))
                    .layoutPriority(1)
                Text(verbatim: " · \(row.problem)")
                    .font(.plexSans(12))
                    .foregroundStyle(.role(.textMuted))
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 12))
        .frame(height: AppearanceModel.Browser.rowHeight)
        .overlay(alignment: .top) { if drawsTopLine { SettingsDivider() } }
        .contentShape(Rectangle())
        .help(Text(verbatim: row.tooltip))
    }
}

/// The row's scheme at a glance, in that scheme: „Aa“ on its `--surface`, then `--accent` and
/// the three agent states. The ring sits outside, in the window's scheme.
private struct ColorStrip: View {
    let theme: Theme

    static let size = CGSize(width: 72, height: 18)
    private static let fields: [ThemeRole] = [.accent, .agentWorking, .agentWaiting, .agentDone]

    var body: some View {
        HStack(spacing: 0) {
            Text(verbatim: "Aa")
                .font(.plexSans(10, weight: .semibold))
                .foregroundStyle(.role(.text))
                .frame(width: 28, height: Self.size.height)
                .background(.role(.surface))
            ForEach(Self.fields, id: \.self) { role in
                Rectangle().fill(.role(role))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .themeFixed(theme)
        .overlay { Rectangle().stroke(.role(.border), lineWidth: 1).padding(-0.5) }
        .accessibilityHidden(true)
    }
}

/// Lucide `check` drawn with the design's stroke 2.5 on its 24 grid; the bundled SVG stays
/// unmodified at stroke 2.
private struct SelectionCheck: View {
    var body: some View {
        GeometryReader { proxy in
            let unit = proxy.size.width / 24
            Path { path in
                // "M20 6 9 17l-5-5"
                path.move(to: CGPoint(x: 20 * unit, y: 6 * unit))
                path.addLine(to: CGPoint(x: 9 * unit, y: 17 * unit))
                path.addLine(to: CGPoint(x: 4 * unit, y: 12 * unit))
            }
            .stroke(style: StrokeStyle(lineWidth: 2.5 * unit, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

// MARK: Preview

/// The popover in miniature: title bar with a tab, three rows with the agent status forms, the
/// status bar; 88 × 52 as in the design, the boxes' heights including their lines. Colors from
/// the scheme the caller sets around it.
private struct MiniPopover: View {
    /// The rows' width inside their 0/4 insets, which the design's percentages refer to.
    private static let rowWidth: CGFloat = 80

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 1).fill(.role(.surfaceRaised)).frame(width: 14, height: 5)
                Rectangle().fill(.role(.textSubtle)).frame(width: 8, height: 2)
                Rectangle().fill(.role(.textSubtle)).frame(width: 9, height: 2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .frame(height: 9)
            .background(.role(.surfaceSunken))
            line
            row(.haloDot(bright: false), role: .agentWorking, name: 0.30, detail: 0.16)
            row(.diamond, role: .agentWaiting, name: 0.24, detail: 0.22)
            row(.check, role: .agentDone, name: 0.36, detail: 0.10)
            Spacer(minLength: 0)
            line
            Rectangle().fill(.role(.surfaceSunken)).frame(height: 4)
        }
        .background(.role(.surface))
        .clipped()
        .accessibilityHidden(true)
    }

    private var line: some View {
        Rectangle().fill(.role(.border)).frame(height: 1)
    }

    /// The name and detail strokes take shares of the row's width, as in the design.
    private func row(_ shape: StatusShape, role: ThemeRole, name: CGFloat, detail: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                StatusShapeView(shape, role: role, size: 6)
                Rectangle().fill(.role(.text)).frame(width: Self.rowWidth * name, height: 2)
                Rectangle().fill(.role(role)).frame(width: Self.rowWidth * detail, height: 2)
                Spacer(minLength: 0)
                Rectangle().fill(.role(.textSubtle)).frame(width: 6, height: 2)
            }
            .padding(.horizontal, 4)
            .frame(height: 8)
            line
        }
    }
}

#if DEBUG
private struct AppearancePreview: View {
    @State var choice: ThemeChoice

    init(
        light: String = BundledThemes.defaultLight, dark: String = BundledThemes.defaultDark,
        mode: ThemeMode = .system, fixed: String = BundledThemes.defaultLight
    ) {
        _choice = State(initialValue: ThemeChoice(light: light, dark: dark, mode: mode, fixed: fixed))
    }

    var body: some View {
        AppearancePane(choice: $choice)
            .frame(width: 460, height: 720)
            .background(.role(.surface))
            .environment(\.themeChoice, choice)
            .tracksKeyboardUse()
    }
}

#Preview("Appearance – Latte in use") { AppearancePreview() }
#Preview("Appearance – Macchiato in use") { AppearancePreview().preferredColorScheme(.dark) }
#Preview("Appearance – GitHub Light, Mocha chosen") { AppearancePreview(light: "github", dark: "catppuccin-mocha") }
#Preview("Appearance – always Mocha") { AppearancePreview(mode: .fixed, fixed: "catppuccin-mocha") }
#endif
