import Foundation

// MARK: - FetchDiagnostics

/// The **raw**, uncapped record of one usage-poll attempt — the data the Troubleshoot window
/// renders (ADR-0020). Distinct from ``UsageError``/``UsageSnapshot``: those drive the popup's
/// aggregated health, while this preserves the exact HTTP status and full response body so a bug
/// report can be reproduced from the widget alone, without a `log stream` session.
///
/// A pure value type flowing through the pure pipeline (`DiagnosedFetch` → `PollResult` →
/// `PollOutput.diagnostics`), never captured in `PollState`: it describes the *last attempt*, not
/// accumulated state (ADR-0020).
///
/// ## Body is uncapped and token-free
/// Unlike ``UsageError/http(status:body:)`` (capped at ``UsageClient/maxBodyLength`` for the popup
/// detail line), ``body`` here is the **full** UTF-8 response body. It never carries the bearer
/// token — the token rides only in the request's `Authorization` header, never in the *response*
/// (the same argument recorded in ``UsageClient/responseText(from:)``), so it is safe to surface
/// verbatim in the diagnostic UI.
public struct FetchDiagnostics: Sendable, Equatable {

    /// How the attempt ended — the exhaustive set of terminal states one poll can reach.
    public enum Outcome: Sendable, Equatable {
        /// HTTP 200 and the body decoded into a snapshot.
        case success
        /// Any non-2xx status, **including 429** — the raw status rides in ``httpStatus`` and the
        /// server's payload in ``body`` (uncapped, unlike the popup's capped copy).
        case httpError
        /// HTTP 200 but the body failed to decode (e.g. an unannounced schema change) — the raw
        /// body is kept in ``body`` so the offending shape is visible.
        case decodeFailure
        /// A transport-level failure (offline, DNS, TLS, cancellation); `message` is a
        /// `.public`-safe description, never the token.
        case transportError(message: String)
        /// The response was not an `HTTPURLResponse`.
        case nonHTTPResponse
        /// The request was **never sent** — a token error short-circuited before the network
        /// (ADR-0007), or the `User-Agent` guard tripped. `reason` explains which.
        case notSent(reason: String)
    }

    /// When the attempt was made (the poll instant `now`), for the "last response" timestamp.
    public let attemptAt: Date
    /// The HTTP status when a response arrived (200, 429, 401, …), else `nil` (transport /
    /// non-HTTP / not-sent).
    public let httpStatus: Int?
    /// The **full** UTF-8 response body, or `nil` when there is none / it was not UTF-8. Never
    /// carries the bearer token (see the type doc).
    public let body: String?
    /// How the attempt ended.
    public let outcome: Outcome
    /// `Retry-After` header value in seconds when the server sent one (only on HTTP 429), else `nil`.
    /// Captured here so the usage journal (#242) can record how long the server asked us to back off
    /// without re-parsing the response — the popup's aggregated health drops this detail.
    public let retryAfter: TimeInterval?
    /// The request round-trip latency in **milliseconds** — measured around `transport.data(for:)`,
    /// so it covers only the network call (not decode). `nil` when the request was never sent
    /// (``Outcome/notSent``) or the User-Agent guard tripped. Journalled (#242) as the API's response
    /// time; also handy for the Troubleshoot window.
    public let durationMs: Int?

    public init(
        attemptAt: Date,
        httpStatus: Int?,
        body: String?,
        outcome: Outcome,
        retryAfter: TimeInterval? = nil,
        durationMs: Int? = nil
    ) {
        self.attemptAt = attemptAt
        self.httpStatus = httpStatus
        self.body = body
        self.outcome = outcome
        self.retryAfter = retryAfter
        self.durationMs = durationMs
    }
}

// MARK: - TokenDiagnostics

/// The auth-token metadata surfaced by the Troubleshoot window — **dates only, no secret**
/// (ADR-0020). Because this value flows into the shell and UI, it deliberately excludes the token
/// string: only *when it was read* and *when it expires* are diagnostic, and neither is a secret.
///
/// - `readAt`: the instant the credentials were read from the Keychain in the poll loop. The
///   Keychain payload has no issued-at field (`RawCredentials` decodes only
///   `accessToken`/`refreshToken`/`expiresAt`/`scopes`/`subscriptionType`/`rateLimitTier`), so the
///   read instant is the best available "obtained at".
/// - `expiresAt`: the token's `expiresAt` (`TokenCredentials.expiresAt`). Populated even for an
///   expired token — the most valuable diagnostic case ("it expired at HH:MM and hasn't refreshed").
public struct TokenDiagnostics: Sendable, Equatable {
    public let readAt: Date
    public let expiresAt: Date

    public init(readAt: Date, expiresAt: Date) {
        self.readAt = readAt
        self.expiresAt = expiresAt
    }
}

// MARK: - PollDiagnostics

/// Both diagnostic channels of one poll iteration — the fetch record plus the token metadata.
///
/// `token` is `nil` only when the credentials could not be read at all (itemNotFound / malformed /
/// keychain error); an expired-but-readable token still carries its dates (see ``TokenDiagnostics``).
public struct PollDiagnostics: Sendable, Equatable {
    public let fetch: FetchDiagnostics
    public let token: TokenDiagnostics?

    public init(fetch: FetchDiagnostics, token: TokenDiagnostics?) {
        self.fetch = fetch
        self.token = token
    }
}

// MARK: - DiagnosedFetch

/// The result of ``UsageClient/diagnosedFetch(accessToken:now:transport:)``: the usual
/// snapshot-or-error **plus** the raw ``FetchDiagnostics`` captured along the way. `fetch` (the
/// plain wrapper) discards the diagnostics via `result.get()`; the poll loop keeps both.
public struct DiagnosedFetch: Sendable {
    public let result: Result<UsageSnapshot, UsageError>
    public let diagnostics: FetchDiagnostics

    public init(result: Result<UsageSnapshot, UsageError>, diagnostics: FetchDiagnostics) {
        self.result = result
        self.diagnostics = diagnostics
    }
}
