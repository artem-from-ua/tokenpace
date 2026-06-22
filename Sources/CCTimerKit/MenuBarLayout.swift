import Foundation

// MARK: - BarView

/// Everything `StatusItemView` needs to draw **one** pacing bar — the pure-geometry side of
/// issue #10, with no AppKit dependency.
///
/// `layout` carries the three drawable zones and the time-indicator position (`BarLayout`, #6);
/// `indicator` carries the severity tier (`LimitIndicator`, #6) so the view can flag a bar that is
/// near its cap. Colours are **not** resolved here — `BarView` exposes only the semantic
/// `PacingState`/`LimitIndicator`, and the `NSColor` mapping lives in `StatusItemView` so
/// `CCTimerKit` never imports AppKit (mirrors the `BarLayout` split in ADR-0005).
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
/// Two cases ship in issue #10:
/// - ``idle``: both limits are deep in the normal band, so the widget collapses to a single
///   compact glyph (a bold `*`) to save menu-bar space (SPEC "Компактний режим при idle").
/// - ``expanded(fiveHour:sevenDay:reset:which:)``: the full widget — two stacked bars (5h top,
///   7d bottom) plus the countdown to the nearest reset.
///
/// **Reserved for #12:** error states (`⚠️` / stale-data warning) get their own case there; the
/// enum is left open for that addition rather than overloading ``idle``.
public enum MenuBarMode: Sendable, Equatable {
    /// Both windows under the idle threshold and no pacing warning — draw the compact glyph.
    case idle
    /// Full widget: 5h bar, 7d bar, and the nearest-reset countdown.
    ///
    /// - Parameters:
    ///   - fiveHour: The 5-hour bar (drawn on top).
    ///   - sevenDay: The 7-day bar (drawn below).
    ///   - reset: Formatted countdown to whichever window resets first (`ResetClock`).
    ///   - which: Which window drives `reset` (so the view can label/associate it).
    case expanded(fiveHour: BarView, sevenDay: BarView, reset: TimeToReset, which: LimitWindow)
}

// MARK: - MenuBarLayout

/// The pure, AppKit-free model of the menu-bar widget for one usage snapshot — the testable core
/// behind `StatusItemView` (issue #10).
///
/// Like `PacingModel`/`ResetClock`, ``make(from:now:)`` is **stateless and deterministic**: `now`
/// is injected so the idle decision and the reset countdown are reproducible in tests without a
/// clock. The struct does no drawing — it computes *what* to draw (`MenuBarMode`); the thin
/// `NSView` shell in the `cc-timer` target does *how* (ADR-0009).
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
/// The only fresh decision is the **idle vs. expanded** split (see ``idleUtilizationThreshold``).
public struct MenuBarLayout: Sendable, Equatable {
    /// The mode `StatusItemView` switches on to draw.
    public let mode: MenuBarMode

    public init(mode: MenuBarMode) {
        self.mode = mode
    }

    // MARK: idle threshold

    /// Utilisation percent (per window) below which a window counts as "idle".
    ///
    /// The widget collapses to the compact glyph only when **both** windows are under this. `5.0`
    /// matches the SPEC orientation value ("обидва ліміти < ~5% і нема pacing-попередження") — the
    /// "no warning" half is automatic, since a warning needs `utilization > 90` (see ``make``).
    /// The comparison is strict `<` — exactly `5.0` is **not** idle —
    /// matching the strict boundary convention elsewhere (`OAuthCredentials.isExpired`'s `<=`,
    /// `PacingModel`'s `> 90`). Recorded in ADR-0009.
    static let idleUtilizationThreshold = 5.0

    // MARK: make

    /// Build the menu-bar layout from one usage snapshot at instant `now`.
    ///
    /// Steps, all delegating to tested pure logic:
    /// 1. Compute the 5h and 7d `BarLayout` + `LimitIndicator` via `PacingModel`.
    /// 2. Resolve the nearest-reset countdown via `ResetClock.resetDisplay`.
    /// 3. Decide ``MenuBarMode``: ``MenuBarMode/idle`` when both windows are under
    ///    ``idleUtilizationThreshold``; otherwise ``MenuBarMode/expanded``.
    ///
    /// A pacing warning cannot coexist with idle, so it is not a separate condition: both
    /// `LimitIndicator` alerts require `utilization > 90` (`.warning`) or `== 100` (`.critical`)
    /// — far above the 5 % idle threshold — so any warned window is already non-idle. The widget
    /// therefore always shows the full bars whenever the user is anywhere near a cap.
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

        let bothLow = snapshot.fiveHour.utilization < idleUtilizationThreshold
            && snapshot.sevenDay.utilization < idleUtilizationThreshold

        if bothLow {
            AppLogger.ui.notice("menu-bar mode=idle")
            return MenuBarLayout(mode: .idle)
        }

        let (which, reset) = ResetClock.resetDisplay(
            fiveHourResetsAt: snapshot.fiveHour.resetsAt,
            sevenDayResetsAt: snapshot.sevenDay.resetsAt,
            now: now
        ) ?? (.fiveHour, .resetNow)

        AppLogger.ui.notice("menu-bar mode=expanded which=\(String(describing: which), privacy: .public)")
        return MenuBarLayout(
            mode: .expanded(fiveHour: five, sevenDay: seven, reset: reset, which: which)
        )
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
