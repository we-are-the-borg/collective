extension Array where Element: Equatable {
    /// The element `offset` places from `element`, held at either end: what ↑ ↓ (and ← →)
    /// select in a macOS list or radio group, which do not wrap around. Nil when `element`
    /// is not one of them.
    public func arrowKeyStep(from element: Element, by offset: Int) -> Element? {
        guard let index = firstIndex(of: element) else { return nil }
        return self[Swift.min(Swift.max(index + offset, 0), count - 1)]
    }
}
