import AppKit
import CollectiveKit
import CollectiveUI
import SubspaceKit
import SwiftUI

/// Wires the popover view to the model. `PopoverController` builds this view
/// on every open and drops it on close, so its clocks only run while the
/// popover is on screen; the controller also tells the model about both.
/// The clock turns only when the model changes by time alone (`ModelClock`);
/// the times that count have their own at the leaves.
struct PopoverContent: View {
    let model: CollectiveModel
    let onSetUp: () -> Void
    let onSettings: () -> Void
    let onOpenUpdate: (UpdateFooterLink.Target) -> Void

    var body: some View {
        ModelClock { now in model.popoverModel(now: now) } content: { popover in
            PopoverView(
                popover,
                onSelectTab: model.selectTab,
                onToggleEarlierSessions: model.toggleEarlierSessions,
                onArchive: model.archive,
                onUndo: model.undo,
                onUndoHover: model.undoHover,
                onUndoLast: model.undoLast,
                onToggleSubagents: model.toggleSubagents,
                onToggleSubagentFold: model.toggleSubagentFold,
                onCheckAgain: model.checkIntegrations,
                onSetUp: onSetUp,
                onSettings: onSettings,
                onOpenUpdate: onOpenUpdate,
                onShowTerminal: { _ = model.showTerminal($0) },
                onRowSeen: model.rowSeen
            )
        }
    }
}
