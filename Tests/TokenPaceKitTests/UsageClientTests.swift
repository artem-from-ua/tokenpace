import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Shared fixtures

/// A fixed "current time" so request construction is deterministic.
private let now = Date(timeIntervalSince1970: 1_000_000)

/// Build a usage-response JSON body from string fragments, omitting any `nil` field —
/// mirrors `TokenProviderTests.payload(...)`. A non-nil window/limits fragment is spliced
/// in verbatim, so a test can pass malformed JSON for a single field.
private func usageJSON(
    fiveHour: String? = #"{"utilization":13.0,"resets_at":"2026-06-21T05:30:00.619428+00:00"}"#,
    sevenDay: String? = #"{"utilization":40.0,"resets_at":"2026-06-28T00:00:00.000000+00:00"}"#,
    sevenDayOpus: String? = nil,
    sevenDaySonnet: String? = nil,
    limits: String? = "[]",
    extras: String = ""
) -> Data {
    var fields: [String] = []
    if let fiveHour { fields.append("\"five_hour\":\(fiveHour)") }
    if let sevenDay { fields.append("\"seven_day\":\(sevenDay)") }
    if let sevenDayOpus { fields.append("\"seven_day_opus\":\(sevenDayOpus)") }
    if let sevenDaySonnet { fields.append("\"seven_day_sonnet\":\(sevenDaySonnet)") }
    if let limits { fields.append("\"limits\":\(limits)") }
    let body = fields.joined(separator: ",") + extras
    return "{\(body)}".data(using: .utf8)!
}

/// Stub transport returning a canned result — no live network.
private struct StubTransport: UsageTransport {
    let result: Result<(Data, URLResponse), Error>

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try result.get()
    }

    /// An HTTP response with the given status, body, and headers.
    static func http(
        _ status: Int,
        body: Data = Data(),
        headers: [String: String] = [:]
    ) -> StubTransport {
        let response = HTTPURLResponse(
            url: UsageClient.endpoint,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        return StubTransport(result: .success((body, response)))
    }

    /// A transport that throws `error` (connection failure, cancellation, …).
    static func failing(_ error: Error) -> StubTransport {
        StubTransport(result: .failure(error))
    }

    /// A non-HTTP `URLResponse`, to exercise the `nonHTTPResponse` branch.
    static func nonHTTP() -> StubTransport {
        let response = URLResponse(
            url: UsageClient.endpoint,
            mimeType: "application/json",
            expectedContentLength: 0,
            textEncodingName: nil
        )
        return StubTransport(result: .success((Data(), response)))
    }
}

// MARK: - decode

@Suite("UsageClient.decode")
struct UsageDecodeTests {

    @Test func validPayloadDecodesCoreWindows() throws {
        let snapshot = try UsageClient.decode(from: usageJSON())
        #expect(snapshot.fiveHour.utilization == 13.0)
        // `resets_at` is preserved verbatim as a raw string — NOT parsed into a Date here.
        #expect(snapshot.fiveHour.resetsAt == "2026-06-21T05:30:00.619428+00:00")
        #expect(snapshot.sevenDay.utilization == 40.0)
        #expect(snapshot.sevenDay.resetsAt == "2026-06-28T00:00:00.000000+00:00")
    }

    @Test func nullModelFieldsDecodeToNil() throws {
        let snapshot = try UsageClient.decode(from: usageJSON(
            sevenDayOpus: "null", sevenDaySonnet: "null"))
        #expect(snapshot.sevenDayOpus == nil)
        #expect(snapshot.sevenDaySonnet == nil)
    }

    @Test func absentModelFieldsDecodeToNil() throws {
        // Default fixture omits both model keys entirely.
        let snapshot = try UsageClient.decode(from: usageJSON())
        #expect(snapshot.sevenDayOpus == nil)
        #expect(snapshot.sevenDaySonnet == nil)
    }

