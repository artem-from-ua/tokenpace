import Foundation

// MARK: - UsageTransport

/// Minimal injection seam over `URLSession` so ``UsageClient/fetch(accessToken:now:transport:)``
/// is testable with a stub — no live network, no `URLProtocol` subclassing. Mirrors the
/// codebase's "inject the dependency as a parameter with a default" convention
/// (`URLSession.shared`). Recorded in ADR-0008.
public protocol UsageTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// `URLSession` already exposes this exact signature, so conformance is free.
extension URLSession: UsageTransport {}

// MARK: - UsageClient

/// HTTP client for `GET /api/oauth/usage`.
///
/// A stateless namespace (like ``TokenProvider``): no stored state, no timer. The bearer
/// token is passed **in** as a `String` — the polling loop (#13) obtains it via
/// `TokenProvider.currentAccessToken(now:)`, handles `.expired`, and hands the fresh token
/// here. As a result `UsageClient` never imports `Security`/Keychain and stays trivially
/// testable with a literal token (ADR-0008).
///
/// ## Layers (purity split, ADR-0007 precedent)
/// | Layer | Purity | Unit-tested |
/// |---|---|---|
/// | ``buildRequest(accessToken:now:)`` | pure (→ `URLRequest`) | yes |
/// | ``decode(from:)`` | pure (`Data` → ``UsageSnapshot``) | yes |
/// | ``fetch(accessToken:now:transport:)`` | network I/O | no (stub / manual) |
///
/// `fetch` performs exactly one request and never sleeps or retries — the caller advances
/// ``PollingBackoff`` from the returned snapshot or thrown ``UsageError`` and schedules the
/// next wake.
public enum UsageClient {

    /// The usage endpoint. Force-unwrapped: the literal is a compile-time constant and a
    /// failure here is a programmer error, not a runtime condition.
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Fixed `anthropic-beta` header value required by the OAuth usage API.
    static let betaHeader = "oauth-2025-04-20"

    /// `claude-code/<version>` — **mandatory** on every request. Without it the API drops
    /// the client into an aggressively rate-limited bucket (constant 429s). The version is
    /// ``TokenPaceKit/version``, the single source of truth mirrored from the root `VERSION`.
    static func userAgent() -> String { "claude-code/\(TokenPaceKit.version)" }

    // MARK: buildRequest (pure seam)

    /// Build the GET request with all four mandatory headers, or throw
    /// ``UsageError/missingUserAgent`` if the `User-Agent` would be empty — the explicit,
    /// testable form of the "do not request without a User-Agent" guard.
    ///
    /// - Parameter now: Accepted for signature symmetry with the rest of the codebase and
    ///   for a future `If-Modified-Since`/caching header; unused in the Phase-1 header set.
    public static func buildRequest(accessToken: String, now: Date) throws -> URLRequest {
        try buildRequest(accessToken: accessToken, now: now, userAgent: userAgent())
    }

