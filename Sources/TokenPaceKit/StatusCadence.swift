import Foundation

/// The polite polling cadence for a service status page — a pure decision seam, no clock, no I/O
/// (ADR-0013, revised by ADR-0119).
///
/// ## The status loop owns its own heartbeat
/// It did not always. Until ADR-0119 the status poll had no timer and rode the usage tick: it was
/// evaluated once per `PollOutput`, and this type **required** the current usage interval to decide
/// anything. That worked while there was exactly one status page sitting next to a usage poll that
/// was always running — and stopped working the moment a source has status and **no** usage poll to
/// ride (there is no heartbeat to borrow), or the usage poll is switched off entirely
/// (`servicesOnly`, #341), where the heartbeat became whatever the idle usage loop happened to tick
/// at.
///
/// So the loop now runs on its own `PollScheduler` and this type answers the question it was always
/// really answering: **how long to wait before the next status poll**. The usage interval survives
/// only as an *optional* input, and only in the direction that is polite — it can **slow status
/// polling down** (when the user is idle and the usage cadence has stretched to 30 min, there is no
/// reason for the status page to keep being asked at the floor), never speed it up. With no usage
/// tick to consider, `interval` collapses to the applicable floor, which is exactly the standalone
/// cadence a lone status source should have.
///
/// ## Two floors, and a hold above them both
/// The floors are the politeness contract with a third-party page: ``floor`` (5 min) normally,
/// ``problemFloor`` (60 s) while *that source* has a problem in progress. The problem flag is passed
/// **in**, per source — never read from a shared, flattened health value — because one provider's
/// incident must not accelerate polling of another provider's page (ADR-0119 §3c; #454 adds the
/// second source).
///
/// Above both floors sits the 429 hold: ``nextInterval(backoff:usageInterval:hasProblem:)`` gives an
/// active ``PollingBackoff`` hold absolute priority, mirroring the usage loop's
/// `429 hold > idle > base` ordering. A page that has told us to back off outranks our own opinion
/// about how interesting it currently is.
public enum StatusCadence {
    /// The minimum gap between status polls **when everything is operational**. 5 minutes — polite to
    /// a third-party status page, while still surfacing an outage within a coffee break.
    public static let floor: TimeInterval = 5 * 60

    /// The minimum gap **while a problem is in progress** — our general fast floor (60 s, matching
    /// `PollingEngine.minInterval`). Once a monitored component is non-operational the page is worth
    /// watching closely: an outage resolves or escalates on the minute scale, so we drop the polite
    /// 5-min floor to catch the change (and the recovery) quickly.
    public static let problemFloor: TimeInterval = 60

    /// The interval to wait before the next status poll: the applicable floor, stretched to the usage
    /// interval when that is slower.
    ///
    /// - Parameters:
    ///   - usageInterval: The current usage polling interval, when there is a usage poll worth
    ///     settling with; `nil` (the standalone case) leaves the floor alone.
    ///   - hasProblem: Whether **this source's** last known status has a non-operational component →
    ///     use ``problemFloor`` instead of ``floor``.
    public static func interval(
        usageInterval: TimeInterval? = nil, hasProblem: Bool = false
    ) -> TimeInterval {
        max(hasProblem ? problemFloor : floor, usageInterval ?? 0)
    }

    /// The full next-poll interval including the 429 hold — the value the status loop actually waits.
    ///
    /// An active hold wins outright over any floor: the server named a number, and honouring it is
    /// the whole point of reading `Retry-After`. With no hold this is just
    /// ``interval(usageInterval:hasProblem:)``.
    ///
    /// - Parameters:
    ///   - backoff: **This source's** backoff. One instance per status source, never shared — a 429
    ///     from one page must leave every other page's cadence untouched.
    ///   - usageInterval: As in ``interval(usageInterval:hasProblem:)``.
    ///   - hasProblem: As in ``interval(usageInterval:hasProblem:)`` — this source's own problem
    ///     signal, not a flattened one.
    public static func nextInterval(
        backoff: PollingBackoff, usageInterval: TimeInterval? = nil, hasProblem: Bool = false
    ) -> TimeInterval {
        if backoff.isHolding { return backoff.interval }
        return interval(usageInterval: usageInterval, hasProblem: hasProblem)
    }

    /// Whether a status poll is due at `now`, given when the last one succeeded. `nil` last-success
    /// (cold start) is always due.
    ///
    /// The loop's scheduler already waits the interval, so this is the second gate: it also guards the
    /// off-schedule wake-ups (`.wake`, `.networkRestored`, and the usage tick that still calls in) from
    /// turning into extra requests against a third-party page.
    ///
    /// - Parameters:
    ///   - lastSuccess: Instant of the last successful status poll, or `nil` if none yet.
    ///   - backoff: This source's 429 backoff — an active hold raises the bar above the floor.
    ///   - usageInterval: The current usage polling interval, or `nil` when standing alone.
    ///   - hasProblem: Whether this source's last known status has any non-operational component.
    ///   - now: Current instant — inject for deterministic tests; never call `Date()` here.
    public static func isDue(
        lastSuccess: Date?,
        backoff: PollingBackoff = PollingBackoff(),
        usageInterval: TimeInterval? = nil,
        hasProblem: Bool = false,
        now: Date
    ) -> Bool {
        guard let lastSuccess else { return true }
        let wait = nextInterval(
            backoff: backoff, usageInterval: usageInterval, hasProblem: hasProblem)
        return now.timeIntervalSince(lastSuccess) >= wait
    }
}