    @Test func presentModelFieldsDecode() throws {
        let snapshot = try UsageClient.decode(from: usageJSON(
            sevenDayOpus: #"{"utilization":5.0,"resets_at":"2026-06-28T00:00:00+00:00"}"#,
            sevenDaySonnet: #"{"utilization":7.5,"resets_at":"2026-06-28T00:00:00+00:00"}"#))
        #expect(snapshot.sevenDayOpus?.utilization == 5.0)
        #expect(snapshot.sevenDaySonnet?.utilization == 7.5)
    }

    // A present sub-window with `resets_at: null` (the live reset-boundary case) must NOT render a
    // bogus "resetting…" — it borrows the 7-day reset (they reset together) and keeps its util.
    @Test func sonnetPresentButNullResetBorrowsSevenDayReset() throws {
        let snapshot = try UsageClient.decode(from: usageJSON(
            sevenDaySonnet: #"{"utilization":0.0,"resets_at":null}"#))
        #expect(snapshot.sevenDaySonnet != nil)            // present, not nil-ed out
        #expect(snapshot.sevenDaySonnet?.utilization == 0.0)
        // resets_at filled from seven_day (default fixture value).
        #expect(snapshot.sevenDaySonnet?.resetsAt == snapshot.sevenDay.resetsAt)
        #expect(ResetClock.parse(snapshot.sevenDaySonnet!.resetsAt) != nil)  // parseable now
    }

    @Test func opusPresentButNullResetBorrowsSevenDayReset() throws {
        let snapshot = try UsageClient.decode(from: usageJSON(
            sevenDayOpus: #"{"utilization":3.0,"resets_at":null}"#))
        #expect(snapshot.sevenDayOpus?.utilization == 3.0)
        #expect(snapshot.sevenDayOpus?.resetsAt == snapshot.sevenDay.resetsAt)
    }

    @Test func sonnetNonzeroUtilNullResetKeepsUtil() throws {
        // util preserved (not zeroed) when only resets_at was null.
        let snapshot = try UsageClient.decode(from: usageJSON(
            sevenDaySonnet: #"{"utilization":42.0,"resets_at":null}"#))
        #expect(snapshot.sevenDaySonnet?.utilization == 42.0)
        #expect(!snapshot.sevenDaySonnet!.resetsAt.isEmpty)
    }

    @Test func limitsArrayDecodes() throws {
        let limits = """
        [{"kind":"five_hour","group":"default","percent":13.0,"severity":"normal",\
        "resets_at":"2026-06-21T05:30:00+00:00","is_active":true}]
        """
        let snapshot = try UsageClient.decode(from: usageJSON(limits: limits))
        #expect(snapshot.limits.count == 1)
        let limit = snapshot.limits[0]
        #expect(limit.kind == "five_hour")
        #expect(limit.group == "default")
        #expect(limit.percent == 13.0)
        #expect(limit.severity == "normal")
        #expect(limit.resetsAt == "2026-06-21T05:30:00+00:00")
        #expect(limit.isActive == true)
    }

    @Test func emptyLimitsDecodes() throws {
        let snapshot = try UsageClient.decode(from: usageJSON(limits: "[]"))
        #expect(snapshot.limits.isEmpty)
    }

    @Test func absentLimitsDecodesToEmpty() throws {
        // `limits` omitted entirely — hardened `init(from:)` defaults it to [].
        let snapshot = try UsageClient.decode(from: usageJSON(limits: nil))
        #expect(snapshot.limits.isEmpty)
    }

    @Test func unknownFieldsTolerated() throws {
        let extras = #","extra_usage":{"is_enabled":false},"spend":{"amount":0}"#
        let snapshot = try UsageClient.decode(from: usageJSON(extras: extras))
        #expect(snapshot.fiveHour.utilization == 13.0)
    }

    // MARK: reset-boundary synthesis
    //
    // On a window reset the API may send a core window as `null`, missing, or with
    // `utilization: null`. The decoder must synthesize a fresh zero-usage window instead of
    // failing the whole snapshot (which surfaced as a false "Usage API unavailable").

    @Test func utilizationNullSynthesizesZeroKeepingResetsAt() throws {
        // `utilization: null` but `resets_at` present → util defaults to 0, resets_at kept verbatim.
        let snapshot = try UsageClient.decode(
            from: usageJSON(fiveHour: #"{"utilization":null,"resets_at":"2026-06-23T05:40:00+00:00"}"#),
            now: now)
        #expect(snapshot.fiveHour.utilization == 0)
        #expect(snapshot.fiveHour.resetsAt == "2026-06-23T05:40:00+00:00")
        #expect(!snapshot.sessionIdle)   // present resets_at → active window, not idle
    }

    @Test func nullFiveHourPullsResetsAtFromSessionLimit() throws {
        // Whole window null → resets_at from the matching limits[] entry (live API kind="session").
        let limits = """
        [{"kind":"session","group":"session","percent":0,"severity":"normal",\
        "resets_at":"2026-06-23T05:40:00+00:00","is_active":false}]
        """
        let snapshot = try UsageClient.decode(
            from: usageJSON(fiveHour: "null", limits: limits), now: now)
        #expect(snapshot.fiveHour.utilization == 0)
        #expect(snapshot.fiveHour.resetsAt == "2026-06-23T05:40:00+00:00")
        #expect(!snapshot.sessionIdle)   // a limits[] backfill is a boundary blip, NOT idle
    }

    @Test func nullFiveHourPullsResetsAtFromFiveHourLimit() throws {
        // Older/fixture kind="five_hour" must also map to the five-hour window.
        let limits = """
        [{"kind":"five_hour","group":"default","percent":0,"severity":"normal",\
        "resets_at":"2026-06-23T05:40:00+00:00","is_active":true}]
        """
        let snapshot = try UsageClient.decode(
            from: usageJSON(fiveHour: "null", limits: limits), now: now)
        #expect(snapshot.fiveHour.resetsAt == "2026-06-23T05:40:00+00:00")
        #expect(!snapshot.sessionIdle)
    }

    @Test func nullSevenDayPullsResetsAtFromWeeklyAllLimit() throws {
        let limits = """
        [{"kind":"weekly_all","group":"weekly","percent":36,"severity":"normal",\
        "resets_at":"2026-06-23T06:59:59+00:00","is_active":true}]
        """
        let snapshot = try UsageClient.decode(
            from: usageJSON(sevenDay: "null", limits: limits), now: now)
        #expect(snapshot.sevenDay.utilization == 0)
        #expect(snapshot.sevenDay.resetsAt == "2026-06-23T06:59:59+00:00")
    }

    @Test func nullFiveHourWithoutMatchingLimitIsSessionIdle() throws {
        // No usable limits[] entry for five_hour → the honest idle state (#100): NO local estimate, NO
        // phantom reset. `sessionIdle == true`, `resetsAt` is empty, utilisation 0.
        let snapshot = try UsageClient.decode(
            from: usageJSON(fiveHour: "null", limits: "[]"), now: now)
        #expect(snapshot.sessionIdle)
        #expect(snapshot.fiveHour.utilization == 0)
        #expect(snapshot.fiveHour.resetsAt.isEmpty)
    }

    @Test func missingFiveHourWithoutLimitIsSessionIdle() throws {
        // Key omitted entirely (not just null) and no session limit → idle, not synthesized.
        let snapshot = try UsageClient.decode(from: usageJSON(fiveHour: nil), now: now)
        #expect(snapshot.sessionIdle)
        #expect(snapshot.fiveHour.resetsAt.isEmpty)
    }

    @Test func sevenDayNullWithoutLimitStillUsesLocalEstimate() throws {
        // The weekly window always exists, so its degenerate case keeps the local estimate — and is
        // never `sessionIdle` (that flag is five_hour-only).
        let snapshot = try UsageClient.decode(
            from: usageJSON(sevenDay: "null", limits: "[]"), now: now)
        #expect(!snapshot.sessionIdle)
        #expect(snapshot.sevenDay.utilization == 0)
        let expected = ResetClock.nextReset(now: now, window: .sevenDay)
        #expect(ResetClock.parse(snapshot.sevenDay.resetsAt) == expected)
    }

    @Test func idleLiveBodyDetectsSessionIdle() throws {
        // Body A (verbatim live shape): five_hour resets_at null, NO session entry in limits[] — the
        // real "no active session" body. Decodes idle; seven_day + Fable preserved.
        let body = #"""
        {"five_hour":{"utilization":0.0,"resets_at":null,"limit_dollars":null,"used_dollars":null,"remaining_dollars":null},"seven_day":{"utilization":31.0,"resets_at":"2026-07-28T07:00:00.405400+00:00","limit_dollars":null,"used_dollars":null,"remaining_dollars":null},"seven_day_oauth_apps":null,"seven_day_opus":null,"seven_day_sonnet":null,"tangelo":null,"extra_usage":{"is_enabled":false},"limits":[{"kind":"weekly_all","group":"weekly","percent":31,"severity":"normal","resets_at":"2026-07-28T07:00:00.405400+00:00","scope":null,"is_active":true},{"kind":"weekly_scoped","group":"weekly","percent":15,"severity":"normal","resets_at":"2026-07-28T07:00:00.405400+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}]}
        """#
        let snapshot = try UsageClient.decode(from: Data(body.utf8), now: now)
        #expect(snapshot.sessionIdle)
        #expect(snapshot.fiveHour.utilization == 0)
        #expect(snapshot.fiveHour.resetsAt.isEmpty)
        #expect(snapshot.sevenDay.utilization == 31.0)
        #expect(snapshot.sevenDay.resetsAt == "2026-07-28T07:00:00.405400+00:00")
        #expect(snapshot.scopedModelWindows.map(\.name) == ["Fable"])
        #expect(snapshot.scopedModelWindows.first?.window.utilization == 15)
    }

    @Test func activeBodyWithInactiveSessionFlagIsNotIdle() throws {
        // Body B: an active 2 % 5h window whose `session` limit carries `is_active:false`. The window
        // has a real resets_at, so it is NOT idle — `is_active` must be ignored (proven unreliable).
        let body = #"""
        {"five_hour":{"utilization":2.0,"resets_at":"2026-07-24T18:39:00.000000+00:00","limit_dollars":null},"seven_day":{"utilization":31.0,"resets_at":"2026-07-28T07:00:00.000000+00:00"},"seven_day_opus":null,"seven_day_sonnet":null,"limits":[{"kind":"session","group":"session","percent":2,"severity":"normal","resets_at":"2026-07-24T18:39:00.000000+00:00","scope":null,"is_active":false},{"kind":"weekly_all","group":"weekly","percent":31,"severity":"normal","resets_at":"2026-07-28T07:00:00.000000+00:00","scope":null,"is_active":true}]}
        """#
        let snapshot = try UsageClient.decode(from: Data(body.utf8), now: now)
        #expect(!snapshot.sessionIdle)
        #expect(snapshot.fiveHour.utilization == 2.0)
        #expect(snapshot.fiveHour.resetsAt == "2026-07-24T18:39:00.000000+00:00")
    }

    @Test func memberwiseDefaultIsNotIdle() {
        // The memberwise init defaults sessionIdle to false so every fixture stays non-idle by default.
        let snapshot = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 10, resetsAt: "2026-06-21T05:30:00+00:00"),
            sevenDay: UsageWindow(utilization: 20, resetsAt: "2026-06-28T00:00:00+00:00"))
        #expect(!snapshot.sessionIdle)
    }

    @Test func limitEntryWithNullFieldsDoesNotFailSnapshot() throws {
        // A limits[] entry missing severity / with null percent must not crash the whole decode.
        let limits = """
        [{"kind":"weekly_all","group":"weekly","percent":null,\
        "resets_at":"2026-06-23T06:59:59+00:00","is_active":true}]
        """
        let snapshot = try UsageClient.decode(from: usageJSON(limits: limits), now: now)
        #expect(snapshot.limits.count == 1)
        #expect(snapshot.limits[0].percent == 0)        // null → 0
        #expect(snapshot.limits[0].severity == "normal") // absent → default
    }

    // MARK: weekly_scoped / scope
    //
    // Per-model weekly limits (e.g. Fable) exist ONLY as `weekly_scoped` entries of `limits[]`
    // identified by `scope.model.display_name` — there is no top-level `seven_day_fable` (#65).
    // `UsageSnapshot.scopedModelWindows` extracts them, deduped against the legacy sub-windows.

    /// The Fable `weekly_scoped` entry as captured live on 2026-07-06.
    private static let fableLimitJSON = """
    {"kind":"weekly_scoped","group":"weekly","percent":5,"severity":"normal",\
    "resets_at":"2026-07-07T07:00:00.013978+00:00",\
    "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}
    """

    @Test func weeklyScopedLimitDecodesModelDisplayName() throws {
        let snapshot = try UsageClient.decode(from: usageJSON(limits: "[\(Self.fableLimitJSON)]"))
        #expect(snapshot.limits.count == 1)
        #expect(snapshot.limits[0].kind == "weekly_scoped")
        #expect(snapshot.limits[0].percent == 5)
        #expect(snapshot.limits[0].modelDisplayName == "Fable")
    }

    @Test func scopeNullDecodesToNilDisplayName() throws {
        let limits = """
        [{"kind":"weekly_all","group":"weekly","percent":36,"severity":"normal",\
        "resets_at":"2026-06-23T06:59:59+00:00","scope":null,"is_active":true}]
        """
        let snapshot = try UsageClient.decode(from: usageJSON(limits: limits))
        #expect(snapshot.limits[0].modelDisplayName == nil)
    }

    @Test func malformedScopeDoesNotFailSnapshot() throws {
        // `scope` as a plain string and as an object with a non-object `model` — both must
        // degrade to nil (the `try?` wrap), never fail the whole snapshot.
        for scope in [#""garbage""#, #"{"model":"x"}"#] {
            let limits = """
            [{"kind":"weekly_scoped","group":"weekly","percent":5,"severity":"normal",\
            "resets_at":"2026-07-07T07:00:00+00:00","scope":\(scope),"is_active":false}]
            """
            let snapshot = try UsageClient.decode(from: usageJSON(limits: limits))
            #expect(snapshot.limits[0].modelDisplayName == nil)
        }
    }

    @Test func scopedModelWindowExtracted() throws {
        let snapshot = try UsageClient.decode(from: usageJSON(limits: "[\(Self.fableLimitJSON)]"))
        #expect(snapshot.scopedModelWindows == [
            ScopedModelWindow(
                name: "Fable",
                window: UsageWindow(utilization: 5, resetsAt: "2026-07-07T07:00:00.013978+00:00"))
        ])
    }

    @Test func scopedWindowDedupedAgainstLegacyCaseInsensitive() throws {
        // Legacy `seven_day_sonnet` present + a scoped "SONNET" entry → the legacy field wins.
        let limits = """
        [{"kind":"weekly_scoped","group":"weekly","percent":2,"severity":"normal",\
        "resets_at":"2026-06-28T00:00:00+00:00",\
        "scope":{"model":{"id":null,"display_name":"SONNET"},"surface":null},"is_active":false}]
        """
        let snapshot = try UsageClient.decode(from: usageJSON(
            sevenDaySonnet: #"{"utilization":2.5,"resets_at":"2026-06-28T00:00:00+00:00"}"#,
            limits: limits))
        #expect(snapshot.scopedModelWindows.isEmpty)
    }

    @Test func scopedWindowRendersWhenLegacyAbsent() throws {
        // A scoped "Opus" with no top-level `seven_day_opus` is the only data source → extracted.
        let limits = """
        [{"kind":"weekly_scoped","group":"weekly","percent":8,"severity":"normal",\
        "resets_at":"2026-06-28T00:00:00+00:00",\
        "scope":{"model":{"id":null,"display_name":"Opus"},"surface":null},"is_active":false}]
        """
        let snapshot = try UsageClient.decode(from: usageJSON(limits: limits))
        #expect(snapshot.scopedModelWindows.map(\.name) == ["Opus"])
    }

    @Test func scopedWindowBorrowsSevenDayResetWhenNull() throws {
        // `resets_at: null` in the entry (tolerant decode → "") borrows the weekly reset,
        // mirroring the legacy sub-window borrow — scoped limits reset on the weekly cadence.
        let limits = """
        [{"kind":"weekly_scoped","group":"weekly","percent":5,"severity":"normal",\
        "resets_at":null,\
        "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}]
        """
        let snapshot = try UsageClient.decode(from: usageJSON(limits: limits))
        #expect(snapshot.scopedModelWindows.first?.window.resetsAt == snapshot.sevenDay.resetsAt)
    }

    @Test func nonScopedAndNamelessEntriesIgnored() throws {
        // session / weekly_all / weekly_scoped without a usable display_name → no scoped windows.
        let limits = """
        [{"kind":"session","group":"session","percent":26,"severity":"normal",\
        "resets_at":"2026-07-06T04:00:00+00:00","scope":null,"is_active":true},\
        {"kind":"weekly_all","group":"weekly","percent":3,"severity":"normal",\
        "resets_at":"2026-07-07T07:00:00+00:00","scope":null,"is_active":false},\
        {"kind":"weekly_scoped","group":"weekly","percent":5,"severity":"normal",\
        "resets_at":"2026-07-07T07:00:00+00:00","scope":{"model":{"id":null,"display_name":null},\
        "surface":null},"is_active":false}]
        """
        let snapshot = try UsageClient.decode(from: usageJSON(limits: limits))
        #expect(snapshot.scopedModelWindows.isEmpty)
    }

    @Test func duplicateScopedEntriesDedupedApiOrderKept() throws {
        let limits = """
        [{"kind":"weekly_scoped","group":"weekly","percent":5,"severity":"normal",\
        "resets_at":"2026-07-07T07:00:00+00:00",\
        "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false},\
        {"kind":"weekly_scoped","group":"weekly","percent":6,"severity":"normal",\
        "resets_at":"2026-07-07T07:00:00+00:00",\
        "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false},\
        {"kind":"weekly_scoped","group":"weekly","percent":1,"severity":"normal",\
        "resets_at":"2026-07-07T07:00:00+00:00",\
        "scope":{"model":{"id":null,"display_name":"Haiku"},"surface":null},"is_active":false}]
        """
        let snapshot = try UsageClient.decode(from: usageJSON(limits: limits))
        #expect(snapshot.scopedModelWindows.map(\.name) == ["Fable", "Haiku"])
        #expect(snapshot.scopedModelWindows[0].window.utilization == 5)   // first entry wins
    }

    @Test func garbageBytesThrowDecode() {
        let data = "not json at all".data(using: .utf8)!
        #expect(throws: UsageError.decode) { try UsageClient.decode(from: data) }
    }

    @Test func emptyDataThrowsDecode() {
        #expect(throws: UsageError.decode) { try UsageClient.decode(from: Data()) }
    }

    @Test func utilizationAsStringThrowsDecode() {
        let data = usageJSON(
            fiveHour: #"{"utilization":"13","resets_at":"2026-06-21T05:30:00+00:00"}"#)
        #expect(throws: UsageError.decode) { try UsageClient.decode(from: data) }
    }

    /// Regression: a verbatim live API body captured during a real 5-hour reset — it carries the
    /// fields that newer servers added (`scope`, `seven_day_oauth_apps`, `tangelo`, `extra_usage`,
    /// `spend`, per-window `*_dollars`) plus `scope` objects inside `limits[]`. It must decode
    /// cleanly; this is the exact shape that previously surfaced as "Usage API unavailable".
    @Test func liveBodyWithNewFieldsDecodes() throws {
        let body = #"""
        {"five_hour":{"utilization":0.0,"resets_at":"2026-06-23T05:39:59.278084+00:00","limit_dollars":null,"used_dollars":null,"remaining_dollars":null},"seven_day":{"utilization":36.0,"resets_at":"2026-06-23T06:59:59.278110+00:00","limit_dollars":null,"used_dollars":null,"remaining_dollars":null},"seven_day_oauth_apps":null,"seven_day_opus":null,"seven_day_sonnet":{"utilization":2.0,"resets_at":"2026-06-23T07:00:00.278117+00:00","limit_dollars":null,"used_dollars":null,"remaining_dollars":null},"seven_day_cowork":null,"seven_day_omelette":null,"tangelo":null,"iguana_necktie":null,"omelette_promotional":null,"cinder_cove":null,"amber_ladder":null,"extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null,"currency":null,"decimal_places":null,"disabled_reason":null,"daily":null,"weekly":null},"limits":[{"kind":"session","group":"session","percent":0,"severity":"normal","resets_at":"2026-06-23T05:39:59.278084+00:00","scope":null,"is_active":false},{"kind":"weekly_all","group":"weekly","percent":36,"severity":"normal","resets_at":"2026-06-23T06:59:59.278110+00:00","scope":null,"is_active":true},{"kind":"weekly_scoped","group":"weekly","percent":2,"severity":"normal","resets_at":"2026-06-23T07:00:00.278117+00:00","scope":{"model":{"id":null,"display_name":"Sonnet"},"surface":null},"is_active":false}],"spend":{"used":{"amount_minor":0,"currency":"USD","exponent":2},"limit":null,"percent":0,"severity":"normal","enabled":false,"disabled_reason":null}}
        """#
        let snapshot = try UsageClient.decode(from: Data(body.utf8), now: now)
        #expect(snapshot.fiveHour.utilization == 0.0)
        #expect(snapshot.fiveHour.resetsAt == "2026-06-23T05:39:59.278084+00:00")
        #expect(snapshot.sevenDay.utilization == 36.0)
        #expect(snapshot.sevenDaySonnet?.utilization == 2.0)
        #expect(snapshot.sevenDayOpus == nil)
        #expect(snapshot.limits.count == 3)
        #expect(snapshot.limits.contains { $0.kind == "weekly_scoped" })  // scope object tolerated
        // This body carries Sonnet in BOTH forms — the legacy window and a weekly_scoped entry.
        // The scoped one must decode its name yet be deduped, or the popup renders Sonnet twice.
        #expect(snapshot.limits.contains { $0.modelDisplayName == "Sonnet" })
        #expect(snapshot.scopedModelWindows.isEmpty)
        #expect(!snapshot.sessionIdle)   // an active 5h window with a real reset is never idle
    }

    /// Regression: a live API body captured 2026-07-06 — the first shape where a per-model limit
    /// (Fable) has NO top-level window and exists only as a `weekly_scoped` entry of `limits[]`
    /// (#65). The scoped window must be extracted with the entry's own `resets_at`.
    @Test func liveBodyWithFableScopedLimitDecodes() throws {
        let body = #"""
        {"five_hour":{"utilization":26.0,"resets_at":"2026-07-06T04:00:00.013695+00:00","limit_dollars":null,"used_dollars":null,"remaining_dollars":null},"seven_day":{"utilization":3.0,"resets_at":"2026-07-07T07:00:00.013718+00:00","limit_dollars":null,"used_dollars":null,"remaining_dollars":null},"seven_day_oauth_apps":null,"seven_day_opus":null,"seven_day_sonnet":null,"seven_day_cowork":null,"seven_day_omelette":null,"tangelo":null,"iguana_necktie":null,"omelette_promotional":null,"nimbus_quill":null,"cinder_cove":null,"amber_ladder":null,"extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null,"currency":null,"decimal_places":null,"disabled_reason":null,"daily":null,"weekly":null},"limits":[{"kind":"session","group":"session","percent":26,"severity":"normal","resets_at":"2026-07-06T04:00:00.013695+00:00","scope":null,"is_active":true},{"kind":"weekly_all","group":"weekly","percent":3,"severity":"normal","resets_at":"2026-07-07T07:00:00.013718+00:00","scope":null,"is_active":false},{"kind":"weekly_scoped","group":"weekly","percent":5,"severity":"normal","resets_at":"2026-07-07T07:00:00.013978+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}],"spend":{"used":{"amount_minor":0,"currency":"USD","exponent":2},"limit":null,"percent":0,"severity":"normal","enabled":false,"disabled_reason":null,"cap":null,"balance":null,"auto_reload":null,"disclaimer":"Usage credits cover you when you hit your plan limits.","can_purchase_credits":false,"can_toggle":false},"member_dashboard_available":false}
        """#
        let snapshot = try UsageClient.decode(from: Data(body.utf8), now: now)
        #expect(snapshot.limits.count == 3)
        let fable = try #require(snapshot.limits.first { $0.kind == "weekly_scoped" })
        #expect(fable.modelDisplayName == "Fable")
        #expect(fable.percent == 5)
        #expect(snapshot.scopedModelWindows == [
            ScopedModelWindow(
                name: "Fable",
                window: UsageWindow(utilization: 5, resetsAt: "2026-07-07T07:00:00.013978+00:00"))
        ])
        #expect(!snapshot.sessionIdle)   // five_hour has a real reset (26 %) → active, not idle
    }
}

// MARK: - buildRequest

@Suite("UsageClient.buildRequest")
struct BuildRequestTests {

    @Test func setsAllFourHeaders() throws {
        let request = try UsageClient.buildRequest(accessToken: "acc-123", now: now)
        let headers = request.allHTTPHeaderFields ?? [:]
        #expect(headers["Authorization"] == "Bearer acc-123")
        #expect(headers["anthropic-beta"] == "oauth-2025-04-20")
        #expect(headers["User-Agent"] == "claude-code/\(TokenPaceKit.version)")
        #expect(headers["Content-Type"] == "application/json")
    }

    @Test func methodIsGET() throws {
        let request = try UsageClient.buildRequest(accessToken: "acc", now: now)
        #expect(request.httpMethod == "GET")
    }

    @Test func urlIsEndpoint() throws {
        let request = try UsageClient.buildRequest(accessToken: "acc", now: now)
        #expect(request.url == UsageClient.endpoint)
    }

    @Test func userAgentEmbedsVersion() throws {
        let request = try UsageClient.buildRequest(accessToken: "acc", now: now)
        let ua = request.value(forHTTPHeaderField: "User-Agent")
        #expect(ua?.isEmpty == false)
        #expect(ua?.contains(TokenPaceKit.version) == true)
        #expect(ua == "claude-code/\(TokenPaceKit.version)")
    }

    @Test func tokenAppearsOnlyInAuthorizationHeader() throws {
        let token = "super-secret-token-xyz"
        let request = try UsageClient.buildRequest(accessToken: token, now: now)
        for (name, value) in request.allHTTPHeaderFields ?? [:] where name != "Authorization" {
            #expect(!value.contains(token), "token leaked into header \(name)")
        }
    }
}

// MARK: - userAgentGuard

@Suite("UsageClient.userAgentGuard")
struct UserAgentGuardTests {

    @Test func nonEmptyUserAgentBuildsRequest() throws {
        // The real, non-empty constant must not trip the guard.
        let request = try UsageClient.buildRequest(accessToken: "acc", now: now)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.isEmpty == false)
    }

    @Test func emptyUserAgentThrows() {
        #expect(throws: UsageError.missingUserAgent) {
            try UsageClient.buildRequest(accessToken: "acc", now: now, userAgent: "")
        }
    }

    @Test func bareSlashUserAgentThrows() {
        // A version that decayed to "" would yield "claude-code/" — also rejected.
        #expect(throws: UsageError.missingUserAgent) {
            try UsageClient.buildRequest(accessToken: "acc", now: now, userAgent: "claude-code/")
        }
    }
}

// MARK: - fetch

@Suite("UsageClient.fetch")
struct FetchTests {

    @Test func success200ReturnsSnapshot() async throws {
        let transport = StubTransport.http(200, body: usageJSON())
        let snapshot = try await UsageClient.fetch(accessToken: "acc", now: now, transport: transport)
        #expect(snapshot.fiveHour.utilization == 13.0)
    }

    @Test func status429ThrowsRateLimited() async {
        let transport = StubTransport.http(429)
        await #expect(throws: UsageError.rateLimited(retryAfter: nil)) {
            try await UsageClient.fetch(accessToken: "acc", now: now, transport: transport)
        }
    }

    @Test func status429WithRetryAfterParsed() async {
        let transport = StubTransport.http(429, headers: ["Retry-After": "42"])
        await #expect(throws: UsageError.rateLimited(retryAfter: 42)) {
            try await UsageClient.fetch(accessToken: "acc", now: now, transport: transport)
        }
    }

    @Test func status401ThrowsHTTP() async {
        // No body → `.http(status:body:)` with a nil body.
        let transport = StubTransport.http(401)
        await #expect(throws: UsageError.http(status: 401, body: nil)) {
            try await UsageClient.fetch(accessToken: "acc", now: now, transport: transport)
        }
    }

    @Test func status500ThrowsHTTP() async {
        let transport = StubTransport.http(500)
        await #expect(throws: UsageError.http(status: 500, body: nil)) {
            try await UsageClient.fetch(accessToken: "acc", now: now, transport: transport)
        }
    }

    @Test func httpErrorCarriesResponseBody() async {
        // The server's plain-text error message rides along in `body` for the popup detail line.
        let transport = StubTransport.http(401, body: "Invalid bearer token".data(using: .utf8)!)
        await #expect(throws: UsageError.http(status: 401, body: "Invalid bearer token")) {
            try await UsageClient.fetch(accessToken: "acc", now: now, transport: transport)
        }
    }

    @Test func httpErrorBodyIsTrimmedAndCapped() {
        // Whitespace trimmed; over-long bodies truncated to `maxBodyLength`.
        #expect(UsageClient.responseText(from: "  hi  \n".data(using: .utf8)!) == "hi")
        #expect(UsageClient.responseText(from: Data()) == nil)
        let long = String(repeating: "x", count: UsageClient.maxBodyLength + 50)
        #expect(UsageClient.responseText(from: long.data(using: .utf8)!)?.count == UsageClient.maxBodyLength)
    }

    @Test func transportErrorThrowsTransport() async {
        let transport = StubTransport.failing(URLError(.notConnectedToInternet))
        await #expect(throws: (any Error).self) {
            try await UsageClient.fetch(accessToken: "acc", now: now, transport: transport)
        }
        // Assert the specific case and that the underlying URLError.Code is carried through.
        do {
            _ = try await UsageClient.fetch(accessToken: "acc", now: now, transport: transport)
            Issue.record("expected a thrown error")
        } catch let error as UsageError {
            guard case let .transport(_, code) = error else {
                Issue.record("expected .transport, got \(error)")
                return
            }
            #expect(code == .notConnectedToInternet)
        } catch {
            Issue.record("expected UsageError.transport, got \(error)")
        }
    }

    @Test func nonHTTPResponseThrows() async {
        let transport = StubTransport.nonHTTP()
        await #expect(throws: UsageError.nonHTTPResponse) {
            try await UsageClient.fetch(accessToken: "acc", now: now, transport: transport)
        }
    }

    @Test func malformedBodyOn200ThrowsDecode() async {
        let transport = StubTransport.http(200, body: "garbage".data(using: .utf8)!)
        await #expect(throws: UsageError.decode) {
            try await UsageClient.fetch(accessToken: "acc", now: now, transport: transport)
        }
    }
}

// MARK: - diagnosedFetch (ADR-0020)

@Suite("UsageClient.diagnosedFetch")
struct DiagnosedFetchTests {

    @Test func success200CapturesStatusBodyAndTime() async {
        let body = usageJSON()
        let transport = StubTransport.http(200, body: body)
        let diagnosed = await UsageClient.diagnosedFetch(accessToken: "acc", now: now, transport: transport)
        // The snapshot decoded.
        guard case let .success(snapshot) = diagnosed.result else {
            Issue.record("expected success, got \(diagnosed.result)"); return
        }
        #expect(snapshot.fiveHour.utilization == 13.0)
        // The diagnostic: 200, the exact body, the poll instant.
        #expect(diagnosed.diagnostics.outcome == .success)
        #expect(diagnosed.diagnostics.httpStatus == 200)
        #expect(diagnosed.diagnostics.attemptAt == now)
        #expect(diagnosed.diagnostics.body == String(data: body, encoding: .utf8))
    }

    @Test func httpErrorKeepsFullBodyWhileUsageErrorCaps() async {
        // A 401 whose body exceeds the popup cap: the diagnostic body is FULL length; the mapped
        // UsageError.http body is still capped at maxBodyLength. This is the key divergence.
        let long = String(repeating: "x", count: UsageClient.maxBodyLength + 100)
        let transport = StubTransport.http(401, body: Data(long.utf8))
        let diagnosed = await UsageClient.diagnosedFetch(accessToken: "acc", now: now, transport: transport)
        #expect(diagnosed.diagnostics.outcome == .httpError)
        #expect(diagnosed.diagnostics.httpStatus == 401)
        #expect(diagnosed.diagnostics.body?.count == UsageClient.maxBodyLength + 100)  // uncapped
        guard case let .failure(.http(status, body)) = diagnosed.result else {
            Issue.record("expected .http failure, got \(diagnosed.result)"); return
        }
        #expect(status == 401)
        #expect(body?.count == UsageClient.maxBodyLength)   // capped copy for the popup
    }

    @Test func rateLimitedCapturesStatusAndBody() async {
        // 429 — previously the body was lost entirely; now it is captured for diagnostics.
        let transport = StubTransport.http(
            429, body: Data("slow down".utf8), headers: ["Retry-After": "30"])
        let diagnosed = await UsageClient.diagnosedFetch(accessToken: "acc", now: now, transport: transport)
        #expect(diagnosed.diagnostics.outcome == .httpError)
        #expect(diagnosed.diagnostics.httpStatus == 429)
        #expect(diagnosed.diagnostics.body == "slow down")
        guard case .failure(.rateLimited(retryAfter: 30)) = diagnosed.result else {
            Issue.record("expected .rateLimited(30), got \(diagnosed.result)"); return
        }
    }

    @Test func decodeFailureKeepsRawBody() async {
        // 200 with garbage → decodeFailure, and the raw body is preserved (schema-change diagnosis).
        let transport = StubTransport.http(200, body: Data("not json".utf8))
        let diagnosed = await UsageClient.diagnosedFetch(accessToken: "acc", now: now, transport: transport)
        #expect(diagnosed.diagnostics.outcome == .decodeFailure)
        #expect(diagnosed.diagnostics.httpStatus == 200)
        #expect(diagnosed.diagnostics.body == "not json")
        guard case .failure(.decode) = diagnosed.result else {
            Issue.record("expected .decode failure, got \(diagnosed.result)"); return
        }
    }

    @Test func transportErrorHasNilStatusAndBody() async {
        let transport = StubTransport.failing(URLError(.notConnectedToInternet))
        let diagnosed = await UsageClient.diagnosedFetch(accessToken: "acc", now: now, transport: transport)
        guard case .transportError = diagnosed.diagnostics.outcome else {
            Issue.record("expected .transportError, got \(diagnosed.diagnostics.outcome)"); return
        }
        #expect(diagnosed.diagnostics.httpStatus == nil)
        #expect(diagnosed.diagnostics.body == nil)
        guard case .failure(.transport) = diagnosed.result else {
            Issue.record("expected .transport failure, got \(diagnosed.result)"); return
        }
    }

    @Test func nonHTTPResponseCaptured() async {
        let transport = StubTransport.nonHTTP()
        let diagnosed = await UsageClient.diagnosedFetch(accessToken: "acc", now: now, transport: transport)
        #expect(diagnosed.diagnostics.outcome == .nonHTTPResponse)
        #expect(diagnosed.diagnostics.httpStatus == nil)
        guard case .failure(.nonHTTPResponse) = diagnosed.result else {
            Issue.record("expected .nonHTTPResponse, got \(diagnosed.result)"); return
        }
    }
}

// MARK: - PollingBackoff (honored-hold, ADR-0032)

@Suite("PollingBackoff")
struct PollingBackoffTests {

    @Test func initialIsHealthy180() {
        let b = PollingBackoff()
        #expect(b.isHolding == false)
        #expect(b.interval == 180)
    }

    @Test func honorsRetryAfterVerbatim() {
        let b = PollingBackoff().honoring(retryAfter: 450)
        #expect(b.isHolding == true)
        #expect(b.interval == 450)   // exactly the server hint, no step schedule
    }

    @Test func absentRetryAfterFallsBackToBase() {
        let b = PollingBackoff().honoring(retryAfter: nil)
        #expect(b.isHolding == true)
        #expect(b.interval == 180)   // base hold when the server gave no hint
    }

    @Test func nonPositiveRetryAfterFallsBackToBase() {
        // A zero/negative hint is meaningless as a wait — fall back to the base rather than hold at 0.
        #expect(PollingBackoff().honoring(retryAfter: 0).interval == 180)
        #expect(PollingBackoff().honoring(retryAfter: -5).interval == 180)
    }

    @Test func repeatHonoringDoesNotEscalate() {
        // The core of the new rule: a second 429 with the same hint re-sets the same hold, it never
        // climbs. A second 429 with a *longer* hint simply adopts the latest hint.
        var b = PollingBackoff().honoring(retryAfter: 200)
        b = b.honoring(retryAfter: 200)
        #expect(b.interval == 200)   // not 400, not a doubled step
        b = b.honoring(retryAfter: 500)
        #expect(b.interval == 500)   // adopts the newest hint
    }

    @Test func resetReturnsToDefault() {
        var b = PollingBackoff().honoring(retryAfter: 900)
        b = b.reset()
        #expect(b.isHolding == false)
        #expect(b.interval == 180)
    }

    @Test func honorThenResetThenHonor() {
        var b = PollingBackoff().honoring(retryAfter: 600)
        b = b.reset()                       // 200 → healthy
        #expect(b.interval == 180)
        b = b.honoring(retryAfter: 300)     // a fresh 429 → back to a hold
        #expect(b.isHolding == true)
        #expect(b.interval == 300)
    }
}
