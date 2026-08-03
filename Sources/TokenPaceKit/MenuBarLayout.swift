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
    /// Exhausted flag (`.critical`/`.neutral`) from `PacingModel.limitIndicator`.
    public let indicator: LimitIndicator
    /// Which rolling window this bar represents (5h on top, 7d below — see ``MenuBarMode``).
    public let window: LimitWindow
    /// Whether this bar is the **idle** 5-hour bar — the 5h window does not exist server-side (no
    /// active session, ``UsageSnapshot/sessionIdle``, #100). When `true` the view draws a **solid,
    /// knobless** track (`StatusItemView` fills it with `Palette.idleBlue`, no zones, no time dot); the
    /// `layout`/`indicator` are inert placeholders (`usage 0 / time 0`, `.neutral`) that the idle draw
    /// path ignores. `false` on every normal bar, including a genuine 0 %-with-valid-reset 5h window.
    public let idle: Bool
    /// Whether this **idle** 5-hour bar is also **blocked** — the 7-day limit is exhausted and paid
    /// credits cannot cover, so there is no path to start a session (#158, `CreditsPacing.isBlocked`).
    /// When `true` the view draws the solid idle track in **grey** (not the "ready" blue), meaning
    /// "waiting for a limit to reset" rather than "ready to start, full quota available". Only ever
    /// `true` alongside ``idle``; `false` on every normal bar and on a non-blocked idle bar.
    public let blocked: Bool

    public init(
        layout: BarLayout, indicator: LimitIndicator, window: LimitWindow,
        idle: Bool = false, blocked: Bool = false
    ) {
        self.layout = layout
        self.indicator = indicator
        self.window = window
        self.idle = idle
        self.blocked = blocked
    }

    /// The bar's pacing **severity** for reset-countdown selection (#103, ADR-0028/0029). Delegates to
    /// `BarLayout.severity`, except an **idle** 5-hour bar is always ``PacingSeverity/calm``: it carries
    /// an inert placeholder `layout` (`usage 0 / time 0`) and means "ready to start, full quota
    /// available", never a pacing concern — so it must not drive the countdown. Only the 7-day bar
    /// decides in the idle state.
    public var severity: PacingSeverity { idle ? .calm : layout.severity }

    /// Whether this bar is "calm" (blue/green/yellow — not worth flagging). Derived from ``severity``
    /// (idle → always calm); both `.calm` and the calmer-than-green `.farBehind` (blue) count, matching
    /// ``BarLayout/isCalm``. Reset-countdown selection uses `.ahead`/`.exhausted` directly, so blue never
    /// forces a countdown (see `selectReset`).
    public var isCalm: Bool { severity == .calm || severity == .farBehind }
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
    ///   - fiveHour: The 5-hour bar (drawn on top, or alone and vertically centred when `sevenDay`
    ///     is `nil`).
    ///   - sevenDay: The 7-day bar (drawn below), or `nil` when it is **hidden** because it is calm
    ///     and the user opted into the quieter single-bar look (`hideCalmSevenDay`, #94). The view
    ///     then draws only the 5h bar, vertically centred. `nil` never means "no data" — an absent
    ///     7-day window is impossible here (both windows always resolve); it means "deliberately not
    ///     drawn". Independent of `resetToShow`: hiding the bar does not change which reset is shown.
    ///   - resetToShow: The countdown to draw and which window drives it, or `nil` to draw no
    ///     countdown. Computed by `MenuBarLayout.selectReset` from the 5h×7d severity table and the
    ///     user's `ResetCountdownMode` (#103, ADR-0029) — the view just draws what it is given.
    case expanded(fiveHour: BarView, sevenDay: BarView?, resetToShow: ResetToShow?)
    /// Blocked state with **no bars** — just the reset countdown, with the leading red pause icon
    /// (#194, #227). Shown only when the user has "Pause icon hides bars" on (`pauseHidesBars`) **and**
    /// is fully blocked (`CreditsPacing.isBlocked` — every main window exhausted **and** paid credits
    /// can't cover). A red "100 %" bar carries no pacing information, so it is dropped and only the
    /// actionable countdown to the blocking reset remains (`BlockingReset.forBlocked`, formatted like
    /// the chosen window's `ResetToShow`). The view draws the pause icon plus a single label, no bar
    /// column, and `itemWidth` reserves the icon + label width.
    ///
    /// Entered from both the active-exhausted path and the idle-blocked path of ``make(from:now:)``.
    /// The error/stale path never produces it (its `make` call passes `pauseHidesBars: false`), so
    /// diagnostic stale bars are always kept alongside the ⚠️ glyph.
    ///
    /// - Parameters:
    ///   - reset: The formatted countdown to the blocking reset.
    ///   - which: Which window drives it (`.fiveHour` for a 5h-cadence reset, `.sevenDay` for a
    ///     7-day-cadence or credits/monthly reset) — decides the label format and mirrors `ResetToShow`.
    case blockedReset(reset: TimeToReset, which: LimitWindow)
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

