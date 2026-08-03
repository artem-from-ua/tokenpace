import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - usage(from:) mapping

@Suite("JournalRecord.usage domain mapping")
struct JournalUsageMappingTests {

    /// A fixed "now" and a reset one hour out on a half-elapsed 5h window, so pacing is well-defined.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func isoOffset(_ seconds: TimeInterval) -> String {
        ResetClock.isoString(from: now.addingTimeInterval(seconds))
    }

    @Test func mapsWindowsAndLatency() throws {
        let snapshot = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 40, resetsAt: isoOffset(9_000)),   // half of 5h left
            sevenDay: UsageWindow(utilization: 60, resetsAt: isoOffset(302_400)))
        guard case let .usage(s) = JournalRecord.usage(from: snapshot, now: now, durationMs: 123) else {
            Issue.record("expected .usage"); return
        }
        #expect(s.h5.util == 40)
        #expect(s.d7.util == 60)
        #expect(s.ms == 123)
        #expect(s.t == ResetClock.isoString(from: now))
        // timePct is the elapsed fraction — half-elapsed 5h → ~0.5.
        #expect(abs(s.h5.timePct - 0.5) < 0.001)
    }

    @Test func exhaustedWindowIsBlockedAndRed() throws {
        let snapshot = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 100, resetsAt: isoOffset(3_600)),
            sevenDay: UsageWindow(utilization: 50, resetsAt: isoOffset(302_400)))
        guard case let .usage(s) = JournalRecord.usage(from: snapshot, now: now) else {
            Issue.record("expected .usage"); return
        }
        #expect(s.blocked == true)          // 5h exhausted, no credits cover
        #expect(s.h5.sev == .red)
    }

    @Test func spendMapsToFullMoney() throws {
        let spend = SpendInfo(
            used: Money(amountMinor: 1077, currency: "EUR", exponent: 2),
            limit: Money(amountMinor: 5000, currency: "EUR", exponent: 2),
            enabled: true)
        let snapshot = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 100, resetsAt: isoOffset(3_600)),
            sevenDay: UsageWindow(utilization: 50, resetsAt: isoOffset(302_400)),
            spend: spend)
        guard case let .usage(s) = JournalRecord.usage(from: snapshot, now: now),
              let js = s.spend else {
            Issue.record("expected .usage with spend"); return
        }
        #expect(js.used == MoneySample(minor: 1077, cur: "EUR", exp: 2))
        #expect(js.limit == MoneySample(minor: 5000, cur: "EUR", exp: 2))
        #expect(js.spentFrac == 1077.0 / 5000.0)
        #expect(js.enabled == true)
    }

    @Test func gapIsTimeMinusUtil() throws {
        // Half-elapsed 5h window (timePct ~0.5 → 50 %) at 40 % util → gap ~ +10 pts (headroom).
        let snapshot = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 40, resetsAt: isoOffset(9_000)),
            sevenDay: UsageWindow(utilization: 60, resetsAt: isoOffset(302_400)))
        guard case let .usage(s) = JournalRecord.usage(from: snapshot, now: now) else {
            Issue.record("expected .usage"); return
        }
        #expect(abs(s.h5.gap - (s.h5.timePct * 100 - 40)) < 0.001)
        #expect(s.h5.gap > 0)   // behind pace → positive headroom
    }

    @Test func creditGapNilWithoutLimit() throws {
        // Unlimited credits (no limit) → creditGap is nil (nothing to pace against).
        let spend = SpendInfo(used: Money(amountMinor: 500, currency: "EUR", exponent: 2),
                              limit: nil, enabled: true)
        let snapshot = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 100, resetsAt: isoOffset(3_600)),
            sevenDay: UsageWindow(utilization: 50, resetsAt: isoOffset(302_400)),
            spend: spend)
        guard case let .usage(s) = JournalRecord.usage(from: snapshot, now: now), let js = s.spend else {
            Issue.record("expected .usage with spend"); return
        }
        #expect(js.creditGap == nil)
    }

    @Test func creditGapSetWithLimit() throws {
        let spend = SpendInfo(
            used: Money(amountMinor: 1000, currency: "EUR", exponent: 2),
            limit: Money(amountMinor: 5000, currency: "EUR", exponent: 2),
            enabled: true)
        let snapshot = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 100, resetsAt: isoOffset(3_600)),
            sevenDay: UsageWindow(utilization: 50, resetsAt: isoOffset(302_400)),
            spend: spend)
        guard case let .usage(s) = JournalRecord.usage(from: snapshot, now: now),
              let js = s.spend, let gap = js.creditGap, let frac = js.spentFrac else {
            Issue.record("expected .usage with credit gap"); return
        }
        #expect(abs(gap - (js.monthPct * 100 - frac * 100)) < 0.001)
    }

    @Test func idleSnapshotCarriesFlag() throws {
        let snapshot = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 0, resetsAt: ""),
            sevenDay: UsageWindow(utilization: 20, resetsAt: isoOffset(302_400)),
            sessionIdle: true)
        guard case let .usage(s) = JournalRecord.usage(from: snapshot, now: now) else {
            Issue.record("expected .usage"); return
        }
        #expect(s.sessionIdle == true)
    }
}

