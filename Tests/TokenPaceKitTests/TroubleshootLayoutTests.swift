import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Shared fixtures

/// A fixed instant so every timestamp assertion is deterministic:
/// 2026-07-22 12:00:00 UTC → 15:00:00 Europe/Kyiv (UTC+3 in July).
private let t0 = Date(timeIntervalSince1970: 1_784_721_600)

private let kyiv = TimeZone(identifier: "Europe/Kyiv")!
private let utc = TimeZone(identifier: "UTC")!
/// Foundation canonicalizes the "UTC" identifier to "GMT" — the format uses `timeZone.identifier`,
/// so the parenthesized zone reads "(GMT)". Built from the live value so the tests stay honest.
private let utcID = utc.identifier

/// Build a `PollOutput` around a `FetchDiagnostics` outcome + optional token dates.
private func output(
    _ outcome: FetchDiagnostics.Outcome,
    httpStatus: Int? = nil,
    body: String? = nil,
    interval: TimeInterval = 180,
    token: TokenDiagnostics? = nil,
    attemptAt: Date = t0
) -> PollOutput {
    let fetch = FetchDiagnostics(
        attemptAt: attemptAt, httpStatus: httpStatus, body: body, outcome: outcome)
    return PollOutput(
        snapshot: nil, health: UsageHealth(lastSuccess: nil, failingSince: nil, reason: nil),
        interval: interval, diagnostics: PollDiagnostics(fetch: fetch, token: token))
}

private let freshToken = TokenDiagnostics(
    readAt: t0, expiresAt: t0.addingTimeInterval(8 * 3600))

// MARK: - prettyPrinted

@Suite("TroubleshootLayout.prettyPrinted")
struct PrettyPrintedTests {

    @Test func smallJSONIsSortedAndIndented() {
        // Keys sorted (b before z alphabetically), two-space indent, no slash escaping.
        let input = #"{"z":1,"a":{"nested":true}}"#
        let expected = """
        {
          "a" : {
            "nested" : true
          },
          "z" : 1
        }
        """
        #expect(TroubleshootLayout.prettyPrinted(input) == expected)
    }

    @Test func slashesNotEscaped() {
        let input = #"{"url":"https://api.anthropic.com/x"}"#
        #expect(TroubleshootLayout.prettyPrinted(input).contains("https://api.anthropic.com/x"))
    }

    @Test func liveBodyRoundTrips() {
        // A trimmed live-shape body — must pretty-print without throwing, and stay valid JSON.
        let body = #"{"five_hour":{"utilization":13.0,"resets_at":"2026-06-21T05:30:00+00:00"},"seven_day":{"utilization":40.0,"resets_at":"2026-06-28T00:00:00+00:00"},"limits":[]}"#
        let pretty = TroubleshootLayout.prettyPrinted(body)
        #expect(pretty.contains("\"five_hour\""))
        #expect(pretty != body)   // it was reformatted
        // Round-trips back to valid JSON.
        #expect((try? JSONSerialization.jsonObject(with: Data(pretty.utf8))) != nil)
    }

    @Test func htmlPassesThroughUnchanged() {
        let html = "<html><body>502 Bad Gateway</body></html>"
        #expect(TroubleshootLayout.prettyPrinted(html) == html)
    }

    @Test func plainTextPassesThroughUnchanged() {
        let text = "Invalid bearer token"
        #expect(TroubleshootLayout.prettyPrinted(text) == text)
    }

    @Test func emptyPassesThroughUnchanged() {
        #expect(TroubleshootLayout.prettyPrinted("") == "")
    }
}

// MARK: - timestampText

@Suite("TroubleshootLayout.timestampText")
struct TimestampTextTests {

    @Test func kyivFormat() {
        // 12:00 UTC + 3h (July DST) = 15:00 Kyiv.
        #expect(TroubleshootLayout.timestampText(t0, timeZone: kyiv)
            == "2026-07-22 15:00:00 (Europe/Kyiv)")
    }

    @Test func utcFormat() {
        // Foundation canonicalizes "UTC" → "GMT"; the format echoes `timeZone.identifier`.
        #expect(TroubleshootLayout.timestampText(t0, timeZone: utc)
            == "2026-07-22 12:00:00 (\(utcID))")
    }
}

// MARK: - make

@Suite("TroubleshootLayout.make")
struct MakeTests {