// MARK: - ResetSelection

/// The outcome of ``MenuBarLayout/selectReset(...)`` — three distinct results, so the caller can tell
/// "hide the countdown" apart from "the chosen window's `resets_at` is broken" (which is an API data
/// error, not an empty state — #167, ADR-0043):
/// - ``hide`` — draw no countdown (both bars calm and the mode does not force one, or a distant
///   ahead-of-pace 7-day gated off). A legitimate quiet state.
/// - ``show(_:)`` — draw this countdown.
/// - ``dataError(_:)`` — the chosen (noisy) window has a missing/unparseable `resets_at`: the layer
///   promotes the whole menu bar to its ⚠️ error state, exactly as for other API failures, rather than
///   inventing a fake countdown. Carries the window whose date was broken (for diagnostics/tests).
public enum ResetSelection: Sendable, Equatable {
    case hide
    case show(ResetToShow)
    case dataError(LimitWindow)
}

// MARK: - CreditsMarker

/// The money-credits ("extra usage") icon the menu bar should draw — the pure decision behind the
/// trailing currency glyph (`coloncurrencysign` ¤) of issue #144.
///
/// Its **presence** answers "draw the icon at all?" (a `nil` ``MenuBarLayout/credits`` means "no
/// icon"); its ``bar`` answers "which colour?", using the **same** ``BarLayout`` → colour mapping the
/// pacing bars use (`PopupBarView.aheadColor` in the AppKit layer). This mirrors the ``BarView`` split
/// (ADR-0005/0009): the Kit owns only the semantic `BarLayout`, and `StatusItemView` resolves the
/// `NSColor` — so `TokenPaceKit` never imports AppKit.
///
/// - ``bar`` **non-`nil`** — there is a money cap to pace against, so the icon is coloured by the same
///   `usage`-vs-`time` grading as a token bar: green (on pace / behind) → yellow → orange → **red only
///   at the cap** (`CreditsPacing.barLayout` forces `usage = 1` when `spend_limit_reached`).
/// - ``bar`` **`nil`** — the monthly limit is *unlimited* (`spend.limit: null`): there is nothing to
///   pace, so the view draws the icon in a **neutral** foreground colour (no pacing tint). The icon
///   still shows (credits are active), it just carries no severity.
///
/// Built by ``MenuBarLayout/make(from:now:credits:)`` from `CreditsPacing.shouldShowIcon` (presence)
/// and `CreditsPacing.barLayout` (the `bar`); the view maps it in `StatusItemView.drawCreditsIcon`.
public struct CreditsMarker: Sendable, Equatable {
    /// The pacing bar whose colour tints the icon, or `nil` for an **unlimited** monthly limit —
    /// then the view draws the icon neutrally (no pacing colour). Fed the same `aheadColor` mapping as
    /// the token bars, so a yellow credits icon and a yellow 7-day bar read as the same amber.
    public let bar: BarLayout?

    /// The ISO currency code of the credits (e.g. `"EUR"`, `"USD"`) — drives *which glyph* the view
    /// draws: a known currency uses its own SF Symbol (`eurosign`/`dollarsign`/…), an unknown or empty
    /// code falls back to the generic `coloncurrencysign` (¤). Kept here (not resolved to a glyph) so
    /// `TokenPaceKit` stays AppKit-free — `StatusItemView.creditsSymbolName` maps code → symbol.
    public let currency: String

    public init(bar: BarLayout?, currency: String = "") {
        self.bar = bar
        self.currency = currency
    }

    /// Whether the icon's pacing is "calm" (green/yellow) — the same predicate the bars use to mute
    /// their colour under "Calm colours" (#105). An **unlimited** marker (`bar == nil`) is treated as
    /// calm: a neutral, non-pacing icon is a soft signal, so it mutes to white alongside the calm bars
    /// rather than staying a stray tint over a quieted menu bar. Delegates to ``BarLayout/isCalm``.
    public var isCalm: Bool { bar?.isCalm ?? true }
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

