import AppKit
import CollectiveKit
import os
import UniformTypeIdentifiers

/// The Appearance pane's custom theme actions with the panels the system draws: the open panel,
/// "Replace?" and the failure alerts, and Finder (design `themes.md` › Eigene Themes). What each
/// import outcome shows comes from the kit (`CustomThemeImportAlert`); the catalog follows by
/// itself, since the library re-reads the folder after an import and a Move to Trash.
@MainActor
enum CustomThemeCommands {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Collective", category: "CustomThemes")

    /// Several files at once, YAML only; invalid ones are copied all the same
    /// and show as error rows.
    static func importThemes(into library: CustomThemeLibrary) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.allowedContentTypes = yamlTypes
        // App-modal, so it would otherwise follow the system, not the active scheme.
        panel.appearance = ThemeDefaults.activeNSAppearance()
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task {
            let plan = await library.importPlan(for: urls)
            var replacing = Set<URL>()
            for source in plan.conflicts where askToReplace(source.lastPathComponent) {
                replacing.insert(source)
            }
            let results = await library.import(urls, replacing: replacing)
            for alert in CustomThemeImportAlert.alerts(after: results) {
                show(alert)
            }
        }
    }

    /// Creates the folder first: it does not exist until the first import.
    static func showFolder(of library: CustomThemeLibrary) {
        Task {
            do {
                try await library.ensureFolder()
            } catch {
                log.error("Could not create the themes folder: \(String(describing: error), privacy: .public)")
                return
            }
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: library.folder.path)
        }
    }

    static func showFile(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Without asking: the Trash gives it back. A chosen theme falls back by itself.
    static func moveToTrash(_ url: URL, in library: CustomThemeLibrary) {
        Task {
            do {
                try await library.moveToTrash(url)
            } catch {
                log.error("Could not move \(url.lastPathComponent, privacy: .public) to the Trash: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// `.yml` too, should the system not count it as `public.yaml`.
    private static var yamlTypes: [UTType] {
        var types = [UTType.yaml]
        for ext in ["yaml", "yml"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }

    /// Cancel is the default, so Return and Esc keep the file in the folder.
    private static func askToReplace(_ fileName: String) -> Bool {
        let prompt = CustomThemeImportAlert.replace(fileName: fileName)
        let alert = NSAlert()
        alert.messageText = prompt.message
        alert.informativeText = prompt.informativeText
        let cancel = alert.addButton(withTitle: String(localized: CustomThemeImportAlert.cancelButton))
        let replace = alert.addButton(withTitle: String(localized: CustomThemeImportAlert.replaceButton))
        cancel.keyEquivalent = "\r"
        replace.keyEquivalent = ""
        alert.window.appearance = ThemeDefaults.activeNSAppearance()
        // A button has one key equivalent: Cancel holds Return, so Esc reaches it this way.
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, event.window == alert.window else { return event }
            cancel.performClick(nil)
            return nil
        }
        defer { escape.map(NSEvent.removeMonitor) }
        return alert.runModal() == .alertSecondButtonReturn
    }

    private static func show(_ content: CustomThemeImportAlert) {
        let alert = NSAlert()
        alert.messageText = content.message
        alert.informativeText = content.informativeText
        alert.addButton(withTitle: String(localized: SettingsText.ok))
        alert.window.appearance = ThemeDefaults.activeNSAppearance()
        alert.runModal()
    }
}
