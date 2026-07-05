import Foundation

// MARK: - BarView

/// Everything `StatusItemView` needs to draw **one** pacing bar — the pure-geometry side of
/// issue #10, with no AppKit dependency.
///
/// `layout` carries the three drawable zones and the time-indicator position (`BarLayout`, #6);
/// `indicator` carries the severity tier (`LimitIndicator`, #6) so the view can flag a bar that is
/// near its cap. Colours are **not** resolved here — `BarView` exposes only the semantic
/// `PacingState`/`LimitIndicator`, and the `NSColor` mapping lives in `StatusItemView` so
/// `TokenPaceKit` never imports AppKit (mirrors the `BarLayout` split in ADR-0005).
public struct BarView: Sendable, Equatable {
    /// Continuous zone geometry + pacing colour semantics for this window (`PacingModel.barLayout`).
    public let layout: BarLayout
    /// Severity tier (`.critical`/`.warning`/`.neutral`) from `PacingModel.limitIndicator`.
    public let indicator: LimitIndicator
    /// Which rolling window this bar represents (5h on top, 7d below — see ``MenuBarMode``).
    public let window: LimitWindow

    public init(layout: BarLayout, indicator: LimitIndicator, window: LimitWindow) {
        self.layout = layout
        self.indicator = indicator
        self.window = window
    }
}

// MARK: - MenuBarMode

/// What the menu-bar item should currently show — the discriminated result `StatusItemView`
/// switches on when drawing.
///
/// Cases:
/// - ``expanded(fiveHour:sevenDay:reset:which:)``: the normal widget — two stacked bars (5h top,
///   7d bottom) plus the countdown to the nearest reset. Shown whenever there is a usable snapshot,
///   at any `utilization` — the widget never collapses to a compact glyph (ADR-0015 supersedes the
///   earlier idle mode).
/// - ``error(fiveHour:sevenDay:reset:which:)``: there is no usable data to show — polling has been
///   failing long enough to surface a ⚠️ glyph (issue #12), **or** it is a cold start before the
///   first poll resolves (e.g. token expired, API unreachable). The bars are **optional**: present
///   during the 30–60 min "stale" phase (⚠️ drawn alongside the last known bars), `nil` past 60 min
///   or on a cold start (⚠️ alone).
public enum MenuBarMode: Sendable, Equatable {
    /// Full widget: 5h bar, 7d bar, and the nearest-reset countdown.
    ///
    /// - Parameters:
    ///   - fiveHour: The 5-hour bar (drawn on top).
    ///   - sevenDay: The 7-day bar (drawn below).
    ///   - reset: Formatted countdown to whichever window resets first (`ResetClock`).
    ///   - which: Which window drives `reset` (so the view can label/associate it).
    case expanded(fiveHour: BarView, sevenDay: BarView, reset: TimeToReset, which: LimitWindow)
    /// Error state: a ⚠️ glyph, optionally with the last known bars beside it.
    ///
    /// All associated values are `nil` together (⚠️ only) or all non-`nil` together (⚠️ + bars) —
    /// the view treats a `nil` `fiveHour` as "draw the glyph alone". The split mirrors
    /// ``expanded`` so the view reuses the same bar/reset drawing.
    ///
    /// - Parameters:
    ///   - fiveHour: The last known 5-hour bar, or `nil` to draw the glyph alone.
    ///   - sevenDay: The last known 7-day bar, or `nil`.
    ///   - reset: The last known nearest-reset countdown, or `nil`.
    ///   - which: Which window drove `reset`, or `nil`.
    case error(fiveHour: BarView?, sevenDay: BarView?, reset: TimeToReset?, which: LimitWindow?)
}

// MARK: - MenuBarLayout

