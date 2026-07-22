import Foundation

// MARK: - TroubleshootLayout

/// The **pure** view-model for the Troubleshoot window (ADR-0020): the exact lines and body text to
/// render, derived from a ``PollOutput``. No AppKit — the same pure-core / thin-shell split as
/// `PopupLayout`/`MenuBarLayout` (ADR-0009), so every string is unit-tested and the
/// `TroubleshootWindowController` only maps fields onto views.
///
/// Two sections:
/// 1. **Usage API — last response**: `timestampLine` (when the last response arrived, with its
///    time zone), an optional `statusLine` (HTTP status or a transport/not-sent explanation), an
///    optional `nextUpdateLine` (`≈ attemptAt + interval`), and `bodyText` — the pretty-printed
///    JSON on success, or the raw error payload otherwise.
/// 2. **Auth token**: `tokenReadLine` (when the token was read, or why it is unavailable) and an
///    optional `tokenExpiryLine` (when it expires).
public struct TroubleshootLayout: Sendable, Equatable {
    public let timestampLine: String
    public let statusLine: String?
    public let nextUpdateLine: String?
    public let bodyText: String
    public let tokenReadLine: String
    public let tokenExpiryLine: String?

    public init(
        timestampLine: String,
        statusLine: String?,
        nextUpdateLine: String?,
        bodyText: String,
        tokenReadLine: String,
        tokenExpiryLine: String?
    ) {
        self.timestampLine = timestampLine
        self.statusLine = statusLine
        self.nextUpdateLine = nextUpdateLine
        self.bodyText = bodyText
        self.tokenReadLine = tokenReadLine
        self.tokenExpiryLine = tokenExpiryLine
    }

    // MARK: Placeholders

    /// Shown before the first poll lands — no attempt has been made yet.
    static let noResponseYet = "No response yet…"
    static let bodyPlaceholder = "(no response yet)"
    static let noResponseBody = "(no response body)"

    // MARK: make

    /// Build the layout for a poll result (or `nil` before the first poll), formatting every date in
    /// `timeZone` (defaults to `.current`). Exhaustive over the diagnostics' shape — a `switch` with
    /// no `default`, so a new ``FetchDiagnostics/Outcome`` case must be handled consciously.
    public static func make(from output: PollOutput?, timeZone: TimeZone = .current) -> TroubleshootLayout {
        guard let output, let diagnostics = output.diagnostics else {
            return TroubleshootLayout(
                timestampLine: noResponseYet,
                statusLine: nil,
                nextUpdateLine: nil,
                bodyText: bodyPlaceholder,
                tokenReadLine: "Token: unavailable (no poll yet)",
                tokenExpiryLine: nil)
        }

        let fetch = diagnostics.fetch
        let ts = timestampText(fetch.attemptAt, timeZone: timeZone)

        let statusLine: String?
        let bodyText: String
        switch fetch.outcome {
        case .success:
            statusLine = "HTTP 200"
            bodyText = prettyPrinted(fetch.body ?? "")
        case .httpError:
            let status = fetch.httpStatus.map(String.init) ?? "?"
            statusLine = "HTTP \(status)"
            // The error payload may be JSON (pretty-print it) or HTML/plain text (passed through).
            bodyText = fetch.body.map(prettyPrinted) ?? noResponseBody
        case .decodeFailure:
            statusLine = "HTTP 200 — body failed to decode"
            bodyText = fetch.body ?? noResponseBody
        case let .transportError(message):
            statusLine = "Transport error: \(message)"
            bodyText = noResponseBody
        case .nonHTTPResponse:
            statusLine = "Non-HTTP response"
            bodyText = noResponseBody
        case let .notSent(reason):
            statusLine = "Request not sent: \(reason)"
            bodyText = noResponseBody
        }

        // The next scheduled poll — approximate (wake / network restoration can trigger it earlier).
        let nextUpdate = fetch.attemptAt.addingTimeInterval(output.interval)
        let nextUpdateLine = "Next update: ≈ \(timestampText(nextUpdate, timeZone: timeZone))"

        let tokenReadLine: String
        let tokenExpiryLine: String?
        if let token = diagnostics.token {
            tokenReadLine = "Token read: \(timestampText(token.readAt, timeZone: timeZone))"
            tokenExpiryLine = "Token expires: \(timestampText(token.expiresAt, timeZone: timeZone))"
        } else {
            // No token → explain with the same reason the fetch carried (it was `.notSent`).
            let reason = Self.tokenUnavailableReason(fetch.outcome)
            tokenReadLine = "Token unavailable: \(reason)"
            tokenExpiryLine = nil
        }

        return TroubleshootLayout(
            timestampLine: "Last response: \(ts)",
            statusLine: statusLine,
            nextUpdateLine: nextUpdateLine,
            bodyText: bodyText,
            tokenReadLine: tokenReadLine,
            tokenExpiryLine: tokenExpiryLine)
    }

    /// The explanation for a missing token — the `.notSent` reason when present, else a generic note.
    private static func tokenUnavailableReason(_ outcome: FetchDiagnostics.Outcome) -> String {
        if case let .notSent(reason) = outcome { return reason }
        return "credentials could not be read"
    }

    // MARK: Formatting helpers

    /// Pretty-print a JSON string with sorted keys and indentation, for stable, diff-friendly output.
    /// Any failure (the payload is HTML / plain text / already not JSON) returns the input unchanged —
    /// error bodies are frequently non-JSON. `sortedKeys` makes the output deterministic for tests;
    /// `withoutEscapingSlashes` keeps URLs/timestamps readable. First use of `JSONSerialization` in
    /// the codebase (the app's own decode path uses `Codable`).
    public static func prettyPrinted(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let result = String(data: pretty, encoding: .utf8)
        else { return text }
        return result
    }

    /// A fixed, unambiguous timestamp for bug reports: `2026-07-22 14:32:05 (Europe/Kyiv)` —
    /// `yyyy-MM-dd HH:mm:ss` in `en_US_POSIX`, in `timeZone` (default `.current`), with the zone
    /// identifier in parentheses. A deliberate departure from the localized `ResetClock` format
    /// (ADR-0020): diagnostics must be exact and machine-comparable, not locale-shaped.
    public static func timestampText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "\(formatter.string(from: date)) (\(timeZone.identifier))"
    }
}
