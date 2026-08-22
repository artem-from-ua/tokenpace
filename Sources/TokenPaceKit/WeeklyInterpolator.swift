import Foundation

// MARK: - WeeklyInterpolator

/// Reconstructs a **continuous** seven-day utilization from the quantised one, by carrying the
/// five-hour counter's much finer steps across the weekly bucket.
///
/// The API rounds `seven_day.utilization` to a whole percent, and one point is **1 h 40 m** of work:
/// measured over 4 327 records, 96.4 % of consecutive pairs do not move at all, and ~88 % of spend
/// motion is invisible on the weekly scale. The five-hour counter is quantised the same way, but its
/// point is **3 min**, and both meter the same spend — so the weekly scale can be read through it.
///
/// ## The quantisation model
///
/// An observed integer `k` is not a value, it is an **interval**. Edge buckets are half-width,
/// because the scale is bounded at both ends:
///
/// | observed `k` | true value | width |
/// |---|---|---|
/// | `0` | `[0, 0.5)` | 0.5 |
/// | `1…99` | `[k − 0.5, k + 0.5)` | 1.0 |
/// | `100` | `[99.5, 100]` | 0.5 |
///
/// `ceil(100) == 100` is what protects every `>= 100` exhaustion detector in the app: the
/// reconstruction can never carry a value across that line (see ``WeeklyUtilization/applied(to:)``).
///
/// ## The two anchors
///
/// - **A bump was observed** (`k−1 → k` between two polls): at that instant the true value had just
///   crossed `k − 0.5`, so the anchor is that **exact lower edge**. No assumption.
/// - **The anchor was inherited** (first run, or a long break): `t₀` is unknown and the position
///   inside the bucket is not observable from any available signal. The anchor is the bucket
///   **centre** — measured on 4 295 samples with a known `t₀`, that position is uniform (median
///   0.500), so the centre minimises expected error. It is never worse than shipping the raw value,
///   which carries the same ±0.5 pp bound while standing still.
///
/// Ablation confirms this is the one choice that matters: using `k` instead of `k − 0.5` shifts the
/// result by a mean of **0.37–0.42 pp** — an order of magnitude more than any other component.
///
/// ## Monotonicity
///
/// The reconstruction can neither fall nor overtake reality, **by construction**:
///
/// - before a bump the value is clipped from above at `ceil(k)`, so `u_before ≤ k + 0.5`;
/// - after a bump to `k+1` the firm anchor is exactly `(k+1) − 0.5 = k + 0.5`;
/// - therefore `u_after ≥ u_before` always — the ceiling of one bucket and the floor of the next are
///   *the same point*, so they meet without a gap.
///
/// Verified empirically too: 0 violations over 98 599 samples across 44 cold-start offsets (Max 5x)
/// and 0 over the Pro series.
///
/// ## What limits it
///
/// Not the algorithm — the **five-hour step between polls**. Median `h5` rise per poll: +1 pp at a
/// 193 s cadence → a weekly step of 0.10 pp ≈ 10 min (≈10 positions per bucket); +5 pp at 900 s →
/// 0.50 pp ≈ 50 min (2 positions). At a slow cadence the reconstruction is twice as fine, not ten
/// times. Worth stating plainly rather than promising "10×" everywhere.
public struct WeeklyInterpolator: Sendable, Equatable, Codable {

    // MARK: - State

    /// The rolling estimate of N.
    public private(set) var ratio: WeeklyRatio
    /// The raw integer the current anchor was derived from; `nil` before the first poll. Also the
    /// desync guard: if the incoming window no longer carries this value, the accumulation belongs
    /// to a different bucket (see ``WeeklyUtilization/applied(to:)``).
    public private(set) var anchoredRaw: Double?
    /// Where the value is carried up from: the bucket's lower edge once a bump has been seen, its
    /// centre while the anchor is inherited.
    public private(set) var anchor: Double
    /// Whether ``anchor`` came from an observed bump (firm) rather than being inherited.
    public private(set) var isFirm: Bool
    /// Σ of positive five-hour gains since the anchor was set, in `h5` percentage points.
    public private(set) var fiveHourSinceAnchor: Double
    /// The highest value already shown for the current bucket — the **floor a degraded state falls
    /// back to**, never below.
    ///
    /// Without this, entering ``isDegraded`` would drop the bar from its reconstructed position
    /// (say 93.06) back to the raw quantum (93.0), i.e. the progress bar would visibly move
    /// *backwards* while spend only ever grew. Replaying the real journals caught exactly that: 8
    /// such steps on the Max 5x series, 1 on the Pro one, every single one at a `degraded`
    /// transition. Spend is monotone within a bucket, so what we already knew stays known even once
    /// we stop learning more. Cleared with the anchor.
    public private(set) var shownFloor: Double?
    /// The previous poll's five-hour utilization, for the delta rule.
    public private(set) var lastFiveHour: Double?
    /// Whether a polling hole has invalidated the current accumulation.
    public private(set) var isDegraded: Bool
    /// Recent poll intervals, for the adaptive hole threshold. Kept short — it tracks the *current*
    /// cadence, which switches between the 3-minute active and 15-minute idle rates.
    public private(set) var recentIntervals: [TimeInterval]
    /// The instant of the last folded poll, so a resumed state can tell a short break from a long one.
    public private(set) var lastPollAt: Date?

