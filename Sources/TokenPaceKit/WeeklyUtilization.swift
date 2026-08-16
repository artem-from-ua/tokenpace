import Foundation

// MARK: - WeeklyUtilization

/// The seven-day utilization in **both** forms the app needs — the API's quantised integer and the
/// value reconstructed from the five-hour counter (#386) — plus how the second one was produced.
///
/// Never two bare `Double`s. The whole point of #386 is that a consumer must not be able to pick
/// the wrong one by accident: the reconstruction reaches a bar **only** through ``applied(to:)``,
/// which rewrites the snapshot's `seven_day` window, exactly as ``ResetClock/optimisticReset(_:now:)``
/// rewrites a rolled-over window. After that call `snapshot.sevenDay.utilization` *is* the effective
/// value, and there is no path back to the raw one through the snapshot — which is what keeps the
/// menu bar, the popup, the colour thresholds and the weekly gate from ever disagreeing.
///
/// The raw value stays reachable **here**, for the two places that legitimately need it: the journal
/// (which records both, plus ``Source``) and Troubleshoot (which shows them side by side). The
/// Troubleshoot *body* is the transport's raw JSON and is not touched by this type at all.
public struct WeeklyUtilization: Sendable, Equatable, Codable {

    // MARK: - Source

    /// How ``effective`` was produced — the honesty carrier for the journal, Troubleshoot and the
    /// downstream metrics (#245), so a reader can filter by the *kind* of estimate rather than guess.
    public enum Source: String, Sendable, Equatable, Codable, CaseIterable {
        /// No bump has been observed yet since this state was created (fresh install, or a long
        /// break that dropped the accumulation): the anchor sits at the **centre** of the bucket
        /// because the position inside it is not observable. Measured on 4 295 samples with a known
        /// bump time, that position is distributed uniformly (median 0.500), so the centre minimises
        /// expected error — and it is never worse than what shipped before, which showed `k` with the
        /// same ±0.5 pp bound and no movement at all.
        case inherited
        /// The steady state: a bump was observed, so the anchor is the bucket's **exact lower edge**
        /// (`k − 0.5`), and the accumulated five-hour gain carries the value up from there.
        case interpolated
        /// The accumulation reached the bucket ceiling and is pinned there, waiting for the next
        /// bump — which means N is running low. Observed on 4.5 % of samples (Max 5x) and 0.1 %
        /// (Pro); usually a couple of polls, once for 128 polls (≈6.4 h). The bar looks exactly as
        /// it did before the reconstruction, so the state is recorded to make a systematically low
        /// N visible rather than silent.
        case clipped
        /// A polling hole invalidated the accumulation (the five-hour counter may have both risen
        /// *and* reset unobserved), so the raw value is shown instead. Cleared by the next bump.
        case degraded
    }

    // MARK: - Stored

    /// The API value verbatim — integer-quantised, step 1 pp = 1 h 40 m of weekly work.
    public let raw: Double
    /// The value every renderer must use. Equals ``raw`` in the ``Source/degraded`` state.
    public let effective: Double
    /// How ``effective`` was produced.
    public let source: Source
    /// The exchange rate in force when this value was produced, for the journal and Troubleshoot.
    public let ratio: Double
    /// How many segments back ``ratio`` — a seeded estimate reads as `0`.
    public let sampleCount: Int

    public init(raw: Double, effective: Double, source: Source, ratio: Double, sampleCount: Int) {
        self.raw = raw
        self.effective = effective
        self.source = source
        self.ratio = ratio
        self.sampleCount = sampleCount
    }

    /// The identity value — effective *is* raw, nothing reconstructed. Used before any state exists
    /// (cold start of the poll loop) and by fixtures/previews that have no interpolator.
    public static func passthrough(_ raw: Double) -> WeeklyUtilization {
        WeeklyUtilization(raw: raw, effective: raw, source: .degraded,
                          ratio: WeeklyRatio.seed, sampleCount: 0)
    }

    // MARK: - Applying

    /// Rewrite `snapshot`'s `seven_day` window to carry ``effective`` — the only way the
    /// reconstruction reaches a bar.
    ///
    /// **A no-op in three cases**, each guarding a detector that would otherwise change behaviour:
    ///
    /// - `raw == 0` — a zero window must stay exactly zero. Several `> 0` predicates key off it
    ///   (`PopupLayout.groupIsAboveZero`), and a 0.3 % reconstruction would flip them. The bar draws
    ///   the same "nothing spent" state either way, so nothing is lost.
    /// - `effective == raw` — nothing to rewrite.
    /// - **the anchor has desynchronised** (`snapshot.sevenDay.utilization != raw`) — the window we
    ///   are looking at is not the one the interpolator measured. This is what makes the overlay
    ///   safe to apply *after* ``ResetClock/optimisticReset(_:now:)``: that one may zero the weekly
    ///   window locally before the server confirms it, and without this guard we would add the
    ///   accumulated gain on top of the fresh zero.
    ///
    /// The **`>= 100` detectors are protected by construction**, not by a guard here: the ceiling of
    /// the top bucket is exactly 100, so `raw < 100 ⟹ effective < 100` and `raw == 100 ⟹ effective
    /// == 100`. That invariant is what lets `CreditsPacing`, `MenuBarLayout`, `BlockingReset` and
    /// `PacingModel.limitIndicator` keep their exhaustion tests untouched (#386 audit).
    ///
    /// Only `seven_day` is rewritten. The per-model sub-windows (`seven_day_opus`, `seven_day_sonnet`)
    /// and the `weekly_scoped` entries are left raw: they meter *different* spend and have no
    /// five-hour counter of their own, so a single N is incorrect for them by construction.
    public func applied(to snapshot: UsageSnapshot) -> UsageSnapshot {
        guard raw > 0, effective != raw, snapshot.sevenDay.utilization == raw else { return snapshot }
        return UsageSnapshot(
            fiveHour: snapshot.fiveHour,
            sevenDay: UsageWindow(utilization: effective, resetsAt: snapshot.sevenDay.resetsAt),
            sevenDayOpus: snapshot.sevenDayOpus,
            sevenDaySonnet: snapshot.sevenDaySonnet,
            limits: snapshot.limits,
            sessionIdle: snapshot.sessionIdle,
            spend: snapshot.spend)
    }

    // MARK: - Disclosure

    /// The Troubleshoot line — the one place both numbers appear together, so the estimate can be
    /// judged on live data. `nil` when there is nothing to disclose (effective == raw).
    ///
    /// ```
    /// weekly: 88 % raw → 88.34 % est (N ≈ 9.8, 12 samples)
    /// weekly: 88 % raw → 88.49 % est (N ≈ 9.8, 12 samples, clipped)
    /// weekly: 88 % raw (degraded — polling gap)
    /// ```
    public var troubleshootLine: String? {
        guard source != .degraded else {
            return "weekly: \(Self.percent(raw)) raw (degraded — polling gap)"
        }
        guard effective != raw else { return nil }
        var note = "N ≈ \(Self.ratioText(ratio)), \(sampleCount) sample\(sampleCount == 1 ? "" : "s")"
        if source == .clipped { note += ", clipped" }
        if source == .inherited { note += ", inherited anchor" }
        return "weekly: \(Self.percent(raw)) raw → \(Self.estimateText(effective)) est (\(note))"
    }

    private static func percent(_ value: Double) -> String { "\(Int(value.rounded())) %" }
    private static func estimateText(_ value: Double) -> String { String(format: "%.2f %%", value) }
    private static func ratioText(_ value: Double) -> String { String(format: "%.1f", value) }
}
