import Foundation

// MARK: - FailureReason

/// Why usage data is currently unavailable — the **semantic, user-facing** cause.
///
/// The diagnostic errors `TokenError`/`UsageError` carry implementation detail (an `OSStatus`, an
/// `HTTPURLResponse` body, a `URLError.Code`) that should not leak verbatim into the UI. This enum
/// collapses them to the handful of distinctions the popup actually explains, while keeping the
/// **payload** the view needs to build a sentence (the HTTP status/body). It is localisation-free —
/// the human sentence is assembled in `PopupViewController` (the localisation seam), like
/// `PacingState`/`LimitIndicator` (ADR-0009).
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
/// ## Menu-bar phases (SPEC "Стан помилок"; two phases since ADR-0091)
/// The widget reacts to the **duration** of an unbroken failure run, `now - failingSince`:
/// | Phase | Condition | Menu bar |
/// |---|---|---|
/// | fresh-ish | within ``glyphAfter(for:)`` and a last snapshot exists | stale bars, **no** ⚠️ |
/// | dead | past it, or cold start (no snapshot) | ⚠️ **only** — no bars, no countdown |
///
/// The middle phase (⚠️ *beside* stale bars, 30–60 min) is gone: bars that old invite a reading they
/// cannot support, and the popup already explains the failure in words.
///
/// The popup, by contrast, warns **immediately** on any failure (no threshold) — `isFailing`
/// drives `PopupLayout.warning`. The phase logic itself lives in `MenuBarLayout.make`; this type
/// owns only the inputs and the threshold.
///
/// ## The third state: `notPolling` (#341)
/// "We are deliberately not asking" is neither healthy nor failing, and both attempts to encode it
/// with the two existing states break something. Reporting it as failing makes the popup show a red
/// error banner instantly and the menu bar decay to ⚠️ after 30 minutes — the user switched the poll
/// off, and the UI tells them it is broken. Reporting it as healthy makes `lastSuccess` lie: the
/// popup says "Updated just now" with no data behind it.
///
/// So it is a separate flag, and **every** consumer that branches on failure must consider it. The
/// compiler cannot help here — this is a `struct` of predicates, not an enum, so nothing fails to
/// build if a consumer is missed. The predicates below exist to make each site read as a decision
/// rather than an omission.
public struct UsageHealth: Sendable, Equatable {
    /// Instant of the last successful 200, or `nil` if we have **never** succeeded (cold start).
    /// Drives the "Last update …" staleness line and the stale-vs-dead menu-bar decision.
    public let lastSuccess: Date?
    /// Instant the current unbroken failure run began (the first failure after the last success),
    /// or `nil` when the most recent poll succeeded (i.e. healthy). Drives the 30/60-min thresholds.
    public let failingSince: Date?
    /// The most recent failure's user-facing cause, or `nil` when healthy. Drives the popup warning.
    public let reason: FailureReason?
    /// Whether the usage API is deliberately not being polled (#341) — the user switched it off.
    ///
    /// Orthogonal to the failure fields on purpose: entering this state does not invent a failure,
    /// and leaving it does not clear one. While it is `true`, `failingSince` is `nil` and
    /// `lastSuccess` is whatever it was — stale, and the UI must not present it as fresh.
    public let notPolling: Bool
    /// The cadence polls are currently attempted at, which is what makes the ⚠️ threshold meaningful:
    /// see ``glyphAfter(for:)``. Defaults to `PollingEngine.baseInterval` so the many construction
    /// sites that predate this — and every test that does not care — keep the healthy-cadence answer.
    public let pollInterval: TimeInterval

    /// Defaulted so the many existing construction sites — production and test alike — keep meaning
    /// "we are polling", and only the polling engine's service-only path opts in.
    public init(
        lastSuccess: Date?, failingSince: Date?, reason: FailureReason?, notPolling: Bool = false,
        pollInterval: TimeInterval = PollingEngine.baseInterval
    ) {
        self.lastSuccess = lastSuccess
        self.failingSince = failingSince
        self.reason = reason
        self.notPolling = notPolling
        self.pollInterval = pollInterval
    }

