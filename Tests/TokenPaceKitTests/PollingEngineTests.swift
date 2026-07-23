import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Shared fixtures

/// A fixed "current time" so transitions are deterministic.
private let t0 = Date(timeIntervalSince1970: 1_000_000)

/// A snapshot with the given 5h/7d utilisation (the fields the engine's change-detection reads).
/// `resets_at` is constant — only utilisation drives "changed" per the user's definition.
private func snap(five: Double, seven: Double) -> UsageSnapshot {
    UsageSnapshot(
        fiveHour: UsageWindow(utilization: five, resetsAt: "2026-06-21T05:30:00+00:00"),
        sevenDay: UsageWindow(utilization: seven, resetsAt: "2026-06-28T00:00:00+00:00"))
}

/// Stub transport returning a canned result — no live network. (Mirrors `UsageClientTests`.)
private struct StubTransport: UsageTransport {
    let result: Result<(Data, URLResponse), Error>

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try result.get()
    }

    /// A 200 carrying the given snapshot's utilisation, JSON-encoded like the real endpoint.
    static func success(five: Double, seven: Double) -> StubTransport {
        let body = """
        {"five_hour":{"utilization":\(five),"resets_at":"2026-06-21T05:30:00+00:00"},\
        "seven_day":{"utilization":\(seven),"resets_at":"2026-06-28T00:00:00+00:00"},"limits":[]}
        """.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: UsageClient.endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        return StubTransport(result: .success((body, response)))
    }

    /// An HTTP response with the given status (no body).
    static func http(_ status: Int, headers: [String: String] = [:]) -> StubTransport {
        let response = HTTPURLResponse(
            url: UsageClient.endpoint, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: headers)!
        return StubTransport(result: .success((Data(), response)))
    }

    /// An HTTP response with the given status and a UTF-8 body — for diagnostics assertions.
    static func httpBody(_ status: Int, body: String) -> StubTransport {
        let response = HTTPURLResponse(
            url: UsageClient.endpoint, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: [:])!
        return StubTransport(result: .success((Data(body.utf8), response)))
    }

    /// A transport that throws (connection failure, cancellation, …).
    static func failing(_ error: Error) -> StubTransport {
        StubTransport(result: .failure(error))
    }
}

/// A token seam returning literal credentials, or — since ADR-0020 — modelling expiry/read errors.
///
/// `.expired` no longer throws (the engine judges expiry): it is surfaced as **readable but stale**
/// credentials (a past `expiresAt`), so the engine short-circuits and refreshes. Any other injected
/// `TokenError` still throws (credentials genuinely unreadable). A far-future expiry otherwise.
private struct StubTokenProvider: TokenProviding {
    var token: String? = "acc-123"
    var error: TokenError?
    func currentCredentials(now: Date) throws -> TokenCredentials {
        if let error {
            if error == .expired {
                return TokenCredentials(accessToken: token!, expiresAt: now.addingTimeInterval(-1))
            }
            throw error
        }
        return TokenCredentials(accessToken: token!, expiresAt: now.addingTimeInterval(3600))
    }
}

/// A probe returning a fixed activity reading.
private struct StubProbe: ClaudeActivityProbe {
    let active: Bool
    func isClaudeRunning() -> Bool { active }
}

// MARK: - Pure core: PollState helpers

/// A failing state at `t0` with the given failure age — for threshold-independent assertions.
private func failingState(reason: FailureReason) -> PollState {
    PollState(failingSince: t0, lastSnapshot: snap(five: 40, seven: 75), reason: reason)
}

// MARK: - advance: success path

@Suite("PollingEngine.advance — success")
struct AdvanceSuccessTests {

    @Test func successResetsBackoffAndHealth() {
        var prev = PollState(failingSince: t0.addingTimeInterval(-100), reason: .timeout)
        prev.backoff = PollingBackoff().escalated().escalated()  // climbed to 360 s
        let next = PollingEngine.advance(
            previous: prev, outcome: .success(snap(five: 10, seven: 20)),
            claudeActive: true, now: t0)
        #expect(next.backoff.level == nil)         // 200 cleared the backoff
        #expect(next.lastSuccess == t0)
        #expect(next.failingSince == nil)
        #expect(next.reason == nil)
        #expect(next.lastSnapshot == snap(five: 10, seven: 20))
        #expect(next.health.isFailing == false)
    }

    @Test func firstSuccessKeepsAdaptiveAtFloor() {
        // No previous snapshot → counts as a change → adaptive stays at the responsive floor.
        let next = PollingEngine.advance(
            previous: PollState(), outcome: .success(snap(five: 10, seven: 20)),
            claudeActive: true, now: t0)
        #expect(next.adaptive.interval == 180)
    }