    // MARK: - Constants

    /// How many recent intervals the adaptive threshold medians over.
    static let intervalWindow = 20
    /// The fallback expected interval before enough intervals are known — the idle cadence, the
    /// conservative choice (a shorter guess would call normal slow polling a hole).
    static let fallbackInterval: TimeInterval = 900
    /// The multiplier on the expected interval above which a gap counts as a hole. The same factor
    /// ``JournalGap/gapThresholdMultiplier`` already uses, so "hole" means one thing in this codebase.
    static let holeMultiplier: Double = 2
    /// How long an accumulation survives a break in ``resumed(at:)``. Beyond this the five-hour
    /// counter has certainly reset unobserved, so the accumulation is dropped — but the ratio window
    /// is kept, because the exchange rate is a property of the plan and does not spoil while idle.
    static let accumulationTTL: TimeInterval = 6 * 3600

    // MARK: - Init

    public init(
        ratio: WeeklyRatio = WeeklyRatio(),
        anchoredRaw: Double? = nil,
        anchor: Double = 0,
        isFirm: Bool = false,
        fiveHourSinceAnchor: Double = 0,
        shownFloor: Double? = nil,
        lastFiveHour: Double? = nil,
        isDegraded: Bool = false,
        recentIntervals: [TimeInterval] = [],
        lastPollAt: Date? = nil
    ) {
        self.ratio = ratio
        self.anchoredRaw = anchoredRaw
        self.anchor = anchor
        self.isFirm = isFirm
        self.fiveHourSinceAnchor = fiveHourSinceAnchor
        self.shownFloor = shownFloor
        self.lastFiveHour = lastFiveHour
        self.isDegraded = isDegraded
        self.recentIntervals = recentIntervals
        self.lastPollAt = lastPollAt
    }

    // MARK: - Bucket geometry

    /// The lower edge of the bucket an observed `k` denotes — `0` for `k == 0` (the scale is bounded
    /// below), `k − 0.5` otherwise.
    static func floor(of k: Double) -> Double { k <= 0 ? 0 : k - 0.5 }

    /// The upper edge — `100` for `k == 100` (bounded above, and the invariant that protects every
    /// `>= 100` detector), `k + 0.5` otherwise.
    static func ceiling(of k: Double) -> Double { k >= 100 ? 100 : k + 0.5 }

    /// The centre of the bucket: the best guess when the crossing instant is unknown. Half-width at
    /// the edges (`0.25` for `k == 0`, `99.75` for `k == 100`).
    static func centre(of k: Double) -> Double { (floor(of: k) + ceiling(of: k)) / 2 }

    // MARK: - Folding a poll

