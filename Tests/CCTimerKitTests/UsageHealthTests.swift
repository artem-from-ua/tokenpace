import Testing
import Foundation
@testable import CCTimerKit

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

    @Test func expiredIsTokenStale() {
        // An expired local token is benign/self-healing, NOT a server rejection — its own reason now.
        #expect(FailureReason(TokenError.expired) == .tokenStale)
    }

    @Test func accessDeniedIsAuthHTTP401() {
        // A Keychain ACL block IS an auth-level rejection, so — unlike .expired — it stays a 401.
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

    @Test func thresholdsAreThirtyAndSixtyMinutes() {
        #expect(UsageHealth.glyphAfter == 30 * 60)
        #expect(UsageHealth.hideBarsAfter == 60 * 60)
    }
}
