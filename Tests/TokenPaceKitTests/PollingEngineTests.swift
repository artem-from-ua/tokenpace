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
        prev.backoff = PollingBackoff().honoring(retryAfter: 300)  // an active hold
        let next = PollingEngine.advance(
            previous: prev, outcome: .success(snap(five: 10, seven: 20)),
            claudeActive: true, now: t0)
        #expect(next.backoff.isHolding == false)   // 200 cleared the hold
        #expect(next.lastSuccess == t0)
        #expect(next.failingSince == nil)
        #expect(next.reason == nil)
        #expect(next.lastSnapshot == snap(five: 10, seven: 20))
        #expect(next.health.isFailing == false)
    }

    @Test func successKeepsBaseInterval() {
        // With no 429 hold and an active session, a success leaves the flat 3-min base.
        let next = PollingEngine.advance(
            previous: PollState(), outcome: .success(snap(five: 10, seven: 20)),
            claudeActive: true, now: t0)
        #expect(PollingEngine.effectiveInterval(next) == 180)
    }

    @Test func repeatSuccessStaysAtBase() {
        // The interval no longer reacts to whether utilisation moved — it is a flat base now.
        let prev = PollState(lastSnapshot: snap(five: 40, seven: 75))
        let next = PollingEngine.advance(
            previous: prev, outcome: .success(snap(five: 40, seven: 75)),  // identical
            claudeActive: true, now: t0)
        #expect(PollingEngine.effectiveInterval(next) == 180)
    }
}

// MARK: - advance: failure paths

@Suite("PollingEngine.advance — failure")
struct AdvanceFailureTests {

    @Test func rateLimitedHoldsAndKeepsSnapshot() {
        // No Retry-After → the hold falls back to the 180 s base, and the snapshot is preserved.
        let prev = PollState(lastSnapshot: snap(five: 40, seven: 75))
        let next = PollingEngine.advance(
            previous: prev, outcome: .usageError(.rateLimited(retryAfter: nil)),
            claudeActive: true, now: t0)
        #expect(next.backoff.isHolding == true)
        #expect(next.backoff.interval == 180)      // no hint → base hold
        #expect(next.reason == .serverProblem)     // the popup still explains it in words
        #expect(next.lastSnapshot == snap(five: 40, seven: 75))  // stale data preserved
    }

    @Test func rateLimitedDoesNotStartTheFailureRun() {
        // A 429 is the server saying "not so fast", not "the data is unavailable" (ADR-0091). It takes the
        // backoff hold and the popup's reason line, but it must **not** start `failingSince` — that clock
        // is what ages the menu bar into the bare ⚠️, and a `Retry-After` of several minutes would trip
        // the glyph threshold on its own, reporting a fault where the system is working as designed.
        let next = PollingEngine.advance(
            previous: PollState(lastSnapshot: snap(five: 40, seven: 75)),
            outcome: .usageError(.rateLimited(retryAfter: 700)),
            claudeActive: true, now: t0)
        #expect(next.failingSince == nil)
        #expect(next.health.isFailing == false)   // …so the ⚠️ threshold never starts counting
    }

    @Test func rateLimitedPreservesAnExistingFailureRun() {
        // The other half of "never started": a 429 arriving mid-outage must not *clear* the run either.
        // Only a success does that — otherwise a rate-limited retry during a real failure would reset the
        // menu bar's staleness clock and hide an outage that is still ongoing.
        let earlier = t0.addingTimeInterval(-600)
        let failing = PollingEngine.advance(
            previous: PollState(), outcome: .usageError(.transport(message: "offline", code: .notConnectedToInternet)),
            claudeActive: true, now: earlier)
        let next = PollingEngine.advance(
            previous: failing, outcome: .usageError(.rateLimited(retryAfter: nil)),
            claudeActive: true, now: t0)
        #expect(next.failingSince == earlier)   // carried through untouched, not re-stamped at t0
    }

