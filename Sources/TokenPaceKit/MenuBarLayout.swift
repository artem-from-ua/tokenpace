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
    /// Whether this bar is the **idle** 5-hour bar — the 5h window does not exist server-side (no
    /// active session, ``UsageSnapshot/sessionIdle``, #100). When `true` the view draws a **solid,
    /// knobless** track (`StatusItemView` fills it with `Palette.idleBlue`, no zones, no time dot); the
    /// `layout`/`indicator` are inert placeholders (`usage 0 / time 0`, `.neutral`) that the idle draw
    /// path ignores. `false` on every normal bar, including a genuine 0 %-with-valid-reset 5h window.
    public let idle: Bool

    public init(layout: BarLayout, indicator: LimitIndicator, window: LimitWindow, idle: Bool = false) {
        self.layout = layout
        self.indicator = indicator
        self.window = window
        self.idle = idle
    }

    /// The bar's pacing **severity** for reset-countdown selection (#103, ADR-0028/0029). Delegates to
    /// `BarLayout.severity`, except an **idle** 5-hour bar is always ``PacingSeverity/calm``: it carries
    /// an inert placeholder `layout` (`usage 0 / time 0`) and means "ready to start, full quota
    /// available", never a pacing concern — so it must not drive the countdown. Only the 7-day bar
    /// decides in the idle state.
    public var severity: PacingSeverity { idle ? .calm : layout.severity }

    /// Whether this bar is "calm" (green/yellow). Derived from ``severity`` (idle → always calm).
    public var isCalm: Bool { severity == .calm }
}

// MARK: - MenuBarMode

/// What the menu-bar item should currently show — the discriminated result `StatusItemView`
/// switches on when drawing.
///
/// Cases:
/// - ``expanded(fiveHour:sevenDay:resetToShow:)``: the normal widget — two stacked bars (5h top,
///   7d bottom) plus an **optional** reset countdown. Shown whenever there is a usable snapshot,
///   at any `utilization` — the widget never collapses to a compact glyph (ADR-0015 supersedes the
///   earlier idle mode). `resetToShow` is `nil` when no countdown should be drawn (ADR-0029).
/// - ``error(fiveHour:sevenDay:reset:which:)``: there is no usable data to show — polling has been
///   failing long enough to surface a ⚠️ glyph (issue #12), **or** it is a cold start before the
///   first poll resolves (e.g. token expired, API unreachable). The bars are **optional**: present
///   during the 30–60 min "stale" phase (⚠️ drawn alongside the last known bars), `nil` past 60 min
///   or on a cold start (⚠️ alone).
public enum MenuBarMode: Sendable, Equatable {
    /// Full widget: 5h bar, 7d bar, and an optional reset countdown.
    ///
    /// - Parameters:
    ///   - fiveHour: The 5-hour bar (drawn on top).
    ///   - sevenDay: The 7-day bar (drawn below).
    ///   - resetToShow: The countdown to draw and which window drives it, or `nil` to draw no
    ///     countdown. Computed by `MenuBarLayout.selectReset` from the 5h×7d severity table and the
    ///     user's `ResetCountdownMode` (#103, ADR-0029) — the view just draws what it is given.
    case expanded(fiveHour: BarView, sevenDay: BarView, resetToShow: ResetToShow?)
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

// MARK: - ResetToShow

/// A reset countdown the menu bar should draw: the formatted `display` text and `which` window it
/// belongs to. Produced by `MenuBarLayout.selectReset` (#103, ADR-0029); a `nil` `ResetToShow?`
/// means "draw no countdown".
public struct ResetToShow: Sendable, Equatable {
    public let which: LimitWindow
    public let display: TimeToReset

    public init(which: LimitWindow, display: TimeToReset) {
        self.which = which
        self.display = display
    }
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
/// collapse (ADR-0015 removed it). The only mode variation is the error state (issue #12). The
/// session-idle state (#100, ADR-0027) stays ``MenuBarMode/expanded`` too: it only recolours the 5h
/// bar (``BarView/idle``) and swaps the reset label to the 7-day one — the bars never disappear.
public struct MenuBarLayout: Sendable, Equatable {
    /// The mode `StatusItemView` switches on to draw.
    public let mode: MenuBarMode