    @Test func unchangedUtilisationDoublesAdaptive() {
        let prev = PollState(lastSnapshot: snap(five: 40, seven: 75))
        let next = PollingEngine.advance(
            previous: prev, outcome: .success(snap(five: 40, seven: 75)),
            claudeActive: true, now: t0)
        #expect(next.adaptive.interval == 360)     // identical snapshot → one step slower
    }

    @Test func changedUtilisationSnapsAdaptiveToFloor() {
        var prev = PollState(lastSnapshot: snap(five: 40, seven: 75))
        prev.adaptive = AdaptiveCadence().unchanged().unchanged()  // climbed to 720 s
        let next = PollingEngine.advance(
            previous: prev, outcome: .success(snap(five: 41, seven: 75)),  // 5h moved
            claudeActive: true, now: t0)
        #expect(next.adaptive.interval == 180)     // change → instant reset to floor
    }

    @Test func sevenDayChangeAloneCountsAsChange() {
        var prev = PollState(lastSnapshot: snap(five: 40, seven: 75))
        prev.adaptive = AdaptiveCadence().unchanged()
        let next = PollingEngine.advance(
            previous: prev, outcome: .success(snap(five: 40, seven: 76)),  // 7d moved
            claudeActive: true, now: t0)
        #expect(next.adaptive.interval == 180)
    }
}

// MARK: - advance: failure paths

@Suite("PollingEngine.advance — failure")
struct AdvanceFailureTests {

    @Test func rateLimitedEscalatesBackoffAndKeepsSnapshot() {
        let prev = PollState(lastSnapshot: snap(five: 40, seven: 75))
        let next = PollingEngine.advance(
            previous: prev, outcome: .usageError(.rateLimited(retryAfter: nil)),
            claudeActive: true, now: t0)
        #expect(next.backoff.level == 0)           // first 429 → step 0
        #expect(next.failingSince == t0)
        #expect(next.reason == .serverProblem)
        #expect(next.lastSnapshot == snap(five: 40, seven: 75))  // stale data preserved
    }

    @Test func rateLimitedHonoursRetryAfter() {
        let next = PollingEngine.advance(
            previous: PollState(), outcome: .usageError(.rateLimited(retryAfter: 700)),
            claudeActive: true, now: t0)
        #expect(next.backoff.interval == 720)      // jumped to the step >= the hint
    }

    @Test func offlineDoesNotEscalateBackoff() {
        let prev = PollState(lastSnapshot: snap(five: 40, seven: 75))
        let next = PollingEngine.advance(
            previous: prev,
            outcome: .usageError(.transport(message: "offline", code: .notConnectedToInternet)),
            claudeActive: true, now: t0)
        #expect(next.backoff.level == nil)         // not a 429 → cadence unchanged
        #expect(PollingEngine.effectiveInterval(next) == 180)
        #expect(next.failingSince == t0)
        #expect(next.reason == .network("offline"))
        #expect(next.lastSnapshot == snap(five: 40, seven: 75))  // stale data preserved
    }

    @Test func firstFailureStampsFailingSinceThenPreservesIt() {
        let firstFail = PollingEngine.advance(
            previous: PollState(lastSuccess: t0.addingTimeInterval(-50)),
            outcome: .usageError(.http(status: 500, body: nil)),
            claudeActive: true, now: t0)
        #expect(firstFail.failingSince == t0)
        // A second consecutive failure 60 s later keeps the original failingSince.
        let secondFail = PollingEngine.advance(
            previous: firstFail,
            outcome: .usageError(.http(status: 500, body: nil)),
            claudeActive: true, now: t0.addingTimeInterval(60))
        #expect(secondFail.failingSince == t0)     // run start unchanged
    }

    @Test func tokenErrorRecordsFailureWithoutTouchingIntervals() {
        var prev = PollState(lastSnapshot: snap(five: 40, seven: 75))
        prev.adaptive = AdaptiveCadence().unchanged()  // 360 s
        let next = PollingEngine.advance(
            previous: prev, outcome: .tokenError(.itemNotFound),
            claudeActive: true, now: t0)
        #expect(next.reason == .notSignedIn)
        #expect(next.failingSince == t0)
        #expect(next.backoff.level == nil)             // untouched
        #expect(next.adaptive.interval == 360)         // untouched
        #expect(next.lastSnapshot == snap(five: 40, seven: 75))
    }

    @Test func recoveryClearsFailingSince() {
        let failing = failingState(reason: .timeout)
        let recovered = PollingEngine.advance(
            previous: failing, outcome: .success(snap(five: 50, seven: 80)),
            claudeActive: true, now: t0.addingTimeInterval(120))
        #expect(recovered.failingSince == nil)
        #expect(recovered.reason == nil)
        #expect(recovered.lastSuccess == t0.addingTimeInterval(120))
    }
}

// MARK: - effectiveInterval: priority

@Suite("PollingEngine.effectiveInterval")
struct EffectiveIntervalTests {

    @Test func inactiveClaudeForces30m() {
        var state = PollState(claudeActive: false)
        state.adaptive = AdaptiveCadence()             // would be 180 s if active
        #expect(PollingEngine.effectiveInterval(state) == 30 * 60)
    }

