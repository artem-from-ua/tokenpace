import Foundation

// MARK: - LimitRow

/// One section of the popup: a named limit window with its pacing, a drawable bar, and a split
/// reset countdown. The pure-data side of issue #11 — no AppKit, no human-readable sentences (the
/// view assembles "% used · on pace · resets in …"). Reset *time* strings are the one exception:
/// they are produced by `ResetClock` (shared time arithmetic, reused in Phase 2), not localised
/// prose, so they live here rather than in the view.
///
/// Used for all four kinds of section — `5h`, `7d`, and the per-model sub-windows (`Opus`,
/// `Sonnet`), which are paced as `.sevenDay` (they reset on the weekly cadence).
public struct LimitRow: Sendable, Equatable {
    /// Section heading, e.g. `"5-hour limit"`, `"7-day limit"`, `"Opus (7-day)"`. A raw label
    /// (the window identity), not a localised string — the view renders it as-is for now.
    public let title: String
    /// API `utilization`, percent in [0, 100].
    public let utilization: Double
    /// Pacing relative to the elapsed window (`PacingModel.barLayout(...).pacing`).
    public let pacing: PacingState
    /// Severity tier (`PacingModel.limitIndicator`).
    public let indicator: LimitIndicator
    /// Continuous bar geometry for drawing the pacing bar (same `BarLayout` the menu bar draws).
    public let bar: BarLayout
    /// Always-shown relative countdown — `"20m"`, `"3d"`, `"1h30m"` — or `nil` when the reset is
    /// now/past or `resets_at` was unparseable (the view shows a stale signal).
    public let resetRelative: String?
    /// Absolute wall-clock `"10:30"` — present **only when the reset is < 24 h away** (the view
    /// appends "@ 10:30"); `nil` for far-off resets where a clock time is noise.
    public let resetAbsolute: String?

    public init(
        title: String,
        utilization: Double,
        pacing: PacingState,
        indicator: LimitIndicator,
        bar: BarLayout,
        resetRelative: String?,
        resetAbsolute: String?
    ) {
        self.title = title
        self.utilization = utilization
        self.pacing = pacing
        self.indicator = indicator
        self.bar = bar
        self.resetRelative = resetRelative
        self.resetAbsolute = resetAbsolute
    }
}

// MARK: - PopupLayout

/// The pure, AppKit-free model of the click-to-open popup for one usage snapshot — the testable
/// core behind `PopupViewController` (issue #11).
///
/// Mirrors `MenuBarLayout` (#10): `make(...)` is **stateless and deterministic** (`now`,
/// `lastUpdate`, `interval` are injected) and adds **no new pacing arithmetic** — it reuses
/// `PacingModel` and `ResetClock`. The struct computes *what* to show; the thin `NSViewController`
/// shell in `cc-timer` does *how* (ADR-0009).
///
/// The service-line values (`lastUpdateAge`, `intervalSeconds`) are **raw seconds** — the view
/// formats them ("just now", "3m") so a future localisation touches only the view.
///
/// Issue #12 adds ``warning``: when a poll is failing, the popup shows a two-line banner
/// **immediately** (no 30-min threshold — that gate is the menu bar's, not the popup's), above the
/// possibly-stale ``rows``. A healthy layout leaves it `nil`.
public struct PopupLayout: Sendable, Equatable {
    /// Age of the last successful 200, in seconds (clamped ≥ 0). Drives "Last update: …".
    public let lastUpdateAge: TimeInterval
    /// Current polling interval in seconds (`PollingBackoff.interval`). Drives "Update interval: …".
    public let intervalSeconds: TimeInterval
    /// The limit sections, in display order: `5h`, `7d`, then any present per-model rows
    /// (`Opus`, `Sonnet`). Absent models are simply not in the array (null-safe). Empty on a
    /// cold-start failure (no snapshot yet — the warning stands alone).
    public let rows: [LimitRow]
    /// The current failure cause when a poll is failing, else `nil`. Drives the popup warning banner
    /// (issue #12); the view turns it into the two-line title/detail (the localisation seam).
    public let warning: FailureReason?

    public init(
        lastUpdateAge: TimeInterval,
        intervalSeconds: TimeInterval,
        rows: [LimitRow],
        warning: FailureReason? = nil
    ) {
        self.lastUpdateAge = lastUpdateAge
        self.intervalSeconds = intervalSeconds
        self.rows = rows
        self.warning = warning
    }

    // MARK: make