    /// The most severe non-operational Claude service state, or `nil` when both tracked components
    /// are operational / no status is known yet (issue #31). When non-`nil`, `StatusItemView` draws
    /// a small colour dot as the **trailing** (rightmost) element of the widget, after the bars/glyph;
    /// when `nil`, no dot. Orthogonal to `mode` — a service problem and the usage state are independent.
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
    /// as the neutral `"<1m"` boundary text (#36). The normal reset-boundary flow does not reach this:
    /// the coordinator's optimistic-reset timer rolls the window forward before zero (see ADR-0030).
    ///
    /// **Session-idle (#100, ADR-0027).** When `snapshot.sessionIdle` (the 5h window does not exist
    /// server-side — no active session), the mode is still ``MenuBarMode/expanded`` with **both** bars
    /// (ADR-0015's "bars never collapse" still holds), but:
    /// - the 5h bar is built ``BarView/idle`` `= true` (inert `usage 0 / time 0` layout; the view draws
    ///   a solid-blue knobless track — **no** synthesized `now + 5h` phantom reset, the bug this fixes);
    /// - the reset label switches to the **7-day** reset via
    ///   ``ResetClock/timeToResetCompactDays(resetsAt:now:locale:timeZone:)`` (`"4d"` when ≥ 24 h,
    ///   `"20:40"` when nearer), with `which == .sevenDay`.
    ///
    /// - Parameters:
    ///   - snapshot: A decoded usage poll (`UsageClient`/#9).
    ///   - now: Current instant — inject for deterministic tests; never call `Date()` here.
    ///   - resetMode: How to pick/hide the reset countdown (#103, ADR-0029). Default `.showDistant7d`.
    public static func make(
        from snapshot: UsageSnapshot, now: Date, resetMode: ResetCountdownMode = .showDistant7d
    ) -> MenuBarLayout {
        let seven = bar(for: snapshot.sevenDay, window: .sevenDay, now: now)
        let sevenResetsAt = ResetClock.parse(snapshot.sevenDay.resetsAt)

        if snapshot.sessionIdle {
            // No active 5h window: an inert, knobless placeholder bar (the idle draw path ignores its
            // geometry). The 5h bar is always calm here, so only the 7-day bar drives the countdown —
            // pass a nil 5h reset (never derived from the empty `fiveHour.resetsAt`).
            let five = BarView(
                layout: BarLayout(usageFraction: 0, timeFraction: 0, pacing: .onPaceOrBehind),
                indicator: .neutral, window: .fiveHour, idle: true)
            let resetToShow = selectReset(
                fiveSeverity: .calm, fiveResetsAt: nil,
                sevenSeverity: seven.severity, sevenResetsAt: sevenResetsAt,
                now: now, mode: resetMode)
            return MenuBarLayout(mode: .expanded(fiveHour: five, sevenDay: seven, resetToShow: resetToShow))
        }

        let five = bar(for: snapshot.fiveHour, window: .fiveHour, now: now)
        let fiveResetsAt = ResetClock.parse(snapshot.fiveHour.resetsAt)

        // Pick which reset countdown to show (or hide) from the 5h×7d severity table + mode (ADR-0029).
        let resetToShow = selectReset(
            fiveSeverity: five.severity, fiveResetsAt: fiveResetsAt,
            sevenSeverity: seven.severity, sevenResetsAt: sevenResetsAt,
            now: now, mode: resetMode)
        return MenuBarLayout(mode: .expanded(fiveHour: five, sevenDay: seven, resetToShow: resetToShow))
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
    ///     the trailing dot; it does not affect the usage `mode`.
    public static func make(
        from snapshot: UsageSnapshot?, health: UsageHealth, now: Date,
        serviceProblem: ServiceStatus? = nil, resetMode: ResetCountdownMode = .showDistant7d
    ) -> MenuBarLayout {
        usageMode(from: snapshot, health: health, now: now, resetMode: resetMode)
            .withServiceProblem(serviceProblem)
    }

    /// The usage-driven `mode` only (no service dot) — the existing #12 decision tree, factored out
    /// so ``make(from:health:now:serviceProblem:resetMode:)`` can graft the service dot onto its result.
    private static func usageMode(
        from snapshot: UsageSnapshot?, health: UsageHealth, now: Date, resetMode: ResetCountdownMode
    ) -> MenuBarLayout {
        // Healthy, or stale within the grace window: show the (possibly stale) bars unchanged.
        // A healthy state with no snapshot only happens at the very first tick before the first
        // poll resolves; with no data to draw, fall back to the bare ⚠️ error glyph.
        guard let age = health.failureAge(now: now) else {
            return snapshot.map { make(from: $0, now: now, resetMode: resetMode) }
                ?? MenuBarLayout(mode: .error(fiveHour: nil, sevenDay: nil, reset: nil, which: nil))
        }
        if let snapshot, age <= UsageHealth.glyphAfter {
            return make(from: snapshot, now: now, resetMode: resetMode)
        }

        // Failing past the glyph threshold. Keep the bars only in the 30–60 min stale window and
        // only if we have a snapshot; otherwise the glyph stands alone. The countdown here is
        // **diagnostic** ("data is stale, last reset was …"), so it always shows the nearest reset,
        // independent of `resetMode`'s selection table (ADR-0029).
        let keepBars = snapshot != nil && age <= UsageHealth.hideBarsAfter
        guard keepBars, let snapshot,
              case let .expanded(five, seven, _) = make(from: snapshot, now: now, resetMode: resetMode).mode else {
            return MenuBarLayout(mode: .error(fiveHour: nil, sevenDay: nil, reset: nil, which: nil))
        }
        let (which, reset) = ResetClock.resetDisplay(
            fiveHourResetsAt: snapshot.fiveHour.resetsAt,
            sevenDayResetsAt: snapshot.sevenDay.resetsAt,
            now: now
        ) ?? (.fiveHour, .resetNow)
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

    // MARK: - Reset-countdown selection (#103, ADR-0029)

    /// Choose which reset countdown (5h or 7d) the menu bar should show, per the 5h×7d severity table
    /// and the user's ``ResetCountdownMode``. Returns `nil` to hide the countdown. Pure/testable — the
    /// single source of the selection table.
    ///
    /// The semantics ("show the next real unblock"):
    /// - both bars **calm** → hidden, unless the mode shows a countdown even then (`always` → nearest).
    /// - exactly one bar **noisy** → that bar's reset. A lone **7d ahead-of-pace (orange)** is gated:
    ///   shown when `< 24 h` out, or when the mode allows a distant one; a 7d **exhausted (red)** is
    ///   always shown. A noisy **5h** is always shown (its reset is near by definition).
    /// - both bars **noisy** → the next unblock: both **exhausted** → the **later** reset (blocked
    ///   until both clear); both **ahead** → the **earlier** reset (neither blocks yet); **red+orange**
    ///   → the **red** bar's reset (only it blocks).
    ///
    /// `nil` `resetsAt` (missing/unparseable) is tolerated: a chosen bar with a `nil` instant yields
    /// `.resetNow` (rendered as the neutral `"<1m"`, #36), matching the rest of the layer.
    static func selectReset(
        fiveSeverity: PacingSeverity, fiveResetsAt: Date?,
        sevenSeverity: PacingSeverity, sevenResetsAt: Date?,
        now: Date, mode: ResetCountdownMode,
        locale: Locale = .current, timeZone: TimeZone = .current
    ) -> ResetToShow? {
        if mode == .never { return nil }

        let fiveNoisy = fiveSeverity != .calm
        let sevenNoisy = sevenSeverity != .calm

        // Format a chosen window's reset (5h → live countdown; 7d → compact-days variant).
        func display(_ window: LimitWindow, _ resetsAt: Date?) -> ResetToShow {
            guard let at = resetsAt else { return ResetToShow(which: window, display: .resetNow) }
            let text = window == .sevenDay
                ? ResetClock.timeToResetCompactDays(resetsAt: at, now: now, locale: locale, timeZone: timeZone)
                : ResetClock.timeToReset(resetsAt: at, now: now, locale: locale, timeZone: timeZone)
            return ResetToShow(which: window, display: text)
        }
        func pick(_ nr: NearestReset?) -> ResetToShow? {
            guard let nr else { return nil }
            return display(nr.window, nr.resetsAt)
        }

        let chosen: ResetToShow?
        switch (fiveNoisy, sevenNoisy) {
        case (true, true):
            // Both noisy → next unblock.
            if fiveSeverity == .exhausted && sevenSeverity == .exhausted {
                chosen = pick(ResetClock.latestReset(fiveHour: fiveResetsAt, sevenDay: sevenResetsAt))
            } else if fiveSeverity == .ahead && sevenSeverity == .ahead {
                chosen = pick(ResetClock.nearestReset(fiveHour: fiveResetsAt, sevenDay: sevenResetsAt))
            } else {
                // red + orange → the red (exhausted) bar.
                chosen = fiveSeverity == .exhausted
                    ? display(.fiveHour, fiveResetsAt)
                    : display(.sevenDay, sevenResetsAt)
            }
        case (true, false):
            // Only 5h noisy → its reset (always near enough to matter).
            chosen = display(.fiveHour, fiveResetsAt)
        case (false, true):
            // Only 7d noisy. Red → always; orange → gated by distance + mode.
            if sevenSeverity == .exhausted {
                chosen = display(.sevenDay, sevenResetsAt)
            } else {
                let far = (sevenResetsAt?.timeIntervalSince(now) ?? 0) >= 24 * 3_600
                chosen = (far && !mode.showsDistantAhead7d) ? nil : display(.sevenDay, sevenResetsAt)
            }
        case (false, false):
            // Both calm → hidden, unless the mode shows a countdown anyway (nearest).
            chosen = mode.showsWhenBothCalm
                ? pick(ResetClock.nearestReset(fiveHour: fiveResetsAt, sevenDay: sevenResetsAt))
                : nil
        }
        return chosen
    }
}
