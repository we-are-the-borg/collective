import Synchronization
import Testing

/// Not `.heavy` itself: the scopes below would count as nested inside it.
struct HeavyTraitTests {
    /// A case under two `.heavy` traits (nested suites, or suite and test) must
    /// take one place, not wait for a second one it might never get.
    @Test func nestedScopesHoldOnePlace() async throws {
        let gate = HeavyGate(width: 2)
        let trait = HeavyTrait(gate: gate)
        let test = try #require(Test.current)
        let freeInside = Mutex<Int?>(nil)
        try await trait.provideScope(for: test, testCase: Test.Case.current) {
            try await trait.provideScope(for: test, testCase: Test.Case.current) {
                freeInside.withLock { $0 = gate.free }
            }
        }
        #expect(freeInside.withLock { $0 } == 1)
        #expect(gate.free == 2)
    }

    /// The gate belongs to each case, not to the suite around it: a suite
    /// holding a place would keep its own cases out.
    @Test func scopesCasesButNotTheTestItself() throws {
        let trait = HeavyTrait(gate: HeavyGate(width: 1))
        let test = try #require(Test.current)
        let testCase = try #require(Test.Case.current)
        #expect(trait.scopeProvider(for: test, testCase: nil) == nil)
        #expect(trait.scopeProvider(for: test, testCase: testCase) != nil)
    }
}