    @Test func nilOutputShowsPlaceholders() {
        let layout = TroubleshootLayout.make(from: nil, timeZone: utc)
        #expect(layout.timestampLine == TroubleshootLayout.noResponseYet)
        #expect(layout.statusLine == nil)
        #expect(layout.nextUpdateLine == nil)
        #expect(layout.bodyText == TroubleshootLayout.bodyPlaceholder)
        #expect(layout.tokenExpiryLine == nil)
    }

    @Test func successPrettyPrintsBodyAndShowsStatus() {
        let body = #"{"b":2,"a":1}"#
        let layout = TroubleshootLayout.make(
            from: output(.success, httpStatus: 200, body: body, token: freshToken), timeZone: utc)
        #expect(layout.statusLine == "HTTP 200")
        #expect(layout.bodyText == "{\n  \"a\" : 1,\n  \"b\" : 2\n}")
        #expect(layout.timestampLine == "Last response: 2026-07-22 12:00:00 (\(utcID))")
    }

    @Test func nextUpdateIsAttemptPlusInterval() {
        // attemptAt 12:00 UTC + interval 180 s = 12:03:00.
        let layout = TroubleshootLayout.make(
            from: output(.success, httpStatus: 200, body: "{}", interval: 180, token: freshToken),
            timeZone: utc)
        #expect(layout.nextUpdateLine == "Next update: ≈ 2026-07-22 12:03:00 (\(utcID))")
    }

    @Test func httpErrorShowsStatusAndPayload() {
        let payload = "Invalid bearer token"
        let layout = TroubleshootLayout.make(
            from: output(.httpError, httpStatus: 401, body: payload, token: freshToken), timeZone: utc)
        #expect(layout.statusLine == "HTTP 401")
        #expect(layout.bodyText == payload)   // plain text, passed through
    }

    @Test func rateLimitedShowsStatus() {
        let layout = TroubleshootLayout.make(
            from: output(.httpError, httpStatus: 429, body: "slow down", token: freshToken),
            timeZone: utc)
        #expect(layout.statusLine == "HTTP 429")
        #expect(layout.bodyText == "slow down")
    }

    @Test func decodeFailureShowsRawBody() {
        let layout = TroubleshootLayout.make(
            from: output(.decodeFailure, httpStatus: 200, body: "not json", token: freshToken),
            timeZone: utc)
        #expect(layout.statusLine == "HTTP 200 — body failed to decode")
        #expect(layout.bodyText == "not json")
    }

    @Test func transportErrorExplainsAndHasNoBody() {
        let layout = TroubleshootLayout.make(
            from: output(.transportError(message: "offline"), token: freshToken), timeZone: utc)
        #expect(layout.statusLine == "Transport error: offline")
        #expect(layout.bodyText == TroubleshootLayout.noResponseBody)
    }

    @Test func notSentExplainsAndHasNoBody() {
        let layout = TroubleshootLayout.make(
            from: output(.notSent(reason: "token expired"), token: freshToken), timeZone: utc)
        #expect(layout.statusLine == "Request not sent: token expired")
        #expect(layout.bodyText == TroubleshootLayout.noResponseBody)
    }

    @Test func tokenPresentShowsReadAndExpiry() {
        let layout = TroubleshootLayout.make(
            from: output(.success, httpStatus: 200, body: "{}", token: freshToken), timeZone: utc)
        #expect(layout.tokenReadLine == "Token read: 2026-07-22 12:00:00 (\(utcID))")
        #expect(layout.tokenExpiryLine == "Token expires: 2026-07-22 20:00:00 (\(utcID))")
    }

    @Test func expiredTokenStillShowsDates() {
        // The key diagnostic case: an expired token's dates are still rendered.
        let expired = TokenDiagnostics(readAt: t0, expiresAt: t0.addingTimeInterval(-3600))
        let layout = TroubleshootLayout.make(
            from: output(.notSent(reason: "token expired"), token: expired), timeZone: utc)
        #expect(layout.tokenReadLine == "Token read: 2026-07-22 12:00:00 (\(utcID))")
        #expect(layout.tokenExpiryLine == "Token expires: 2026-07-22 11:00:00 (\(utcID))")
    }

    @Test func tokenNilExplainsUnavailability() {
        let layout = TroubleshootLayout.make(
            from: output(.notSent(reason: "not signed in"), token: nil), timeZone: utc)
        #expect(layout.tokenReadLine == "Token unavailable: not signed in")
        #expect(layout.tokenExpiryLine == nil)
    }
}
