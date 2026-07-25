import Testing
import Foundation
@testable import TokenPaceKit

/// A fixed "current time" so transitions are deterministic.
private let t0 = Date(timeIntervalSince1970: 1_000_000)

// MARK: - RefreshGate transitions

@Suite("RefreshGate")
struct RefreshGateTests {

    @Test func freshGateAllowsImmediately() {
        #expect(RefreshGate().allows(now: t0))
        #expect(RefreshGate().consecutiveFailures == 0)
    }

    @Test func failureBlocksUntilCooldownElapses() {
        let gate = RefreshGate().afterFailure(now: t0)
        #expect(gate.allows(now: t0) == false)
        #expect(gate.allows(now: t0.addingTimeInterval(59)) == false)
        // The boundary counts as elapsed (>= semantics, mirroring OAuthCredentials.isExpired).
        #expect(gate.allows(now: t0.addingTimeInterval(60)) == true)
    }

    @Test func consecutiveFailuresEscalateAndHoldAtCeiling() {
        var gate = RefreshGate()
        let expected: [TimeInterval] = [60, 300, 1800, 3600, 3600]  // 5th failure holds at 60 min
        for (index, cooldown) in expected.enumerated() {
            gate = gate.afterFailure(now: t0)
            #expect(gate.consecutiveFailures == index + 1)
            #expect(gate.nextAttemptAllowed == t0.addingTimeInterval(cooldown))
        }
    }

    @Test func successResetsToFreshGate() {
        let gate = RefreshGate()
            .afterFailure(now: t0)
            .afterFailure(now: t0.addingTimeInterval(60))
            .afterSuccess()
        #expect(gate == RefreshGate())
        #expect(gate.allows(now: t0))
    }

    @Test func stepsAreInSeconds() {
        // 1, 5, 30, 60 minutes — the `* 60` factor is load-bearing (minutes stored as seconds).
        #expect(RefreshGate.steps == [60, 300, 1800, 3600])
    }
}