    @Test func activeUsesAdaptive() {
        var state = PollState(claudeActive: true)
        state.adaptive = AdaptiveCadence().unchanged()  // 360 s
        #expect(PollingEngine.effectiveInterval(state) == 360)
    }

    @Test func rateLimitOverridesInactiveAndAdaptive() {
        var state = PollState(claudeActive: false)     // would force 30 min
        state.backoff = PollingBackoff().escalated().escalated()  // 360 s
        #expect(PollingEngine.effectiveInterval(state) == 360)    // 429 wins outright
    }

    @Test func activeChangedIsFloor() {
        let state = PollState(claudeActive: true)      // fresh adaptive = floor
        #expect(PollingEngine.effectiveInterval(state) == 180)
    }
}

// MARK: - Safety floor: a tight request loop must be impossible

@Suite("PollingEngine.minInterval floor")
struct MinIntervalFloorTests {

    @Test func effectiveIntervalNeverBelowFloor() {
        // The adaptive floor is 180 s (above the 60 s safety floor), but assert the rail directly:
        // even a hypothetical sub-floor raw interval is clamped.
        var state = PollState(claudeActive: true)
        // Force the adaptive level to the floor (180) — still well above minInterval.
        state.adaptive = AdaptiveCadence()
        #expect(PollingEngine.effectiveInterval(state) >= PollingEngine.minInterval)
    }

    @Test func everyIntervalCombinationRespectsFloor() {
        // Exhaustively: across activity × adaptive level × backoff level, the effective interval is
        // never below the safety floor — the rail that makes ~50 req/s impossible regardless of state.
        for active in [true, false] {
            for adaptiveSteps in 0...5 {
                for backoffSteps in 0...5 {
                    var adaptive = AdaptiveCadence()
                    for _ in 0..<adaptiveSteps { adaptive = adaptive.unchanged() }
                    var backoff = PollingBackoff()
                    for _ in 0..<backoffSteps { backoff = backoff.escalated() }
                    let state = PollState(backoff: backoff, adaptive: adaptive, claudeActive: active)
                    #expect(PollingEngine.effectiveInterval(state) >= PollingEngine.minInterval)
                }
            }
        }
    }

    @Test func floorIsBelowBaseCadence() {
        // The floor must never slow normal operation: 60 s < 180 s base.
        #expect(PollingEngine.minInterval < PollingBackoff.defaultInterval)
        #expect(PollingEngine.minInterval == 60)
    }

    @Test func loopWithInstantSchedulerStillRequestsFloorInterval() async {
        // A malicious/buggy scheduler that returns `.elapsed` instantly (the shape of the shipped
        // bug) must NOT let the loop request faster than the floor: every interval the loop hands the
        // scheduler is >= minInterval. We record the intervals the scheduler is asked to wait.
        let recorder = RecordingScheduler()
        let engine = PollingEngine(
            transport: StubTransport.success(five: 10, seven: 20),
            tokenProvider: StubTokenProvider(), scheduler: recorder,
            probe: StubProbe(active: true), now: { t0 })
        var seen = 0
        for await _ in engine.run() {
            seen += 1
            if seen >= 5 { break }
        }
        let intervals = await recorder.intervals
        #expect(intervals.allSatisfy { $0 >= PollingEngine.minInterval },
            "loop asked to poll faster than the floor: \(intervals)")
        #expect(intervals.count >= 4)
    }
}

/// A scheduler that returns `.elapsed` instantly (no real delay) and records every interval it was
/// asked to wait — to prove the engine never *requests* a sub-floor cadence even if the scheduler
/// fails to enforce one. This is the exact failure shape of the shipped bug.
private actor RecordingScheduler: PollScheduler {
    private(set) var intervals: [TimeInterval] = []
    func waitForNextPoll(interval: TimeInterval) async -> PollWakeReason {
        intervals.append(interval)
        return .elapsed
    }
    func waitWhileAsleep() async {}
}

// MARK: - intervalDecision: logging causes

@Suite("PollingEngine.intervalDecision")
struct IntervalDecisionTests {

    @Test func noChangeReturnsNil() {
        let s = PollState(claudeActive: true)
        #expect(PollingEngine.intervalDecision(previous: s, next: s) == nil)
    }

    @Test func contentUnchangedDoubling() {
        let prev = PollState(claudeActive: true)                 // 180
        var next = prev
        next.adaptive = AdaptiveCadence().unchanged()            // 360
        let d = PollingEngine.intervalDecision(previous: prev, next: next)
        #expect(d?.from == 180)
        #expect(d?.to == 360)
        #expect(d?.cause == .contentUnchanged)
    }

