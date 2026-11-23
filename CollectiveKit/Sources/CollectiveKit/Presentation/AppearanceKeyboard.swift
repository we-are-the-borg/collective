import Foundation

// The Appearance pane's keyboard as the design's key table has it: what a key does on a slot,
// in the open browser's search field and in its list. Tab and Shift-Tab are left to the
// system's focus order, which already runs mode group → slot → [search → Done → list] → next
// slot. The view reads the key press and carries out the action.

/// Where the keyboard focus sits in the pane: a slot, the open browser's search field, `Done`
/// or its list, which is one stop for all its rows, Custom and Built-in together.
public enum AppearanceFocus: Hashable, Sendable {
    case slot(ThemeSlot)
    case search
    case done
    case list
}

/// A key the pane may act on.
public enum AppearanceKey: Sendable, Equatable {
    case upArrow, downArrow, leftArrow, rightArrow
    case home, end, pageUp, pageDown
    case space, `return`, escape
    /// ⌘F.
    case find
    /// ⌫.
    case deleteBackward
    /// Printable text, typed without ⌘ or ⌃.
    case text(String)

    /// The text of a key press that types: none for Tab, Return, Esc, ⌫ and the function keys,
    /// whose characters are control characters or in AppKit's range from U+F700.
    public static func typed(_ characters: String) -> AppearanceKey? {
        guard !characters.isEmpty else { return nil }
        let printable = characters.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
        }
        return printable ? .text(characters) : nil
    }
}

/// What a key does in the pane.
public enum AppearanceKeyAction: Sendable, Equatable {
    /// Not the pane's: the system's handling stands (typing, the caret, the focus order).
    case pass
    /// Taken without an effect: Return in the search field, ← → in the list, ↓ without
    /// matches.
    case swallow
    /// Opens or closes the slot's browser.
    case toggle(ThemeSlot)
    /// The list's ring onto the row, without choosing it.
    case focusRow(String)
    /// The ring onto the row and the row chosen, at once.
    case selectRow(String)
    /// Chooses the row, closes the browser and puts the focus back on its slot.
    case selectAndCollapse(String)
    /// Into the search field with this text, the caret at its end.
    case editSearch(String)
    case caretToStart
    case caretToEnd
    /// Empties the search field; the list comes back.
    case clearSearch
    /// Closes the browser and puts the focus back on its slot.
    case collapse
    /// Opens the slot's browser unless it is open and focuses its search field, the text
    /// marked.
    case find(ThemeSlot)
}

extension AppearanceModel {
    /// What `key` does with the focus at `focus`, `nil` for anywhere else in the window;
    /// `focusedRowID` is the row with the ring while the list has the focus.
    public func action(for key: AppearanceKey, focus: AppearanceFocus?, focusedRowID: String?) -> AppearanceKeyAction {
        if key == .find {
            // Inside an open browser ⌘F stays in it; anywhere else it opens the slot in use.
            if let browser, let focus, [.search, .list, .done].contains(focus) {
                return .find(browser.slot)
            }
            return .find(slotInUse)
        }
        switch focus {
        case .slot(let slot):
            return key == .space || key == .return ? .toggle(slot) : .pass
        case .search:
            return browser.map { searchAction(for: key, in: $0) } ?? .pass
        case .list:
            return browser.map { listAction(for: key, in: $0, focusedRowID: focusedRowID) } ?? .pass
        case .done, nil:
            return .pass
        }
    }

    /// The slot macOS shows now; in fixed mode the only one.
    private var slotInUse: ThemeSlot {
        (slots.first(where: \.isInUse) ?? slots.first)?.id ?? .fixed
    }

    private func searchAction(for key: AppearanceKey, in browser: Browser) -> AppearanceKeyAction {
        switch key {
        case .downArrow: browser.entryRowID.map(AppearanceKeyAction.focusRow) ?? .swallow
        case .return: .swallow
        case .escape: browser.query.isEmpty ? .collapse : .clearSearch
        // The field editor scrolls on Home and End, it does not move the caret.
        case .home: .caretToStart
        case .end: .caretToEnd
        default: .pass
        }
    }

    private func listAction(for key: AppearanceKey, in browser: Browser, focusedRowID: String?) -> AppearanceKeyAction {
        guard let current = browser.focusedRow(focusedRowID), let first = browser.rowIDs.first,
              let last = browser.rowIDs.last else { return .pass }
        /// Choosing the row already chosen changes nothing and reads nothing again.
        func select(_ id: String?) -> AppearanceKeyAction {
            guard let id else { return .pass }
            return id == current && browser.row(id)?.isSelected == true ? .swallow : .selectRow(id)
        }
        switch key {
        case .downArrow: return select(browser.rowID(from: current, by: 1))
        case .upArrow: return current == first ? .editSearch(browser.query) : select(browser.rowID(from: current, by: -1))
        case .home: return select(first)
        case .end: return select(last)
        case .pageDown: return select(browser.rowID(from: current, by: browser.pageRowCount))
        case .pageUp: return select(browser.rowID(from: current, by: -browser.pageRowCount))
        case .space: return select(current)
        case .return: return .selectAndCollapse(current)
        case .escape: return .collapse
        case .leftArrow, .rightArrow: return .swallow
        // No type-select: the keys go on in the search field.
        case .text(let text): return .editSearch(browser.query + text)
        case .deleteBackward: return .editSearch(String(browser.query.dropLast()))
        case .find: return .pass
        }
    }
}

extension AppearanceModel.Browser {
    /// The row with the list's ring: `focusedRowID` while it is a row of the list, else where
    /// the focus enters it, as after Tab or once the search filtered the row away.
    public func focusedRow(_ focusedRowID: String?) -> String? {
        focusedRowID.flatMap { rowIDs.contains($0) ? $0 : nil } ?? entryRowID
    }

    public func row(_ id: String) -> AppearanceModel.Row? {
        for section in sections {
            for case .row(let row) in section.items where row.id == id { return row }
        }
        return nil
    }
}
