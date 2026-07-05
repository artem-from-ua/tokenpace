import Testing
import Foundation
@testable import TokenPaceKit

/// Tests for the **production** scheduler — the component whose absence of a test let a tight
/// request loop ship. Timing is compressed via `nanosPerSecond` so a "10 s" interval sleeps ~10 ms,
/// keeping the real `Task.sleep` path exercised without slow tests.
@Suite("LivePollScheduler")
struct LivePollSchedulerTests {

    /// 1 "second" == 1 ms of real time. The timing path is real; only the scale is compressed.
    private let fastNanos: Double = 1_000_000

    /// Make a scheduler plus the continuation that feeds signals into it.
    private func makeScheduler() -> (LivePollScheduler, AsyncStream<PollSignal>.Continuation) {
        let (stream, continuation) = AsyncStream.makeStream(of: PollSignal.self)
        return (LivePollScheduler(signals: stream, nanosPerSecond: fastNanos), continuation)
    }

    // MARK: The regression: an empty stream must NOT return early

    @Test func emptyStreamWaitsTheFullInterval() async {
        // THE regression test. No signal is ever sent. The wait must elapse (return `.elapsed`)
        // only after sleeping — never instantly. With the old broken iterator this returned
        // immediately, producing the ~50 req/s hammering.
        let (scheduler, _continuation) = makeScheduler()
        let start = Date()
        let reason = await scheduler.waitForNextPoll(interval: 50)   // 50 ms compressed
        let elapsed = Date().timeIntervalSince(start)
        #expect(reason == .elapsed)
        #expect(elapsed >= 0.04, "wait returned in \(elapsed)s — far too early; tight-loop regression")
        _ = _continuation
    }

    @Test func tenConsecutiveWaitsEachTakeTime() async {
        // Stronger form: ten waits in a row with no signals must each consume their interval, so the
        // total is bounded below — a tight loop would finish in microseconds.
        let (scheduler, _continuation) = makeScheduler()
        let start = Date()
        for _ in 0..<10 {
            _ = await scheduler.waitForNextPoll(interval: 20)   // 20 ms each
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed >= 0.15, "10 waits took only \(elapsed)s — tight-loop regression")
        _ = _continuation
    }

    // MARK: Signals interrupt the wait

    @Test func wakeSignalInterruptsImmediately() async {
        let (scheduler, continuation) = makeScheduler()
        // A long interval (1 s compressed = 1 s real would be slow, so use 5 s compressed = 5 ms);
        // the signal should win well before it elapses.
        continuation.yield(.wake)
        let reason = await scheduler.waitForNextPoll(interval: 5000)   // 5 s compressed; signal wins
        #expect(reason == .interrupted(.wake))
    }

    @Test func networkRestoredInterrupts() async {
        let (scheduler, continuation) = makeScheduler()
        continuation.yield(.networkRestored)
        let reason = await scheduler.waitForNextPoll(interval: 5000)
        #expect(reason == .interrupted(.networkRestored))
    }

    @Test func signalDeliveredEvenIfSentBeforeWait() async {
        // A signal arriving while nobody waits is buffered and delivered to the next wait — a `.wake`
        // between polls is not lost.
        let (scheduler, continuation) = makeScheduler()
        continuation.yield(.networkRestored)
        // Give the drain task a moment to buffer it.
        try? await Task.sleep(nanoseconds: 2_000_000)
        let reason = await scheduler.waitForNextPoll(interval: 5000)
        #expect(reason == .interrupted(.networkRestored))
    }

    // MARK: Park / wake

    @Test func waitWhileAsleepReturnsOnWake() async {
        let (scheduler, continuation) = makeScheduler()
        let parked = Task { await scheduler.waitWhileAsleep() }
        try? await Task.sleep(nanoseconds: 2_000_000)
        continuation.yield(.wake)
        // Should return promptly once awake — bound the wait so a hang fails the test.
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await parked.value; return true }
            group.addTask { try? await Task.sleep(nanoseconds: 200_000_000); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(finished, "waitWhileAsleep did not return after .wake")
    }

    @Test func waitWhileAsleepIgnoresDuplicateSleep() async {
        let (scheduler, continuation) = makeScheduler()
        let parked = Task { await scheduler.waitWhileAsleep() }
        continuation.yield(.sleep)   // duplicate sleep — must be ignored, stay parked
        try? await Task.sleep(nanoseconds: 3_000_000)
        #expect(parked.isCancelled == false)
        continuation.yield(.networkRestored)   // now wake it
        _ = await parked.value
    }

    // MARK: End-to-end: the engine + the REAL scheduler cannot hammer the API

    /// Counts how many fetches the engine issues, over the real `LivePollScheduler`, in a fixed wall
    /// window. This is the integration guard the original work lacked: it runs the *actual* timing
    /// path (compressed) with no signals and asserts the request rate stays bounded — the exact thing
    /// that went wrong in production (~50 req/s). With a 180 s base cadence compressed to 180 ms,
    /// roughly one fetch per 180 ms, so a ~0.6 s window must see only a small handful, never dozens.
    @Test func engineWithRealSchedulerStaysBounded() async {
        let counter = CountingTransport(inner: .success(five: 10, seven: 20))
        let (stream, _continuation) = AsyncStream.makeStream(of: PollSignal.self)
        let engine = PollingEngine(
            transport: counter,
            tokenProvider: StubTokenProvider(),
            scheduler: LivePollScheduler(signals: stream, nanosPerSecond: fastNanos),  // 1 s → 1 ms
            probe: StubProbe(active: true),
            now: { Date() })

        let loop = Task { for await _ in engine.run() {} }
        try? await Task.sleep(nanoseconds: 600_000_000)   // ~0.6 s real
        loop.cancel()
        let count = await counter.count
        // 180 s base → 180 ms compressed: ~3-4 polls in 600 ms. Cap well below a runaway loop.
        #expect(count <= 10, "engine issued \(count) fetches in 0.6 s — runaway-loop regression")
        #expect(count >= 1, "engine issued no fetches at all")
        _ = _continuation
    }
}

/// A transport that wraps a canned success and counts how many requests pass through. (Local copy —
/// the one in PollingEngineTests is `private` to that file.)
private actor CountingTransport: UsageTransport {
    private let inner: StubTransport
    private(set) var count = 0
    init(inner: StubTransport) { self.inner = inner }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        count += 1
        return try await inner.data(for: request)
    }
}

/// Stub transport (local copy — `private` in PollingEngineTests).
private struct StubTransport: UsageTransport {
    let result: Result<(Data, URLResponse), Error>
    func data(for request: URLRequest) async throws -> (Data, URLResponse) { try result.get() }
    static func success(five: Double, seven: Double) -> StubTransport {
        let body = """
        {"five_hour":{"utilization":\(five),"resets_at":"2026-06-21T05:30:00+00:00"},\
        "seven_day":{"utilization":\(seven),"resets_at":"2026-06-28T00:00:00+00:00"},"limits":[]}
        """.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: UsageClient.endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        return StubTransport(result: .success((body, response)))
    }
}

/// Token seam returning a literal. (Local copy.)
private struct StubTokenProvider: TokenProviding {
    func currentAccessToken(now: Date) throws -> String { "acc-123" }
}

/// Probe returning a fixed reading. (Local copy.)
private struct StubProbe: ClaudeActivityProbe {
    let active: Bool
    func isClaudeRunning() -> Bool { active }
}