    @Test func contentChangedReset() {
        var prev = PollState(claudeActive: true)
        prev.adaptive = AdaptiveCadence().unchanged().unchanged()  // 720
        var next = prev
        next.adaptive = prev.adaptive.changed()                   // 180
        let d = PollingEngine.intervalDecision(previous: prev, next: next)
        #expect(d?.cause == .contentChanged)
        #expect(d?.to == 180)
    }

    @Test func claudeInactiveCause() {
        let prev = PollState(claudeActive: true)                 // 180
        let next = PollState(claudeActive: false)                // 1800
        let d = PollingEngine.intervalDecision(previous: prev, next: next)
        #expect(d?.cause == .claudeInactive)
        #expect(d?.to == 1800)
    }

    @Test func claudeResumedCause() {
        let prev = PollState(claudeActive: false)                // 1800
        let next = PollState(claudeActive: true)                 // 180
        let d = PollingEngine.intervalDecision(previous: prev, next: next)
        #expect(d?.cause == .claudeActiveResumed)
    }

    @Test func rateLimitedCause() {
        let prev = PollState(claudeActive: true)
        var next = prev
        next.backoff = PollingBackoff().escalated().escalated()  // 360
        let d = PollingEngine.intervalDecision(previous: prev, next: next)
        #expect(d?.cause == .rateLimited)
    }

    @Test func rateLimitClearedCause() {
        var prev = PollState(claudeActive: true)
        prev.backoff = PollingBackoff().escalated().escalated()  // 360
        var next = prev
        next.backoff = prev.backoff.reset()                      // back to adaptive 180
        let d = PollingEngine.intervalDecision(previous: prev, next: next)
        #expect(d?.cause == .rateLimitCleared)
        #expect(d?.to == 180)
    }

    @Test func logMessageFormatsWholeMinutes() {
        let d = IntervalDecision(from: 180, to: 360, cause: .contentUnchanged)
        #expect(d.logMessage.hasPrefix("interval 3m→6m:"))
    }
}

// MARK: - pollOnce: token gating

@Suite("PollingEngine.pollOnce")
struct PollOnceTests {

    /// An engine whose transport counts how many requests reach the network.
    private func engine(
        transport: UsageTransport, token: StubTokenProvider, probe: Bool = true
    ) -> PollingEngine {
        PollingEngine(
            transport: transport, tokenProvider: token,
            scheduler: ManualScheduler(), probe: StubProbe(active: probe), now: { t0 })
    }

    @Test func expiredTokenSkipsFetch() async {
        // A counting transport proves the network was never touched. (No refresher injected —
        // the delegated-refresh path is covered by `PollOnceRefreshTests`.)
        let counter = CountingTransport(inner: .success(five: 10, seven: 20))
        let e = engine(transport: counter, token: StubTokenProvider(error: .expired))
        let result = await e.pollOnce(state: PollState(), claudeActive: true)
        #expect(result.outcome == .tokenError(.expired))
        #expect(result.refresh == nil)             // no refresher → no attempt
        #expect(await counter.count == 0)          // no request was sent
        // Expired maps to its own honest reason (ADR-0017); the popup warns immediately.
        #expect(FailureReason(.expired) == .tokenExpired)
    }

    @Test func notSignedInSkipsFetch() async {
        let counter = CountingTransport(inner: .success(five: 10, seven: 20))
        let e = engine(transport: counter, token: StubTokenProvider(error: .itemNotFound))
        let result = await e.pollOnce(state: PollState(), claudeActive: true)
        #expect(result.outcome == .tokenError(.itemNotFound))
        #expect(await counter.count == 0)
    }

    @Test func validTokenFetchesAndSucceeds() async {
        let counter = CountingTransport(inner: .success(five: 13, seven: 40))
        let e = engine(transport: counter, token: StubTokenProvider())
        let result = await e.pollOnce(state: PollState(), claudeActive: true)
        guard case let .success(snapshot) = result.outcome else {
            Issue.record("expected success, got \(result.outcome)"); return
        }
        #expect(snapshot.fiveHour.utilization == 13)
        #expect(await counter.count == 1)
    }

    @Test func rateLimitedSurfacesAsUsageError() async {
        let e = engine(transport: StubTransport.http(429), token: StubTokenProvider())
        let result = await e.pollOnce(state: PollState(), claudeActive: true)
        #expect(result.outcome == .usageError(.rateLimited(retryAfter: nil)))
    }

    @Test func offlineSurfacesAsUsageErrorNotThrow() async {
        // AC #2: an offline fetch must not crash — it collapses to a typed usageError.
        let e = engine(
            transport: StubTransport.failing(URLError(.notConnectedToInternet)),
            token: StubTokenProvider())
        let result = await e.pollOnce(state: PollState(), claudeActive: true)
        guard case let .usageError(error) = result.outcome else {
            Issue.record("expected usageError, got \(result.outcome)"); return
        }
        guard case let .transport(_, code) = error else {
            Issue.record("expected .transport, got \(error)"); return
        }
        #expect(code == .notConnectedToInternet)
    }
}

