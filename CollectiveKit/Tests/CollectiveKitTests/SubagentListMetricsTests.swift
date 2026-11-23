import AppKit
import SwiftUI
import Testing
@testable import CollectiveUI

/// The numbers of a row's subagent section.
@Suite("Subagent list metrics")
struct SubagentListMetricsTests {
    /// Level 1 is the orchestrator's own subagents; 14 pt in per level below it.
    @Test func eachLevelIsIndentedFourteenPoints() {
        #expect(SubagentListMetrics.leadingInset(depth: 1) == 10)
        #expect(SubagentListMetrics.leadingInset(depth: 2) == 24)
        #expect(SubagentListMetrics.leadingInset(depth: 4) == 52)
        // No level above the first.
        #expect(SubagentListMetrics.leadingInset(depth: 0) == 10)
    }

    /// The toggle line 22 high; the list pulled up 2 and in 4, behind a 1 px guide line.
    @Test func theListHangsUnderTheToggleLine() {
        #expect(SubagentListMetrics.toggleHeight == 22)
        #expect(SubagentListMetrics.pullUp == 2)
        #expect(SubagentListMetrics.listInset == 4)
        #expect(SubagentListMetrics.guideWidth == 1)
    }

    /// One line 24 high on the grid `12px | 1fr | auto`, gap 8, the form 10 pt.
    @Test func aRowIsOneLineOnTheBoardsGrid() {
        #expect(SubagentListMetrics.rowHeight == 24)
        #expect(SubagentListMetrics.rowLeading == 10)
        #expect(SubagentListMetrics.shapeColumn == 12)
        #expect(SubagentListMetrics.shapeSize == 10)
        #expect(SubagentListMetrics.columnGap == 8)
    }

    @Test func theListIsAsTallAsItsRowsUpTo220() {
        #expect(SubagentListMetrics.maxHeight == 220)
        #expect(SubagentListMetrics.visibleHeight(content: 80) == 80)
        #expect(SubagentListMetrics.visibleHeight(content: 220) == 220)
        #expect(SubagentListMetrics.visibleHeight(content: 1_400) == 220)
    }

    /// Measured in the layout pass: a scroll view unbounded in height asks for
    /// what it holds, so a short list is as tall as its rows from the first frame.
    @MainActor @Test(arguments: [(2, 80.0), (5, 200.0), (6, 220.0), (40, 220.0)])
    func theCappedScrollViewTakesItsRowsHeight(rows: Int, height: Double) {
        let view = CappedHeight(maxHeight: SubagentListMetrics.maxHeight) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(0..<rows, id: \.self) { _ in Color.clear.frame(height: 40) }
                }
            }
        }
        .frame(width: 300)
        #expect(Double(NSHostingView(rootView: view).fittingSize.height).rounded() == height)
    }
}
