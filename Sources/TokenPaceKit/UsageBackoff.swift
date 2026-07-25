import Foundation

// MARK: - UsageError

/// Distinguishable failure causes of one usage poll.
///
/// `throws` + a typed `enum` (not `Result`), matching ``TokenError`` and ADR-0007:
/// the project is async, so this composes naturally with `async throws`. Each case
/// drives a different reaction in the polling layer (#13) — `rateLimited` advances the
/// backoff, `http`/`transport` keep the cadence and show stale data, `missingUserAgent`
/// is a programmer error that must never reach the network.
///
/// Carried payloads are `.public`-safe diagnostics only (a status code, an interval, a
/// transport description) — the bearer token is never part of an error.
public enum UsageError: Error, Equatable {
    /// The `User-Agent` would be empty — the request is **not** sent (issue #9
    /// acceptance: "Без `User-Agent` — НЕ ходити"). Without it the API drops the client
    /// into an aggressively rate-limited bucket and returns constant 429s.
    case missingUserAgent
    /// Transport-level failure (no connectivity, DNS, TLS, cancellation). `message` is a
    /// `.public`-safe description and never carries the token; `code` is the underlying
    /// `URLError.Code` when the failure was a `URLError` (else `nil`), so the error UI can
    /// distinguish a timeout from a DNS failure precisely instead of parsing the message
    /// string (issue #12). `URLError.Code` is `Sendable`/`Equatable`, so this stays both.
    case transport(message: String, code: URLError.Code?)
    /// The response was not an `HTTPURLResponse`.
    case nonHTTPResponse
    /// HTTP 429. Carries the parsed `Retry-After` seconds when the server sent them, so
    /// the backoff layer can honor a hint longer than its own schedule; `nil` → use the
    /// schedule's next step.
    case rateLimited(retryAfter: TimeInterval?)
    /// Any other non-2xx status (401 / 403 / 5xx). Carries the `.public`-safe status code
    /// and the response `body` (when present) so the error UI can surface the server's own
    /// message — e.g. the popup shows "Auth error (HTTP 401)" on one line and the body text
    /// on the next (issue #12). The body is plain text, truncated, and never carries the
    /// bearer token (it is the *response*, not the request).
    case http(status: Int, body: String?)
    /// The 200 body decoded as non-JSON, or a required window (`five_hour`/`seven_day`)
    /// was missing.
    case decode
}

// MARK: - PollingBackoff

/// Pure, value-type hold for the 429 rate-limit response.
///
/// SPEC "Частота оновлення" (revised, ADR-0032): poll every **180 s** by default; on a 429 wait
/// exactly the server's `Retry-After` (or 180 s when it is absent), then **hold** at that one
/// interval — a repeat 429 just re-sets the same hold, it does **not** escalate. The first 200
/// clears the hold and returns to the 180 s base.
///
/// This replaces the earlier escalating `3 → 6 → 12 → 15 min` schedule: the app now trusts the
/// server's own hint instead of inventing its own back-pressure curve. The type owns **no timer**
/// and never sleeps — like ``PacingModel``, every transition is deterministic and side-effect-free.
/// The polling loop (#13) owns the clock: it reads ``interval`` to schedule the next wake, calls
/// ``honoring(retryAfter:)`` on a 429, and ``reset()`` on a 200. Splitting the pure hold out of the
/// timer is the boundary decision recorded in ADR-0008; it keeps the logic fully unit-testable.
public struct PollingBackoff: Sendable, Equatable {

    /// The healthy cadence — 180 s (SPEC). Used whenever not holding, and as the fallback hold when a
    /// 429 arrives without a usable `Retry-After`.
    public static let defaultInterval: TimeInterval = 180

    /// The interval to hold at while rate-limited: the honored `Retry-After` (or ``defaultInterval``).
    /// `nil` means healthy — no active hold, use ``defaultInterval``.
    public private(set) var heldInterval: TimeInterval?

    /// A fresh, healthy backoff (180 s cadence, no hold).
    public init() {
        self.heldInterval = nil
    }

    /// Whether a 429 hold is currently active (the engine's top interval priority).
    public var isHolding: Bool { heldInterval != nil }

    /// The interval the caller should wait before the next poll: the active hold when rate-limited,
    /// otherwise ``defaultInterval``.
    public var interval: TimeInterval {
        heldInterval ?? Self.defaultInterval
    }

    /// Enter (or refresh) the 429 hold, honoring the server's `Retry-After` seconds. A `nil` or
    /// non-positive hint falls back to ``defaultInterval`` (180 s). A repeat 429 simply re-sets the
    /// hold to the latest hint — there is **no** escalation across consecutive 429s. Returns a copy.
    public func honoring(retryAfter: TimeInterval?) -> PollingBackoff {
        var copy = self
        if let retryAfter, retryAfter > 0 {
            copy.heldInterval = retryAfter
        } else {
            copy.heldInterval = Self.defaultInterval
        }
        return copy
    }

    /// Reset to the healthy 180 s cadence after a successful 200 (clears any hold). Returns a copy.
    public func reset() -> PollingBackoff {
        var copy = self
        copy.heldInterval = nil
        return copy
    }
}
