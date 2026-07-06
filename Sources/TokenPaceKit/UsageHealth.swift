import Foundation

// MARK: - FailureReason

/// Why usage data is currently unavailable — the **semantic, user-facing** cause.
///
/// The diagnostic errors `TokenError`/`UsageError` carry implementation detail (an `OSStatus`, an
/// `HTTPURLResponse` body, a `URLError.Code`) that should not leak verbatim into the UI. This enum
/// collapses them to the handful of distinctions the popup actually explains, while keeping the
/// **payload** the view needs to build a sentence (the HTTP status/body). It is localisation-free —
/// the human sentence is assembled in `PopupViewController` (the localisation seam), like
/// `PacingState`/`TimeToReset` (ADR-0009).
///
/// The `init(_:)` maps are exhaustive `switch`es with **no `default`**: a new `TokenError`/
/// `UsageError` case must break the build so it is consciously mapped, never silently bucketed
/// into `.unknown`.
public enum FailureReason: Sendable, Equatable {
    /// No token / not signed in (`TokenError.itemNotFound`). UX: "authenticate in Claude Code".
    case notSignedIn
    /// The stored token is expired and the delegated refresh (ADR-0017) has not fixed it yet —
    /// either the attempt failed (no `claude` binary, timeout) or the gate is cooling down.
    /// UX: honest "token expired" wording instead of a synthetic HTTP 401.
    case tokenExpired
    /// An HTTP auth rejection — the API returned 401/403, or the local token was ACL-blocked
    /// (mapped to a synthetic 401). `body` is the server's plain-text message when one
    /// came back, shown on the popup's detail line beneath "Auth error (HTTP <status>)".
    case authHTTP(status: Int, body: String?)
    /// The request timed out (`URLError.timedOut`). UX: "Authentication API timeout".
    case timeout
    /// DNS could not resolve the endpoint host (`URLError.cannotFindHost` / `.dnsLookupFailed`).
    /// UX: "Unable to resolve API endpoint hostname".
    case cannotResolveHost
    /// Any other transport/connectivity failure (offline, TLS, connection refused). `message` is a
    /// `.public`-safe description; the view renders a generic "connectivity issue".
    case network(String)
    /// A server-side problem that is not auth: 5xx, 429, a malformed 200 body, or a non-HTTP
    /// response. UX: "Usage API is unavailable right now".
    case serverProblem
    /// Catch-all for causes that should never reach the UI in normal operation
    /// (`UsageError.missingUserAgent` is a programmer error; `TokenError.malformedData`/
    /// `.keychainError` are rare). Generic "could not fetch usage" wording.
    case unknown

    // MARK: from TokenError

    /// Map a Keychain/token failure to its user-facing reason. Exhaustive, no `default`.
    public init(_ error: TokenError) {
        switch error {
        case .itemNotFound:
            self = .notSignedIn
        case .expired:
            // Expired is its own reason (not a synthetic 401): the delegated refresh may still
            // fix it unattended, so the UI wording must not demand a re-login outright.
            self = .tokenExpired
        case .accessDenied:
            // The token is present but unreadable — treat as an auth rejection (401), no server body.
            self = .authHTTP(status: 401, body: nil)
        case .malformedData, .keychainError:
            self = .unknown
        }
    }

    // MARK: from UsageError

    /// Map a usage-poll failure to its user-facing reason. Exhaustive, no `default`.
    ///
    /// `http(401/403)` is an auth rejection; any other status is a generic server problem.
    /// `transport` is refined by its `URLError.Code` into timeout / DNS / other.
    public init(_ error: UsageError) {
        switch error {
        case let .http(status, body):
            self = (status == 401 || status == 403) ? .authHTTP(status: status, body: body)
                                                     : .serverProblem
        case let .transport(message, code):
            switch code {
            case .timedOut:
                self = .timeout
            case .cannotFindHost, .dnsLookupFailed:
                self = .cannotResolveHost
            default:
                self = .network(message)
            }
        case .nonHTTPResponse:
            self = .network("non-HTTP response")
        case .rateLimited, .decode:
            self = .serverProblem
        case .missingUserAgent:
            self = .unknown
        }
    }
}