    @Test func rateLimitedHonoursRetryAfterExactly() {
        // The hold is the honored Retry-After verbatim — no step schedule, no rounding up.
        let next = PollingEngine.advance(
            previous: PollState(), outcome: .usageError(.rateLimited(retryAfter: 700)),
            claudeActive: true, now: t0)
        #expect(next.backoff.interval == 700)
    }

    @Test func repeatRateLimitDoesNotEscalate() {
        // Two consecutive 429s with the same hint hold at the same interval — no climbing.
        let first = PollingEngine.advance(
            previous: PollState(), outcome: .usageError(.rateLimited(retryAfter: 200)),
            claudeActive: true, now: t0)
        let second = PollingEngine.advance(
            previous: first, outcome: .usageError(.rateLimited(retryAfter: 200)),
            claudeActive: true, now: t0.addingTimeInterval(200))
        #expect(first.backoff.interval == 200)
        #expect(second.backoff.interval == 200)    // still 200, not doubled
    }

    @Test func offlineDoesNotHold() {
        let prev = PollState(lastSnapshot: snap(five: 40, seven: 75))
        let next = PollingEngine.advance(
            previous: prev,
            outcome: .usageError(.transport(message: "offline", code: .notConnectedToInternet)),
            claudeActive: true, now: t0)
        #expect(next.backoff.isHolding == false)   // not a 429 → cadence unchanged
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
        prev.backoff = PollingBackoff().honoring(retryAfter: 240)  // a pre-existing hold
        let next = PollingEngine.advance(
            previous: prev, outcome: .tokenError(.itemNotFound),
            claudeActive: true, now: t0)
        #expect(next.reason == .notSignedIn)
        #expect(next.failingSince == t0)
        #expect(next.backoff.interval == 240)          // hold untouched (network was skipped)
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

    @Test func inactiveClaudeForces15m() {
        let state = PollState(claudeActive: false)
        #expect(PollingEngine.effectiveInterval(state) == 15 * 60)
    }

    @Test func activeUsesBase() {
        let state = PollState(claudeActive: true)
        #expect(PollingEngine.effectiveInterval(state) == 180)
    }

    @Test func rateLimitOverridesInactiveAndBase() {
        var state = PollState(claudeActive: false)     // would force 15 min
        state.backoff = PollingBackoff().honoring(retryAfter: 600)
        #expect(PollingEngine.effectiveInterval(state) == 600)   // 429 hold wins outright
    }

    @Test func baseIsThreeMinutes() {
        #expect(PollingEngine.baseInterval == 180)
        let state = PollState(claudeActive: true)
        #expect(PollingEngine.effectiveInterval(state) == 180)
    }

    @Test func shortRetryAfterFlooredToMinInterval() {
        // A tiny Retry-After (30 s) is still floored at the 60 s safety rail.
        var state = PollState(claudeActive: true)
        state.backoff = PollingBackoff().honoring(retryAfter: 30)
        #expect(PollingEngine.effectiveInterval(state) == PollingEngine.minInterval)
    }
}

// MARK: - wakeRearmInterval: redundant-wake suppression (ADR-0032 D6)

@Suite("PollingEngine.wakeRearmInterval")
struct WakeRearmIntervalTests {

    @Test func staleCachePollsNow() {
        // interval elapsed since the last success → nil (poll immediately).
        let last = t0
        let now = t0.addingTimeInterval(200)   // 200 > 180
        #expect(PollingEngine.wakeRearmInterval(lastSuccess: last, interval: 180, now: now) == nil)
    }

    @Test func exactlyIntervalPollsNow() {
        // remaining == 0 is not > 0 → poll now (boundary).
        let now = t0.addingTimeInterval(180)
        #expect(PollingEngine.wakeRearmInterval(lastSuccess: t0, interval: 180, now: now) == nil)
    }

    @Test func noPriorSuccessPollsNow() {
        // Cold start / still-failing → a wake must be free to fetch.
        #expect(PollingEngine.wakeRearmInterval(lastSuccess: nil, interval: 180, now: t0) == nil)
    }

    @Test func freshCacheReArmsForRemainder() {
        // 60 s into a 180 s interval → re-arm for the remaining 120 s (no fetch).
        let now = t0.addingTimeInterval(60)
        #expect(PollingEngine.wakeRearmInterval(lastSuccess: t0, interval: 180, now: now) == 120)
    }

