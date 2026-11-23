import Foundation
import Synchronization
import Testing

/// Marks a suite whose cases each keep threads busy for a long stretch: the
/// replays of every captured run, the randomized tree walks. Across the whole
/// run, at most `HeavyGate.width` of these cases run at once; the others wait
/// suspended and hold no thread meanwhile.
///
/// Swift Testing starts every case at once on the cooperative pool, one thread
/// per core. Unbounded, these cases filled the pool, and the tests waiting for
/// a reader's or a status source's next batch (`SpoolReaderTests`,
/// `ClaudeCodeSessionStatusSourceTests`) ran into their `waitFor`/`eventually`
/// limits. `.serialized` would not do, it only
/// orders the cases of one suite.
struct HeavyTrait: SuiteTrait, TestTrait, TestScoping {
    var gate: HeavyGate = .shared

    @TaskLocal static var isInside = false

    var isRecursive: Bool { true }

    /// Each case takes the gate, not the suite around it: a suite holding it
    /// would keep its own cases out.
    func scopeProvider(for test: Test, testCase: Test.Case?) -> HeavyTrait? {
        testCase == nil ? nil : self
    }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        // Traits are not deduplicated: a case under two `.heavy` (nested
        // suites, or suite and test) would otherwise wait for a second place.
        guard !Self.isInside else { return try await function() }
        await gate.enter()
        defer { gate.leave() }
        try await Self.$isInside.withValue(true) { try await function() }
    }
}

extension Trait where Self == HeavyTrait {
    static var heavy: Self { HeavyTrait() }
}

/// A counting semaphore whose waiters are suspended, not blocked.
final class HeavyGate: Sendable {
    /// Half the pool: the other half stays free for the tests that wait, and a
    /// single run takes no longer than without the gate.
    static let width = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    static let shared = HeavyGate(width: width)

    private struct State {
        var free: Int
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state: Mutex<State>

    init(width: Int) { state = Mutex(State(free: width)) }

    /// The places nobody holds right now.
    var free: Int { state.withLock { $0.free } }

    /// Ignores cancellation: a cancelled case still waits for its place, which
    /// is fine because every place is released and the wait ends.
    func enter() async {
        await withCheckedContinuation { continuation in
            let entered = state.withLock { state in
                guard state.free > 0 else {
                    state.waiting.append(continuation)
                    return false
                }
                state.free -= 1
                return true
            }
            if entered { continuation.resume() }
        }
    }

    /// Hands the place to the longest waiter, or frees it.
    func leave() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.waiting.isEmpty else {
                state.free += 1
                return nil
            }
            return state.waiting.removeFirst()
        }
        next?.resume()
    }
}
