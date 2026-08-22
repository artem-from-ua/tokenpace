import Foundation

// MARK: - StatusClient

/// HTTP client for a Statuspage-shaped status summary — by default Claude's,
/// `GET https://status.claude.com/api/v2/summary.json`.
///
/// A stateless namespace mirroring ``UsageClient``: no stored state, no timer. It is a **second,
/// independent** data source from the usage API (ADR-0013). Independence is now literal in both
/// directions: since ADR-0119 the status loop has a 429 backoff **of its own** — one
/// ``PollingBackoff`` per status source — so a rate-limited status page holds only that source, and
/// never touches the usage backoff or another source's. The endpoint needs no auth.
///
/// ## Parameterised, so a second source costs no fork
/// `endpoint` and `userAgent` are **parameters with defaults**, not hardcoded constants
/// (ADR-0119 §4). The defaults are Claude's URL and `claude-code/<version>`, so every existing call
/// site reads unchanged; another provider's page passes its own URL and — importantly — its own
/// User-Agent, since `claude-code/<version>` is the right thing to send to Anthropic's page and the
/// wrong thing to send to anyone else's.
///
/// ## Layers (purity split, mirrors ``UsageClient``)
/// | Layer | Purity | Unit-tested |
/// |---|---|---|
/// | ``buildRequest(endpoint:userAgent:)`` | pure (→ `URLRequest`) | yes |
/// | ``decode(from:)`` | pure (`Data` → ``StatusSummary``) | yes |
/// | ``fetch(transport:endpoint:userAgent:)`` | network I/O | no (stub / manual) |
///
/// `fetch` performs exactly one request and never sleeps or retries — the shell's status loop
/// schedules the next poll on its own cadence. Any failure throws a narrow ``StatusFetchError``
/// that the shell turns into ``StatusHealth/unknown``; a `429` additionally carries the server's
/// `Retry-After` so the caller's own backoff can honour it.
public enum StatusClient {

    /// The **default** status summary endpoint (Claude's). Force-unwrapped: a compile-time literal
    /// whose failure would be a programmer error, not a runtime condition.
    ///
    /// Still a `static let` because it is also the routing key the dev stub transport matches on
    /// (`request.url == StatusClient.endpoint`); parameterising the *request* did not make this
    /// constant go away, it made it the default rather than the only option.
    public static let endpoint = URL(string: "https://status.claude.com/api/v2/summary.json")!

    /// `claude-code/<version>` — the **default** User-Agent, correct for Anthropic's own status page
    /// (consistency with the usage client, and a well-behaved client of that page). The version is
    /// ``TokenPaceKit/version``. A third-party page gets its own string instead.
    public static func userAgent() -> String { "claude-code/\(TokenPaceKit.version)" }

    // MARK: buildRequest (pure seam)

    /// Build the GET request with the `User-Agent` header. No auth, no beta header — a status
    /// page is public.
    ///
    /// - Parameters:
    ///   - endpoint: The summary URL. Defaults to ``endpoint`` (Claude's).
    ///   - userAgent: The `User-Agent` to send. Defaults to ``userAgent()``.
    public static func buildRequest(
        endpoint: URL = StatusClient.endpoint,
        userAgent: String = StatusClient.userAgent()
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    // MARK: decode (pure seam)

    /// Decode a 200 body into a ``StatusSummary``. Any `DecodingError` maps to
    /// ``StatusFetchError/decode``. Unknown keys (`status`, `scheduled_maintenances`, `page`, …) are
    /// ignored; absent `components` / `incidents` arrays decode to `[]`.
    public static func decode(from data: Data) throws -> StatusSummary {
        do {
            return try JSONDecoder().decode(StatusSummary.self, from: data)
        } catch is DecodingError {
            AppLogger.network.error("status decode failed")
            throw StatusFetchError.decode
        }
    }

    // MARK: fetch (network)

    /// Perform one status poll. Returns the summary on 200; otherwise throws a ``StatusFetchError``.
    /// Does **not** sleep, retry, or own a timer — the shell's status loop schedules the next poll.
    ///
    /// - Parameters:
    ///   - transport: Injected for testing; defaults to `URLSession.shared`. Reuses the
    ///     ``UsageTransport`` seam (same `data(for:)` signature) — no second protocol needed.
    ///   - endpoint: The summary URL. Defaults to Claude's ``endpoint``.
    ///   - userAgent: The `User-Agent` to send. Defaults to ``userAgent()``.
    public static func fetch(
        transport: UsageTransport = URLSession.shared,
        endpoint: URL = StatusClient.endpoint,
        userAgent: String = StatusClient.userAgent()
    ) async throws -> StatusSummary {
        try await fetchRaw(transport: transport, endpoint: endpoint, userAgent: userAgent).summary
    }

    /// Like ``fetch(transport:endpoint:userAgent:)`` but also hands back the **verbatim** response body, for the dev
    /// payload log (ADR-0071 §10) which records raw JSON rather than a re-encoded digest — the point
    /// of that log is to study exactly what the server sent.
    ///
    /// ``fetch(transport:endpoint:userAgent:)`` is expressed in terms of this, so there is one implementation of the
    /// request/response handling and existing callers are untouched.
    public static func fetchRaw(
        transport: UsageTransport = URLSession.shared,
        endpoint: URL = StatusClient.endpoint,
        userAgent: String = StatusClient.userAgent()
    ) async throws -> (summary: StatusSummary, body: Data) {
        let request = buildRequest(endpoint: endpoint, userAgent: userAgent)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            AppLogger.network.error(
                "status request transport error: \(error.localizedDescription, privacy: .public)")
            throw StatusFetchError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            AppLogger.network.error("status response not HTTP")
            throw StatusFetchError.transport("non-HTTP response")
        }

        switch http.statusCode {
        case 200:
            let summary = try decode(from: data)
            AppLogger.network.notice(
                "status 200 ok components=\(summary.components.count, privacy: .public) incidents=\(summary.incidents.count, privacy: .public)")
            return (summary, data)
        case 429:
            // The one code worth modelling (ADR-0119): the page is asking us to slow down, and the
            // caller's per-source `PollingBackoff` can only honour that if the hint survives the
            // throw. Everything else still collapses into `.decode` below.
            let retryAfter = retryAfterSeconds(from: http)
            AppLogger.network.error(
                "status rate-limited: HTTP 429 retryAfter=\(retryAfter ?? -1, privacy: .public)")
            throw StatusFetchError.rateLimited(retryAfter: retryAfter)
        default:
            // The status page carries no secrets and no per-status meaning beyond "not 200" for our
            // purposes — all of these map to `.decode` (→ `StatusHealth.unknown`), so we do not model
            // individual codes the way the usage client does for auth.
            AppLogger.network.error(
                "status request failed: HTTP \(http.statusCode, privacy: .public)")
            throw StatusFetchError.decode
        }
    }

    /// Parse the `Retry-After` header, **delta-seconds form only**. The HTTP-date form maps to `nil`
    /// rather than being parsed — deliberately, and identically to
    /// ``UsageClient/retryAfterSeconds(from:)``: `nil` is not a failure here, it simply means "no
    /// usable hint", and ``PollingBackoff/honoring(retryAfter:)`` already answers that with its
    /// 180 s default. A malformed value takes the same path.
    ///
    /// Deliberately **not** shared with the usage client. The two clients are separate seams over
    /// separate services (ADR-0013), and a one-line header read is a poor reason to couple them —
    /// the coupling would be the thing that later has to be undone.
    static func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw) else { return nil }
        return seconds
    }
}
