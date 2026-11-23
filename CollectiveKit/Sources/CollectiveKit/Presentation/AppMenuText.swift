import Foundation

/// Items the app puts into the standard menu bar it has while a window is
/// open (`DockPresence`), kept here so every text lives in the kit's catalog.
public enum AppMenuText {
    /// Replaces the standard About panel: there is only one About, the
    /// settings pane, with its own version rule (`AppVersionLabel`).
    public static let about: LocalizedStringResource = .kit("About The Collective", defaultValue: "About The Collective")
}