// MARK: - pollOnce: delegated refresh (ADR-0017)

@Suite("PollingEngine.pollOnce — delegated refresh")
struct PollOnceRefreshTests {

    private func engine(
        transport: UsageTransport, token: TokenProviding, refresher: DelegatedRefresher?
    ) -> PollingEngine {
        PollingEngine(
            transport: transport, tokenProvider: token, refresher: refresher,
            scheduler: ManualScheduler(), probe: StubProbe(active: true), now: { t0 })
    }

    @Test func refreshFixesExpiredTokenWithinSameCycle() async {
        // Expired token → the refresher runs, "Claude Code" rewrites its store (rotate()),
        // the engine re-reads and fetches — recovery does NOT wait for the next poll.
        let provider = RotatingTokenProvider()
        let refresher = StubRefresher(outcome: .refreshed, onRefresh: { provider.rotate() })
        let counter = CountingTransport(inner: .success(five: 10, seven: 20))
        let e = engine(transport: counter, token: provider, refresher: refresher)
        let result = await e.pollOnce(state: PollState(), claudeActive: true)
        guard case .success = result.outcome else {
            Issue.record("expected success, got \(result.outcome)"); return
        }
        #expect(result.refresh == .refreshed)
        #expect(await refresher.calls == 1)
        #expect(await counter.count == 1)
    }

    @Test func failedRefreshFallsBackToExpiredError() async {
        let counter = CountingTransport(inner: .success(five: 10, seven: 20))
        let refresher = StubRefresher(outcome: .cliNotFound)
        let e = engine(
            transport: counter, token: StubTokenProvider(error: .expired), refresher: refresher)
        let result = await e.pollOnce(state: PollState(), claudeActive: true)
        #expect(result.outcome == .tokenError(.expired))
        #expect(result.refresh == .cliNotFound)    // advance() folds this as a gate failure
        #expect(await counter.count == 0)          // still no request with a dead token
    }

    @Test func refreshedButStillExpiredIsFailure() async {
        // The CLI claimed success but the re-read still throws — exactly one re-read per cycle,
        // no retry loop.
        let refresher = StubRefresher(outcome: .refreshed)  // no side effect: stays expired
        let e = engine(
            transport: CountingTransport(inner: .success(five: 10, seven: 20)),
            token: StubTokenProvider(error: .expired), refresher: refresher)
        let result = await e.pollOnce(state: PollState(), claudeActive: true)
        #expect(result.outcome == .tokenError(.expired))
        #expect(result.refresh == .refreshed)      // reported so advance() escalates the gate
    }

    @Test func coolingGateSkipsRefresher() async {
        let refresher = StubRefresher(outcome: .refreshed)
        let e = engine(
            transport: CountingTransport(inner: .success(five: 10, seven: 20)),
            token: StubTokenProvider(error: .expired), refresher: refresher)
        let blocked = PollState(refreshGate: RefreshGate().afterFailure(now: t0))
        let result = await e.pollOnce(state: blocked, claudeActive: true)
        #expect(result.outcome == .tokenError(.expired))
        #expect(result.refresh == nil)
        #expect(await refresher.calls == 0)        // gate held — no respawn this cycle
    }

    @Test func missingTokenDoesNotTriggerRefresh() async {
        // Only `.expired` delegates; `.itemNotFound` (signed out) cannot be fixed by the CLI alone.
        let refresher = StubRefresher(outcome: .refreshed)
        let e = engine(
            transport: CountingTransport(inner: .success(five: 10, seven: 20)),
            token: StubTokenProvider(error: .itemNotFound), refresher: refresher)
        let result = await e.pollOnce(state: PollState(), claudeActive: true)
        #expect(result.outcome == .tokenError(.itemNotFound))
        #expect(result.refresh == nil)
        #expect(await refresher.calls == 0)
    }
}

// MARK: - pollOnce: diagnostics (ADR-0020)

@Suite("PollingEngine.pollOnce — diagnostics")
struct PollOnceDiagnosticsTests {

    private func engine(
        transport: UsageTransport, token: TokenProviding, refresher: DelegatedRefresher? = nil
    ) -> PollingEngine {
        PollingEngine(
            transport: transport, tokenProvider: token, refresher: refresher,
            scheduler: ManualScheduler(), probe: StubProbe(active: true), now: { t0 })
    }

    @Test func successCarriesFullDiagnostics() async {
        let e = engine(transport: StubTransport.success(five: 13, seven: 40), token: StubTokenProvider())
        let result = await e.pollOnce(state: PollState(), claudeActive: true)
        let fetch = result.diagnostics.fetch
        #expect(fetch.outcome == .success)
        #expect(fetch.httpStatus == 200)
        #expect(fetch.attemptAt == t0)
        #expect(fetch.body?.contains("\"utilization\"") == true)   // the real 200 body is captured
        // Token read this cycle → dates present (readAt == t0, the stub's +3600 expiry).
        #expect(result.diagnostics.token?.readAt == t0)
        #expect(result.diagnostics.token?.expiresAt == t0.addingTimeInterval(3600))
    }