    /// Fold one successful poll in, returning the advanced state. Pure — `now` is injected, no clock
    /// is read here (ADR-0009).
    ///
    /// The five-hour delta rule, in order:
    /// - **rose or held** → the difference is real spend;
    /// - **fell on a fresh poll** (gap within the hole threshold) → the counter reset between the two
    ///   polls, so the *new* value is the spend that happened after that reset. Credited in full;
    /// - **fell across a hole** → the gap may hide more than one reset, so the movement is
    ///   unrecoverable: nothing is credited and the state degrades.
    ///
    /// Weekly transitions:
    /// - **rose** → the segment closes (its ratio feeds ``WeeklyRatio``) and the anchor becomes firm
    ///   at the new bucket's lower edge;
    /// - **fell** (a reset, scheduled or not) → the anchor moves and the accumulation clears, but the
    ///   ratio window is **kept**: the tier did not change because the week turned over.
    public func advanced(with snapshot: UsageSnapshot, now: Date) -> WeeklyInterpolator {
        var next = self
        let five = snapshot.fiveHour.utilization
        let weekly = snapshot.sevenDay.utilization

        guard let previousFive = lastFiveHour, let previousAt = lastPollAt else {
            // First poll of this state: nothing to compare against, so the anchor is inherited.
            next.anchoredRaw = weekly
            next.anchor = Self.centre(of: weekly)
            next.isFirm = false
            next.fiveHourSinceAnchor = 0
            next.shownFloor = nil
            next.isDegraded = false
            next.lastFiveHour = five
            next.lastPollAt = now
            return next
        }

        let gap = now.timeIntervalSince(previousAt)
        let expected = Self.expectedInterval(from: recentIntervals)
        let isHole = gap > Self.holeMultiplier * expected
        next.recentIntervals = Array((recentIntervals + [gap]).suffix(Self.intervalWindow))

        // Five-hour delta.
        //
        // A hole damages the *accumulation*, not the ability to keep measuring: the counter may have
        // risen and reset unobserved, so that stretch of spend is lost for good. What follows is
        // measurable again from the next poll on. So `isDegraded` marks the poll where trust broke —
        // it does not latch across subsequent polls. The lost spend still shows up as a low
        // reconstruction, which the ceiling clip then absorbs at the next bump.
        next.isDegraded = isHole
        if five >= previousFive {
            next.fiveHourSinceAnchor += five - previousFive
        } else if !isHole {
            // The counter fell on a fresh poll. The intended reading is "it reset between the two
            // polls, so the new value is spend that happened after the reset" — true when the drop
            // lands near zero, which is what a real reset looks like (measured: median 0, p90 2).
            //
            // But a drop is not proof of a reset. The same journal holds `49 → 42`, `67 → 21` and
            // `53 → 51` minutes apart — the server lowering its own counter, not 42 points of spend
            // in three minutes. Crediting the new value there invents work that never happened, and
            // a wrapping counter (99 → 0 → 1) hands over its whole value on every lap.
            //
            // So the credit is capped at what the five-hour window could physically have burned in
            // the elapsed gap. Near-zero post-reset values — the overwhelming majority — pass
            // untouched; the three server-side reductions above are cut to the honest few points.
            next.fiveHourSinceAnchor += min(five, Self.maxCreditableSpend(over: gap))
        }

        // Weekly transition.
        let previousWeekly = anchoredRaw ?? weekly
        if weekly > previousWeekly {
            if !isHole {
                next.ratio.record(fiveHourGained: next.fiveHourSinceAnchor,
                                  sevenDayGained: weekly - previousWeekly)
            }
            next.fiveHourSinceAnchor = 0
            next.anchor = Self.floor(of: weekly)
            next.isFirm = true
            next.isDegraded = false
            next.shownFloor = nil          // a new bucket starts its own floor
        } else if weekly < previousWeekly {
            // A reset — scheduled or not. Same handling either way: the reconstruction needs the
            // *fact* of the break, not its cause. The ratio window survives on purpose.
            next.fiveHourSinceAnchor = 0
            next.anchor = Self.floor(of: weekly)
            next.isFirm = true
            next.isDegraded = false
            next.shownFloor = nil          // the value must be free to fall on a reset
        }

        next.anchoredRaw = weekly
        next.lastFiveHour = five
        next.lastPollAt = now
        // Remember what the *reconstruction* would show, so a later degradation cannot walk the bar
        // backwards. Deliberately **not** raised by the degraded fallback itself: that value is the
        // raw quantum, and letting it set the floor would pin the bar above the honest estimate
        // once measurement resumes — the reconstruction would then have to fall to catch up with
        // reality, which is the very step this floor exists to prevent.
        if !next.isDegraded { next.shownFloor = max(next.shownFloor ?? 0, next.reconstructed(forRaw: weekly)) }
        return next
    }

    /// Restore a persisted state for use at `now`, dropping what a break has invalidated.
    ///
    /// The **ratio window always survives** — N is a property of the plan and does not spoil while
    /// the app is closed. The **accumulation does not**: it is tied to a specific bucket, and after
    /// ``accumulationTTL`` the five-hour counter has certainly reset unobserved. So a returning user
    /// gets a working reconstruction from the first poll, with an inherited anchor, rather than
    /// either a stale value or a cold start.
    public func resumed(at now: Date) -> WeeklyInterpolator {
        guard let last = lastPollAt, now.timeIntervalSince(last) <= Self.accumulationTTL else {
            return WeeklyInterpolator(ratio: ratio)
        }
        return self
    }

    /// The most five-hour percentage points that could honestly have been spent over `gap` seconds.
    ///
    /// The window is 100 points of 5 hours, so it cannot burn faster than `100 / 18 000` points per
    /// second even at full tilt. A generous ×2 covers clock skew and a poll that lands late, and a
    /// small floor keeps a zero-length gap (a forced refresh, or a stub on a frozen clock) from
    /// crediting nothing at all when the counter genuinely moved.
    ///
    /// This bounds only the **post-reset** credit, where the drop itself is the sole evidence. A
    /// plain rise needs no cap: the server reported both endpoints, so the difference is measured,
    /// not inferred.
    static func maxCreditableSpend(over gap: TimeInterval) -> Double {
        let full = Double(LimitWindow.fiveHour.durationSeconds)
        return max(5, 2 * 100 * max(0, gap) / full)
    }

