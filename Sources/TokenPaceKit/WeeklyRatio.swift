import Foundation

// MARK: - WeeklyRatio

/// The running estimate of **N** — how many five-hour percentage points buy one seven-day point
/// (#386). The translation constant that lets the weekly scale be read through the five-hour
/// counter, which is quantised 33.6× more finely.
///
/// ## Why an estimate rather than a constant
///
/// N is a property of the **plan**, not of the app: it moves with the tier, the model mix, and
/// Anthropic's temporary promotions (observed: *"your weekly Claude Code limit is 50 % higher
/// through August 19"*). Crucially, `GET /api/oauth/usage` carries **no field** announcing any of
/// that — measured over 4 327 journal records, `tier` never changed once. So a shifted N is the
/// *only* observable trace of a changed exchange rate, which is why this type estimates rather
/// than hard-codes (see `docs/reference/users-and-goals.md` § "Співвідношення квот між вікнами").
///
/// ## Why the median
///
/// **Both** counters are integer-quantised, so a single segment's ratio carries ±0.5 pp of error
/// in its denominator — ±50 % when the step is 1. Measured on two independent journals: individual
/// `localN` values scatter over **3–24** (Max 5x) and **4–30** (Pro), and a rolling *mean* wanders
/// 8.4–11.7 — while the rolling **median holds 10.0** on both. The median is the only one of the
/// three estimators that survives that noise; a least-squares fit and a sum-over-sum are both
/// dragged by the tails.
///
/// A sum-over-sum is also **not rolling**: it answers with the inertia of the whole history, so a
/// promotion would take days to show. A 15-segment window forgets a stale rate after ≈15 weekly
/// ticks ≈ 25 h of active work, which is the scale a tier change actually happens on.
///
/// ## The seed
///
/// With no segments yet the estimate is ``seed`` (10.0) — a **measured** value, not a guess: the
/// median came out at exactly 10.0 on *both* a Max 5x and a Pro journal, i.e. plans scale both
/// windows proportionally. It matters only for the first few polls: an ablation with the seed set
/// to 5 or 20 instead of 10 changed the reconstructed value by a mean of **0.000 pp** on both
/// series, because the first real segments displace it within ≈15 polls (≈0.8 h of work).
///
/// Deliberately **no confidence tiers**. An earlier design gated the reconstruction behind "at
/// least N segments"; measurement showed the gate bought nothing (the always-on variant had *fewer*
/// ceiling clips — 4.5 % vs 7.2 %) while costing up to 20 h of the feature being off after a
/// relaunch. See ``WeeklyInterpolator`` for what happens before any segment exists.
public struct WeeklyRatio: Sendable, Equatable, Codable {

    // MARK: constants

    /// How many segments the rolling window keeps. 15 weekly ticks ≈ 25 h of active work — long
    /// enough to average out the ±50 % per-segment quantisation noise, short enough to forget a
    /// retired promotion. Ablation: `K = 5` adds ≈0.05 pp of jitter, `K = 40` is indistinguishable
    /// from 15, so the exact value is not critical — only the order of magnitude is.
    public static let window = 15

    /// The estimate used until the first segment closes: **10.0**, measured as the median on both a
    /// Max 5x and a Pro journal. Never the answer for long — the first real segment displaces it.
    public static let seed: Double = 10.0

    /// The band a single segment's ratio must fall in to be trusted. Outside `[3, 40]` the segment
    /// is not describing a tier — it is describing corrupt or pathological data (a missed quantum,
    /// a torn record). Wide on purpose: a genuine promotion moves N by tens of percent, not by 4×.
    static let plausible: ClosedRange<Double> = 3...40

    /// The largest weekly jump a segment may close on. A jump of 3 pp or more means we slept
    /// through several quanta, so the denominator is a lie and the segment says nothing about N.
    static let maxSegmentJump: Double = 2

    // MARK: state

    /// The rolling window of per-segment ratios, oldest first, capped at ``window``. Kept as raw
    /// ratios (not a running median) so the window can be re-medianed after any edit and so a
    /// `Codable` round-trip restores the estimator exactly.
    public private(set) var segments: [Double]

    public init(segments: [Double] = []) {
        self.segments = Array(segments.suffix(Self.window))
    }

    // MARK: estimate

    /// The current exchange rate: the median of the window, or ``seed`` while the window is empty.
    ///
    /// Never `nil` — the reconstruction is always on, and a seeded estimate is strictly better than
    /// showing a quantised value (the seed carries the same 0.5 pp error bound the raw value
    /// already has, but the value stops standing still).
    public var estimate: Double {
        guard !segments.isEmpty else { return Self.seed }
        let sorted = segments.sorted()
        let mid = sorted.count / 2
        // Even counts average the two middle values; odd counts take the centre. The average keeps
        // the estimate from stepping between two adjacent samples as the window slides.
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// How many segments back the estimate — surfaced in Troubleshoot and the journal so a reader
    /// can tell a seeded estimate from a settled one without a separate flag.
    public var sampleCount: Int { segments.count }

    // MARK: recording

    /// Fold one closed segment into the window: `fiveHourGained` points of `h5` bought
    /// `sevenDayGained` points of `d7`.
    ///
    /// The segment is **rejected** (and the window left untouched) when it cannot describe a tier:
    /// - a non-positive gain on either side — nothing was measured;
    /// - a weekly jump above ``maxSegmentJump`` — several quanta passed unobserved;
    /// - a ratio outside ``plausible`` — corrupt rather than merely noisy.
    ///
    /// Ablation note: these filters change the reconstructed value by a mean of 0.001 pp on real
    /// data. They are kept as a guard against pathology, not as an accuracy measure.
    public mutating func record(fiveHourGained: Double, sevenDayGained: Double) {
        guard fiveHourGained > 0, sevenDayGained > 0,
              sevenDayGained <= Self.maxSegmentJump else { return }
        let ratio = fiveHourGained / sevenDayGained
        guard Self.plausible.contains(ratio) else { return }
        segments.append(ratio)
        if segments.count > Self.window { segments.removeFirst(segments.count - Self.window) }
    }
}