    /// Header-construction core with the `User-Agent` injected, so the guard can be exercised
    /// with an empty string in tests (the public path always passes the non-empty constant).
    static func buildRequest(accessToken: String, now: Date, userAgent: String) throws -> URLRequest {
        guard !userAgent.isEmpty, userAgent != "claude-code/" else {
            throw UsageError.missingUserAgent
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    // MARK: decode (pure seam)

    /// Decode a 200 body into a ``UsageSnapshot``. Unknown keys (`extra_usage`, `spend`, `scope`,
    /// …) are ignored; `null` model windows decode to `nil`. On a reset boundary the API may send
    /// the core `five_hour`/`seven_day` windows as `null` — ``UsageSnapshot`` synthesizes a fresh
    /// zero-usage window for those (it needs `now`, threaded through `userInfo`) rather than
    /// failing. A genuinely malformed body (non-JSON, truncated) still maps to ``UsageError/decode``,
    /// and the (capped) body is logged so the failure is diagnosable.
    ///
    /// - Parameters:
    ///   - data: The raw 200 body.
    ///   - now: The poll instant, forwarded to the reconstruction rung
    ///     (``ResetClock/rollForward(anchor:by:until:)``). Defaults to `Date()` for call sites (e.g.
    ///     tests) that do not thread a clock; the live path (`fetch`) passes the real `now`.
    ///   - lastKnownSevenDayReset: The last **server-supplied** weekly reset. When the body omits
    ///     `seven_day.resets_at` entirely — which it does for hours at every weekly reset — this is
    ///     what the decoder rolls forward instead of inventing a date (ADR-0107). Only set it from a
    ///     value the API actually sent: ``ResetSource/isUnrolledServerFact`` is the caller's guard.
    public static func decode(
        from data: Data,
        now: Date = Date(),
        lastKnownSevenDayReset: Date? = nil
    ) throws -> UsageSnapshot {
        let decoder = JSONDecoder()
        decoder.userInfo[.usageNow] = now
        if let lastKnownSevenDayReset {
            decoder.userInfo[.lastKnownSevenDayReset] = lastKnownSevenDayReset
        }
        do {
            return try decoder.decode(UsageSnapshot.self, from: data)
        } catch is DecodingError {
            // Log the (capped, token-free) body so the next genuine decode failure — e.g. an
            // unannounced schema change — is diagnosable, instead of just "usage decode failed".
            let body = responseText(from: data) ?? "<empty/non-utf8 \(data.count) bytes>"
            AppLogger.network.error("usage decode failed body=\(body, privacy: .public)")
            throw UsageError.decode
        }
    }

    // MARK: fetch (network)

    /// Perform one usage poll. Returns the snapshot on 200; otherwise throws a typed
    /// ``UsageError``. Does **not** sleep, retry, or own a timer — the caller (#13) advances
    /// ``PollingBackoff`` from the result and schedules the next wake.
    ///
    /// - Parameters:
    ///   - accessToken: Fresh bearer token from `TokenProvider` (never stale — see ADR-0007).
    ///   - now: Threaded into ``buildRequest(accessToken:now:)`` for signature symmetry.
    ///   - transport: Injected for testing; defaults to `URLSession.shared`.
    ///   - lastKnownSevenDayReset: The last **server-supplied** weekly reset, for the decoder's
    ///     reconstruction rung (ADR-0107). Defaults to `nil` — no anchor, and nothing is invented.
    public static func fetch(
        accessToken: String,
        now: Date,
        transport: UsageTransport = URLSession.shared,
        lastKnownSevenDayReset: Date? = nil
    ) async throws -> UsageSnapshot {
        try (await diagnosedFetch(accessToken: accessToken, now: now, transport: transport,
                                  lastKnownSevenDayReset: lastKnownSevenDayReset)).result.get()
    }

    /// The core of ``fetch(accessToken:now:transport:)`` that also captures the raw
    /// ``FetchDiagnostics`` for the Troubleshoot window (ADR-0020). Same one-request-no-retry
    /// behaviour and same log lines as `fetch` — but instead of throwing, it returns a
    /// ``DiagnosedFetch`` carrying both the snapshot-or-error **and** the uncapped, full-length
    /// diagnostic record captured in every branch (200, 429, other non-2xx, decode failure,
    /// transport error, non-HTTP, User-Agent guard). `fetch` is the thin wrapper that discards the
    /// diagnostics; the poll loop keeps them.
    ///
    /// The diagnostic ``FetchDiagnostics/body`` is the **full** response body (not capped to
    /// ``maxBodyLength`` like the popup's copy), and is captured for 429 and decode failures too —
    /// bodies the throwing `fetch` never surfaced. It never carries the bearer token (see
    /// ``FetchDiagnostics``).
    public static func diagnosedFetch(
        accessToken: String,
        now: Date,
        transport: UsageTransport = URLSession.shared,
        lastKnownSevenDayReset: Date? = nil
    ) async -> DiagnosedFetch {
        let request: URLRequest
        do {
            request = try buildRequest(accessToken: accessToken, now: now)  // UA guard first
        } catch {
            // The request is never sent — surface it as a not-sent diagnostic, no HTTP anything.
            let diag = FetchDiagnostics(
                attemptAt: now, httpStatus: nil, body: nil,
                outcome: .notSent(reason: "missing User-Agent"))
            return DiagnosedFetch(result: .failure(.missingUserAgent), diagnostics: diag)
        }

        // Wall-clock latency of the network call only (not decode). Measured in the I/O layer around
        // the awaited transport — this is real elapsed time, distinct from the injected poll `now`
        // (which anchors the deterministic pure pipeline). Journalled as the API's response time (#242).
        let sentAt = Date()
        func elapsedMs() -> Int { Int((Date().timeIntervalSince(sentAt) * 1000).rounded()) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            let code = (error as? URLError)?.code
            AppLogger.network.error(
                "usage request transport error: \(error.localizedDescription, privacy: .public)")
            let diag = FetchDiagnostics(
                attemptAt: now, httpStatus: nil, body: nil,
                outcome: .transportError(message: error.localizedDescription),
                durationMs: elapsedMs())
            return DiagnosedFetch(
                result: .failure(.transport(message: error.localizedDescription, code: code)),
                diagnostics: diag)
        }
        let durationMs = elapsedMs()

        guard let http = response as? HTTPURLResponse else {
            AppLogger.network.error("usage response not HTTP")
            let diag = FetchDiagnostics(
                attemptAt: now, httpStatus: nil, body: nil, outcome: .nonHTTPResponse,
                durationMs: durationMs)
            return DiagnosedFetch(result: .failure(.nonHTTPResponse), diagnostics: diag)
        }

        // The full, uncapped body captured once per HTTP branch — the diagnostic copy the window
        // shows verbatim. `nil` when the body is absent / not UTF-8.
        let fullBody = fullResponseText(from: data)

        switch http.statusCode {
        case 200:
            do {
                let snapshot = try decode(from: data, now: now,
                                         lastKnownSevenDayReset: lastKnownSevenDayReset)
                // One line per success: status **and** the full JSON body, so there is no duplicate
                // "200 ok" / "200 body" pair. `.notice` so it shows at the default log level (no
                // `--level info` needed). The usage payload carries no secrets — the token rides only in
                // the request's Authorization header, which is never logged — so the body is `.public`.
                // Logged in full (not capped) so the per-model breakdown is visible; once per poll
                // (≈180 s) the volume is negligible.
                let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
                AppLogger.network.notice("usage 200 ok body=\(bodyText, privacy: .public)")
                let diag = FetchDiagnostics(
                    attemptAt: now, httpStatus: 200, body: fullBody, outcome: .success,
                    durationMs: durationMs)
                return DiagnosedFetch(result: .success(snapshot), diagnostics: diag)
            } catch {
                // `decode` already logged the (capped) body; here the diagnostic keeps the full one.
                let diag = FetchDiagnostics(
                    attemptAt: now, httpStatus: 200, body: fullBody, outcome: .decodeFailure,
                    durationMs: durationMs)
                return DiagnosedFetch(result: .failure(.decode), diagnostics: diag)
            }
        case 429:
            let retryAfter = retryAfterSeconds(from: http)
            AppLogger.network.error(
                "usage rate-limited: HTTP 429 retryAfter=\(retryAfter ?? -1, privacy: .public)")
            let diag = FetchDiagnostics(
                attemptAt: now, httpStatus: 429, body: fullBody, outcome: .httpError,
                retryAfter: retryAfter, durationMs: durationMs)
            return DiagnosedFetch(
                result: .failure(.rateLimited(retryAfter: retryAfter)), diagnostics: diag)
        default:
            let body = responseText(from: data)   // capped copy for the popup detail line
            AppLogger.network.error(
                "usage request failed: HTTP \(http.statusCode, privacy: .public)")
            let diag = FetchDiagnostics(
                attemptAt: now, httpStatus: http.statusCode, body: fullBody, outcome: .httpError,
                durationMs: durationMs)
            return DiagnosedFetch(
                result: .failure(.http(status: http.statusCode, body: body)), diagnostics: diag)
        }
    }

    /// The longest response body kept for the error UI. The server's error messages are short;
    /// the cap stops a stray large/HTML body from bloating a `UsageError` (and the popup).
    static let maxBodyLength = 500

    /// Decode an error response body to trimmed, length-capped plain text for the popup's detail
    /// line, or `nil` when it is empty / not UTF-8. This is the **response** body — it never
    /// carries the request's bearer token, so it is `.public`-safe to surface to the user.
    static func responseText(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > maxBodyLength ? String(trimmed.prefix(maxBodyLength)) : trimmed
    }

    /// The **full**, uncapped response body as UTF-8 text for ``FetchDiagnostics/body`` — the raw
    /// bytes the Troubleshoot window shows verbatim (ADR-0020). Unlike ``responseText(from:)`` it
    /// neither trims nor truncates (the diagnostic must be faithful), returning `nil` only when the
    /// body is empty or not UTF-8. Like ``responseText(from:)`` it is the *response* body, so it
    /// never carries the bearer token.
    static func fullResponseText(from data: Data) -> String? {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// Parse the `Retry-After` header (seconds form) if present. The HTTP-date form is not
    /// handled in Phase 1 (the server sends seconds). Carries no token.
    static func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw) else { return nil }
        return seconds
    }
}
