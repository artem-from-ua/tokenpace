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
    /// `.public`-safe description and never carries the token.
    case transport(String)
    /// The response was not an `HTTPURLResponse`.
    case nonHTTPResponse
    /// HTTP 429. Carries the parsed `Retry-After` seconds when the server sent them, so
    /// the backoff layer can honor a hint longer than its own schedule; `nil` → use the
    /// schedule's next step.
    case rateLimited(retryAfter: TimeInterval?)
    /// Any other non-2xx status (401 / 403 / 5xx). Carries the `.public`-safe status code.
    case http(status: Int)
    /// The 200 body decoded as non-JSON, or a required window (`five_hour`/`seven_day`)
    /// was missing.
    case decode
}

// MARK: - PollingBackoff

/// Pure, value-type state machine for the 429 backoff schedule.
///
/// SPEC "Частота оновлення": poll every **180 s** by default; on a 429 step the interval
/// `3 → 6 → 12 → 15 min`, then hold at 15 min until a success; on a 200 reset to 180 s.
///
/// This type owns **no timer** and never sleeps — like ``PacingModel``, every transition
/// is deterministic and side-effect-free. The polling loop (#13) owns the clock: it reads
/// ``interval`` to schedule the next wake, calls ``escalated()``/``escalated(retryAfter:)``
/// on a 429, and ``reset()`` on a 200. Splitting the pure schedule out of the timer is the
/// boundary decision recorded in ADR-0008; it keeps the schedule fully unit-testable
/// (issue #9 acceptance: "Backoff працює (unit-тест на логіку інтервалів)").
public struct PollingBackoff: Sendable, Equatable {

    /// The escalating 429 steps, **in seconds**: 3, 6, 12, 15 min → `[180, 360, 720, 900]`.
    /// The minutes-to-seconds factor (`* 60`) is load-bearing — storing `[3, 6, 12, 15]`
    /// would back off by seconds, not minutes. The last value is the ceiling held until a
    /// success. `stepsAreInSeconds` guards this in the tests.
    public static let steps: [TimeInterval] = [3 * 60, 6 * 60, 12 * 60, 15 * 60]

    /// The healthy cadence — 180 s (SPEC). Used whenever not backing off.
    public static let defaultInterval: TimeInterval = 180

    /// Current escalation level: `nil` means healthy (use ``defaultInterval``); otherwise an
    /// index into ``steps``, held at `steps.count - 1` once the ceiling is reached.
    public private(set) var level: Int?

    /// A fresh, healthy backoff (180 s cadence).
    public init() {
        self.level = nil
    }

    /// The interval the caller should wait before the next poll: ``defaultInterval`` when
    /// healthy, otherwise `steps[level]` (clamped to the ceiling).
    public var interval: TimeInterval {
        guard let level else { return Self.defaultInterval }
        return Self.steps[min(level, Self.steps.count - 1)]
    }

    /// Advance one escalation step after a 429. First 429 → step 0 (3 min); subsequent 429s
    /// climb 6 → 12 → 15 min, then stay at 15 min (idempotent at the ceiling). Returns a copy.
    public func escalated() -> PollingBackoff {
        var copy = self
        switch level {
        case nil:
            copy.level = 0
        case let current?:
            copy.level = min(current + 1, Self.steps.count - 1)
        }
        return copy
    }

    /// Advance one step after a 429, honoring a server `Retry-After` hint. The resulting
    /// ``interval`` is the larger of the scheduled step and `retryAfter` — a hint longer
    /// than our schedule wins, a shorter (or absent) one is ignored in favor of the step.
    ///
    /// The hint is applied by skipping ahead to the first scheduled step that meets or
    /// exceeds it (so the state stays a plain `level` and ``reset()`` still works); if no
    /// step is long enough, the ceiling is used.
    public func escalated(retryAfter: TimeInterval?) -> PollingBackoff {
        let stepped = escalated()
        guard let retryAfter, retryAfter > stepped.interval else { return stepped }
        var copy = self
        // Jump to the first step whose interval is >= the server hint, else the ceiling.
        let target = Self.steps.firstIndex(where: { $0 >= retryAfter }) ?? (Self.steps.count - 1)
        copy.level = max(stepped.level ?? 0, target)
        return copy
    }

    /// Reset to the healthy 180 s cadence after a successful 200. Returns a copy.
    public func reset() -> PollingBackoff {
        var copy = self
        copy.level = nil
        return copy
    }
}