// MARK: - status(from:) mapping

@Suite("JournalRecord.status domain mapping")
struct JournalStatusMappingTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func mapsComponentsAndWorst() throws {
        let summary = StatusSummary(components: [
            StatusComponent(name: "Claude Code", status: "operational"),
            StatusComponent(name: "Claude API (api.anthropic.com)", status: "major_outage"),
        ])
        let health = StatusHealth.from(summary, config: .default)
        guard case let .status(s) = JournalRecord.status(from: summary, health: health, now: now) else {
            Issue.record("expected .status"); return
        }
        #expect(s.svc.count == 2)
        #expect(s.svc.first?.n == "Claude Code")
        #expect(s.worst == "major_outage")
    }

    @Test func allOperationalWorstIsOperational() throws {
        // Every monitored component present and operational — an absent component would resolve to
        // `.unknown` (which counts as a problem), so include all three that `.default` monitors.
        let summary = StatusSummary(components: [
            StatusComponent(name: StatusHealth.claudeAPIComponentName, status: "operational"),
            StatusComponent(name: StatusHealth.claudeCodeComponentName, status: "operational"),
            StatusComponent(name: StatusHealth.claudeWebComponentName, status: "operational"),
        ])
        let health = StatusHealth.from(summary, config: .default)
        guard case let .status(s) = JournalRecord.status(from: summary, health: health, now: now) else {
            Issue.record("expected .status"); return
        }
        #expect(s.worst == "operational")
    }
}

// MARK: - error(diagnostics:) taxonomy

@Suite("JournalRecord.error taxonomy")
struct JournalErrorMappingTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func errorSample(_ d: FetchDiagnostics, failure: FailureReason?) -> ErrorSample? {
        guard case let .error(s) = JournalRecord.error(diagnostics: d, failure: failure, now: now) else { return nil }
        return s
    }

    @Test func rateLimitedIsClientProblem() throws {
        let d = FetchDiagnostics(attemptAt: now, httpStatus: 429, body: nil, outcome: .httpError,
                                 retryAfter: 60, durationMs: 142)
        let s = try #require(errorSample(d, failure: .serverProblem))
        #expect(s.code == .http(429))
        #expect(s.reason == "clientProblem")
        #expect(s.retryAfter == 60)
        #expect(s.ms == 142)
    }

    @Test func serverErrorIsServerProblem() throws {
        let d = FetchDiagnostics(attemptAt: now, httpStatus: 503, body: nil, outcome: .httpError, durationMs: 88)
        let s = try #require(errorSample(d, failure: .serverProblem))
        #expect(s.code == .http(503))
        #expect(s.reason == "serverProblem")
        #expect(s.retryAfter == nil)
    }

    @Test func authErrorIsAuth() throws {
        let d = FetchDiagnostics(attemptAt: now, httpStatus: 401, body: nil, outcome: .httpError)
        let s = try #require(errorSample(d, failure: .authHTTP(status: 401, body: nil)))
        #expect(s.code == .http(401))
        #expect(s.reason == "auth")
    }

    @Test func decodeFailureIsDecode() throws {
        let d = FetchDiagnostics(attemptAt: now, httpStatus: 200, body: nil, outcome: .decodeFailure, durationMs: 95)
        let s = try #require(errorSample(d, failure: .serverProblem))
        #expect(s.code == .category("decode"))
        #expect(s.reason == "decode")
    }

    @Test func timeoutIsTimeout() throws {
        let d = FetchDiagnostics(attemptAt: now, httpStatus: nil, body: nil,
                                 outcome: .transportError(message: "timed out"), durationMs: 30000)
        let s = try #require(errorSample(d, failure: .timeout))
        #expect(s.code == .category("timeout"))
        #expect(s.reason == "timeout")
        #expect(s.ms == 30000)
    }

    @Test func dnsIsDns() throws {
        let d = FetchDiagnostics(attemptAt: now, httpStatus: nil, body: nil,
                                 outcome: .transportError(message: "cannot find host"))
        let s = try #require(errorSample(d, failure: .cannotResolveHost))
        #expect(s.code == .category("dns"))
        #expect(s.reason == "dns")
    }

    @Test func notSentHasNilLatency() throws {
        let d = FetchDiagnostics(attemptAt: now, httpStatus: nil, body: nil,
                                 outcome: .notSent(reason: "missing User-Agent"))
        let s = try #require(errorSample(d, failure: .unknown))
        #expect(s.code == .category("notSent"))
        #expect(s.ms == nil)
    }
}
