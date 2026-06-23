import Testing
import Foundation
@testable import CCTimerKit

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

    @Test func nullWindowWithoutMatchingLimitUsesLocalEstimate() throws {
        // No usable limits[] entry → fall back to ResetClock.nextReset (now + 5h, ceil to 10 min).
        let snapshot = try UsageClient.decode(
            from: usageJSON(fiveHour: "null", limits: "[]"), now: now)
        #expect(snapshot.fiveHour.utilization == 0)
        let expected = ResetClock.nextReset(now: now, window: .fiveHour)
        #expect(ResetClock.parse(snapshot.fiveHour.resetsAt) == expected)
    }

    @Test func missingFiveHourSynthesizes() throws {
        // Key omitted entirely (not just null) → still synthesized, snapshot does not fail.
        let snapshot = try UsageClient.decode(from: usageJSON(fiveHour: nil), now: now)
        #expect(snapshot.fiveHour.utilization == 0)
        #expect(!snapshot.fiveHour.resetsAt.isEmpty)
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
        #expect(headers["User-Agent"] == "claude-code/\(CCTimerKit.version)")
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
        #expect(ua?.contains(CCTimerKit.version) == true)
        #expect(ua == "claude-code/\(CCTimerKit.version)")
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

// MARK: - PollingBackoff

@Suite("PollingBackoff")
struct PollingBackoffTests {

    @Test func initialIsHealthy180() {
        let b = PollingBackoff()
        #expect(b.level == nil)
        #expect(b.interval == 180)
    }

    @Test func firstEscalationIsThreeMin() {
        let b = PollingBackoff().escalated()
        #expect(b.level == 0)
        #expect(b.interval == 180)  // step 0 == 3 min == 180 s
    }

    @Test func escalationClimbs() {
        var b = PollingBackoff()
        let expected: [TimeInterval] = [180, 360, 720, 900]
        for want in expected {
            b = b.escalated()
            #expect(b.interval == want)
        }
        #expect(b.level == 3)
    }

    @Test func holdsAtFifteenMin() {
        var b = PollingBackoff()
        for _ in 0..<6 { b = b.escalated() }
        #expect(b.interval == 900)
        #expect(b.level == PollingBackoff.steps.count - 1)
    }

    @Test func resetReturnsToDefault() {
        var b = PollingBackoff()
        for _ in 0..<4 { b = b.escalated() }
        b = b.reset()
        #expect(b.level == nil)
        #expect(b.interval == 180)
    }

    @Test func escalateThenResetThenEscalate() {
        var b = PollingBackoff()
        for _ in 0..<3 { b = b.escalated() }   // climb
        b = b.reset()                          // 200 → healthy
        #expect(b.interval == 180)
        b = b.escalated()                      // single 429 → back to step 0
        #expect(b.level == 0)
        #expect(b.interval == 180)
    }

    @Test func stepsAreInSeconds() {
        // Guards the minutes-vs-seconds trap: 3,6,12,15 min must be stored as seconds.
        #expect(PollingBackoff.steps == [180, 360, 720, 900])
    }

    struct ProgressionCase {
        let escalations: Int
        let expected: TimeInterval
    }

    @Test(arguments: [
        ProgressionCase(escalations: 0, expected: 180),  // healthy default
        ProgressionCase(escalations: 1, expected: 180),  // step 0 (3 min)
        ProgressionCase(escalations: 2, expected: 360),
        ProgressionCase(escalations: 3, expected: 720),
        ProgressionCase(escalations: 4, expected: 900),
        ProgressionCase(escalations: 5, expected: 900),  // ceiling hold
        ProgressionCase(escalations: 6, expected: 900),
    ])
    func progression(_ c: ProgressionCase) {
        var b = PollingBackoff()
        for _ in 0..<c.escalations { b = b.escalated() }
        #expect(b.interval == c.expected,
            "after \(c.escalations) escalations expected \(c.expected), got \(b.interval)")
    }

    @Test func retryAfterLongerThanStepIsHonored() {
        // At level 0 the scheduled interval is 180 s; a 1200 s hint should win.
        let b = PollingBackoff().escalated(retryAfter: 1200)
        #expect(b.interval == 900)  // clamps to the ceiling (no step >= 1200)
    }

    @Test func retryAfterMatchingStepJumpsToit() {
        // A 700 s hint at level 0 should jump to the 720 s step.
        let b = PollingBackoff().escalated(retryAfter: 700)
        #expect(b.interval == 720)
    }

    @Test func retryAfterShorterIsIgnored() {
        // A hint shorter than the scheduled step falls back to the step.
        let b = PollingBackoff().escalated(retryAfter: 10)
        #expect(b.interval == 180)
        #expect(b.level == 0)
    }
}
