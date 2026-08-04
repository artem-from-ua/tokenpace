import Foundation

// MARK: - JournalGap

/// Decides when a sampling gap is large enough to warrant a ``ResumeMarker`` — so a reader can tell
/// "nothing happened" (a genuine quiet stretch inside the expected cadence) from "we weren't
/// polling" (app quit, Mac asleep, screen-lock pause) and never interpolate across the latter.
///
/// Pure and clock-free: the caller passes the previous poll instant, the current one, and the
/// interval it expected between them.
public enum JournalGap {
    /// Multiplier on the expected interval past which a gap counts as a real hole. A little slack (the
    /// poll cadence jitters, and a single skipped tick is normal) so a marker means a genuine outage,
    /// not routine variance. 2× the expected interval: one missed poll is fine, two is a gap.
    public static let gapThresholdMultiplier: Double = 2

    /// A resume marker when `now - previous` exceeds `expectedInterval × gapThresholdMultiplier`, else
    /// `nil`. `previous == nil` (cold start / first poll after relaunch) yields `nil` — there is no
    /// prior instant to measure a gap from, and the first line already anchors the series.
    ///
    /// - Parameters:
    ///   - previous: The last poll instant written to this file, or `nil` if none yet.
    ///   - now: The current poll instant.
    ///   - expectedInterval: The cadence the caller expected (e.g. the poll's effective interval).
    public static func marker(previous: Date?, now: Date, expectedInterval: TimeInterval) -> ResumeMarker? {
        guard let previous else { return nil }
        let gap = now.timeIntervalSince(previous)
        guard expectedInterval > 0, gap > expectedInterval * gapThresholdMultiplier else { return nil }
        return ResumeMarker(t: ResetClock.isoString(from: now), gap: gap)
    }
}
