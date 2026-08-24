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
///    optional `intervalLine` (the current refresh cadence as a duration, e.g. `3m`), an optional
///    `nextUpdateLine` (`≈ attemptAt + interval`), and `bodyText` — the pretty-printed JSON on
///    success, or the raw error payload otherwise.
/// 2. **Auth token**: an optional `tokenStatusLine` (why the token is unavailable — `nil` when it
///    read cleanly, so nothing is shown) and an optional `tokenExpiryLine` (when it expires). There
///    is deliberately no "token read at" line: the Keychain payload has no issued-at field and the
///    access token is opaque (not a JWT), so the only honest instant we could show is the Keychain
///    *read* time — misleading as an "obtained at", so it is not surfaced (`TokenDiagnostics.readAt`).
public struct TroubleshootLayout: Sendable, Equatable {
    public let timestampLine: String
    public let statusLine: String?
    public let intervalLine: String?
    public let nextUpdateLine: String?
    /// The weekly reconstruction (#386): the API's quantised value and the value derived from the
    /// five-hour counter, side by side with the exchange rate behind it. `nil` only when there is no
    /// snapshot to describe — **not** when the two numbers agree.
    ///
    /// Kept visible even while the reconstruction has nothing to add, because this is a diagnostic
    /// surface: an absent row reads as "nothing to report", which looks exactly like "the feature is
    /// broken". It also keeps `N` and the sample count on screen while they warm up, which is the
    /// slow part worth watching.
    ///
    /// This is the **only** surface showing both numbers at once, and the one place the estimate can
    /// be judged on live data rather than on a stub — which is why it ships a full release before
    /// anything renders from the reconstructed value.
    public let weeklyLine: String?
    /// The weekly **reset** instant and where it came from (ADR-0107) — the date to the second, plus
    /// its ``ResetSource``. `nil` only when there is no snapshot to describe.
    ///
    /// Exists for the same reason ``weeklyLine`` does, and answers the question that one cannot: the
    /// popup rounds the countdown to `6d`, which is far too coarse to tell a reconstruction from a
    /// drifting estimate — the old fallback moved in 10-minute steps and rounded to the same `6d` for
    /// hours. Only the seconds distinguish "this date is holding" from "this date is creeping", and
    /// this is the one place they are visible.
    ///
    /// Also the only surface that names the source, so a blackout can be recognised while it is
    /// happening rather than reconstructed afterwards from the journal.
    public let weeklyResetLine: String?
    public let bodyText: String
    /// Whether `bodyText` is pretty-printed JSON (so the shell should syntax-highlight it) rather
    /// than an error/plain payload or a placeholder. Decided here in the tested core — on success,
    /// and on any other outcome whose body round-tripped through `prettyPrinted` (an error payload
    /// can itself be JSON). `false` for HTML/plain error bodies and the "no response" placeholders,
    /// which the shell then renders as monolithic monospace (see `JSONHighlighter`).
    public let bodyIsJSON: Bool
    public let tokenStatusLine: String?
    public let tokenExpiryLine: String?