    @Test func httpErrorCapturesStatusAndBody() async {
        // A 401 with a body over the popup cap → the diagnostic body is the FULL length (the key
        // divergence from `UsageError.http`, still capped at maxBodyLength for the popup).
        let longBody = String(repeating: "x", count: UsageClient.maxBodyLength + 200)
        let e = engine(
            transport: StubTransport.httpBody(401, body: longBody), token: StubTokenProvider())
        let result = await e.pollOnce(state: PollState(), claudeActive: true)
        let fetch = result.diagnostics.fetch
        #expect(fetch.outcome == .httpError)
        #expect(fetch.httpStatus == 401)
        #expect(fetch.body?.count == UsageClient.maxBodyLength + 200)   // uncapped
        // The mapped UsageError, by contrast, is still capped.
        guard case let .usageError(.http(_, body)) = result.outcome else {
            Issue.record("expected .usageError(.http), got \(result.outcome)"); return
        }
        #expect(body?.count == UsageClient.maxBodyLength)
    }

    @Test func expiredTokenFillsTokenDiagnostics() async {
        // Expired → no request; the token dates are STILL captured (when it expired matters).
        let e = engine(
            transport: StubTransport.success(five: 10, seven: 20),
            token: StubTokenProvider(error: .expired))
        let result = await e.pollOnce(state: PollState(), claudeActive: true)
        #expect(result.outcome == .tokenError(.expired))
        #expect(result.diagnostics.fetch.outcome == .notSent(reason: "token expired"))
        #expect(result.diagnostics.token?.readAt == t0)                       // read happened
        #expect(result.diagnostics.token?.expiresAt == t0.addingTimeInterval(-1))  // stale expiry visible
    }

    @Test func keychainErrorLeavesTokenNil() async {
        // Credentials unreadable → no token dates; the fetch record explains why nothing was sent.
        let e = engine(
            transport: StubTransport.success(five: 10, seven: 20),
            token: StubTokenProvider(error: .itemNotFound))
        let result = await e.pollOnce(state: PollState(), claudeActive: true)
        #expect(result.diagnostics.token == nil)
        #expect(result.diagnostics.fetch.outcome == .notSent(reason: "not signed in"))
        #expect(result.diagnostics.fetch.httpStatus == nil)
    }

    @Test func successfulRefreshUpdatesTokenExpiry() async {
        // After a delegated refresh fixes the token, the token diagnostics reflect the NEW expiry.
        let provider = RotatingTokenProvider()
        let refresher = StubRefresher(outcome: .refreshed, onRefresh: { provider.rotate() })
        let e = engine(
            transport: StubTransport.success(five: 10, seven: 20), token: provider,
            refresher: refresher)
        let result = await e.pollOnce(state: PollState(), claudeActive: true)
        guard case .success = result.outcome else {
            Issue.record("expected success, got \(result.outcome)"); return
        }
        // Re-read after rotate → fresh +3600 expiry, not the stale -1.
        #expect(result.diagnostics.token?.expiresAt == t0.addingTimeInterval(3600))
    }

    @Test func expiredTokenNeverReachesNetwork() async {
        // The ADR-0007 contract, now enforced by the engine: an expired token skips the transport.
        let counter = CountingTransport(inner: .success(five: 10, seven: 20))
        let e = engine(transport: counter, token: StubTokenProvider(error: .expired))
        _ = await e.pollOnce(state: PollState(), claudeActive: true)
        #expect(await counter.count == 0)
    }
}

// MARK: - run(): diagnostics propagation

@Suite("PollingEngine.run — diagnostics")
struct RunDiagnosticsTests {

    @Test func outputCarriesAttemptDiagnostics() async {
        let counter = CountingTransport(inner: .success(five: 13, seven: 40))
        let scheduler = ManualScheduler(script: [.elapsed])
        let engine = PollingEngine(
            transport: counter, tokenProvider: StubTokenProvider(), scheduler: scheduler,
            probe: StubProbe(active: true), now: { t0 })
        var output: PollOutput?
        for await o in engine.run() { output = o; break }
        let diag = output?.diagnostics
        #expect(diag?.fetch.outcome == .success)
        #expect(diag?.fetch.httpStatus == 200)
        #expect(diag?.token?.readAt == t0)
    }
}

// MARK: - advance: RefreshGate folding

@Suite("PollingEngine.advance — refresh gate")
struct AdvanceRefreshGateTests {

    @Test func fixedRefreshResetsGate() {
        var prev = PollState()
        prev.refreshGate = RefreshGate().afterFailure(now: t0.addingTimeInterval(-3600))
        let next = PollingEngine.advance(
            previous: prev, outcome: .success(snap(five: 10, seven: 20)), refresh: .refreshed,
            claudeActive: true, now: t0)
        #expect(next.refreshGate == RefreshGate())
    }

