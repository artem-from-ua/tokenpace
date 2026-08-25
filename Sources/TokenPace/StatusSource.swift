import Foundation
import TokenPaceKit

/// One status source's mutable slots, held together so a source is added by declaring one property
/// rather than five (ADR-0119 gives each source its own cadence, hold and markers — this is where
/// that per-source state lives).
///
/// Kept as a plain `struct` on `AppDelegate` rather than a class: every field is already read and
/// written on the main actor, and value semantics mean a source cannot accidentally alias another's
/// hold — the cross-contamination ADR-0119 §2 exists to prevent.
@MainActor
struct StatusSourceState {
    /// This source's mapped health, or `nil` until its first poll lands. Merged with the other
    /// sources' at render time, never in place.
    var health: StatusHealth?
    /// Instant of the last **successful** poll, driving `StatusCadence.isDue`. A failed poll does not
    /// advance it. Stamped with `currentDate()` so a time-mocking stub renders a sane age.
    var lastSuccess: Date?
    /// This source's incidents. A failed poll leaves them alone — an unreachable status page is not
    /// evidence an incident ended.
    var incidents: [VisibleIncident] = []
    /// This source's **own** 429 hold, never shared: hold at exactly `Retry-After` (or 180 s), no
    /// escalation, first 200 clears it.
    var backoff = PollingBackoff()
    /// The in-flight fetch, held so a new tick cancels a slow one rather than overlapping.
    var task: Task<Void, Never>?
    /// This source's heartbeat, on its own `SignalHub` subscription. Cancelled on terminate.
    var loopTask: Task<Void, Never>?

    /// Drop everything the popup would draw for this source, for when its switch goes off. Returns
    /// whether anything was actually there — the caller re-renders only then, so a poll against an
    /// already-off source does not churn the widget.
    mutating func clearIfPresent() -> Bool {
        guard health != nil || !incidents.isEmpty else { return false }
        health = nil
        lastSuccess = nil
        incidents = []
        return true
    }

    /// Make the next poll fetch rather than wait: the cadence gate measures from the last success, so
    /// clearing it is what "poll now" means, and a live hold would otherwise outrank the request.
    mutating func makeDue() {
        lastSuccess = nil
        backoff = backoff.reset()
    }

    func cancelAll() {
        task?.cancel()
        loopTask?.cancel()
    }
}

/// What one status fetch produced — the only step the three sources genuinely differ in, and so the
/// only thing their shared driver asks them for.
///
/// `rateLimited` is a double optional on purpose: the outer `nil` means "not rate limited at all",
/// the inner one means "429 with no usable `Retry-After`", which `PollingBackoff` answers with its
/// 180 s default. Collapsing them would lose the difference between a page that never complained and
/// one that complained without a number.
struct StatusFetchOutcome {
    var health: StatusHealth
    var succeeded = false
    var incidents: [VisibleIncident] = []
    var rateLimited: TimeInterval??
    /// The summary a successful fetch decoded, for the callers that journal it. `nil` on failure.
    var summary: StatusSummary?
    /// The raw response body, for the dev payload log. Only Claude's fetch keeps it — the others
    /// decode and discard, so nothing holds a second copy of a page nobody reads back.
    var body: Data?
    /// Whether a source that fetches two documents got the second one. `false` is the degraded run:
    /// the statuses stand, the rows the second document would have filled are absent — which must
    /// stay distinguishable from "the second document was empty".
    var secondaryFetched = false
}
