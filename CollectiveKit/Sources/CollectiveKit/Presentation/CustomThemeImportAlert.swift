import Foundation

/// A system alert around an import of custom themes, in macOS's own wording; the app shows it
/// with `NSAlert`, which draws it.
public struct CustomThemeImportAlert: Sendable, Equatable {
    public let message: String
    public let informativeText: String

    /// Asked once per name the folder already has, before anything is copied.
    public static func replace(fileName: String) -> CustomThemeImportAlert {
        CustomThemeImportAlert(
            message: String(localized: .kit(
                "“%@” already exists. Do you want to replace it?",
                defaultValue: "“\(fileName)” already exists. Do you want to replace it?"
            )),
            informativeText: String(localized: .kit(
                "A file with the same name already exists in the Themes folder. Replacing it will overwrite its current contents.",
                defaultValue: "A file with the same name already exists in the Themes folder. Replacing it will overwrite its current contents."
            ))
        )
    }

    /// The prompt's buttons; Cancel is the default, so Return keeps the file there.
    public static let replaceButton: LocalizedStringResource = .kit("Replace", defaultValue: "Replace")
    public static let cancelButton: LocalizedStringResource = .kit("Cancel", defaultValue: "Cancel")

    /// What to tell after an import: one alert per file that could not be copied, with the
    /// system's reason. Invalid files are copied and show as error rows, a declined name
    /// was the user's answer, so neither gets one.
    public static func alerts(after results: [CustomThemeImport]) -> [CustomThemeImportAlert] {
        results.compactMap { result in
            guard case .failed(let reason) = result.outcome else { return nil }
            let name = result.fileName
            return CustomThemeImportAlert(
                message: String(localized: .kit("Couldn’t import “%@”.", defaultValue: "Couldn’t import “\(name)”.")),
                informativeText: reason
            )
        }
    }
}
