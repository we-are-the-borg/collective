import AppKit
import CollectiveKit
import CollectiveUI
import SwiftUI

/// The setup window's scene id and the link in its footer.
enum SetupWindow {
    static let id = "setup"
    /// The README's FAQ entry.
    static let faqURL = URL(string: "https://github.com/we-are-the-borg/collective#what-if-i-dont-see-any-sessions")
}

extension OpenWindowAction {
    func openSetupWindow() {
        bringToFront(id: SetupWindow.id)
    }
}

/// Wires the setup window to the model. The tools are checked when it opens,
/// so it never shows an old result, and every 5 s while it is open, so
/// commands the user runs meanwhile show up.
struct SetupWindowContent: View {
    let model: CollectiveModel

    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            SetupWindowView(
                model: SetupWindowModel(
                    integrations: model.integrations,
                    runs: model.setupRuns.snapshots,
                    lastEvents: model.lastEvents.bySource,
                    outputShown: model.setupRuns.outputShown,
                    updateRuns: model.setupRuns.updateSnapshots,
                    availability: model.updateAvailabilities,
                    checksForUpdates: model.releaseChecker.checksForUpdates,
                    checkedAt: model.integrationsCheckedAt,
                    now: context.date
                ),
                appIcon: Image(nsImage: NSApp.applicationIconImage),
                faqURL: SetupWindow.faqURL,
                onRun: model.runSetup,
                onRunUpdate: model.runUpdate,
                onToggleOutput: model.setupRuns.toggleOutput(for:),
                onCheckAgain: model.checkIntegrations,
                onClose: { dismissWindow(id: SetupWindow.id) }
            )
        }
        // Runs show until the window closes; see `SetupRuns`.
        .onAppear {
            model.setupRuns.windowDidAppear(.setup)
            DockPresence.opened(SetupWindow.id)
            // The update switch's footnote promises a lookup when Setup opens.
            model.checkSubspaceReleasesOnOpen()
        }
        .onDisappear { model.setupRuns.windowDidDisappear(.setup) }
        // Cancelled when the window closes.
        .task {
            while !Task.isCancelled {
                model.checkIntegrations()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}
