import Foundation

// The browser's list box as the design lays it out: every item has a fixed height with its lines
// inside, so where each header sits follows from the items alone, without measuring the drawn
// list. A lazy list draws only the rows in view, so the headers that stick at the top
// (`position: sticky` in the design) are worked out here and drawn over it.

extension AppearanceModel.Browser {
    /// Section headers and the variant headers of fixed mode.
    public static let headerHeight: Double = 24
    /// Rows and error rows.
    public static let rowHeight: Double = 32

    /// The box's height at most, its 1 px line included: just over 6 rows in Match, 8 in fixed mode.
    public var maxBoxHeight: Double {
        slot == .fixed ? 262 : 200
    }

    /// The rows Page Up and Page Down move: a box's height.
    public var pageRowCount: Int {
        Int(maxBoxHeight / Self.rowHeight)
    }

    /// The items' height, which the box takes up to its maximum.
    public var contentHeight: Double {
        sections.reduce(0) { $0 + $1.height }
    }

    /// A header stuck at the top of the box.
    public struct PinnedHeader: Sendable, Equatable, Identifiable {
        public enum Level: Sendable, Equatable {
            /// `Custom`, `Built-in`: at 0, on `--surface-sunken`.
            case section
            /// `Light`, `Dark` in fixed mode: 24 below, on `--surface`.
            case variant
        }

        public let level: Level
        public let title: String
        public let drawsTopLine: Bool
        /// From the box's top edge; below 0 while the next section pushes it out.
        public let y: Double

        public var id: String { "\(level):\(title)" }
    }

    /// The headers stuck at the top of the box scrolled `scrollOffset` down, in drawing order
    /// (later ones paint over earlier ones). A section header sticks at 0 until its section's
    /// end pushes it up; a variant header sticks 24 lower within its section, and the next one
    /// slides over it, as in the design. Empty while unscrolled: every header stands in place.
    public func pinnedHeaders(scrollOffset offset: Double) -> [PinnedHeader] {
        guard offset > 0 else { return [] }
        let header = Self.headerHeight
        var start = 0.0
        for (sectionIndex, section) in sections.enumerated() {
            let end = start + section.height
            defer { start = end }
            guard start < offset, offset < end else { continue }
            // The header's bottom stays inside its section.
            let limit = end - offset - header

            var variants: [PinnedHeader] = []
            var y = start + header
            for (index, item) in section.items.enumerated() {
                defer { y += item.height }
                guard case .header(let title) = item else { continue }
                let shown = y - offset
                let pinned = PinnedHeader(level: .variant, title: title, drawsTopLine: section.drawsTopLine(at: index), y: min(header, limit))
                if shown <= header {
                    // The latest one stuck covers those before it.
                    variants = [pinned]
                } else if shown < 2 * header {
                    // Still sliding in, over the stuck one.
                    variants.append(PinnedHeader(level: .variant, title: title, drawsTopLine: pinned.drawsTopLine, y: shown))
                }
            }
            let sectionHeader = PinnedHeader(level: .section, title: section.title, drawsTopLine: drawsTopLine(ofSection: sectionIndex), y: min(0, limit))
            return variants + [sectionHeader]
        }
        return []
    }
}

extension AppearanceModel.Browser {
    /// Where the box scrolled `offset` down must scroll so that row `id` stands wholly in its
    /// `viewport`, below the headers stuck over it: its section's, and in fixed mode its
    /// variant's; `nil` while it already does, or for no row of the list.
    public func scrollOffset(revealing id: String, from offset: Double, viewport: Double) -> Double? {
        var y = 0.0
        for section in sections {
            y += Self.headerHeight
            var underVariant = false
            for item in section.items {
                defer { y += item.height }
                if case .header = item { underVariant = true }
                guard case .row(let row) = item, row.id == id else { continue }
                let top = y - Self.headerHeight * (underVariant ? 2 : 1)
                let bottom = y + Self.rowHeight - viewport
                if offset > top { return max(0, top) }
                if offset < bottom { return bottom }
                return nil
            }
        }
        return nil
    }
}

extension AppearanceModel.Browser {
    /// A line above a section's header where the section above ends in an item; an empty
    /// `Custom` ends in its header, which draws its own line below.
    public func drawsTopLine(ofSection index: Int) -> Bool {
        index > 0 && !sections[index - 1].items.isEmpty
    }
}

extension AppearanceModel.Section {
    /// A line above every item but the first and one right under a header.
    public func drawsTopLine(at index: Int) -> Bool {
        guard index > 0 else { return false }
        if case .header = items[index - 1] { return false }
        return true
    }

    var height: Double {
        AppearanceModel.Browser.headerHeight + items.reduce(0) { $0 + $1.height }
    }
}

extension AppearanceModel.Item {
    var height: Double {
        if case .header = self { AppearanceModel.Browser.headerHeight } else { AppearanceModel.Browser.rowHeight }
    }
}