    /// The money-credits icon to draw, or `nil` when no credits icon should be shown (#144). Presence is
    /// decided by `CreditsPacing.shouldShowIcon` (`enabled`/`spend_limit_reached` **and** a base limit
    /// exhausted); its ``CreditsMarker/bar`` carries the colour. Orthogonal to `mode`/`serviceProblem` —
    /// the credits state is independent of the usage bars and the service status. When `nil`, no icon and
    /// no width is reserved for it. **Placement** is view-side (`StatusItemView`): in the bars modes
    /// (`.expanded`/`.blockedReset`) it is a **leading** element between the pause icon and the bars/
    /// countdown (#227); in the diagnostic `.error` state it stays **trailing** (before the service dot).
    public let credits: CreditsMarker?

    /// Whether to draw the red "pause" glyph as the **leading** element (#199, #227). Set `true`
    /// **whenever** the snapshot is `CreditsPacing.isBlocked` (every limit exhausted **and** paid credits
    /// can't cover — no path to work), always — the icon is not user-optional. The view draws it left of
    /// the bars in ``MenuBarMode/expanded`` and left of the countdown in the bars-less
    /// ``MenuBarMode/blockedReset`` (#194). Whether the bars are kept beside it or hidden is the separate
    /// `PersistedConfig.pauseHidesBars` toggle (decided in `make` before this decoration). Never `true`
    /// for the diagnostic ``MenuBarMode/error`` state. Orthogonal to `mode` — a leading decoration,
    /// computed at the health-aware `make` seam like `credits`. When `false`, no glyph is drawn and no
    /// width is reserved.
    public let blockedPause: Bool

    /// The Claude Code sessions awaiting user input to advertise with the `hand.raised` indicator
    /// (#233, ADR-0066), or `nil` to draw nothing. `nil` whenever the feature is off, the count is
    /// `0`, or the watcher isn't running — the view reserves no width then. When non-`nil` (count
    /// `≥ 1`) the menu bar draws the **bare icon** (no count — the count is popup-only), tinted by
    /// ``AwaitingSessions/urgency`` (red/orange/neutral by soonest deletion). Sourced by the shell
    /// from `AwaitingInputWatcher`, independent of the usage snapshot, so it's grafted on like
    /// `credits`/`blockedPause` rather than computed in `make`.
    public let awaitingInput: AwaitingSessions?

