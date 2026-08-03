import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Codable round-trip

@Suite("JournalRecord Codable round-trip")
struct JournalRecordCodableTests {

    private func roundTrip(_ record: JournalRecord) throws -> JournalRecord {
        let data = try JSONEncoder().encode(record)
        return try JSONDecoder().decode(JournalRecord.self, from: data)
    }

    @Test func usageRoundTrips() throws {
        let sample = UsageSample(
            t: "2026-08-03T09:12:04Z", ms: 142,
            h5: WindowSample(util: 41.2, reset: "2026-08-03T11:00:00Z", timePct: 0.62, gap: 20.8, sev: .green),
            d7: WindowSample(util: 63.8, reset: "2026-08-07T00:00:00Z", timePct: 0.55, gap: -8.8, sev: .orange),
            opus: WindowSample(util: 12, reset: "2026-08-07T00:00:00Z", timePct: 0.55, gap: 43, sev: .green),
            sonnet: nil,
            scoped: [ScopedSample(name: "Fable", pct: 8, reset: "2026-08-07T00:00:00Z", timePct: 0.55, gap: 47, sev: .green)],
            sessionIdle: false,
            spend: SpendSample(
                used: MoneySample(minor: 1077, cur: "EUR", exp: 2),
                limit: MoneySample(minor: 5000, cur: "EUR", exp: 2),
                enabled: true, spendLimitReached: false, usedCredits: 1077,
                currency: "EUR", decimalPlaces: 2, spentFrac: 0.2154, monthPct: 0.1),
            blocked: false,
            credits: CreditsFlags(active: true, showIcon: false, onCredits: false),
            brokenReset: false,
            blockingReset: nil)
        #expect(try roundTrip(.usage(sample)) == .usage(sample))
    }

    @Test func statusRoundTrips() throws {
        let sample = StatusSample(
            t: "2026-08-03T09:12:10Z",
            svc: [.init(n: "Claude Code", s: "operational"),
                  .init(n: "Claude API (api.anthropic.com)", s: "degraded_performance")],
            worst: "degraded_performance")
        #expect(try roundTrip(.status(sample)) == .status(sample))
    }

    @Test func errorRoundTripsHTTPAndCategory() throws {
        let http = ErrorSample(t: "t", code: .http(429), reason: "clientProblem", retryAfter: 60, ms: 142)
        #expect(try roundTrip(.error(http)) == .error(http))
        let cat = ErrorSample(t: "t", code: .category("timeout"), reason: "timeout", retryAfter: nil, ms: 30000)
        #expect(try roundTrip(.error(cat)) == .error(cat))
    }

    @Test func resumeRoundTrips() throws {
        let marker = ResumeMarker(t: "2026-08-03T13:40:00Z", gap: 15840)
        #expect(try roundTrip(.resume(marker)) == .resume(marker))
    }

    @Test func errorCodeEncodesAsBareValue() throws {
        // `code` must serialise as a bare JSON number / string, not a wrapper object.
        let httpData = try JSONEncoder().encode(ErrorCode.http(503))
        #expect(String(data: httpData, encoding: .utf8) == "503")
        let catData = try JSONEncoder().encode(ErrorCode.category("decode"))
        #expect(String(data: catData, encoding: .utf8) == #""decode""#)
    }
}

// MARK: - Tolerant decode

@Suite("JournalRecord tolerant decode")
struct JournalRecordTolerantTests {

    @Test func unknownKindDecodesToUnknown() throws {
        let json = #"{"kind":"future_shape","x":1}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(JournalRecord.self, from: json) == .unknown)
    }

    @Test func missingKindDecodesToUnknown() throws {
        let json = #"{"t":"2026-08-03T09:12:04Z"}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(JournalRecord.self, from: json) == .unknown)
    }

    @Test func usageMissingOptionalsDecodes() throws {
        // No opus/sonnet/spend/scoped — the optionals default rather than failing.
        let json = #"""
        {"kind":"usage","t":"2026-08-03T09:12:04Z",
         "h5":{"util":41.2,"reset":"r","timePct":0.62,"sev":"green"},
         "d7":{"util":10,"reset":"r","timePct":0.5,"sev":"green"},
         "sessionIdle":false,"credits":{"active":false,"showIcon":false,"onCredits":false}}
        """#.data(using: .utf8)!
        guard case let .usage(sample) = try JSONDecoder().decode(JournalRecord.self, from: json) else {
            Issue.record("expected .usage"); return
        }
        #expect(sample.opus == nil)
        #expect(sample.sonnet == nil)
        #expect(sample.spend == nil)
        #expect(sample.scoped.isEmpty)
        #expect(sample.ms == nil)
    }

    @Test func errorMissingRetryAfterDecodes() throws {
        let json = #"{"kind":"error","t":"t","code":503,"reason":"serverProblem","ms":88}"#.data(using: .utf8)!
        guard case let .error(sample) = try JSONDecoder().decode(JournalRecord.self, from: json) else {
            Issue.record("expected .error"); return
        }
        #expect(sample.code == .http(503))
        #expect(sample.retryAfter == nil)
        #expect(sample.ms == 88)
    }

    @Test func extraUnknownKeysIgnored() throws {
        let json = #"{"kind":"resume","t":"t","gap":900,"futureKey":42}"#.data(using: .utf8)!
        guard case let .resume(marker) = try JSONDecoder().decode(JournalRecord.self, from: json) else {
            Issue.record("expected .resume"); return
        }
        #expect(marker.gap == 900)
    }
}
