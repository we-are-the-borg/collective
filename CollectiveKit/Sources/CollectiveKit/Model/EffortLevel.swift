/// How much an agent's model thinks. Every tool has its own scale, so the
/// adapter spreads its tool's levels over the steps 1 to 5 and passes the
/// level's name as the tool writes it: what shows the effort needs to know
/// no tool's scale, only the step, and can still name the level.
public struct EffortLevel: Sendable, Equatable {
    /// 1 is the least effort, 5 the most.
    public let step: Int
    public let name: String

    /// Nil for a step off the scale: a gauge of five steps can't show it.
    public init?(step: Int, name: String) {
        guard (1...5).contains(step) else { return nil }
        self.step = step
        self.name = name
    }
}
