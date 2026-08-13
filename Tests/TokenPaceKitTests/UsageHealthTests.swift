import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Shared fixtures

/// A fixed "current time" so failure-age math is deterministic.
private let now = Date(timeIntervalSince1970: 1_000_000)

/// A `UsageHealth` failing for `age` seconds, with `lastSuccess` placed the same distance back.
private func failing(for age: TimeInterval, reason: FailureReason = .unknown) -> UsageHealth {
    UsageHealth(
        lastSuccess: now.addingTimeInterval(-age),
        failingSince: now.addingTimeInterval(-age),
        reason: reason
    )
}

// MARK: - FailureReason mapping (TokenError)

@Suite("FailureReason from TokenError")
struct FailureReasonFromTokenErrorTests {

    @Test func itemNotFoundIsNotSignedIn() {
        #expect(FailureReason(TokenError.itemNotFound) == .notSignedIn)
    }

    @Test func expiredIsTokenExpired() {
        // Its own reason (not a synthetic 401): the delegated refresh (ADR-0017) may still fix it.
        #expect(FailureReason(TokenError.expired) == .tokenExpired)
    }

    @Test func accessDeniedIsAuthHTTP401() {
        #expect(FailureReason(TokenError.accessDenied(-25293)) == .authHTTP(status: 401, body: nil))
    }

    @Test func malformedDataIsUnknown() {
        #expect(FailureReason(TokenError.malformedData) == .unknown)
    }

    @Test func keychainErrorIsUnknown() {
        #expect(FailureReason(TokenError.keychainError(-1)) == .unknown)
    }
}

// MARK: - FailureReason mapping (UsageError)

@Suite("FailureReason from UsageError")
struct FailureReasonFromUsageErrorTests {

    @Test func http401IsAuthHTTPCarryingBody() {
        // The status AND the server body must survive the mapping (popup's two lines).
        let reason = FailureReason(UsageError.http(status: 401, body: "Invalid token"))
        #expect(reason == .authHTTP(status: 401, body: "Invalid token"))
    }

    @Test func http403IsAuthHTTP() {
        #expect(FailureReason(UsageError.http(status: 403, body: nil)) == .authHTTP(status: 403, body: nil))
    }

    @Test func http404IsServerProblem() {
        // Boundary: a non-auth status is a generic server problem, not an auth error.
        #expect(FailureReason(UsageError.http(status: 404, body: "nope")) == .serverProblem)
    }

    @Test func http500IsServerProblem() {
        #expect(FailureReason(UsageError.http(status: 500, body: nil)) == .serverProblem)
    }

    @Test func timeoutTransportIsTimeout() {
        #expect(FailureReason(UsageError.transport(message: "timed out", code: .timedOut)) == .timeout)
    }

    @Test func cannotFindHostIsCannotResolveHost() {
        #expect(FailureReason(UsageError.transport(message: "no host", code: .cannotFindHost)) == .cannotResolveHost)
    }

    @Test func dnsLookupFailedIsCannotResolveHost() {
        #expect(FailureReason(UsageError.transport(message: "dns", code: .dnsLookupFailed)) == .cannotResolveHost)
    }

    @Test func otherTransportIsNetwork() {
        let reason = FailureReason(UsageError.transport(message: "offline", code: .notConnectedToInternet))
        #expect(reason == .network("offline"))
    }

    @Test func transportWithoutURLErrorCodeIsNetwork() {
        // A non-URLError transport failure carries no code → generic network.
        #expect(FailureReason(UsageError.transport(message: "boom", code: nil)) == .network("boom"))
    }

    @Test func nonHTTPResponseIsNetwork() {
        #expect(FailureReason(UsageError.nonHTTPResponse) == .network("non-HTTP response"))
    }

    @Test func rateLimitedIsServerProblem() {
        #expect(FailureReason(UsageError.rateLimited(retryAfter: 60)) == .serverProblem)
    }

    @Test func decodeIsServerProblem() {
        #expect(FailureReason(UsageError.decode) == .serverProblem)
    }

    @Test func missingUserAgentIsUnknown() {
        #expect(FailureReason(UsageError.missingUserAgent) == .unknown)
    }
}

// MARK: - UsageHealth derived state

@Suite("UsageHealth state")
struct UsageHealthStateTests {

    @Test func healthyIsNotFailing() {
        let h = UsageHealth.healthy(lastSuccess: now)
        #expect(h.isFailing == false)
        #expect(h.reason == nil)
        #expect(h.failureAge(now: now) == nil)
    }

    @Test func failingReportsAge() throws {
        let age: TimeInterval = 20 * 60
        let h = failing(for: age)
        #expect(h.isFailing == true)
        // `Date` stores seconds as a Double, so the round-trip can carry sub-microsecond error —
        // compare within a tolerance rather than exact equality.
        let reported = try #require(h.failureAge(now: now))
        #expect(abs(reported - age) < 0.001)
    }

    @Test func failureAgeClampsAtZeroForFutureFailingSince() {
        // Clock skew: failingSince slightly in the future → age clamps to 0, never negative.
        let h = UsageHealth(lastSuccess: nil, failingSince: now.addingTimeInterval(30), reason: .unknown)
        #expect(h.failureAge(now: now) == 0)
    }

    @Test func glyphThresholdScalesWithTheCadence() {
        // The threshold is expressed in *attempts*, not wall-clock minutes: three failed polls, floored
        // at 15 min. That is the only way one number can mean the same thing at both cadences the engine
        // uses (180 s during a session, 900 s while idle) — a flat 15 min would raise the ⚠️ after a
        // single missed poll on a merely idle machine.
        let active = UsageHealth(lastSuccess: nil, failingSince: nil, reason: nil, pollInterval: 180)
        let idle = UsageHealth(lastSuccess: nil, failingSince: nil, reason: nil, pollInterval: 900)
        #expect(UsageHealth.glyphAfter(for: active) == 15 * 60)    // 3 × 180 = 540 < floor → floor wins
        #expect(UsageHealth.glyphAfter(for: idle) == 45 * 60)      // 3 × 900 = 2700 > floor → attempts win
    }

    @Test func glyphThresholdConstantsAreTheFloorAndAttemptCount() {
        // Pinned separately from the formula so a change to either input is a deliberate edit, not a
        // silent side effect of touching `glyphAfter(for:)`.
        #expect(UsageHealth.glyphAfterFloor == 15 * 60)
        #expect(UsageHealth.glyphAfterAttempts == 3)
    }

    @Test func defaultPollIntervalIsTheEngineBase() {
        // Every construction site that predates the field — production and test alike — must keep
        // meaning "the healthy session cadence", so the default is what makes the floor the answer.
        let h = UsageHealth(lastSuccess: nil, failingSince: nil, reason: nil)
        #expect(h.pollInterval == PollingEngine.baseInterval)
        #expect(UsageHealth.glyphAfter(for: h) == UsageHealth.glyphAfterFloor)
    }
}
