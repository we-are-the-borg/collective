import Foundation

extension Bundle {
    /// The views' own resource bundle; `Bundle.module` is internal to this target,
    /// so tests reach the catalog through this accessor.
    static var collectiveUI: Bundle { .module }
}