    @Test func remainderFlooredToMinInterval() {
        // 175 s into 180 s → remaining 5 s, but floored at the 60 s safety rail so a burst of wakes
        // can never tighten the cadence below the floor.
        let now = t0.addingTimeInterval(175)
        #expect(PollingEngine.wakeRearmInterval(lastSuccess: t0, interval: 180, now: now)
            == PollingEngine.minInterval)
    }
}

// MARK: - Safety floor: a tight request loop must be impossible

@Suite("PollingEngine.minInterval floor")
struct MinIntervalFloorTests {

    @Test func effectiveIntervalNeverBelowFloor() {
        // The base is 180 s (above the 60 s safety floor); assert the rail directly.
        let state = PollState(claudeActive: true)
        #expect(PollingEngine.effectiveInterval(state) >= PollingEngine.minInterval)
    }

    @Test func everyIntervalCombinationRespectsFloor() {
        // Exhaustively: across activity × hold interval (including sub-floor Retry-After values), the
        // effective interval is never below the safety floor — the rail that makes ~50 req/s impossible.
        let holds: [TimeInterval?] = [nil, 1, 30, 59, 60, 180, 900, 3600]
        for active in [true, false] {
            for hold in holds {
                var backoff = PollingBackoff()
                if let hold { backoff = backoff.honoring(retryAfter: hold) }
                let state = PollState(backoff: backoff, claudeActive: active)
                #expect(PollingEngine.effectiveInterval(state) >= PollingEngine.minInterval)
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

    @Test func claudeInactiveCause() {
        let prev = PollState(claudeActive: true)                 // 180
        let next = PollState(claudeActive: false)                // 900 (15 min)
        let d = PollingEngine.intervalDecision(previous: prev, next: next)
        #expect(d?.cause == .claudeInactive)
        #expect(d?.to == 900)
    }

    @Test func claudeResumedCause() {
        let prev = PollState(claudeActive: false)                // 900
        let next = PollState(claudeActive: true)                 // 180
        let d = PollingEngine.intervalDecision(previous: prev, next: next)
        #expect(d?.cause == .claudeActiveResumed)
        #expect(d?.to == 180)
    }

    @Test func rateLimitedCause() {
        let prev = PollState(claudeActive: true)
        var next = prev
        next.backoff = PollingBackoff().honoring(retryAfter: 600)
        let d = PollingEngine.intervalDecision(previous: prev, next: next)
        #expect(d?.cause == .rateLimited)
        #expect(d?.to == 600)
    }

    @Test func rateLimitClearedCause() {
        var prev = PollState(claudeActive: true)
        prev.backoff = PollingBackoff().honoring(retryAfter: 600)
        var next = prev
        next.backoff = prev.backoff.reset()                      // back to base 180
        let d = PollingEngine.intervalDecision(previous: prev, next: next)
        #expect(d?.cause == .rateLimitCleared)
        #expect(d?.to == 180)
    }

    @Test func logMessageFormatsWholeMinutes() {
        let d = IntervalDecision(from: 180, to: 900, cause: .claudeInactive)
        #expect(d.logMessage.hasPrefix("interval 3m→15m:"))
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
        #expect(next.backoff.isHolding == true)    // the 429 still entered the hold
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

    @Test func staleWakeTriggersImmediatePoll() async {
        // A `.wake` on a cold start (no prior success) fetches at once — `wakeRearmInterval` returns
        // nil when `lastSuccess == nil`, so the loop polls immediately rather than re-arming.
        let counter = CountingTransport(inner: .failing(URLError(.timedOut)))  // never a success
        let scheduler = ManualScheduler(script: [.interrupted(.wake), .elapsed])
        let engine = PollingEngine(
            transport: counter, tokenProvider: StubTokenProvider(), scheduler: scheduler,
            probe: StubProbe(active: true), now: { t0 })
        let outputs = await collect(engine, count: 2)
        #expect(outputs.count == 2)
        #expect(await counter.count >= 2)          // no prior success → the wake fetched off-schedule
    }

    @Test func manualRefreshClearsHoldForImmediatePoll() async {
        // Two 429s that each carry a long Retry-After (600 s) → the loop holds at 600. A
        // `.manualRefresh` between polls 2 and 3 clears the hold *before* the immediate poll 3 runs;
        // poll 3 succeeds (a 200), so its interval is the 180 s base — the manual refresh escaped the
        // 10-minute hold. (Had poll 3 hit another 429, it would re-enter the hold — that is correct.)
        let transport = SequencedTransport(steps: [
            StubTransport.http(429, headers: ["Retry-After": "600"]),
            StubTransport.http(429, headers: ["Retry-After": "600"]),
            StubTransport.success(five: 10, seven: 20),
        ])
        let scheduler = ManualScheduler(script: [.elapsed, .interrupted(.manualRefresh), .elapsed])
        let engine = PollingEngine(
            transport: transport, tokenProvider: StubTokenProvider(), scheduler: scheduler,
            probe: StubProbe(active: true), now: { t0 })
        let outputs = await collect(engine, count: 3)
        #expect(outputs[0].interval == 600)   // first 429 → hold at Retry-After
        #expect(outputs[1].interval == 600)   // second 429 → still 600 (no escalation)
        #expect(outputs[2].interval == 180)   // manual refresh cleared the hold; the 200 stays at base
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

    @Test func inactiveClaudeYieldsFifteenMinInterval() async {
        let counter = CountingTransport(inner: .success(five: 10, seven: 20))
        let scheduler = ManualScheduler(script: [.elapsed])
        let engine = PollingEngine(
            transport: counter, tokenProvider: StubTokenProvider(), scheduler: scheduler,
            probe: StubProbe(active: false), now: { t0 })
        let outputs = await collect(engine, count: 1)
        #expect(outputs[0].interval == 15 * 60)    // hard idle override
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

// MARK: - sessionIdleTransition (#100, ADR-0027)

@Suite("PollingEngine.sessionIdleTransition")
struct SessionIdleTransitionTests {

    /// An active snapshot (has a real five_hour reset → not idle).
    private func active() -> UsageSnapshot { snap(five: 2, seven: 31) }
    /// A session-idle snapshot (five_hour has no reset).
    private func idle() -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: UsageWindow(utilization: 0, resetsAt: ""),
            sevenDay: UsageWindow(utilization: 31, resetsAt: "2026-06-28T00:00:00+00:00"),
            sessionIdle: true)
    }

    @Test func nilToIdleLogsIdle() {
        #expect(PollingEngine.sessionIdleTransition(previous: nil, current: idle())
            == "five_hour idle — no active session (resets_at absent)")
    }

    @Test func activeToIdleLogsIdle() {
        #expect(PollingEngine.sessionIdleTransition(previous: active(), current: idle())
            == "five_hour idle — no active session (resets_at absent)")
    }

    @Test func idleToActiveLogsActiveAgain() {
        #expect(PollingEngine.sessionIdleTransition(previous: idle(), current: active())
            == "five_hour window active again")
    }

    @Test func nilToActiveIsSilent() {
        #expect(PollingEngine.sessionIdleTransition(previous: nil, current: active()) == nil)
    }

    @Test func idleToIdleIsSilent() {
        #expect(PollingEngine.sessionIdleTransition(previous: idle(), current: idle()) == nil)
    }

    @Test func activeToActiveIsSilent() {
        #expect(PollingEngine.sessionIdleTransition(previous: active(), current: active()) == nil)
    }

    @Test func nilCurrentIsSilent() {
        // A failing poll (no new snapshot) never logs a transition.
        #expect(PollingEngine.sessionIdleTransition(previous: idle(), current: nil) == nil)
    }
}

// MARK: - applyIdleGrace (reset-boundary idle suppression, ADR-0041)

@Suite("PollingEngine.applyIdleGrace")
struct ApplyIdleGraceTests {

    /// An active snapshot — a real five_hour window with a present reset.
    private func active() -> UsageSnapshot { snap(five: 40, seven: 84) }

    /// A session-idle snapshot — five_hour with no reset (what the decoder yields right after a reset).
    private func idle() -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: UsageWindow(utilization: 0, resetsAt: ""),
            sevenDay: UsageWindow(utilization: 84, resetsAt: "2026-06-28T00:00:00+00:00"),
            sessionIdle: true)
    }