/// The pure, AppKit-free model of the menu-bar widget for one usage snapshot — the testable core
/// behind `StatusItemView` (issue #10).
///
/// Like `PacingModel`/`ResetClock`, ``make(from:now:)`` is **stateless and deterministic**: `now`
/// is injected so the reset countdown is reproducible in tests without a clock. The struct does no
/// drawing — it computes *what* to draw (`MenuBarMode`); the thin `NSView` shell in the `TokenPace`
/// target does *how* (ADR-0009).
///
/// ## Data flow
/// ```
/// UsageSnapshot ──make(from:now:)──▶ MenuBarLayout(mode:) ──▶ StatusItemView.draw
/// ```
/// Internally `make` reuses the already-tested logic and adds **no new arithmetic**:
/// - `PacingModel.barLayout(...)` → each `BarView.layout`
/// - `PacingModel.limitIndicator(...)` → each `BarView.indicator`
/// - `ResetClock.resetDisplay(...)` → the `reset`/`which` of ``MenuBarMode/expanded``
///
/// On the healthy path the result is always ``MenuBarMode/expanded`` — there is no compact/idle
/// collapse (ADR-0015 removed it). The only mode variation is the error state (issue #12).
public struct MenuBarLayout: Sendable, Equatable {
    /// The mode `StatusItemView` switches on to draw.
    public let mode: MenuBarMode

    /// The most severe non-operational Claude service state, or `nil` when both tracked components
    /// are operational / no status is known yet (issue #31). When non-`nil`, `StatusItemView` draws
    /// a small colour dot as the **leftmost** element of the widget, ahead of the bars/glyph; when
    /// `nil`, no dot. Orthogonal to `mode` — a service problem and the usage state are independent.
    public let serviceProblem: ServiceStatus?

    public init(mode: MenuBarMode, serviceProblem: ServiceStatus? = nil) {
        self.mode = mode
        self.serviceProblem = serviceProblem
    }

    // MARK: make

    /// Build the menu-bar layout from one usage snapshot at instant `now`.
    ///
    /// Steps, all delegating to tested pure logic:
    /// 1. Compute the 5h and 7d `BarLayout` + `LimitIndicator` via `PacingModel`.
    /// 2. Resolve the nearest-reset countdown via `ResetClock.resetDisplay`.
    /// 3. Return ``MenuBarMode/expanded`` — the healthy path always shows both bars (there is no
    ///    idle/compact collapse; ADR-0015).
    ///
    /// When neither `resets_at` parses (both `nil`/malformed), the reset display falls back to
    /// ``TimeToReset/resetNow`` — the snapshot is unusable for a countdown, which the view renders
    /// as the stale ⏰ glyph and the polling layer (#13) treats as a re-poll signal.
    ///
    /// - Parameters:
    ///   - snapshot: A decoded usage poll (`UsageClient`/#9).
    ///   - now: Current instant — inject for deterministic tests; never call `Date()` here.
    public static func make(from snapshot: UsageSnapshot, now: Date) -> MenuBarLayout {
        let five = bar(for: snapshot.fiveHour, window: .fiveHour, now: now)
        let seven = bar(for: snapshot.sevenDay, window: .sevenDay, now: now)

        let (which, reset) = ResetClock.resetDisplay(
            fiveHourResetsAt: snapshot.fiveHour.resetsAt,
            sevenDayResetsAt: snapshot.sevenDay.resetsAt,
            now: now
        ) ?? (.fiveHour, .resetNow)

        return MenuBarLayout(
            mode: .expanded(fiveHour: five, sevenDay: seven, reset: reset, which: which)
        )
    }

    // MARK: make (health-aware, issue #12)

