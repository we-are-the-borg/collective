import SwiftUI

/// Marks the runs of inline code in a reply, so `InlineCodeRenderer` finds them.
struct InlineCodeAttribute: TextAttribute {}

/// The shape of inline code: square like every box in the popover, padding
/// 0 × 3, on `--surface-sunken`. Apart
/// from SwiftUI so the geometry can be tested.
enum InlineCodeFill {
    /// Left and right of the code, inside the fill.
    static let padding: CGFloat = 3
    /// Runs of one line closer than this belong to one code span: the layout
    /// splits a span where its attributes change, as at its tracked last character.
    static let joinTolerance: CGFloat = 0.5

    /// Per run, whether its last character carries the fill's padding as
    /// tracking: the last character of every code run, for the padding on the
    /// right, and the last character before a code run, for the padding on
    /// the left.
    static func tracksLastCharacter(codeFlags: [Bool]) -> [Bool] {
        codeFlags.indices.map { index in
            codeFlags[index] || (codeFlags.indices.contains(index + 1) && codeFlags[index + 1])
        }
    }

    /// The fill behind one code span. `runRect` already holds the padding on
    /// the right, as tracking on the span's last character, so only the left
    /// padding is added; that one lies in the tracking of the character before.
    /// No higher than a line, so the fills of two lines never touch.
    static func codeBackground(runRect: CGRect, lineHeight: CGFloat) -> CGRect {
        let height = min(runRect.height, lineHeight)
        return CGRect(
            x: runRect.minX - padding,
            y: runRect.midY - height / 2,
            width: runRect.width + padding,
            height: height
        )
    }

    /// The fills behind the code runs of one line: touching runs are one span
    /// and get one rounded fill, not two that overlap.
    static func codeBackgrounds(runRects: [CGRect], lineHeight: CGFloat) -> [CGRect] {
        var spans: [CGRect] = []
        for rect in runRects.sorted(by: { $0.minX < $1.minX }) {
            if let last = spans.last, rect.minX <= last.maxX + joinTolerance {
                spans[spans.count - 1] = last.union(rect)
            } else {
                spans.append(rect)
            }
        }
        return spans.map { codeBackground(runRect: $0, lineHeight: lineHeight) }
    }
}

/// Draws a fill behind every run marked `InlineCodeAttribute`, then the text
/// as SwiftUI lays it out. A `Text` run takes a background color but no
/// padding; the renderer gives the code its design shape without changing the
/// text, its layout or its selection.
struct InlineCodeRenderer: TextRenderer {
    /// The text's line height, which caps the fill's height.
    let lineHeight: CGFloat
    /// The resolved `--surface-sunken`: a renderer draws colors, not styles.
    let fill: Color

    /// A span at the start of a line has no character before it to hold its
    /// left padding, so its fill reaches that far beyond the text.
    var displayPadding: EdgeInsets {
        EdgeInsets(top: 0, leading: InlineCodeFill.padding, bottom: 0, trailing: 0)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            let codeRects = line.filter { $0[InlineCodeAttribute.self] != nil }.map(\.typographicBounds.rect)
            for rect in InlineCodeFill.codeBackgrounds(runRects: codeRects, lineHeight: lineHeight) {
                context.fill(Path(rect), with: .color(fill))
            }
            for run in line {
                context.draw(run)
            }
        }
    }
}
