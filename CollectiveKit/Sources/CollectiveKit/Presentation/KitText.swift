import Foundation

extension Bundle {
    /// The kit's own resource bundle; from tests, `Bundle.module` names theirs.
    static var collectiveKit: Bundle { .module }
}

extension LocalizedStringResource {
    /// A text from the kit's own catalog. Without the bundle it would be looked
    /// up in the app's main bundle, which has no catalog of its own.
    static func kit(_ key: StaticString, defaultValue: String.LocalizationValue) -> LocalizedStringResource {
        LocalizedStringResource(key, defaultValue: defaultValue, bundle: .atURL(Bundle.collectiveKit.bundleURL))
    }
}