    /// Build the menu-bar layout from the **last known** snapshot plus the polling health at `now`.
    ///
    /// This is the entry point the live loop (#13) calls; the plain ``make(from:now:)`` stays the
    /// healthy-path core that this delegates to. Decision order, by how long polling has been
    /// failing (`health.failureAge(now:)`, thresholds in ``UsageHealth``):
    ///
    /// 1. **Healthy** (`!isFailing`) → the normal ``make(from:now:)`` result.
    /// 2. **Failing ≤ 30 min**, snapshot present → still ``make(from:now:)``: the bars are stale but
    ///    fresh enough to show; the menu bar gives no error signal (the popup already warns).
    /// 3. **Failing 30–60 min**, snapshot present → ``MenuBarMode/error`` carrying the last bars and
    ///    reset (⚠️ drawn beside them).
    /// 4. **Failing > 60 min, or no snapshot at all** (cold start) → ``MenuBarMode/error`` with all
    ///    values `nil` (⚠️ alone — the data is too old, or there is none).
    ///
    /// - Parameters:
    ///   - snapshot: The last successfully decoded poll, or `nil` if none has ever succeeded.
    ///   - health: The polling-health context (last success, failure start, reason).
    ///   - now: Current instant — inject for deterministic tests; never call `Date()` here.
    ///   - serviceProblem: The worst non-operational Claude service state (issue #31), or `nil` when
    ///     all services are operational / unknown-cold. Threaded onto the result so the view can draw
    ///     the leftmost dot; it does not affect the usage `mode`.
    public static func make(
        from snapshot: UsageSnapshot?, health: UsageHealth, now: Date, serviceProblem: ServiceStatus? = nil
    ) -> MenuBarLayout {
        usageMode(from: snapshot, health: health, now: now).withServiceProblem(serviceProblem)
    }

    /// The usage-driven `mode` only (no service dot) — the existing #12 decision tree, factored out
    /// so ``make(from:health:now:serviceProblem:)`` can graft the service dot onto its result.
    private static func usageMode(from snapshot: UsageSnapshot?, health: UsageHealth, now: Date) -> MenuBarLayout {
        // Healthy, or stale within the grace window: show the (possibly stale) bars unchanged.
        // A healthy state with no snapshot only happens at the very first tick before the first
        // poll resolves; with no data to draw, fall back to the bare ⚠️ error glyph.
        guard let age = health.failureAge(now: now) else {
            return snapshot.map { make(from: $0, now: now) }
                ?? MenuBarLayout(mode: .error(fiveHour: nil, sevenDay: nil, reset: nil, which: nil))
        }
        if let snapshot, age <= UsageHealth.glyphAfter {
            return make(from: snapshot, now: now)
        }

        // Failing past the glyph threshold. Keep the bars only in the 30–60 min stale window and
        // only if we have a snapshot; otherwise the glyph stands alone.
        let keepBars = snapshot != nil && age <= UsageHealth.hideBarsAfter
        guard keepBars, let snapshot,
              case let .expanded(five, seven, reset, which) = make(from: snapshot, now: now).mode else {
            return MenuBarLayout(mode: .error(fiveHour: nil, sevenDay: nil, reset: nil, which: nil))
        }
        return MenuBarLayout(mode: .error(fiveHour: five, sevenDay: seven, reset: reset, which: which))
    }

    /// A copy of this layout carrying `serviceProblem` (the `mode` is unchanged).
    func withServiceProblem(_ serviceProblem: ServiceStatus?) -> MenuBarLayout {
        MenuBarLayout(mode: mode, serviceProblem: serviceProblem)
    }

    // MARK: - Private

    /// One `BarView` for a window, combining its bar geometry and severity tier. The `timePercent`
    /// fed to `limitIndicator` is `barLayout.timeFraction * 100`, keeping the integer-percent
    /// indicator math consistent with the continuous bar geometry (`PacingModel`'s intentional
    /// unit split).
    private static func bar(for window: UsageWindow, window kind: LimitWindow, now: Date) -> BarView {
        let resetsAt = ResetClock.parse(window.resetsAt) ?? now  // unparseable → elapsedFraction = 1.0
        let layout = PacingModel.barLayout(
            utilization: window.utilization,
            resetsAt: resetsAt,
            now: now,
            window: kind
        )
        let indicator = PacingModel.limitIndicator(
            utilization: window.utilization,
            timePercent: layout.timeFraction * 100
        )
        return BarView(layout: layout, indicator: indicator, window: kind)
    }
}