// MARK: - UsageHealth

/// The polling layer's health at instant `now` — the **second input** (besides `UsageSnapshot`)
/// that the error-state UI of issue #12 consumes.
///
/// A pure value type with **no clock of its own**: `now` is injected by the caller, exactly like
/// `PacingModel`/`MenuBarLayout` (ADR-0009). The live polling loop (#13) builds this from real
/// poll results; #12 only defines it, the thresholds, and the rendering. `AppDelegate` builds a
/// mock to exercise the states under `swift run`.
///
/// ## Menu-bar phases (SPEC "Стан помилок", refined with the user)
/// The widget reacts to the **duration** of an unbroken failure run, `now - failingSince`:
/// | Phase | Condition | Menu bar |
/// |---|---|---|
/// | fresh-ish | `≤ 30 min` and a last snapshot exists | stale bars + reset, **no** ⚠️ |
/// | stale | `30 min < age ≤ 60 min` | ⚠️ **plus** stale bars + reset |
/// | dead | `> 60 min`, or cold start (no snapshot) | ⚠️ **only** (data too old / absent) |
///
/// The popup, by contrast, warns **immediately** on any failure (no threshold) — `isFailing`
/// drives `PopupLayout.warning`. The phase logic itself lives in `MenuBarLayout.make`; this type
/// owns only the inputs and the thresholds.
public struct UsageHealth: Sendable, Equatable {
    /// Instant of the last successful 200, or `nil` if we have **never** succeeded (cold start).
    /// Drives the "Last update …" staleness line and the stale-vs-dead menu-bar decision.
    public let lastSuccess: Date?
    /// Instant the current unbroken failure run began (the first failure after the last success),
    /// or `nil` when the most recent poll succeeded (i.e. healthy). Drives the 30/60-min thresholds.
    public let failingSince: Date?
    /// The most recent failure's user-facing cause, or `nil` when healthy. Drives the popup warning.
    public let reason: FailureReason?

    public init(lastSuccess: Date?, failingSince: Date?, reason: FailureReason?) {
        self.lastSuccess = lastSuccess
        self.failingSince = failingSince
        self.reason = reason
    }

    /// Healthy state: the last poll succeeded at `at`, no failure in progress.
    public static func healthy(lastSuccess at: Date) -> UsageHealth {
        UsageHealth(lastSuccess: at, failingSince: nil, reason: nil)
    }

    // MARK: thresholds

    /// Failures must run **longer than** this before the menu bar adds the ⚠️ glyph next to the
    /// (now stale) bars. SPEC "Стан помилок": "Якщо авторизація не працює > 30 хв". 1800 s.
    public static let glyphAfter: TimeInterval = 30 * 60

    /// Failures longer than this drop the bars entirely — the data is too stale to show — leaving
    /// only the ⚠️ glyph (user decision, beyond the SPEC's single 30-min step). 3600 s.
    public static let hideBarsAfter: TimeInterval = 60 * 60

    // MARK: derived state

    /// Whether a failure is currently in progress — the popup warns the moment this is true,
    /// regardless of the menu-bar thresholds (SPEC: "за будь-якої непрацюючої авторизації … одразу").
    public var isFailing: Bool { failingSince != nil }

    /// How long the current failure run has lasted at `now`, or `nil` when healthy. Clamped `≥ 0`
    /// so a `failingSince` slightly in the future (clock skew) never yields a negative age.
    ///
    /// - Parameter now: the current instant (injected for tests; never call `Date()` here).
    public func failureAge(now: Date) -> TimeInterval? {
        guard let failingSince else { return nil }
        return max(0, now.timeIntervalSince(failingSince))
    }
}
