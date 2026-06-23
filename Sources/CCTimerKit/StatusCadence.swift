import Foundation

/// The polite polling cadence for the Claude status page — a pure decision seam, no clock, no I/O
/// (ADR-0013).
///
/// The status loop does **not** run its own timer. Instead it rides the usage poll: each usage
/// `PollOutput` already carries the current usage interval, and the status loop reuses it so the
/// two sources settle together (when the user is idle and the usage cadence stretches to the 30-min
/// inactive interval, status polling stretches with it — fewer requests to a third-party page).
///
/// Crucially it never polls the status page **faster** than ``floor``: the usage interval can drop
/// to 60 s (or thrash under 429 backoff), but the status page is a secondary, third-party source
/// that changes rarely, so a hard politeness floor protects it from the usage cadence's spikes.
/// This is the "separate, polite interval — do not just copy the usage cadence" requirement of the
/// ticket, expressed as `max(floor, usageInterval)`.
public enum StatusCadence {
    /// The minimum gap between status polls **when everything is operational**, regardless of how
    /// fast the usage poll is running. 5 minutes — polite to a third-party status page, while still
    /// surfacing an outage within a coffee break.
    public static let floor: TimeInterval = 5 * 60

    /// The minimum gap **while a problem is in progress** — our general fast floor (60 s, matching
    /// `PollingEngine.minInterval`). Once any component is non-operational the page is worth watching
    /// closely: an outage resolves or escalates on the minute scale, so we drop the polite 5-min
    /// floor to catch the change (and the recovery) quickly. Still never faster than the usage tick.
    public static let problemFloor: TimeInterval = 60

    /// The interval to wait before the next status poll: the usage interval, but never below the
    /// applicable floor. Follows the usage cadence when it is slow (idle/inactive), clamps it when it
    /// is fast (active polling, 429 backoff). When `hasProblem`, the much smaller ``problemFloor``
    /// applies, so during an incident status polling tracks the usage cadence down to ~60 s.
    public static func interval(usageInterval: TimeInterval, hasProblem: Bool = false) -> TimeInterval {
        max(hasProblem ? problemFloor : floor, usageInterval)
    }

    /// Whether a status poll is due at `now`, given when the last one succeeded, the current usage
    /// interval, and whether the last known status has a problem. `nil` last-success (cold start) is
    /// always due. Lets the status loop hang off the usage poll's heartbeat (it fires far more often
    /// than the floor) while honouring the applicable floor — the loop asks this on each usage tick
    /// and only fetches when it returns `true`.
    ///
    /// - Parameters:
    ///   - lastSuccess: Instant of the last successful status poll, or `nil` if none yet.
    ///   - usageInterval: The current usage polling interval (`PollOutput.interval`).
    ///   - hasProblem: Whether the last known status has any non-operational component → poll faster.
    ///   - now: Current instant — inject for deterministic tests; never call `Date()` here.
    public static func isDue(
        lastSuccess: Date?, usageInterval: TimeInterval, hasProblem: Bool = false, now: Date
    ) -> Bool {
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= interval(usageInterval: usageInterval, hasProblem: hasProblem)
    }
}
