import CollectiveKit
import Observation

/// The live theme catalog, bundled and custom, for every window and the popover. One for the
/// app, like `SystemAppearance`, because `themedFromDefaults()` and the AppKit panels read it
/// wherever they are made. The folder is read in `init`, so a chosen custom theme shows from the
/// first frame instead of flashing the default (measured: well under a millisecond without a folder,
/// about 3 ms for a handful of files, in a release build).
@MainActor @Observable
final class ThemeCatalogStore {
    static let shared = ThemeCatalogStore()

    private(set) var catalog: ThemeCatalog
    /// For the Appearance pane: `reload()`, `ensureFolder()`, import and Move to Trash.
    @ObservationIgnored let library: CustomThemeLibrary
    @ObservationIgnored private var watching: Task<Void, Never>?

    private init() {
        library = CustomThemeLibrary()
        catalog = library.initialCatalog
    }

    /// Follows the folder from now on. Once, at launch.
    func start() {
        guard watching == nil else { return }
        // The folder may have changed while the app was not running.
        refreshRemembered()
        watching = Task { [library] in
            for await catalog in library.catalogs() {
                self.catalog = catalog
                self.refreshRemembered()
            }
        }
    }

    /// A chosen custom file that now writes another name or variant is remembered as it reads
    /// now; written only on a change, so the defaults and the windows reading them stay
    /// quiet otherwise.
    private func refreshRemembered() {
        let choice = ThemeDefaults.choice()
        let refreshed = choice.refreshingRemembered(catalog: catalog)
        guard refreshed != choice else { return }
        ThemeDefaults.storeRemembered(of: refreshed)
    }
}