    private let window = PollingEngine.idleGraceWindow  // 300 s

    /// A util-freshness stamp that is fresh at `t0` (a spend happened 1 min ago). The arming path
    /// (ADR-0045) requires this alongside `claudeActive`.
    private var freshUtil: Date { t0.addingTimeInterval(-60) }
    /// A stale util-freshness stamp (>15 min old at `t0`) — a genuine pause with no recent spend.
    private var staleUtil: Date { t0.addingTimeInterval(-PollingEngine.utilFreshnessWindow - 60) }

    @Test func activeToIdleArmsGraceAndSuppresses() {
        // Previous active window, no grace yet, process alive AND a fresh spend → arm the grace and
        // render a non-idle bar with a rolled-forward reset (not "resetting…").
        let out = PollingEngine.applyIdleGrace(
            decoded: idle(), previous: active(), activeUntil: nil, now: t0,
            claudeActive: true, lastUtilizationChange: freshUtil)
        #expect(out.snapshot.sessionIdle == false)
        #expect(out.suppressedUntil == t0.addingTimeInterval(window))
        // The suppressed 5h window carries a future reset — never an empty resets_at that would
        // render "resetting…". It is non-empty and parses to a strictly-positive remaining.
        #expect(!out.snapshot.fiveHour.resetsAt.isEmpty)
        let reset = ResetClock.parse(out.snapshot.fiveHour.resetsAt)
        #expect((reset ?? t0).timeIntervalSince(t0) > 0)
    }