    public init(
        timestampLine: String,
        statusLine: String?,
        intervalLine: String?,
        nextUpdateLine: String?,
        weeklyLine: String? = nil,
        weeklyResetLine: String? = nil,
        bodyText: String,
        bodyIsJSON: Bool,
        tokenStatusLine: String?,
        tokenExpiryLine: String?
    ) {
        self.timestampLine = timestampLine
        self.statusLine = statusLine
        self.intervalLine = intervalLine
        self.nextUpdateLine = nextUpdateLine
        self.weeklyLine = weeklyLine
        self.weeklyResetLine = weeklyResetLine
        self.bodyText = bodyText
        self.bodyIsJSON = bodyIsJSON
        self.tokenStatusLine = tokenStatusLine
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
                intervalLine: nil,
                nextUpdateLine: nil,
                bodyText: bodyPlaceholder,
                bodyIsJSON: false,
                tokenStatusLine: "Token: unavailable (no poll yet)",
                tokenExpiryLine: nil)
        }

        let fetch = diagnostics.fetch
        let ts = timestampText(fetch.attemptAt, timeZone: timeZone)

        // `bodyIsJSON` gates syntax highlighting in the shell — set to `true` only where `bodyText`
        // is genuine JSON. `prettyPrinted` passes non-JSON through unchanged, so "was it reformatted"
        // is not a reliable signal; `isJSON` re-checks parseability directly.
        let statusLine: String?
        let bodyText: String
        let bodyIsJSON: Bool
        switch fetch.outcome {
        case .success:
            statusLine = "HTTP 200"
            let body = fetch.body ?? ""
            bodyText = prettyPrinted(body)
            bodyIsJSON = isJSON(body)
        case .httpError:
            let status = fetch.httpStatus.map(String.init) ?? "?"
            statusLine = "HTTP \(status)"
            // The error payload may be JSON (pretty-print it) or HTML/plain text (passed through).
            bodyText = fetch.body.map(prettyPrinted) ?? noResponseBody
            bodyIsJSON = fetch.body.map(isJSON) ?? false
        case .decodeFailure:
            statusLine = "HTTP 200 — body failed to decode"
            bodyText = fetch.body ?? noResponseBody
            // Not pretty-printed and, by definition of this outcome, did not decode — but it may
            // still be well-formed JSON that failed our schema, so highlight when it parses.
            bodyIsJSON = fetch.body.map(isJSON) ?? false
        case let .transportError(message):
            statusLine = "Transport error: \(message)"
            bodyText = noResponseBody
            bodyIsJSON = false
        case .nonHTTPResponse:
            statusLine = "Non-HTTP response"
            bodyText = noResponseBody
            bodyIsJSON = false
        case let .notSent(reason):
            statusLine = "Request not sent: \(reason)"
            bodyText = noResponseBody
            bodyIsJSON = false
        }

        // The current refresh cadence as a duration (e.g. "3m"), separate from the absolute next-update
        // timestamp below it — the interval is the *rate*, the next update is the *when*.
        let intervalLine = "Refresh interval: \(durationText(output.interval))"

        // The next scheduled poll — approximate (wake / network restoration can trigger it earlier).
        let nextUpdate = fetch.attemptAt.addingTimeInterval(output.interval)
        let nextUpdateLine = "Next update: ≈ \(timestampText(nextUpdate, timeZone: timeZone))"

        // A readable token shows only its expiry — never a "read at" line: `token.readAt` is the
        // Keychain read instant, not an issued-at, so it would misrepresent when the token was
        // obtained (see the type doc). When the token could not be read, `tokenStatusLine` carries
        // the reason instead; otherwise it is `nil` and the shell hides the row.
        let tokenStatusLine: String?
        let tokenExpiryLine: String?
        if let token = diagnostics.token {
            tokenStatusLine = nil
            tokenExpiryLine = "Token expires: \(timestampText(token.expiresAt, timeZone: timeZone))"
        } else {
            // No token → explain with the same reason the fetch carried (it was `.notSent`).
            let reason = Self.tokenUnavailableReason(fetch.outcome)
            tokenStatusLine = "Token unavailable: \(reason)"
            tokenExpiryLine = nil
        }

        return TroubleshootLayout(
            timestampLine: "Last response: \(ts)",
            statusLine: statusLine,
            intervalLine: intervalLine,
            nextUpdateLine: nextUpdateLine,
            weeklyLine: output.weekly?.troubleshootLine,
            weeklyResetLine: output.snapshot.map(Self.weeklyResetLine),
            bodyText: bodyText,
            bodyIsJSON: bodyIsJSON,
            tokenStatusLine: tokenStatusLine,
            tokenExpiryLine: tokenExpiryLine)
    }

    /// The weekly reset instant **to the second**, followed by how it was arrived at (ADR-0107).
    ///
    /// Seconds rather than the popup's rounded countdown, because that is what tells the two failure
    /// modes apart: the fallback this replaced re-estimated `now + 7d` on every poll, so the date
    /// crept forward in 10-minute steps while still rounding to the same `6d` for hours. A held date
    /// and a creeping one are indistinguishable at that resolution and obvious at this one.
    ///
    /// Rendered in UTC, matching the raw `resets_at` in the body below it — the two are meant to be
    /// compared, and a local-time rendering would make them look like different instants.
    static func weeklyResetLine(_ snapshot: UsageSnapshot) -> String {
        let mode = snapshot.sevenDayResetSource.troubleshootDescription
        guard let instant = ResetClock.parse(snapshot.sevenDay.resetsAt) else {
            // No date at all — the cold start. Naming the mode still matters: it says the app chose
            // not to invent one, rather than having failed to parse something.
            return "7d reset: none — \(mode)"
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "7d reset: \(f.string(from: instant)) UTC — \(mode)"
    }

    /// Whether `text` parses as JSON — the gate for syntax-highlighting `bodyText` in the shell.
    /// Uses the same `.fragmentsAllowed` option as `prettyPrinted`, so a bare string/number/bool
    /// body (which `prettyPrinted` also accepts) is still classed as JSON and highlighted. Empty or
    /// non-JSON (HTML, plain text) → `false`.
    static func isJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
        else { return false }
        return true
    }

    /// The explanation for a missing token — the `.notSent` reason when present, else a generic note.
    private static func tokenUnavailableReason(_ outcome: FetchDiagnostics.Outcome) -> String {
        if case let .notSent(reason) = outcome { return reason }
        return "credentials could not be read"
    }

    // MARK: Formatting helpers

    /// A compact duration from a `TimeInterval`, for the refresh-interval line: `<60s → "Ns"`,
    /// `<60m → "Nm"`, `<24h → "Nh Mm"` (a zero trailing minute dropped), else `"Nd Mh"`. Seconds are
    /// truncated to whole units; a negative or zero interval reads `"0s"`.
    public static func durationText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let m = minutes % 60
            return m == 0 ? "\(hours)h" : "\(hours)h \(m)m"
        }
        let days = hours / 24
        let h = hours % 24
        return h == 0 ? "\(days)d" : "\(days)d \(h)h"
    }

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


