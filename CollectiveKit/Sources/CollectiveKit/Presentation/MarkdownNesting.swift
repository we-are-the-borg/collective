import cmark_gfm
import cmark_gfm_extensions

/// Decides whether a text is safe to hand to swift-markdown, which builds,
/// walks and releases its tree by recursion: a reply that nests deep enough
/// overflows the stack, and since replies are replayed from the event store,
/// it would do so at every launch.
///
/// swift-markdown parses with cmark-gfm and then converts the result. cmark
/// itself parses, walks and frees without recursion, however deep the text
/// nests, so the same parse is done here first and its tree measured: the
/// depth is exactly the one swift-markdown would go on to convert.
///
/// The same goes for a tree that is shallow but huge, which costs time and
/// memory instead of the stack: its nodes are counted on the same walk. What
/// cmark-gfm itself would pay for is turned down before it parses, from the
/// text alone.
enum MarkdownNesting {
    /// The deepest tree that is still handed on, counted in nodes from the
    /// document down to the deepest text.
    ///
    /// Measured with swift-markdown 0.9 on arm64, on a thread of 512 kB (what
    /// a secondary thread and the concurrency pool get): converting, walking
    /// and releasing a tree survives a depth of 64 in a release build and of
    /// 135 in a debug build, whatever nests (block quotes, emphasis and
    /// emphasis in a table cell give out first, lists and images later). 24
    /// is three eighths of that: previewing trees of exactly this depth took
    /// a stack of 192 kB in a release build (160 kB was too little) and of
    /// 96 kB in a debug build, so five eighths of such a stack stay with the
    /// caller. Replies people read stay far below: three nested lists in a
    /// quote with a link in bold are 13.
    static let limit = 24

    /// The largest tree that is still handed on, in nodes. cmark-gfm pads
    /// every row of a table to the width of its header, so 8 kB of text can
    /// hold half a million empty cells, which took swift-markdown a second
    /// and 260 MB to convert, at every launch.
    ///
    /// Converting costs about 1.9 µs a node in a release build and 5 µs in a
    /// debug build, whatever the node: this many take 30 ms (80 ms). Text
    /// without a table gives at most one node a byte, so within the 8 kB a
    /// preview parses only padded tables reach the limit. A whole reply does
    /// when a quarter of its bytes are structure: 32 kB of a table with two
    /// short columns, a table of twelve columns beyond 640 rows, or 21 kB of
    /// list items of one letter.
    static let nodeLimit = 16_000

    /// How many steps cmark-gfm may spend looking back over the tables of a
    /// text, see `tableWork(of:)`: at up to 6 ns each 3 ms in a release
    /// build, spent again by every parse.
    static let tableStepLimit = 500_000

    static func exceedsLimit(_ text: String) -> Bool {
        if tableExceedsLimit(text) { return true }
        let size = size(of: text, stoppingAbove: nodeLimit)
        return size.depth > limit || size.nodes > nodeLimit
    }

    /// Whether the tables `text` could hold are too much for cmark-gfm
    /// itself, which pays for them while it parses, before there is a tree
    /// to measure: 2.3 GB and a second for sixteen padded tables in 64 kB,
    /// seven seconds for a column of "^".
    static func tableExceedsLimit(_ text: String) -> Bool {
        let work = tableWork(of: text)
        return work.cells > nodeLimit || work.steps > tableStepLimit
    }