    /// The median of the recent intervals, or ``fallbackInterval`` before enough are known.
    ///
    /// **Adaptive on purpose.** The poll cadence switches between 3 min (active) and 15 min (idle),
    /// so a threshold anchored to the base interval mislabels normal slow polling as a hole — on the
    /// Pro journal a fixed 3-minute basis flagged **576 of 862** samples degraded, against 128 with
    /// this median.
    static func expectedInterval(from intervals: [TimeInterval]) -> TimeInterval {
        guard intervals.count >= 5 else { return fallbackInterval }
        let sorted = intervals.sorted()
        return sorted[sorted.count / 2]
    }

    // MARK: - Reading the value

    /// The reconstructed value for the raw utilization currently in hand.
    ///
    /// - `degraded` → the raw value, unchanged;
    /// - otherwise `anchor + gain / N`, clipped at the bucket ceiling. Hitting that clip is reported
    ///   as ``WeeklyUtilization/Source/clipped`` rather than hidden: it means N is running low, and
    ///   the bar looks exactly as it did before the reconstruction, so the state would otherwise be
    ///   invisible.
    ///
    /// No **ratchet** (`max` against a previous value) is applied, deliberately: `N` never changes
    /// *inside* a segment — a new estimate is only recorded by the bump that closes the segment — so
    /// with `anchor` and `N` fixed and the gain non-decreasing, the expression is monotone
    /// **arithmetically**. A ratchet would suggest N moves mid-segment, which it does not.
    public func value(forRaw raw: Double) -> WeeklyUtilization {
        let n = ratio.estimate
        let samples = ratio.sampleCount

        // An exhausted window is passed through untouched. Interpolating inside the top bucket
        // would land somewhere in [99.5, 100) — and every exhaustion detector in the app tests
        // `utilization >= 100` (`CreditsPacing`, `BlockingReset`, `MenuBarLayout`,
        // `PacingModel.limitIndicator`). A reconstructed 99.7 would silently un-exhaust a blocked
        // week: no red bar, no blocking reset, no switch to credits. There is also nothing to gain
        // — at 100 % the bar is full and the countdown carries the state, so the sub-point position
        // inside the last bucket changes no pixel and no verdict.
        guard raw < 100 else {
            return WeeklyUtilization(raw: raw, effective: raw, source: .interpolated,
                                     ratio: n, sampleCount: samples)
        }

        guard !isDegraded, anchoredRaw == raw, n > 0 else {
            // Degraded: we stop learning, but we do not un-learn, and we do not over-claim either.
            //
            // The fallback is the bucket's **lower edge**, not the bare quantum `k`. `k` is the
            // bucket's *centre*, so falling back to it would assert half a point of spend we never
            // measured — and the moment measurement resumes with an honest, lower estimate, the bar
            // would visibly step *down*.
            //
            // The lower edge is the one thing an observed `k` guarantees, so it can never be
            // contradicted later. Above it we keep whatever the reconstruction had already earned
            // for this bucket (``shownFloor``), which is the part that must not be forgotten.
            let earned = (anchoredRaw == raw ? shownFloor : nil) ?? Self.floor(of: raw)
            let held = max(Self.floor(of: raw), earned)
            return WeeklyUtilization(raw: raw, effective: min(held, Self.ceiling(of: raw)),
                                     source: .degraded, ratio: n, sampleCount: samples)
        }

        let ceiling = Self.ceiling(of: raw)
        let wanted = anchor + fiveHourSinceAnchor / n
        let effective = min(wanted, ceiling)
        let source: WeeklyUtilization.Source =
            wanted > ceiling ? .clipped : (isFirm ? .interpolated : .inherited)

        return WeeklyUtilization(raw: raw, effective: max(0, min(100, effective)),
                                 source: source, ratio: n, sampleCount: samples)
    }

    /// What the reconstruction alone says for `raw` — no ``shownFloor``, no degraded fallback. The
    /// input to that floor, kept separate so remembering a value cannot feed on itself.
    private func reconstructed(forRaw raw: Double) -> Double {
        let n = ratio.estimate
        guard raw < 100, anchoredRaw == raw, n > 0 else { return raw }
        return max(0, min(100, min(anchor + fiveHourSinceAnchor / n, Self.ceiling(of: raw))))
    }
}