    @Test func heldWhileGraceActive() {
        // Grace armed, still before the deadline → keep suppressing, deadline unchanged.
        let deadline = t0.addingTimeInterval(window)
        let out = PollingEngine.applyIdleGrace(
            decoded: idle(), previous: idle(), activeUntil: deadline,
            now: t0.addingTimeInterval(120), claudeActive: true, lastUtilizationChange: freshUtil)
        #expect(out.snapshot.sessionIdle == false)
        #expect(out.suppressedUntil == deadline)
    }

    @Test func graceExpiredSurfacesRealIdle() {
        // Grace armed but the deadline has passed → the window never came back, show the real idle.
        let deadline = t0.addingTimeInterval(window)
        let out = PollingEngine.applyIdleGrace(
            decoded: idle(), previous: idle(), activeUntil: deadline,
            now: deadline.addingTimeInterval(1), claudeActive: true, lastUtilizationChange: freshUtil)
        #expect(out.snapshot.sessionIdle == true)
        #expect(out.suppressedUntil == nil)
    }

    @Test func genuineIdleFromNilPreviousNotSuppressed() {
        // Cold start (no previous snapshot) → a genuine idle from the first poll is never suppressed.
        let out = PollingEngine.applyIdleGrace(
            decoded: idle(), previous: nil, activeUntil: nil, now: t0,
            claudeActive: true, lastUtilizationChange: freshUtil)
        #expect(out.snapshot.sessionIdle == true)
        #expect(out.suppressedUntil == nil)
    }

    @Test func genuineIdleFromIdlePreviousNotSuppressed() {
        // Previous poll was already idle (a settled idle session) → no arming, stays idle.
        let out = PollingEngine.applyIdleGrace(
            decoded: idle(), previous: idle(), activeUntil: nil, now: t0,
            claudeActive: true, lastUtilizationChange: freshUtil)
        #expect(out.snapshot.sessionIdle == true)
        #expect(out.suppressedUntil == nil)
    }

