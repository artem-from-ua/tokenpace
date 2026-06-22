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
    /// ``CCTimerKit/version``, the single source of truth mirrored from the root `VERSION`.
    static func userAgent() -> String { "claude-code/\(CCTimerKit.version)" }

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

    /// Decode a 200 body into a ``UsageSnapshot``. Any `DecodingError` (non-JSON, or a
    /// missing required `five_hour`/`seven_day`) maps to ``UsageError/decode``. Null model
    /// windows decode to `nil`; unknown keys (`extra_usage`, `spend`) are ignored.
    public static func decode(from data: Data) throws -> UsageSnapshot {
        do {
            return try JSONDecoder().decode(UsageSnapshot.self, from: data)
        } catch is DecodingError {
            AppLogger.network.error("usage decode failed")
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
    public static func fetch(
        accessToken: String,
        now: Date,
        transport: UsageTransport = URLSession.shared
    ) async throws -> UsageSnapshot {
        let request = try buildRequest(accessToken: accessToken, now: now)  // UA guard first

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            let code = (error as? URLError)?.code
            AppLogger.network.error(
                "usage request transport error: \(error.localizedDescription, privacy: .public)")
            throw UsageError.transport(message: error.localizedDescription, code: code)
        }

        guard let http = response as? HTTPURLResponse else {
            AppLogger.network.error("usage response not HTTP")
            throw UsageError.nonHTTPResponse
        }

        switch http.statusCode {
        case 200:
            let snapshot = try decode(from: data)
            AppLogger.network.notice("usage 200 ok")
            return snapshot
        case 429:
            let retryAfter = retryAfterSeconds(from: http)
            AppLogger.network.error(
                "usage rate-limited: HTTP 429 retryAfter=\(retryAfter ?? -1, privacy: .public)")
            throw UsageError.rateLimited(retryAfter: retryAfter)
        default:
            let body = responseText(from: data)
            AppLogger.network.error(
                "usage request failed: HTTP \(http.statusCode, privacy: .public)")
            throw UsageError.http(status: http.statusCode, body: body)
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

    /// Parse the `Retry-After` header (seconds form) if present. The HTTP-date form is not
    /// handled in Phase 1 (the server sends seconds). Carries no token.
    static func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw) else { return nil }
        return seconds
    }
}