    /// Healthy state: the last poll succeeded at `at`, no failure in progress.
    public static func healthy(lastSuccess at: Date) -> UsageHealth {
        UsageHealth(lastSuccess: at, failingSince: nil, reason: nil)
    }

    /// The usage poll is off (#341). No failure, and no fresh success to report either — whatever
    /// `lastSuccess` held is left behind as the stale value it is.
    public static func notPollingUsage(lastSuccess: Date? = nil) -> UsageHealth {
        UsageHealth(lastSuccess: lastSuccess, failingSince: nil, reason: nil, notPolling: true)
    }

    // MARK: thresholds

    /// The floor for ``glyphAfter(for:)`` — 15 min. Chosen so the widget gives up on data noticeably
    /// sooner than the old 30-min step, without turning a single hiccup into a ⚠️.
    public static let glyphAfterFloor: TimeInterval = 15 * 60

    /// How many polls must fail before the ⚠️ is warranted, when the cadence is slow enough that the
    /// floor would not cover even that many. Three is the smallest count that cannot be reached by one
    /// unlucky request plus one retry.
    public static let glyphAfterAttempts: Double = 3

    /// Failures must run **longer than** this before the menu bar drops to the bare ⚠️.
    ///
    /// **Why this is not a constant.** A wall-clock threshold silently means different things at
    /// different cadences, and the cadence varies by a factor of five (`PollingEngine`, ADR-0032):
    /// 180 s while a Claude Code session is running, but **900 s** while none is — which is exactly the
    /// 15-minute floor. At that cadence a flat 15 min would raise the ⚠️ after a *single* missed poll,
    /// on a machine that is merely idle. Scaling by the interval keeps the promise the number is
    /// meant to make ("we tried, repeatedly, and could not get data") true at any cadence.
    ///
    /// So: the floor, or three attempts' worth of the current interval, whichever is longer — 15 min
    /// during an active session, 45 min while idle.
    public static func glyphAfter(for health: UsageHealth) -> TimeInterval {
        max(glyphAfterFloor, glyphAfterAttempts * health.pollInterval)
    }

    // MARK: derived state

    /// Whether a failure is currently in progress — the popup warns the moment this is true,
    /// regardless of the menu-bar thresholds (SPEC: "за будь-якої непрацюючої авторизації … одразу").
    ///
    /// Never true while ``notPolling``: not asking is not failing.
    public var isFailing: Bool { failingSince != nil }

    /// Whether usage data is being collected at all — the guard for every consumer that treats
    /// "not failing" as "we have fresh data" (#341).
    ///
    /// The pair `!isFailing && notPolling` is a state that did not exist before this flag, and it is
    /// what silently breaks the naive `guard !isFailing` sites: they read "healthy" and act on a
    /// snapshot that is no longer being refreshed. Prefer this predicate over `!isFailing` wherever
    /// the answer sought is "is the usage data live".
    public var isCollectingUsage: Bool { !notPolling }

    /// Whether the usage data on hand is fresh enough to act on: we are polling **and** not failing.
    /// The condition the back-to-work and extra-usage edge detectors need — both fire on a
    /// transition, and a frozen snapshot must not keep re-triggering one.
    public var hasLiveUsageData: Bool { !notPolling && !isFailing }

    /// How long the current failure run has lasted at `now`, or `nil` when healthy. Clamped `≥ 0`
    /// so a `failingSince` slightly in the future (clock skew) never yields a negative age.
    ///
    /// - Parameter now: the current instant (injected for tests; never call `Date()` here).
    public func failureAge(now: Date) -> TimeInterval? {
        guard let failingSince else { return nil }
        return max(0, now.timeIntervalSince(failingSince))
    }
}