    /// Build the popup layout from one usage snapshot at instant `now`.
    ///
    /// - Parameters:
    ///   - snapshot: A decoded usage poll (`UsageClient`/#9).
    ///   - now: Current instant — inject for deterministic tests; never call `Date()` here.
    ///   - lastUpdate: Instant of the last successful 200 (→ `lastUpdateAge`). Mock today; real with #13.
    ///   - interval: Current polling interval in seconds (`PollingBackoff.interval`). Mock today.
    public static func make(
        from snapshot: UsageSnapshot,
        now: Date,
        lastUpdate: Date,
        interval: TimeInterval
    ) -> PopupLayout {
        let rows = self.rows(from: snapshot, now: now)
        AppLogger.ui.notice("popup layout built rows=\(rows.count, privacy: .public)")
        return PopupLayout(
            lastUpdateAge: max(0, now.timeIntervalSince(lastUpdate)),
            intervalSeconds: interval,
            rows: rows
        )
    }

    // MARK: make (health-aware, issue #12)

    /// Build the popup from the last known snapshot **and** the polling health.
    ///
    /// The entry point the live loop (#13) calls. Unlike the menu bar's staged thresholds, the popup
    /// warns the moment a failure is in progress (SPEC: "за будь-якої непрацюючої авторизації …
    /// одразу"):
    /// - ``warning`` = `health.reason` whenever `health.isFailing`, else `nil`.
    /// - ``lastUpdateAge`` is measured from `health.lastSuccess` so the service line shows how stale
    ///   the data is (clamped `≥ 0`; `0` on a cold start where there is no last success).
    /// - ``rows`` come from the last known `snapshot` (stale data, shown with its timestamp), or are
    ///   empty on a cold-start failure (no snapshot yet — the warning stands alone).
    ///
    /// - Parameters:
    ///   - snapshot: The last successfully decoded poll, or `nil` if none has ever succeeded.
    ///   - health: The polling-health context (last success, failure start, reason).
    ///   - now: Current instant — inject for deterministic tests; never call `Date()` here.
    ///   - interval: Current polling interval in seconds (`PollingBackoff.interval`).
    public static func make(
        from snapshot: UsageSnapshot?,
        health: UsageHealth,
        now: Date,
        interval: TimeInterval
    ) -> PopupLayout {
        let rows = snapshot.map { self.rows(from: $0, now: now) } ?? []
        let lastUpdateAge = health.lastSuccess.map { max(0, now.timeIntervalSince($0)) } ?? 0
        let warning = health.isFailing ? health.reason : nil
        AppLogger.ui.notice(
            "popup layout built rows=\(rows.count, privacy: .public) failing=\(health.isFailing, privacy: .public)")
        return PopupLayout(
            lastUpdateAge: lastUpdateAge,
            intervalSeconds: interval,
            rows: rows,
            warning: warning
        )
    }

    // MARK: - Private

    /// The ordered limit sections for a snapshot: `5h`, `7d`, then any present per-model rows
    /// (`Opus`/`Sonnet`, paced as `.sevenDay`, null-safe — absent models are skipped). Shared by
    /// both ``make`` overloads.
    private static func rows(from snapshot: UsageSnapshot, now: Date) -> [LimitRow] {
        var rows: [LimitRow] = [
            row(title: "5-hour limit", window: snapshot.fiveHour, as: .fiveHour, now: now),
            row(title: "7-day limit", window: snapshot.sevenDay, as: .sevenDay, now: now),
        ]
        if let opus = snapshot.sevenDayOpus {
            rows.append(row(title: "Opus (7-day)", window: opus, as: .sevenDay, now: now))
        }
        if let sonnet = snapshot.sevenDaySonnet {
            rows.append(row(title: "Sonnet (7-day)", window: sonnet, as: .sevenDay, now: now))
        }
        return rows
    }

    /// Build one `LimitRow`, delegating all arithmetic to tested pure logic. An unparseable
    /// `resets_at` falls back to `now` for the bar geometry (→ `elapsedFraction == 1.0`, matching
    /// `MenuBarLayout`) and to `nil` reset strings (the view shows a stale signal).
    private static func row(title: String, window: UsageWindow, as kind: LimitWindow, now: Date) -> LimitRow {
        let parsed = ResetClock.parse(window.resetsAt)
        let bar = PacingModel.barLayout(
            utilization: window.utilization,
            resetsAt: parsed ?? now,
            now: now,
            window: kind
        )
        let indicator = PacingModel.limitIndicator(
            utilization: window.utilization,
            timePercent: bar.timeFraction * 100
        )
        let relative = parsed.flatMap { ResetClock.relativeDuration(resetsAt: $0, now: now) }
        let absolute = parsed.flatMap { ResetClock.absoluteWithin(resetsAt: $0, now: now) }
        return LimitRow(
            title: title,
            utilization: window.utilization,
            pacing: bar.pacing,
            indicator: indicator,
            bar: bar,
            resetRelative: relative,
            resetAbsolute: absolute
        )
    }
}
