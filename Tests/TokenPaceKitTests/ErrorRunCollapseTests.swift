import Testing
import Foundation
@testable import TokenPaceKit

private let e0 = Date(timeIntervalSince1970: 1_000_000)

private func sample(
    code: ErrorCode = .category("notSent"), reason: String = "notSent",
    detail: String? = "token expired", retryAfter: TimeInterval? = nil,
    ms: Int? = nil, n: Int? = nil
) -> ErrorSample {
    ErrorSample(t: ResetClock.isoString(from: e0), code: code, reason: reason, detail: detail,
                retryAfter: retryAfter, ms: ms, n: n)
}

/// Feed a series of identical samples spaced `every` seconds apart, returning the lines written.
private func drain(count: Int, every: TimeInterval, from start: Date = e0) -> [ErrorSample] {
    var open: ErrorRun?
    var written: [ErrorSample] = []
    for i in 0..<count {
        let at = start.addingTimeInterval(Double(i) * every)
        switch ErrorRunCollapse.admit(open, sample: sample(), at: at) {
        case let .extend(run):
            open = run
        case let .flush(closed, next):
            if let line = ErrorRunCollapse.close(closed) { written.append(line) }
            open = next
        }
    }
    if let line = ErrorRunCollapse.close(open) { written.append(line) }
    return written
}

@Suite("ErrorRunCollapse")
struct ErrorRunCollapseTests {

    @Test func identicalErrorsExtendTheRun() {
        var open: ErrorRun?
        for i in 0..<3 {
            let d = ErrorRunCollapse.admit(open, sample: sample(),
                                           at: e0.addingTimeInterval(Double(i)))
            guard case let .extend(run) = d else { Issue.record("expected extend"); return }
            open = run
        }
        #expect(open?.count == 3)
        #expect(open?.first == e0)
        #expect(open?.last == e0.addingTimeInterval(2))
    }

    @Test func aDifferentDetailBreaksTheRun() {
        let open = ErrorRun(code: .category("notSent"), reason: "notSent", detail: "token expired",
                            retryAfter: nil, ms: nil, first: e0, last: e0, count: 4)
        let d = ErrorRunCollapse.admit(open, sample: sample(detail: "keychain access denied"),
                                       at: e0.addingTimeInterval(1))
        guard case let .flush(closed, next) = d else { Issue.record("expected flush"); return }
        #expect(closed.count == 4)
        #expect(next.detail == "keychain access denied")
    }

    /// The failure this whole tag exists to prevent, one layer down: two providers can fail with the
    /// same code, reason, detail and `retryAfter`, and folded together they would leave one line
    /// carrying one of their names.
    @Test func runsDoNotMergeAcrossProviders() {
        let claude = sample()
        let other = ErrorSample(
            t: claude.t, code: claude.code, reason: claude.reason, detail: claude.detail,
            retryAfter: claude.retryAfter, ms: claude.ms, provider: "github")
        let open = ErrorRun(code: claude.code, reason: claude.reason, detail: claude.detail,
                            retryAfter: nil, ms: nil, first: e0, last: e0, count: 3,
                            provider: ProviderID.claude.rawValue)

        let d = ErrorRunCollapse.admit(open, sample: other, at: e0.addingTimeInterval(3))
        guard case let .flush(closed, next) = d else { Issue.record("expected flush"); return }
        #expect(closed.count == 3)
        #expect(closed.provider == ProviderID.claude.rawValue)
        #expect(next.provider == "github")
        #expect(next.count == 1)
    }

    /// The control for the test above: identical in every field including the provider, so it must
    /// extend. Without it, a collapse switched off entirely would make `runsDoNotMergeAcrossProviders`
    /// pass for the wrong reason.
    @Test func theSameProviderStillExtendsTheRun() {
        let open = ErrorRun(code: .category("notSent"), reason: "notSent", detail: "token expired",
                            retryAfter: nil, ms: nil, first: e0, last: e0, count: 3,
                            provider: ProviderID.claude.rawValue)
        let d = ErrorRunCollapse.admit(open, sample: sample(), at: e0.addingTimeInterval(3))
        guard case let .extend(run) = d else { Issue.record("expected extend"); return }
        #expect(run.count == 4)
    }

    /// The writer keeps one open run per provider and must close **all** of them at termination — a
    /// single-provider flush there writes one line and silently drops the rest. This covers the pure
    /// half of that: closing a set of runs yields one line per provider, each keeping its own name and
    /// count. The `UsageJournal.flushAllErrorRuns` loop that drives it lives in the app target, which
    /// has no tests of its own.
    @Test func closingASetOfRunsKeepsEveryProvidersLine() {
        let open: [String: ErrorRun] = ["claude": 3, "github": 5].reduce(into: [:]) { acc, pair in
            acc[pair.key] = ErrorRun(
                code: .category("notSent"), reason: "notSent", detail: nil,
                retryAfter: nil, ms: nil, first: e0, last: e0.addingTimeInterval(60),
                count: pair.value, provider: pair.key)
        }
        let lines = open.values
            .compactMap { ErrorRunCollapse.close($0) }
            .sorted { $0.provider < $1.provider }

        #expect(lines.count == 2)
        #expect(lines.map(\.provider) == ["claude", "github"])
        #expect(lines.map(\.n) == [3, 5])
    }