// MARK: - CodexQuotaTroubleshoot

/// The Codex collector's four Troubleshoot lines, as pure text.
///
/// Its own type rather than four more fields on ``TroubleshootLayout``: that one is built from a
/// ``PollOutput`` — Claude's poll — and the Codex collector is a different source with no entry in it.
///
/// **What can never appear here**: the account email (`account/read` is never called), `codexHome`
/// (present in the handshake reply and deliberately not decoded), and any raw response body. Every
/// string below is assembled from a path, a version, a duration or an already-worded error.
public enum CodexQuotaTroubleshoot {

    /// - Parameters:
    ///   - binaryPath: The executable in use, or `nil` when none was found.
    ///   - candidates: The paths that were tried — shown only when nothing was found, so "not found"
    ///     names them rather than leaving the user to guess what was searched.
    public static func lines(
        binaryPath: String?,
        candidates: [String],
        version: String?,
        lastSuccess: Date?,
        lastLatency: TimeInterval?,
        lastError: String?,
        now: Date
    ) -> [String] {
        var lines: [String] = []
        if let binaryPath {
            lines.append("Binary: \(binaryPath)")
        } else {
            lines.append("Binary: not found (tried \(candidates.joined(separator: ", ")))")
        }
        lines.append("Version: \(version ?? "unknown")")
        if let lastSuccess {
            let age = ResetClock.rounded(duration: max(0, now.timeIntervalSince(lastSuccess)))
                ?? "just now"
            let latency = lastLatency.map { String(format: " in %.2fs", $0) } ?? ""
            lines.append("Last read: \(age) ago\(latency)")
        } else {
            lines.append("Last read: never")
        }
        lines.append("Last error: \(lastError ?? "none")")
        return lines
    }
}