    /// At most how many cells the tables in `text` have, and at most how
    /// many steps cmark-gfm spends looking back over them. Reads the bytes
    /// once and parses nothing: an upper bound, so little here means little
    /// there, while much may still turn out harmless.
    ///
    /// A table begins with a header and a delimiter row below it, which holds
    /// nothing but dashes, colons, pipes and blanks, after the ">" of the
    /// quotes it is in. It is as wide as both: each has at most one cell more
    /// than it has pipes, and the delimiter row a dash in every cell. Every
    /// line after them up to the next blank one may be a row. Three things
    /// then grow faster than the text:
    /// - a row is padded with empty cells to the width of the table,
    /// - an empty cell looks back over its row for the cell it widens, so
    ///   reading a line of p pipes as a row takes up to (p+1)(p+2)/2 steps,
    ///   and a row is read twice: to see that the table goes on, then to
    ///   add it,
    /// - a cell of "^" walks up the rows above it for the cell it extends,
    ///   and finds each by counting from the start of that row.
    ///
    /// cmark-gfm reads a line as a row only while a table is open, or when
    /// the line may be a delimiter row: then that line and every line of
    /// the paragraph above it, once per paragraph, and twice each where its
    /// arena allocator is in use. Pipes anywhere else, as on a line of a
    /// code block, cost nothing.
    ///
    /// What counts for more than it is: lines after a table that are not its
    /// rows because another block began without a blank line (1,800 lines of
    /// a code block right below a table of seven columns), carets that are
    /// not a cell of their own (one in each of 400 rows of a table of five
    /// columns), and lines above a line of dashes that are no paragraph with
    /// it (706 pipes on a line of a code block, a line of dashes further
    /// down in it and no blank line between).
    static func tableWork(of text: String) -> (cells: Int, steps: Int) {
        var cells = 0, steps = 0
        // Of the widest table that may be open, and of the line being read.
        var width = 0, rows = 0
        var pipes = 0, dashes = 0, carets = 0, isBlank = true, isDelimiterRow = true
        var pipesAbove = 0, afterReturn = false
        // Reading twice as rows the lines since the last blank one that no
        // delimiter row was read with yet.
        var headerSteps = 0

        func endLine() {
            if isBlank {
                // Ends every table, whatever it is nested in.
                width = 0
                rows = 0
                pipesAbove = 0
                headerSteps = 0
            } else {
                rows += 1
                cells += width
                let rowSteps = (pipes + 1) * (pipes + 2)
                if width > 0 { steps += rowSteps }
                steps += carets * rows * width
                headerSteps += rowSteps
                // This line as a delimiter row, read with all that may be the
                // paragraph above it. A paragraph that is no table then is not
                // read again, so its lines are counted here once.
                if rows > 1, isDelimiterRow, dashes > 0 {
                    steps += headerSteps
                    headerSteps = 0
                }
                // This line as a delimiter row and the one above as its header,
                // which was not counted as a row of this table yet.
                let columns = min(min(pipesAbove, pipes) + 1, dashes)
                if rows > 1, isDelimiterRow, columns > width {
                    width = columns
                    cells += columns
                }
                pipesAbove = pipes
            }
            pipes = 0
            dashes = 0
            carets = 0
            isBlank = true
            isDelimiterRow = true
        }

        for byte in text.utf8 {
            // A return and a line feed end one line, not two.
            if byte == 0x0A, afterReturn {
                afterReturn = false
                continue
            }
            afterReturn = byte == 0x0D
            switch byte {
            case 0x0A, 0x0D: endLine()
            case 0x20, 0x09: break
            case UInt8(ascii: "|"): (pipes, isBlank) = (pipes + 1, false)
            case UInt8(ascii: "-"): (dashes, isBlank) = (dashes + 1, false)
            case UInt8(ascii: ":"), UInt8(ascii: ">"), 0x0B, 0x0C: isBlank = false
            case UInt8(ascii: "^"): (carets, isBlank, isDelimiterRow) = (carets + 1, false, false)
            default: (isBlank, isDelimiterRow) = (false, false)
            }
        }
        endLine()
        return (cells, steps)
    }

    /// The depth of the tree cmark-gfm builds for `text`.
    static func depth(of text: String) -> Int {
        size(of: text).depth
    }

    /// The depth and the number of nodes of the tree cmark-gfm builds for
    /// `text`, set up as swift-markdown sets it up for `Document(parsing:)`
    /// without options: the same flags and the same three extensions. Stops
    /// counting once there are more nodes than `nodeLimit`: the depth is then
    /// the one reached so far.
    static func size(of text: String, stoppingAbove nodeLimit: Int = .max) -> (depth: Int, nodes: Int) {
        cmark_gfm_core_extensions_ensure_registered()
        // Without a parser or a tree nothing is known: too large to pass.
        guard let parser = cmark_parser_new(CMARK_OPT_TABLE_SPANS | CMARK_OPT_SMART | CMARK_OPT_SOURCEPOS) else { return (.max, .max) }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "tasklist"] {
            cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension(name))
        }
        cmark_parser_feed(parser, text, text.utf8.count)
        guard let document = cmark_parser_finish(parser) else { return (.max, .max) }
        defer { cmark_node_free(document) }

        // Down to the first child, else on to the next sibling, else back up
        // to a parent that has one: every node once, no stack but this loop.
        var deepest = 1
        var depth = 1
        var nodes = 1
        var node = document
        while nodes <= nodeLimit {
            if let child = cmark_node_first_child(node) {
                node = child
                depth += 1
                nodes += 1
                deepest = max(deepest, depth)
                continue
            }
            while node != document, cmark_node_next(node) == nil, let parent = cmark_node_parent(node) {
                node = parent
                depth -= 1
            }
            guard node != document, let next = cmark_node_next(node) else { break }
            node = next
            nodes += 1
        }
        return (deepest, nodes)
    }
}