    @Test func aDifferentCodeBreaksTheRun() {
        let open = ErrorRun(code: .category("notSent"), reason: "notSent", detail: nil,
                            retryAfter: nil, ms: nil, first: e0, last: e0, count: 2)
        let d = ErrorRunCollapse.admit(open, sample: sample(code: .http(429), reason: "clientProblem",
                                                            detail: nil),
                                       at: e0.addingTimeInterval(1))
        guard case .flush = d else { Issue.record("expected flush"); return }
    }

    @Test func aDifferentRetryAfterBreaksTheRun() {
        // Two 429s holding different hints are different failures: merging them would invent a hold
        // neither server asked for.
        let open = ErrorRun(code: .http(429), reason: "clientProblem", detail: nil,
                            retryAfter: 60, ms: nil, first: e0, last: e0, count: 1)
        let d = ErrorRunCollapse.admit(open, sample: sample(code: .http(429), reason: "clientProblem",
                                                            detail: nil, retryAfter: 600),
                                       at: e0.addingTimeInterval(1))
        guard case .flush = d else { Issue.record("expected flush"); return }
    }

    @Test func threeMinutesBoundsTheRunWidth() {
        let open = ErrorRun(code: .category("notSent"), reason: "notSent", detail: "token expired",
                            retryAfter: nil, ms: nil, first: e0, last: e0, count: 10)
        // Exactly at the boundary the run still extends…
        guard case .extend = ErrorRunCollapse.admit(
            open, sample: sample(), at: e0.addingTimeInterval(ErrorRunCollapse.maxRunWidth))
        else { Issue.record("boundary should extend"); return }
        // …one second past it, the run is closed.
        guard case .flush = ErrorRunCollapse.admit(
            open, sample: sample(), at: e0.addingTimeInterval(ErrorRunCollapse.maxRunWidth + 1))
        else { Issue.record("past the boundary should flush"); return }
    }

    @Test func aSingleErrorCarriesNoRunFields() {
        // The common case must not gain `n:1,tEnd:t` noise on every line.
        let line = ErrorRunCollapse.close(
            ErrorRun(code: .category("dns"), reason: "dns", detail: nil, retryAfter: nil, ms: 12,
                     first: e0, last: e0, count: 1))
        #expect(line?.n == nil)
        #expect(line?.tEnd == nil)
        #expect(line?.ms == 12)
    }

    @Test func aClosedRunCarriesFirstLastAndCount() {
        let line = ErrorRunCollapse.close(
            ErrorRun(code: .category("notSent"), reason: "notSent", detail: "token expired",
                     retryAfter: nil, ms: nil,
                     first: e0, last: e0.addingTimeInterval(120), count: 900))
        #expect(line?.n == 900)
        #expect(line?.t == ResetClock.isoString(from: e0))
        #expect(line?.tEnd == ResetClock.isoString(from: e0.addingTimeInterval(120)))
        #expect(line?.detail == "token expired")
        #expect(line?.v == ErrorSample.currentVersion)
    }

    @Test func anAlreadyCollapsedSampleNeverExtendsARun() {
        // What makes a second migration pass a no-op instead of merging everything into one line.
        let open = ErrorRun(code: .category("notSent"), reason: "notSent", detail: "token expired",
                            retryAfter: nil, ms: nil, first: e0, last: e0, count: 3)
        let d = ErrorRunCollapse.admit(open, sample: sample(n: 5), at: e0.addingTimeInterval(1))
        guard case let .flush(closed, next) = d else { Issue.record("expected flush"); return }
        #expect(closed.count == 3)
        #expect(next.count == 5)     // the incoming run keeps its own count
    }

    @Test func theStormCollapsesToOneLinePerThreeMinutes() {
        // The incident in miniature: 122 408 attempts at ~16 Hz over 127 minutes produced 98% of a
        // real journal. Here the same shape at 1 Hz over 12 minutes.
        let written = drain(count: 720, every: 1)
        #expect(written.count == 4)                                  // 12 min / 3 min
        #expect(written.map { $0.n ?? 1 }.reduce(0, +) == 720)       // nothing lost
        #expect(written.allSatisfy { $0.detail == "token expired" })
    }

    @Test func everyAttemptSurvivesAsACount() {
        // The invariant the migration's line-count check is narrowed to: attempts are conserved.
        for spacing in [0.06, 1.0, 60.0, 200.0] {
            let written = drain(count: 50, every: spacing)
            #expect(written.map { $0.n ?? 1 }.reduce(0, +) == 50,
                    "attempts lost at \(spacing)s spacing")
        }
    }
}
