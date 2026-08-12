import Foundation
import TokenPaceKit

/// The `color-cycle` verification stub (ADR-0070): walks the 5-hour bar and one service dot through
/// the whole pacing palette so a maintainer can watch every colour transition live.
///
/// **Why this needs its own driver.** The obvious way to change a bar's colour is to change its
/// usage — but the poll cadence has a hard 60 s floor (`PollingEngine.minInterval`, guarded by its
/// own tests), so data-driven colour changes are far too slow to inspect a 450 ms fade. Instead the
/// app delegate steps this sequence on a short timer and overlays each step on the retained
/// snapshot, exactly as the optimistic-reset path already does. No usage API is involved at all.
///
/// **Why the geometry is frozen.** Walking the colours by moving `utilization` also moves the
/// coloured strip's length and the time marker, so the eye can't tell a colour transition from a
/// geometry jump. Under this stub the strip is pinned at half the track and the marker is hidden
/// (`StatusItemView.frozenStripFraction` / `PopupBarView.frozenStripFraction`), leaving colour as
/// the only thing in motion.
enum ColorCycleStub {

    /// How long each colour is held. Comfortably longer than the transition itself
    /// (``ColorTween/defaultDuration``), so each step reads as *fade, then settle* rather than a
    /// continuous crossfade that never rests.
    static let stepInterval: TimeInterval = 5

    /// The fraction of the track the coloured strip is pinned to while this stub runs.
    static let stripFraction: Double = 0.5

    /// The palette walk: up through the pacing zones and back down, so both directions of every
    /// adjacent transition get seen (green→yellow *and* yellow→green). The endpoints are not
    /// repeated, so the cycle turns around cleanly instead of pausing 10 s on red.
    static let zones: [PacingBucket] = [.blue, .green, .yellow, .orange, .red, .orange, .yellow, .green]

    /// The service-status walk, stepped alongside the colours so the dot exercises its own palette
    /// (yellow → orange → red → blue → grey). Length is deliberately coprime-ish with ``zones`` so
    /// the two do not lock into the same repeating pair.
    static let statuses: [ServiceStatus] = [
        .degraded, .partialOutage, .majorOutage, .underMaintenance, .unknown,
    ]

    /// The 5-hour window utilisation that renders as `zone`, given how much of the window has
    /// elapsed (`timeFraction`).
    ///
    /// The bar colour is a function of the *gap* between usage and elapsed time, so each zone is
    /// produced by placing usage a chosen distance from the time line — see `PacingBucket.of`:
    /// - `.red` — at the cap (`>= 1`), which wins regardless of pacing;
    /// - `.orange` — ahead by at least the dynamic ahead-threshold;
    /// - `.yellow` — ahead, but by less than it;
    /// - `.green` — behind, but within the behind-threshold;
    /// - `.blue` — behind by more than it.
    ///
    /// Values are nudged to sit clearly inside each band rather than on its boundary, so a small
    /// drift in `timeFraction` between steps can't tip a zone into its neighbour.
    static func utilization(for zone: PacingBucket, timeFraction: Double,
                            windowDurationSeconds: Int) -> Double {
        let ahead = PacingModel.aheadThreshold(timeFraction: timeFraction)
        let behind = PacingModel.behindThreshold(windowDurationSeconds: windowDurationSeconds)

        let fraction: Double
        switch zone {
        case .red:
            fraction = 1.0
        case .orange:
            fraction = timeFraction + ahead * 1.5
        case .yellow:
            fraction = timeFraction + ahead * 0.4
        case .green:
            fraction = timeFraction - behind * 0.4
        case .blue:
            fraction = timeFraction - behind * 1.6
        }
        // Keep it a legal utilisation, and keep the non-red zones off the cap (which would read red).
        let capped = zone == .red ? 1.0 : min(0.97, fraction)
        return max(0, capped) * 100
    }
}