    @Test func refreshSuccessThenNetworkFailureStillResetsGate() {
        // The refresh fixed the token; a 429 afterwards is the backoff's business, not the gate's.
        var prev = PollState()
        prev.refreshGate = RefreshGate().afterFailure(now: t0.addingTimeInterval(-3600))
        let next = PollingEngine.advance(
            previous: prev, outcome: .usageError(.rateLimited(retryAfter: nil)),
            refresh: .refreshed, claudeActive: true, now: t0)
        #expect(next.refreshGate == RefreshGate())
        #expect(next.backoff.level == 0)           // the 429 still escalated the backoff
    }

    @Test func failedRefreshEscalatesGate() {
        let next = PollingEngine.advance(
            previous: PollState(), outcome: .tokenError(.expired), refresh: .cliNotFound,
            claudeActive: true, now: t0)
        #expect(next.refreshGate.consecutiveFailures == 1)
        #expect(next.refreshGate.allows(now: t0) == false)
        #expect(next.refreshGate.allows(now: t0.addingTimeInterval(60)))
    }

    @Test func refreshedButStillExpiredEscalatesGate() {
        // A `.refreshed` claim that left the token expired must not reset the gate.
        let next = PollingEngine.advance(
            previous: PollState(), outcome: .tokenError(.expired), refresh: .refreshed,
            claudeActive: true, now: t0)
        #expect(next.refreshGate.consecutiveFailures == 1)
    }

    @Test func noAttemptLeavesGateUntouched() {
        var prev = PollState()
        prev.refreshGate = RefreshGate().afterFailure(now: t0)
        let next = PollingEngine.advance(
            previous: prev, outcome: .tokenError(.expired), refresh: nil,
            claudeActive: true, now: t0)
        #expect(next.refreshGate == prev.refreshGate)  // cooling down, not restarted
    }
}

// MARK: - run() loop: AC #1 / AC #2 end-to-end

@Suite("PollingEngine.run")
struct RunLoopTests {

    /// Drive the loop and collect the first `count` outputs.
    private func collect(
        _ engine: PollingEngine, count: Int
    ) async -> [PollOutput] {
        var outputs: [PollOutput] = []
        for await output in engine.run() {
            outputs.append(output)
            if outputs.count >= count { break }    // breaking cancels the stream's task
        }
        return outputs
    }

    @Test func wakeTriggersImmediatePoll() async {
        // The scheduler interrupts the first wait with `.wake`; the loop must poll again at once.
        let counter = CountingTransport(inner: .success(five: 10, seven: 20))
        let scheduler = ManualScheduler(script: [.interrupted(.wake), .elapsed])
        let engine = PollingEngine(
            transport: counter, tokenProvider: StubTokenProvider(), scheduler: scheduler,
            probe: StubProbe(active: true), now: { t0 })
        let outputs = await collect(engine, count: 2)
        #expect(outputs.count == 2)
        #expect(await counter.count >= 2)          // a second fetch happened off-schedule
    }

    @Test func manualRefreshResetsBackoffToBaseInterval() async {
        // Three consecutive 429s. Without intervention the backoff would climb 180 → 360 → 720.
        // A `.manualRefresh` between polls 2 and 3 resets it, so poll 3 starts back at level 0 (180).
        let transport = SequencedTransport(steps: [
            StubTransport.http(429), StubTransport.http(429), StubTransport.http(429),
        ])
        let scheduler = ManualScheduler(script: [.elapsed, .interrupted(.manualRefresh), .elapsed])
        let engine = PollingEngine(
            transport: transport, tokenProvider: StubTokenProvider(), scheduler: scheduler,
            probe: StubProbe(active: true), now: { t0 })
        let outputs = await collect(engine, count: 3)
        #expect(outputs[0].interval == 180)   // first 429 → step 0
        #expect(outputs[1].interval == 360)   // second 429 → step 1 (climbing)
        #expect(outputs[2].interval == 180)   // manual refresh reset the backoff → back to step 0
    }

    @Test func networkRestoredTriggersImmediatePoll() async {
        // First poll offline (stale), then `.networkRestored` drives an immediate successful poll.
        let transport = SequencedTransport(steps: [
            .failing(URLError(.notConnectedToInternet)),
            .success(five: 50, seven: 80),
        ])
        let scheduler = ManualScheduler(script: [.interrupted(.networkRestored), .elapsed])
        let engine = PollingEngine(
            transport: transport, tokenProvider: StubTokenProvider(), scheduler: scheduler,
            probe: StubProbe(active: true), now: { t0 })
        let outputs = await collect(engine, count: 2)
        #expect(outputs[0].health.isFailing == true)    // offline → failing
        #expect(outputs[1].health.isFailing == false)   // recovered after restore
        #expect(outputs[1].snapshot == snap(five: 50, seven: 80))
    }

