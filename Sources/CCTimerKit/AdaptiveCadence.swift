import Foundation

/// Content-driven polling cadence — the *second*, independent interval dimension alongside
/// ``PollingBackoff`` (which reacts to HTTP 429). Where the backoff escalates on server
/// rate-limiting, this escalates on **the data not changing**: when two adjacent successful
/// snapshots carry the same utilisation, polling slows down (no point asking again so soon);
/// when the utilisation moves, it snaps back to the fastest cadence to track the change closely.
///
/// Pure value-type state machine, no clock and no I/O — the polling layer (#13) reads ``interval``
/// to schedule the next wake, and calls ``unchanged()`` / ``changed()`` after each successful poll.
/// Mirrors ``PollingBackoff``: deterministic transitions, unit-tested in isolation.
///
/// The escalation schedule is **the same** as the 429 backoff — `3 → 6 → 12 → 15 min`, held at the
/// 15-min ceiling — so an idle-but-active session settles to the same gentle 15-min rhythm whether
/// it got there by repeated 429s or by repeatedly seeing no change. Steps are stored **in seconds**;
/// the `* 60` factor is load-bearing and guarded by `stepsAreInSeconds` in the tests.
///
/// Priority among the dimensions lives in ``PollingEngine`` (429 backoff > Claude-inactive 30-min
/// override > this adaptive cadence); this type only owns the "how unchanged data slows polling" rule.
public struct AdaptiveCadence: Sendable, Equatable {

    /// The doubling schedule, **in seconds**: 3, 6, 12, 15 min → `[180, 360, 720, 900]`. The first
    /// value (180 s) is the floor a `changed()` snaps back to; the last (900 s) is the ceiling held
    /// once reached. Shares the shape of ``PollingBackoff/steps`` deliberately — same gentle rhythm.
    public static let steps: [TimeInterval] = [3 * 60, 6 * 60, 12 * 60, 15 * 60]

    /// Index into ``steps``. Starts at `0` (the 180 s floor) and climbs on `unchanged()`, held at
    /// `steps.count - 1` once the ceiling is reached; `changed()` resets it to `0`.
    public private(set) var level: Int

    /// A fresh cadence at the fastest (180 s) rhythm — the right state on cold start and right after
    /// any observed change.
    public init() {
        self.level = 0
    }

    /// The interval the caller should wait before the next poll: `steps[level]`, clamped to the
    /// ceiling so an over-climbed level can never index out of bounds.
    public var interval: TimeInterval {
        Self.steps[min(level, Self.steps.count - 1)]
    }

    /// Two adjacent successful snapshots were identical → slow down one step (double the interval),
    /// holding at the 15-min ceiling. Returns a copy.
    public func unchanged() -> AdaptiveCadence {
        var copy = self
        copy.level = min(level + 1, Self.steps.count - 1)
        return copy
    }

    /// The snapshot moved since the previous successful poll → snap back to the 180 s floor to track
    /// the change closely. Returns a copy.
    public func changed() -> AdaptiveCadence {
        var copy = self
        copy.level = 0
        return copy
    }
}