    @Test func activeAfterGraceElapsedClearsGrace() {
        // The window reappeared AFTER the deadline elapsed → pass the active snapshot through and
        // drop the grace (steady state resumes).
        let deadline = t0.addingTimeInterval(window)
        let out = PollingEngine.applyIdleGrace(
            decoded: active(), previous: idle(), activeUntil: deadline,
            now: deadline.addingTimeInterval(1), claudeActive: true, lastUtilizationChange: freshUtil)
        #expect(out.snapshot.sessionIdle == false)
        #expect(out.suppressedUntil == nil)
    }

    @Test func activeBlipWithinGraceKeepsDeadline() {
        // The window blips active WHILE the grace is still within its deadline → render the active
        // snapshot but CARRY the same deadline forward, so a later idle cannot re-arm a fresh window
        // (ADR-0045, re-arm guard). Render is active; the grace is preserved, not cleared.
        let deadline = t0.addingTimeInterval(window)
        let out = PollingEngine.applyIdleGrace(
            decoded: active(), previous: idle(), activeUntil: deadline,
            now: t0.addingTimeInterval(120), claudeActive: true, lastUtilizationChange: freshUtil)
        #expect(out.snapshot.sessionIdle == false)
        #expect(out.suppressedUntil == deadline)
    }

    @Test func previousNonIdleWithoutResetsAtNotArmed() {
        // A previous snapshot that is technically non-idle but has an empty five_hour resets_at is
        // not a genuine active window → do not arm the grace.
        let prev = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 0, resetsAt: ""),
            sevenDay: UsageWindow(utilization: 84, resetsAt: "2026-06-28T00:00:00+00:00"),
            sessionIdle: false)
        let out = PollingEngine.applyIdleGrace(
            decoded: idle(), previous: prev, activeUntil: nil, now: t0,
            claudeActive: true, lastUtilizationChange: freshUtil)
        #expect(out.snapshot.sessionIdle == true)
        #expect(out.suppressedUntil == nil)
    }

    // MARK: activity gate (ADR-0045) — grace arms only on recent real work

    @Test func notArmedWhenProcessInactive() {
        // Previous active + fresh spend, BUT the claude process is gone → a genuine pause, idle now.
        let out = PollingEngine.applyIdleGrace(
            decoded: idle(), previous: active(), activeUntil: nil, now: t0,
            claudeActive: false, lastUtilizationChange: freshUtil)
        #expect(out.snapshot.sessionIdle == true)
        #expect(out.suppressedUntil == nil)
    }

    @Test func notArmedWhenUtilStale() {
        // Process alive, previous active, BUT no spend for >15 min → parked session, idle now.
        let out = PollingEngine.applyIdleGrace(
            decoded: idle(), previous: active(), activeUntil: nil, now: t0,
            claudeActive: true, lastUtilizationChange: staleUtil)
        #expect(out.snapshot.sessionIdle == true)
        #expect(out.suppressedUntil == nil)
    }

    @Test func notArmedWhenNoUtilStampYet() {
        // No utilization ever observed to rise (nil stamp) → cannot claim recent work, idle now.
        let out = PollingEngine.applyIdleGrace(
            decoded: idle(), previous: active(), activeUntil: nil, now: t0,
            claudeActive: true, lastUtilizationChange: nil)
        #expect(out.snapshot.sessionIdle == true)
        #expect(out.suppressedUntil == nil)
    }

    @Test func armsOnlyWhenBothProcessAndUtilFresh() {
        // Sanity: the conjunction — only (alive AND fresh) arms; the three other combinations don't.
        func arms(_ alive: Bool, _ util: Date?) -> Bool {
            PollingEngine.applyIdleGrace(
                decoded: idle(), previous: active(), activeUntil: nil, now: t0,
                claudeActive: alive, lastUtilizationChange: util).suppressedUntil != nil
        }
        #expect(arms(true, freshUtil) == true)
        #expect(arms(true, staleUtil) == false)
        #expect(arms(false, freshUtil) == false)
        #expect(arms(false, staleUtil) == false)
    }

    // MARK: re-arm guard (ADR-0045) — a mid-grace active blip must not extend the deadline

    @Test func midGraceActiveBlipDoesNotReArm() {
        // Armed grace, an active poll blips in mid-window, then idle again — the deadline must be the
        // ORIGINAL one, not a fresh 5 min from the blip. Driven through `advance` so the state (the
        // suppressed lastSnapshot) is threaded exactly as production does it.
        let s0 = PollingEngine.advance(
            previous: PollState(), outcome: .success(active()), claudeActive: true, now: t0)
        // Bump util so the freshness stamp is set (active() → active2 with higher util).
        let active2 = snap(five: 55, seven: 84)
        let s1 = PollingEngine.advance(
            previous: s0, outcome: .success(active2), claudeActive: true,
            now: t0.addingTimeInterval(60))
        // Reset boundary: idle → arm grace at t0+120, deadline t0+120+window.
        let armedAt = t0.addingTimeInterval(120)
        let s2 = PollingEngine.advance(
            previous: s1, outcome: .success(idle()), claudeActive: true, now: armedAt)
        let originalDeadline = armedAt.addingTimeInterval(window)
        #expect(s2.idleSuppressedUntil == originalDeadline)
        // Active blip mid-grace (t0+180) → grace cleared by the active poll...
        let s3 = PollingEngine.advance(
            previous: s2, outcome: .success(active2), claudeActive: true,
            now: t0.addingTimeInterval(180))
        // ...then idle again at t0+240. Without a guard this re-arms a NEW window ending at
        // t0+240+window (>originalDeadline), holding "resetting"/ready well past 5 min. The genuine
        // idle must instead surface once the original grace would have elapsed. We assert the deadline
        // never extends beyond the original.
        let s4 = PollingEngine.advance(
            previous: s3, outcome: .success(idle()), claudeActive: true,
            now: t0.addingTimeInterval(240))
        if let deadline = s4.idleSuppressedUntil {
            #expect(deadline <= originalDeadline)
        }
    }

    // MARK: integration through advance

    @Test func advanceSuppressesBoundaryIdle() {
        // Two successive successes: active → idle. The second must land a non-idle lastSnapshot with
        // an armed grace deadline. The first active poll (from empty state) sets the util stamp.
        let afterActive = PollingEngine.advance(
            previous: PollState(), outcome: .success(active()), claudeActive: true, now: t0)
        let afterIdle = PollingEngine.advance(
            previous: afterActive, outcome: .success(idle()), claudeActive: true,
            now: t0.addingTimeInterval(180))
        #expect(afterIdle.lastSnapshot?.sessionIdle == false)
        #expect(afterIdle.idleSuppressedUntil == t0.addingTimeInterval(180 + window))
    }

    @Test func advanceExpiresGraceAcrossTime() {
        // A third idle poll after the deadline surfaces the genuine idle and clears the grace.
        let afterActive = PollingEngine.advance(
            previous: PollState(), outcome: .success(active()), claudeActive: true, now: t0)
        let afterIdle = PollingEngine.advance(
            previous: afterActive, outcome: .success(idle()), claudeActive: true,
            now: t0.addingTimeInterval(180))
        let afterExpiry = PollingEngine.advance(
            previous: afterIdle, outcome: .success(idle()), claudeActive: true,
            now: t0.addingTimeInterval(180 + window + 1))
        #expect(afterExpiry.lastSnapshot?.sessionIdle == true)
        #expect(afterExpiry.idleSuppressedUntil == nil)
    }

    @Test func advanceStampsUtilizationRise() {
        // The util-freshness clock is set only when 5h utilization rises vs the previous poll.
        let s1 = PollingEngine.advance(
            previous: PollState(), outcome: .success(snap(five: 10, seven: 84)),
            claudeActive: true, now: t0)
        #expect(s1.lastUtilizationChange == t0)   // 0 → 10 is a rise from the cold nil snapshot
        // A flat poll (same util) does not move the stamp.
        let s2 = PollingEngine.advance(
            previous: s1, outcome: .success(snap(five: 10, seven: 84)),
            claudeActive: true, now: t0.addingTimeInterval(180))
        #expect(s2.lastUtilizationChange == t0)
        // A rise moves it to the new now.
        let s3 = PollingEngine.advance(
            previous: s2, outcome: .success(snap(five: 12, seven: 84)),
            claudeActive: true, now: t0.addingTimeInterval(360))
        #expect(s3.lastUtilizationChange == t0.addingTimeInterval(360))
    }
}