    @Test func offlineKeepsLastSnapshot() async {
        // Success then offline: the second output still carries the first snapshot (stale-safe).
        let transport = SequencedTransport(steps: [
            .success(five: 40, seven: 75),
            .failing(URLError(.notConnectedToInternet)),
        ])
        let scheduler = ManualScheduler(script: [.elapsed, .elapsed])
        let engine = PollingEngine(
            transport: transport, tokenProvider: StubTokenProvider(), scheduler: scheduler,
            probe: StubProbe(active: true), now: { t0 })
        let outputs = await collect(engine, count: 2)
        #expect(outputs[0].snapshot == snap(five: 40, seven: 75))
        #expect(outputs[1].snapshot == snap(five: 40, seven: 75))  // preserved across the failure
        #expect(outputs[1].health.isFailing == true)
    }

    @Test func sleepParksThenWakeResumes() async {
        // `.sleep` parks (no fetch) until the park returns; then a normal poll runs.
        let counter = CountingTransport(inner: .success(five: 10, seven: 20))
        let scheduler = ManualScheduler(script: [.interrupted(.sleep), .elapsed])
        let engine = PollingEngine(
            transport: counter, tokenProvider: StubTokenProvider(), scheduler: scheduler,
            probe: StubProbe(active: true), now: { t0 })
        let outputs = await collect(engine, count: 2)
        #expect(outputs.count == 2)
        #expect(await scheduler.parkCount == 1)    // the loop parked exactly once on .sleep
    }

    @Test func inactiveClaudeYieldsThirtyMinInterval() async {
        let counter = CountingTransport(inner: .success(five: 10, seven: 20))
        let scheduler = ManualScheduler(script: [.elapsed])
        let engine = PollingEngine(
            transport: counter, tokenProvider: StubTokenProvider(), scheduler: scheduler,
            probe: StubProbe(active: false), now: { t0 })
        let outputs = await collect(engine, count: 1)
        #expect(outputs[0].interval == 30 * 60)    // hard idle override
    }
}

// MARK: - Test seams

/// A refresher returning a scripted outcome, counting calls, optionally running a side effect —
/// the shape of Claude Code rewriting its Keychain item during a delegated refresh (ADR-0017).
private actor StubRefresher: DelegatedRefresher {
    private let outcome: DelegatedRefreshOutcome
    private let onRefresh: (@Sendable () -> Void)?
    private(set) var calls = 0

    init(outcome: DelegatedRefreshOutcome, onRefresh: (@Sendable () -> Void)? = nil) {
        self.outcome = outcome
        self.onRefresh = onRefresh
    }

    func refresh() async -> DelegatedRefreshOutcome {
        calls += 1
        onRefresh?()
        return outcome
    }
}

/// A token seam that returns **expired** credentials until `rotate()` is called, then a fresh pair —
/// the observable effect of Claude Code rotating its credentials. Since ADR-0020 the provider no
/// longer throws `.expired`; expiry is expressed by a past `expiresAt` and judged by the engine.
/// `TokenProviding` is sync, so this is a lock-guarded class rather than an actor.
private final class RotatingTokenProvider: TokenProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var expired = true

    func rotate() {
        lock.withLock { expired = false }
    }

    func currentCredentials(now: Date) throws -> TokenCredentials {
        lock.withLock {
            let offset: TimeInterval = expired ? -1 : 3600
            return TokenCredentials(
                accessToken: expired ? "acc-stale" : "acc-fresh",
                expiresAt: now.addingTimeInterval(offset))
        }
    }
}

/// A transport that wraps another and counts how many requests pass through.
private actor CountingTransport: UsageTransport {
    private let inner: StubTransport
    private(set) var count = 0
    init(inner: StubTransport) { self.inner = inner }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        count += 1
        return try await inner.data(for: request)
    }
}

/// A transport that returns a different canned result on each successive call (clamped to the last).
private actor SequencedTransport: UsageTransport {
    private let steps: [StubTransport]
    private var index = 0
    init(steps: [StubTransport]) { self.steps = steps }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let step = steps[min(index, steps.count - 1)]
        index += 1
        return try await step.data(for: request)
    }
}

/// A hand-driven scheduler: returns scripted `PollWakeReason`s in order (clamped to `.elapsed`
/// once exhausted) and counts parks. Deterministic — no real time.
private actor ManualScheduler: PollScheduler {
    private let script: [PollWakeReason]
    private var index = 0
    private(set) var parkCount = 0

    init(script: [PollWakeReason] = []) { self.script = script }

    func waitForNextPoll(interval: TimeInterval) async -> PollWakeReason {
        let reason = index < script.count ? script[index] : .elapsed
        index += 1
        return reason
    }

    func waitWhileAsleep() async {
        parkCount += 1
        // Returns immediately so the test loop makes progress (production blocks until .wake).
    }
}