    public init(mode: MenuBarMode, serviceProblem: ServiceStatus? = nil, credits: CreditsMarker? = nil,
                blockedPause: Bool = false, awaitingInput: AwaitingSessions? = nil) {
        self.mode = mode
        self.serviceProblem = serviceProblem
        self.credits = credits
        self.blockedPause = blockedPause
        self.awaitingInput = awaitingInput
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
    /// When a **noisy** window's `resets_at` is missing/unparseable, ``selectReset(...)`` returns
    /// ``ResetSelection/dataError(_:)`` and the layout is promoted to ``MenuBarMode/error`` (⚠️ + last
    /// bars) — an API data error is shown as one, not as a fabricated countdown (#167, ADR-0043). A
    /// past-boundary window is instead rolled forward before formatting (`optimisticReset`), so no
    /// "reset now" placeholder is ever needed.
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
    ///   - resetMode: How to pick/hide the reset countdown (#103, ADR-0029). Default `.smart`.
    ///   - hideCalmSevenDay: When `true`, the 7-day bar is dropped (`sevenDay == nil`) whenever it is
    ///     **calm** (`BarView.isCalm` — green on-pace/behind or mild-ahead yellow), leaving the 5h bar
    ///     as the single, vertically-centred bar (#94, opt-out `PersistedConfig.hideCalmSevenDayBar`).
    ///     An orange/red 7-day bar is always kept. Default `false` (both bars) so existing callers and
    ///     tests are unaffected. This only elides the *bar*; `selectReset` still runs on the true
    ///     severities, so the reset countdown is unchanged (a hidden calm 7-day never drove it anyway).
    ///     In the session-idle state a calm 7-day is likewise dropped, leaving only the idle 5h bar.
    ///   - pauseHidesBars: When `true` **and** the user is fully blocked (`CreditsPacing.isBlocked` —
    ///     every main window exhausted **and** paid credits can't cover), drop *both* bars and return
    ///     ``MenuBarMode/blockedReset(reset:which:)`` — just the blocking-reset countdown
    ///     (`BlockingReset.forBlocked`), since a red 100 % bar carries no pacing information; the leading
    ///     pause icon then stands alone (#194, #227, `PersistedConfig.pauseHidesBars`). While credits
    ///     still cover an exhausted window it is not a block, so the bars stay. The blocking reset is
    ///     **forced** regardless of `resetMode` (the countdown is the only useful signal once the bars
    ///     are gone). Falls back to the normal bars path when `forBlocked` yields `nil` (an unparseable
    ///     `resets_at` — let the data-error path handle it). Default `false` so existing callers and
    ///     tests are unaffected. The error/stale path deliberately passes `false` (see ``usageMode``) so
    ///     diagnostic stale bars are never dropped.
    public static func make(
        from snapshot: UsageSnapshot, now: Date, resetMode: ResetCountdownMode = .smart,
        hideCalmSevenDay: Bool = false, pauseHidesBars: Bool = false,
        behindMultiplier: Int = 2
    ) -> MenuBarLayout {
        let seven = bar(for: snapshot.sevenDay, window: .sevenDay, now: now, behindMultiplier: behindMultiplier)
        let sevenResetsAt = ResetClock.parse(snapshot.sevenDay.resetsAt)
        // Elide the 7-day bar when it is calm and the user opted in (#94). `selectReset` below still
        // sees the real `seven.severity`, so the reset-countdown logic is untouched.
        let sevenToShow: BarView? = (hideCalmSevenDay && seven.isCalm) ? nil : seven

        // Blocked → no bars, just the countdown (#194, #227). Checked before the idle/active bar-building
        // branches below so it short-circuits both. Gated by `pauseHidesBars` (the pause icon hides the
        // bars) on the strict `isBlocked` predicate — every main window exhausted **and** paid credits
        // can't cover, so there is no path to work (shared with the pause icon and the popup's red badge).
        // While credits still cover, this is not a block: the bars stay. `forBlocked` picks the single
        // reset that unblocks work; a `nil` from it (broken `resets_at`) falls through to the normal path,
        // where `hasBrokenActiveReset`/`selectReset` surface the data error instead of a fabricated one.
        if pauseHidesBars, CreditsPacing.isBlocked(in: snapshot),
           let blockedMode = blockedResetMode(for: snapshot, now: now) {
            return MenuBarLayout(mode: blockedMode)
        }

        if snapshot.sessionIdle {
            // No active 5h window: an inert, knobless placeholder bar (the idle draw path ignores its
            // geometry). When the idle state is genuinely **blocked** (#158 — 7d exhausted and credits
            // cannot cover) the bar is drawn grey and the countdown switches to the **blocking** reset
            // (the "last stand" rule, shared with the popup). Otherwise it stays the "ready" idle bar
            // with the plain 7-day countdown.
            let blocked = CreditsPacing.isBlocked(in: snapshot)
            let five = BarView(
                // Inert placeholder: `.onPaceOrBehind` → `severity` is `.calm` before `remainingSeconds`
                // is ever read, so the value here is immaterial (0).
                layout: BarLayout(usageFraction: 0, timeFraction: 0, pacing: .onPaceOrBehind, remainingSeconds: 0, windowDurationSeconds: 0, behindMultiplier: 2),
                indicator: .neutral, window: .fiveHour, idle: true, blocked: blocked)
            // In the idle state the 5h window is legitimately date-less (ADR-0027, not an error), but the
            // 7-day window is real: if it reports usage yet its `resets_at` is unparseable, that is the
            // same broken-payload data error as on the active path (#167, ADR-0043) → ⚠️.
            // `hasBrokenActiveReset` already excludes the idle 5h, so it checks only the real 7-day here.
            if snapshot.hasBrokenActiveReset {
                return MenuBarLayout(mode: .error(
                    fiveHour: five, sevenDay: sevenToShow, reset: nil, which: nil))
            }
            let resetToShow: ResetToShow?
            if blocked, let choice = BlockingReset.forBlocked(snapshot: snapshot, now: now) {
                // Every blocking candidate in the idle state is a long (7-day-cadence or monthly)
                // window — the 5h window is gone — so format it with the compact-days variant.
                let text = ResetClock.timeToResetCompactDays(resetsAt: choice.resetsAt, now: now)
                resetToShow = ResetToShow(which: .sevenDay, display: text)
            } else {
                // The idle 5h passes `fiveResetsAt: nil` deliberately (no 5h window) with `.calm`
                // severity, so it is never the *chosen* window; a broken 7-day date was already caught
                // above, so `.dataError` should not arise here — handle it coherently regardless.
                switch selectReset(
                    fiveSeverity: .calm, fiveResetsAt: nil,
                    sevenSeverity: seven.severity, sevenResetsAt: sevenResetsAt,
                    now: now, mode: resetMode) {
                case .hide: resetToShow = nil
                case .show(let r): resetToShow = r
                case .dataError:
                    return MenuBarLayout(mode: .error(
                        fiveHour: five, sevenDay: sevenToShow, reset: nil, which: nil))
                }
            }
            return MenuBarLayout(mode: .expanded(
                fiveHour: five, sevenDay: sevenToShow, resetToShow: resetToShow))
        }

        let five = bar(for: snapshot.fiveHour, window: .fiveHour, now: now, behindMultiplier: behindMultiplier)
        let fiveResetsAt = ResetClock.parse(snapshot.fiveHour.resetsAt)

        // API data error (#167, ADR-0043): a window the server reports as **active** (real usage) but
        // with a present-yet-unparseable `resets_at` is a malformed payload — surface the ⚠️ error state
        // (glyph + last bars), not a fabricated countdown. Checked on the raw snapshot, *before*
        // `bar(for:)` masks a broken date as `elapsedFraction == 1.0` / `.calm` (which would otherwise
        // hide the inconsistency). Shared with the popup via `UsageSnapshot.hasBrokenActiveReset`.
        if snapshot.hasBrokenActiveReset {
            return MenuBarLayout(mode: .error(fiveHour: five, sevenDay: sevenToShow, reset: nil, which: nil))
        }

        // Pick which reset countdown to show (or hide) from the 5h×7d severity table + mode (ADR-0029).
        switch selectReset(
            fiveSeverity: five.severity, fiveResetsAt: fiveResetsAt,
            sevenSeverity: seven.severity, sevenResetsAt: sevenResetsAt,
            now: now, mode: resetMode) {
        case .hide:
            return MenuBarLayout(mode: .expanded(fiveHour: five, sevenDay: sevenToShow, resetToShow: nil))
        case .show(let resetToShow):
            return MenuBarLayout(mode: .expanded(
                fiveHour: five, sevenDay: sevenToShow, resetToShow: resetToShow))
        case .dataError:
            // Defensive: a chosen (noisy) window with no valid instant. In practice
            // `hasBrokenActiveReset` above already promotes this to `.error` before the severity table
            // runs, but keep the branch coherent — an unparseable date is never a countdown.
            return MenuBarLayout(mode: .error(fiveHour: five, sevenDay: sevenToShow, reset: nil, which: nil))
        }
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
    ///   - hideCalmSevenDay: Elide the calm 7-day bar on the **healthy/stale** path (#94) — see the
    ///     plain ``make(from:now:resetMode:hideCalmSevenDay:)``. The error state (⚠️ + stale bars)
    ///     ignores it: the 7-day bar is diagnostic there and always kept.
    ///   - showCredits: Whether to compute the money-credits icon (#144), gated by the user's
    ///     `PersistedConfig.showExtraUsage` toggle. When `false`, the credits marker is always `nil`
    ///     (no icon, no width) regardless of the snapshot — the gate is honoured here, at the top, so
    ///     the whole credits path is skipped rather than computed-then-discarded. When `true`, the
    ///     marker is derived from `snapshot.spend` via ``creditsMarker(for:now:)`` — `nil` unless the
    ///     credits show-trigger fires. Independent of `mode`: even the error/cold-start states can
    ///     carry a credits icon (the money state is orthogonal to polling health). Default `false` so
    ///     existing callers and tests are unaffected.
    ///   - pauseHidesBars: When the user is fully blocked (`CreditsPacing.isBlocked`), whether the red
    ///     pause icon **hides** the bars — drop the bars and show only the blocking-reset countdown on the
    ///     **healthy/stale** path (#194, #227, `PersistedConfig.pauseHidesBars`) — see the plain
    ///     ``make(from:now:resetMode:hideCalmSevenDay:pauseHidesBars:)``. `false` keeps the bars beside
    ///     the icon. The error state (⚠️ + stale bars) ignores it: the bars are diagnostic there and
    ///     always kept. Default `false`. Note: the pause icon itself is drawn whenever blocked,
    ///     independent of this flag (see below).
    public static func make(
        from snapshot: UsageSnapshot?, health: UsageHealth, now: Date,
        serviceProblem: ServiceStatus? = nil, resetMode: ResetCountdownMode = .smart,
        hideCalmSevenDay: Bool = false, showCredits: Bool = false, pauseHidesBars: Bool = false,
        behindMultiplier: Int = 2
    ) -> MenuBarLayout {
        let credits = showCredits ? snapshot.flatMap { creditsMarker(for: $0, now: now) } : nil
        let layout = usageMode(from: snapshot, health: health, now: now,
                               resetMode: resetMode, hideCalmSevenDay: hideCalmSevenDay,
                               pauseHidesBars: pauseHidesBars,
                               behindMultiplier: behindMultiplier)
        // Pause icon: drawn whenever the user is fully blocked (`CreditsPacing.isBlocked` — no path to
        // work), **always**, independent of `pauseHidesBars` (that flag only decides whether the bars are
        // hidden beside it). Left of the bars (`.expanded`) or left of the countdown (`.blockedReset`,
        // #194). The diagnostic `.error` state never carries it (stale bars / cold start are not a "fully
        // blocked" signal). #199, #227.
        let blockedPause: Bool = {
            guard let snapshot, CreditsPacing.isBlocked(in: snapshot) else { return false }
            switch layout.mode {
            case .expanded, .blockedReset: return true
            case .error: return false
            }
        }()
        return layout.with(serviceProblem: serviceProblem, credits: credits, blockedPause: blockedPause)
    }

    /// The money-credits icon marker for a snapshot at `now`, or `nil` when no credits icon should
    /// be drawn (#144). Pure/testable — the single Kit-side bridge between ``CreditsPacing`` and the
    /// view.
    ///
    /// Returns `nil` unless **both** halves of the trigger hold (`CreditsPacing.shouldShowIcon`):
    /// credits are active (`enabled` OR `spend_limit_reached`) **and** at least one base limit is
    /// exhausted (`CreditsPacing.anyBaseLimitExhausted`). When it does show, the marker's
    /// ``CreditsMarker/bar`` is `CreditsPacing.barLayout` — the same `usage`-vs-`time` pacing the token
    /// bars use — or `nil` for an unlimited monthly limit (the view then draws a neutral icon).
    ///
    /// A snapshot without a `spend` block (pre-credits payload) yields `nil` — there is nothing to
    /// show. Injects `now` for the month-elapsed `timeFraction`; never calls `Date()`.
    public static func creditsMarker(for snapshot: UsageSnapshot, now: Date) -> CreditsMarker? {
        guard let spend = snapshot.spend else { return nil }
        let baseExhausted = CreditsPacing.anyBaseLimitExhausted(in: snapshot)
        guard CreditsPacing.shouldShowIcon(spend, baseLimitExhausted: baseExhausted) else { return nil }
        return CreditsMarker(
            bar: CreditsPacing.barLayout(for: spend, now: now),
            currency: spend.currencyCode)
    }

    /// The usage-driven `mode` only (no service dot) — the existing #12 decision tree, factored out
    /// so ``make(from:health:now:serviceProblem:resetMode:)`` can graft the service dot onto its result.
    private static func usageMode(
        from snapshot: UsageSnapshot?, health: UsageHealth, now: Date,
        resetMode: ResetCountdownMode, hideCalmSevenDay: Bool, pauseHidesBars: Bool,
        behindMultiplier: Int
    ) -> MenuBarLayout {
        // Healthy, or stale within the grace window: show the (possibly stale) bars unchanged.
        // A healthy state with no snapshot only happens at the very first tick before the first
        // poll resolves; with no data to draw, fall back to the bare ⚠️ error glyph.
        guard let age = health.failureAge(now: now) else {
            return snapshot.map { make(from: $0, now: now, resetMode: resetMode,
                                       hideCalmSevenDay: hideCalmSevenDay, pauseHidesBars: pauseHidesBars,
                                       behindMultiplier: behindMultiplier) }
                ?? MenuBarLayout(mode: .error(fiveHour: nil, sevenDay: nil, reset: nil, which: nil))
        }
        if let snapshot, age <= UsageHealth.glyphAfter {
            return make(from: snapshot, now: now, resetMode: resetMode,
                        hideCalmSevenDay: hideCalmSevenDay, pauseHidesBars: pauseHidesBars,
                        behindMultiplier: behindMultiplier)
        }

        // Failing past the glyph threshold. Keep the bars only in the 30–60 min stale window and
        // only if we have a snapshot; otherwise the glyph stands alone. The countdown here is
        // **diagnostic** ("data is stale, last reset was …"), so it always shows the nearest reset,
        // independent of `resetMode`'s selection table (ADR-0029). The 7-day bar is diagnostic too —
        // rebuild with `hideCalmSevenDay: false` so a calm 7-day is never elided in the error state.
        // `pauseHidesBars` is likewise **not** forwarded (defaults to `false`): an exhausted-yet-stale
        // state must keep its diagnostic bars, and this `case let .expanded` destructuring relies on
        // `make` never returning `.blockedReset` here (#194).
        let keepBars = snapshot != nil && age <= UsageHealth.hideBarsAfter
        guard keepBars, let snapshot,
              case let .expanded(five, seven, _) = make(from: snapshot, now: now, resetMode: resetMode,
                                                        behindMultiplier: behindMultiplier).mode else {
            return MenuBarLayout(mode: .error(fiveHour: nil, sevenDay: nil, reset: nil, which: nil))
        }
        // Both `resets_at` unparseable → no diagnostic countdown (the ⚠️ + stale bars still show).
        let resolved = ResetClock.resetDisplay(
            fiveHourResetsAt: snapshot.fiveHour.resetsAt,
            sevenDayResetsAt: snapshot.sevenDay.resetsAt,
            now: now)
        return MenuBarLayout(mode: .error(
            fiveHour: five, sevenDay: seven, reset: resolved?.display, which: resolved?.which))
    }

    /// A copy of this layout carrying `serviceProblem`, `credits`, and `blockedPause` (the `mode` is
    /// unchanged) — the decorations grafted onto the usage `mode` computed by
    /// ``usageMode(from:health:now:resetMode:hideCalmSevenDay:pauseHidesBars:)``.
    func with(serviceProblem: ServiceStatus?, credits: CreditsMarker?, blockedPause: Bool,
              awaitingInput: AwaitingSessions? = nil) -> MenuBarLayout {
        MenuBarLayout(mode: mode, serviceProblem: serviceProblem, credits: credits,
                      blockedPause: blockedPause, awaitingInput: awaitingInput)
    }

    /// A copy of this layout with the awaiting-input count grafted on, everything else unchanged
    /// (#233). The shell calls this on the `make(...)` result so the awaiting indicator — sourced
    /// from `AwaitingInputWatcher`, not the usage snapshot — doesn't have to thread through `make`.
    public func withAwaitingInput(_ awaitingInput: AwaitingSessions?) -> MenuBarLayout {
        MenuBarLayout(mode: mode, serviceProblem: serviceProblem, credits: credits,
                      blockedPause: blockedPause, awaitingInput: awaitingInput)
    }

    // MARK: - Private

    /// The bars-less blocked mode (#194) for a snapshot whose main window is exhausted, or `nil` when
    /// no blocking reset can be resolved (every exhausted window has an unparseable `resets_at`) — the
    /// caller then falls back to the normal bars path so the data error surfaces as ⚠️ rather than a
    /// fabricated countdown.
    ///
    /// Delegates the *which reset* decision to ``BlockingReset/forBlocked(snapshot:now:)`` (shared with
    /// the popup's red badge and the idle-blocked bar, so all three agree), then formats it exactly like
    /// ``selectReset``'s chosen window: a **5h** reset (`.token(id: 0, …)` — index `0` is the 5h row) as
    /// a live `H:MM` countdown, every longer window (7d, per-model, or credits/monthly) as the
    /// compact-days variant. `which` mirrors that split so the view knows the label format.
    private static func blockedResetMode(for snapshot: UsageSnapshot, now: Date) -> MenuBarMode? {
        guard let choice = BlockingReset.forBlocked(snapshot: snapshot, now: now) else { return nil }
        // Only the 5h window (popup row index 0) resets on the 5-hour cadence; 7d / per-model / credits
        // are all long windows formatted in compact days.
        let isFiveHour: Bool = { if case .token(0, _) = choice { return true } else { return false } }()
        let which: LimitWindow = isFiveHour ? .fiveHour : .sevenDay
        let text = isFiveHour
            ? ResetClock.timeToReset(resetsAt: choice.resetsAt, now: now)
            : ResetClock.timeToResetCompactDays(resetsAt: choice.resetsAt, now: now)
        return .blockedReset(reset: text, which: which)
    }

    /// One `BarView` for a window, combining its bar geometry and its exhausted flag
    /// (`limitIndicator`, `.critical` when usage truncates to 100).
    private static func bar(for window: UsageWindow, window kind: LimitWindow, now: Date,
                            behindMultiplier: Int) -> BarView {
        let resetsAt = ResetClock.parse(window.resetsAt) ?? now  // unparseable → elapsedFraction = 1.0
        let layout = PacingModel.barLayout(
            utilization: window.utilization,
            resetsAt: resetsAt,
            now: now,
            window: kind,
            behindMultiplier: behindMultiplier
        )
        let indicator = PacingModel.limitIndicator(utilization: window.utilization)
        return BarView(layout: layout, indicator: indicator, window: kind)
    }

    // MARK: - Reset-countdown selection (#103, ADR-0029)

    /// Choose which reset countdown (5h or 7d) the menu bar should show, per the 5h×7d severity table
    /// and the user's ``ResetCountdownMode``. Pure/testable — the single source of the selection table.
    ///
    /// The semantics ("show the next real unblock"):
    /// - both bars **calm** → hidden, unless the mode shows a countdown even then (`always` → nearest).
    /// - exactly one bar **noisy** → that bar's reset. A lone **7d ahead-of-pace (orange)** is gated:
    ///   shown when `< 24 h` out, or when the mode shows a days-away one; a 7d **exhausted (red)** is
    ///   always shown. A noisy **5h** is always shown (its reset is near by definition).
    /// - both bars **noisy** → the next unblock: both **exhausted** → the **later** reset (blocked
    ///   until both clear); both **ahead** → the **earlier** reset (neither blocks yet); **red+orange**
    ///   → the **red** bar's reset (only it blocks).
    ///
    /// A chosen (noisy) window whose `resets_at` is **missing/unparseable** yields ``ResetSelection/dataError(_:)``
    /// — an API data error, so the caller promotes the menu bar to its ⚠️ error state rather than
    /// inventing a countdown (#167, ADR-0043). A window that is merely **not chosen** (gated off, both
    /// calm) yields ``ResetSelection/hide`` — a quiet state, not an error.
    static func selectReset(
        fiveSeverity: PacingSeverity, fiveResetsAt: Date?,
        sevenSeverity: PacingSeverity, sevenResetsAt: Date?,
        now: Date, mode: ResetCountdownMode,
        locale: Locale = .current, timeZone: TimeZone = .current
    ) -> ResetSelection {
        if mode == .never { return .hide }

        // "Noisy" = worth forcing a countdown for: only orange (`.ahead`) and red (`.exhausted`).
        // Tested explicitly rather than as `!= .calm` so the calmer-than-green `.farBehind` (blue,
        // deep behind pace) is NOT treated as noisy — a deeply-behind window must never force a
        // countdown. This keeps behaviour identical to before `.farBehind` existed.
        let fiveNoisy = fiveSeverity == .ahead || fiveSeverity == .exhausted
        let sevenNoisy = sevenSeverity == .ahead || sevenSeverity == .exhausted

        // Format a chosen window's reset (5h → live countdown; 7d → compact-days variant). A chosen
        // window with no valid instant is a data error, not a countdown.
        func display(_ window: LimitWindow, _ resetsAt: Date?) -> ResetSelection {
            guard let at = resetsAt else { return .dataError(window) }
            let text = window == .sevenDay
                ? ResetClock.timeToResetCompactDays(resetsAt: at, now: now, locale: locale, timeZone: timeZone)
                : ResetClock.timeToReset(resetsAt: at, now: now, locale: locale, timeZone: timeZone)
            return .show(ResetToShow(which: window, display: text))
        }
        // A "nearest/latest of two calm-ish windows" pick: no window to show → hide (not an error —
        // this branch is only reached when neither window is individually blocking).
        func pick(_ nr: NearestReset?) -> ResetSelection {
            guard let nr else { return .hide }
            return display(nr.window, nr.resetsAt)
        }

        switch (fiveNoisy, sevenNoisy) {
        case (true, true):
            // Both noisy → next unblock.
            if fiveSeverity == .exhausted && sevenSeverity == .exhausted {
                return pick(ResetClock.latestReset(fiveHour: fiveResetsAt, sevenDay: sevenResetsAt))
            } else if fiveSeverity == .ahead && sevenSeverity == .ahead {
                return pick(ResetClock.nearestReset(fiveHour: fiveResetsAt, sevenDay: sevenResetsAt))
            } else {
                // red + orange → the red (exhausted) bar.
                return fiveSeverity == .exhausted
                    ? display(.fiveHour, fiveResetsAt)
                    : display(.sevenDay, sevenResetsAt)
            }
        case (true, false):
            // Only 5h noisy → its reset (always near enough to matter).
            return display(.fiveHour, fiveResetsAt)
        case (false, true):
            // Only 7d noisy. Red → always; orange → gated by distance + mode.
            if sevenSeverity == .exhausted {
                return display(.sevenDay, sevenResetsAt)
            } else {
                let far = (sevenResetsAt?.timeIntervalSince(now) ?? 0) >= 24 * 3_600
                return (far && !mode.showsSevenDayAheadWhenFar) ? .hide : display(.sevenDay, sevenResetsAt)
            }
        case (false, false):
            // Both calm → hidden, unless the mode shows a countdown anyway (nearest).
            return mode.showsWhenBothCalm
                ? pick(ResetClock.nearestReset(fiveHour: fiveResetsAt, sevenDay: sevenResetsAt))
                : .hide
        }
    }
}