// MARK: - advance: weekly reconstruction (#386)

@Suite("PollingEngine.advance — weekly reconstruction")
struct AdvanceWeeklyTests {

    @Test func successFoldsThePollIntoTheReconstruction() {
        let next = PollingEngine.advance(
            previous: PollState(), outcome: .success(snap(five: 10, seven: 80)),
            claudeActive: true, now: t0)
        // The first poll anchors (inherited — no bump observed yet) and starts tracking the counter.
        #expect(next.weeklyInterpolator.anchoredRaw == 80)
        #expect(next.weeklyInterpolator.lastFiveHour == 10)
    }

    @Test func aFailureLeavesTheReconstructionUntouched() {
        // Only a successful poll carries counters; an error must not be mistaken for a hole or a
        // reset — the next success measures the gap itself.
        let seeded = PollingEngine.advance(
            previous: PollState(), outcome: .success(snap(five: 10, seven: 80)),
            claudeActive: true, now: t0)
        let afterError = PollingEngine.advance(
            previous: seeded, outcome: .usageError(.transport(message: "timed out", code: .timedOut)),
            claudeActive: true, now: t0.addingTimeInterval(180))
        #expect(afterError.weeklyInterpolator == seeded.weeklyInterpolator)
    }

    @Test func anObservedBumpFeedsTheRatioAndFirmsTheAnchor() {
        var s = PollingEngine.advance(
            previous: PollState(), outcome: .success(snap(five: 0, seven: 50)),
            claudeActive: true, now: t0)
        // Ten points of 5h spend, then the weekly counter ticks: one segment closes at N = 10.
        s = PollingEngine.advance(
            previous: s, outcome: .success(snap(five: 10, seven: 50)),
            claudeActive: true, now: t0.addingTimeInterval(180))
        s = PollingEngine.advance(
            previous: s, outcome: .success(snap(five: 10, seven: 51)),
            claudeActive: true, now: t0.addingTimeInterval(360))
        #expect(s.weeklyInterpolator.ratio.sampleCount == 1)
        #expect(s.weeklyInterpolator.isFirm)
        #expect(s.weeklyInterpolator.value(forRaw: 51).effective == 50.5)   // firm lower edge
    }

    @Test func theReconstructionReadsTheDecodedSnapshotNotTheIdleGraceRebuild() {
        // The grace rolls the 5h window forward for the UI; that is presentation, not spend, and
        // must not reach the estimator. The decoded 5h value is what gets folded in.
        let s = PollingEngine.advance(
            previous: PollState(), outcome: .success(snap(five: 42, seven: 60)),
            claudeActive: true, now: t0)
        #expect(s.weeklyInterpolator.lastFiveHour == 42)
    }

    @Test func ratioLogFiresOnTheFirstEstimateAndOnRealMoves() {
        let cold = PollState()
        var warm = PollState()
        warm.weeklyInterpolator = WeeklyInterpolator(ratio: WeeklyRatio(segments: [10, 10, 10]))

        // Seed → first real estimate: worth saying once.
        #expect(PollingEngine.weeklyRatioLog(previous: cold, next: warm) != nil)

        // A tiny drift stays silent (the median twitches as the window slides).
        var nudged = warm
        nudged.weeklyInterpolator = WeeklyInterpolator(ratio: WeeklyRatio(segments: [10, 10, 10.2]))
        #expect(PollingEngine.weeklyRatioLog(previous: warm, next: nudged) == nil)

        // A promotion-sized move is news.
        var promoted = warm
        promoted.weeklyInterpolator = WeeklyInterpolator(ratio: WeeklyRatio(segments: [15, 15, 15]))
        #expect(PollingEngine.weeklyRatioLog(previous: warm, next: promoted) != nil)

        // Nothing to say while the estimator is still empty.
        #expect(PollingEngine.weeklyRatioLog(previous: cold, next: cold) == nil)
    }
}
