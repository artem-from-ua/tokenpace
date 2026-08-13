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
    /// "waiting for a limit to reset" rather than "ready to start". Only ever `true` alongside
    /// ``idle``; `false` on every normal bar and on a non-blocked idle bar.
    public let blocked: Bool
    /// Whether the **week** still has room to spend (``PacingModel/weeklyHasHeadroom(in:now:)``), for
    /// the idle bar's fill colour. An idle bar draws no pacing, so it cannot read the gate off its
    /// inert ``layout`` — the verdict rides alongside.
    ///
    /// The "ready to start" blue claims there is quota to burn, which is wrong while the week runs
    /// ahead of pace, so the idle fill degrades to **green** there — grey still means blocked (no work
    /// possible) and blue still means a genuinely calm week. Meaningful only while ``idle``.
    public let weeklyHeadroom: Bool

    public init(
        layout: BarLayout, indicator: LimitIndicator, window: LimitWindow,
        idle: Bool = false, blocked: Bool = false, weeklyHeadroom: Bool = true
    ) {
        self.layout = layout
        self.indicator = indicator
        self.window = window
        self.idle = idle
        self.blocked = blocked
        self.weeklyHeadroom = weeklyHeadroom
    }

    /// The bar's pacing **severity** for reset-countdown selection (#103, ADR-0028/0029). Delegates to
    /// `BarLayout.severity`, except an **idle** 5-hour bar is always ``PacingSeverity/calm``: it carries
    /// an inert placeholder `layout` (`usage 0 / time 0`) and means "ready to start", never a pacing
    /// concern — so it must not drive the countdown. Only the 7-day bar
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
    /// Either bar may be `nil` — whichever one the user chose to hide while it is calm
    /// (``CalmBarHiding``, ADR-0086; the boolean predecessor could only ever hide the 7-day one).
    /// A `nil` here **never** means "no data": both windows always resolve on this path, so it means
    /// "deliberately not drawn". That is the opposite of ``error``, where `nil` *is* absent data.
    ///
    /// **Invariant: at most one of the two is `nil`.** `CalmBarHiding` names a single window, so it can
    /// elide at most one bar whatever the severities are — the widget never renders empty, and the view's
    /// "no bars at all" branch is unreachable. See `CalmBarHiding`'s own note for the argument.
    ///
    /// - Parameters:
    ///   - fiveHour: The 5-hour bar (drawn on top), or `nil` when it is **hidden** because it is calm
    ///     and the user picked `CalmBarHiding.fiveHour`. An **idle** 5-hour bar counts as calm, so it is
    ///     hidden too — between sessions the widget then shows the 7-day bar alone.
    ///   - sevenDay: The 7-day bar (drawn below), or `nil` when it is hidden for the same reason under
    ///     `CalmBarHiding.sevenDay` (the #94 behaviour). Independent of `resetToShow`: hiding a bar does
    ///     not change which reset is shown — `selectReset` runs on the true severities either way.
    ///   - resetToShow: The countdown to draw and which window drives it, or `nil` to draw no
    ///     countdown. Computed by `MenuBarLayout.selectReset` from the 5h×7d severity table and the
    ///     user's `ResetCountdownMode` (#103, ADR-0029) — the view just draws what it is given.
    case expanded(fiveHour: BarView?, sevenDay: BarView?, resetToShow: ResetToShow?)
    /// A subscription-quota state with **no bars** — just the reset countdown, behind a single leading
    /// icon (ADR-0090). The menu bar answers one question, *can we work?*, and this case covers both
    /// answers that are not "yes, on the subscription":
    ///
    /// - **Cannot work** (`CreditsPacing.isBlocked` — every main window exhausted **and** paid credits
    ///   can't cover): the leading red pause icon, countdown from `BlockingReset.forBlocked`.
    /// - **Can work, but paying** (`CreditsPacing.subscriptionExhaustedWhileCovered`): the leading
    ///   currency icon, countdown from `BlockingReset.forSubscriptionExhausted` — the moment the plan
    ///   quota returns and credits stop being spent.
    ///
    /// The two are mutually exclusive by construction (`CreditsPacing` splits them on `creditsCanCover`),
    /// and which icon is drawn is decided by the orthogonal ``MenuBarLayout/blockedPause`` /
    /// ``MenuBarLayout/credits`` fields — not by this case, which only says "no bars, one countdown".
    ///
    /// In both, a red "100 %" bar carries no pacing information: the blocking window is what gates work,
    /// and a 5h bar refilling underneath a blocking 7d window changes nothing (you keep paying until the
    /// *blocking* window resets — which is exactly the countdown shown). The view draws the icon plus a
    /// single label, no bar column, and `itemWidth` reserves the icon + label width.
    ///
    /// Entered from the active-exhausted, idle-blocked and paying paths of ``make(from:now:)``.
    /// The error/stale path never produces it (see ``usageMode``), so diagnostic stale bars are always
    /// kept alongside the ⚠️ glyph.
    ///
    /// - Parameters:
    ///   - reset: The formatted countdown to the reset that ends this state.
    ///   - which: Which window drives it (`.fiveHour` for a 5h-cadence reset, `.sevenDay` for a
    ///     7-day-cadence or credits/monthly reset) — mirrors `ResetToShow`. Informational since
    ///     ADR-0074 made the label format identical on both surfaces.
    case iconOnlyReset(reset: String, which: LimitWindow)
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
    case error(fiveHour: BarView?, sevenDay: BarView?, reset: String?, which: LimitWindow?)
    /// The usage poll is off but services are still watched (#341): a `zzz` glyph, no bars, no
    /// countdown. The status dot — drawn outside this switch — remains the item's only live signal,
    /// which is the point: the widget reports what it is actually collecting.
    ///
    /// A separate case rather than an ``error`` with all-`nil` values, because ``error`` already
    /// carries two meanings (cold start, and a failure run past 60 min) and both decay into a ⚠️.
    /// Reusing it would make a deliberate user choice age into an error report.
    ///
    /// Not to be confused with the *session* idle of ADR-0027 ("no active 5h window"), which is drawn
    /// as a zero bar (ADR-0078). This one means "the user switched usage monitoring off".
    case usagePollingOff
    /// Nothing is monitored at all (#341): a ⚠️ glyph, no bars, no countdown. Distinct from
    /// ``error`` in meaning — nothing is broken — but it does warrant the attention glyph, since a
    /// widget that reports nothing is otherwise indistinguishable from a stuck one. The popup
    /// explains it in words and offers the way back into Settings.
    case nothingMonitored
}

// MARK: - ResetToShow

/// A reset countdown the menu bar should draw: the formatted `display` text and `which` window it
/// belongs to. Produced by `MenuBarLayout.selectReset` (#103, ADR-0029); a `nil` `ResetToShow?`
/// means "draw no countdown".
public struct ResetToShow: Sendable, Equatable {
    public let which: LimitWindow
    /// The ready-to-draw countdown, e.g. `"45m"` / `"5h"` / `"4d"` — one format for every distance
    /// since #284 (ADR-0074), shared with the popup via ``ResetClock/relativeRounded(resetsAt:now:)``.
    public let display: String

    public init(which: LimitWindow, display: String) {
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
    ///   ``ResetClock/timeToReset(resetsAt:now:)`` (`"4d"` when days out, `"20h"` / `"45m"` when
    ///   nearer — one format for every distance since #284), with `which == .sevenDay`.
    ///
    /// - Parameters:
    ///   - snapshot: A decoded usage poll (`UsageClient`/#9).
    ///   - now: Current instant — inject for deterministic tests; never call `Date()` here.
    ///   - resetMode: How to pick/hide the reset countdown (#103, ADR-0029). Default `.smart`.
    ///   - hideCalmBar: Which bar to drop while it is **calm** (`BarView.isCalm` — green on-pace/behind,
    ///     mild-ahead yellow, or far-behind blue), leaving the other one as the single, vertically-centred
    ///     bar (ADR-0086, `PersistedConfig.calmBarHiding`). An orange/red bar is always kept, and at most
    ///     one bar is ever elided, so the widget never ends up empty. Default `.never` (both bars) so
    ///     existing callers and tests are unaffected. This only elides the *bar*; `selectReset` still runs
    ///     on the true severities, so the reset countdown is unchanged (a hidden calm bar never drove it
    ///     anyway). In the session-idle state the inert 5h bar counts as calm and is dropped under
    ///     `.fiveHour`, leaving the 7-day bar alone; under `.sevenDay` a calm 7-day is dropped as before.
    ///
    /// Both bars-less answers to "can we work?" are produced here and need no parameter: being blocked
    /// (`CreditsPacing.isBlocked`) or paying (`CreditsPacing.subscriptionExhaustedWhileCovered`) returns
    /// ``MenuBarMode/iconOnlyReset(reset:which:)`` — the forced countdown to the reset that ends the
    /// state, since a red 100 % bar carries no pacing information either way (ADR-0090; before it, the
    /// blocked half was opt-in via a `pauseHidesBars` toggle). Either falls back to the normal bars path
    /// when its reset does not resolve (an unparseable `resets_at` — let the data-error path handle it).
    /// The error/stale path never reaches them (see ``usageMode``), so diagnostic stale bars are kept.
    public static func make(
        from snapshot: UsageSnapshot, now: Date, resetMode: ResetCountdownMode = .smart,
        hideCalmBar: CalmBarHiding = .never
    ) -> MenuBarLayout {
        // "Can we work?" — the two answers that are not "yes, on the subscription" produce the same
        // bars-less shape (ADR-0090). Both are checked before the idle/active bar-building branches so
        // they short-circuit both, and both fall through to the normal bars path when their reset does
        // not resolve (a broken `resets_at`), letting `hasBrokenActiveReset`/`selectReset` surface the
        // data error instead of a fabricated countdown.
        //
        // The order between them is immaterial — `isBlocked` and `subscriptionExhaustedWhileCovered`
        // are complements on an exhausted main window (`CreditsPacing`, split on `creditsCanCover`), so
        // they are never both true. They are written blocked-first to match the reading order of the
        // question.
        //
        // **No bars, unconditionally.** Before ADR-0090 the blocked branch was gated on a
        // `pauseHidesBars` toggle; the toggle is gone and hiding is now the only behaviour, because a
        // red 100 % bar carries no pacing information in either state.
        if CreditsPacing.isBlocked(in: snapshot),
           let blockedMode = blockedResetMode(for: snapshot, now: now) {
            return MenuBarLayout(mode: blockedMode)
        }
        // Paying: the subscription is spent but credits still cover, so work continues — on money. The
        // countdown is the moment the plan quota returns and credits stop being spent, which is the one
        // thing the user can act on. Deliberately **not** keyed on the credits *icon*'s predicate
        // (`shouldShowIcon` rests on `anyBaseLimitExhausted`, which counts per-model sub-windows that do
        // not gate work at all — an exhausted Opus window must not hide the 5h/7d bars).
        if CreditsPacing.subscriptionExhaustedWhileCovered(in: snapshot),
           let paidMode = paidResetMode(for: snapshot, now: now) {
            return MenuBarLayout(mode: paidMode)
        }

        return MenuBarLayout(mode: expandedBars(for: snapshot, now: now, resetMode: resetMode,
                                                hideCalmBar: hideCalmBar))
    }

    /// The **bars** half of ``make(from:now:resetMode:hideCalmBar:)`` — everything after the two
    /// bars-less answers to "can we work?". Always returns ``MenuBarMode/expanded(fiveHour:sevenDay:resetToShow:)``
    /// or ``MenuBarMode/error(fiveHour:sevenDay:reset:which:)``, **never** ``MenuBarMode/iconOnlyReset(reset:which:)``.
    ///
    /// Split out so the stale/error path in ``usageMode`` can rebuild diagnostic bars from an exhausted
    /// snapshot without being answered with the bars-less shape (ADR-0090). Before that shape became
    /// unconditional, the same guarantee came from passing `pauseHidesBars: false`.
    static func expandedBars(
        for snapshot: UsageSnapshot, now: Date, resetMode: ResetCountdownMode = .smart,
        hideCalmBar: CalmBarHiding = .never
    ) -> MenuBarMode {
        // The weekly gate, resolved once for every exit path below: the 5-hour bar may only go blue
        // while the 7-day window itself has headroom (`PacingModel.weeklyHasHeadroom`). The 7-day bar
        // never gates on itself.
        let weeklyHeadroom = PacingModel.weeklyHasHeadroom(in: snapshot, now: now)
        let seven = bar(for: snapshot.sevenDay, window: .sevenDay, now: now, blueAllowed: true)
        let sevenResetsAt = ResetClock.parse(snapshot.sevenDay.resetsAt)
        // Elide the 7-day bar when it is calm and the user picked it (ADR-0086). `selectReset` below
        // still sees the real `seven.severity`, so the reset-countdown logic is untouched. The 5h side
        // gets the mirror-image treatment on each path that builds it (active and idle alike).
        let sevenToShow: BarView? = hideCalmBar.hides(.sevenDay, isCalm: seven.isCalm) ? nil : seven

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
                layout: BarLayout(usageFraction: 0, timeFraction: 0, pacing: .onPaceOrBehind, remainingSeconds: 0, windowDurationSeconds: 0, blueAllowed: false),
                indicator: .neutral, window: .fiveHour, idle: true, blocked: blocked,
                weeklyHeadroom: weeklyHeadroom)
            // An idle 5h bar reports `.calm` unconditionally (`BarView.severity`), so `.fiveHour` hides
            // it here too — deliberately, with no idle exemption (ADR-0086): between sessions the widget
            // then shows the 7-day bar alone. Nothing else on this path reads `five`; the `selectReset`
            // call below passes `.calm`/`nil` as literals, so eliding the bar cannot move the countdown.
            let fiveToShow: BarView? = hideCalmBar.hides(.fiveHour, isCalm: five.isCalm) ? nil : five
            // In the idle state the 5h window is legitimately date-less (ADR-0027, not an error), but the
            // 7-day window is real: if it reports usage yet its `resets_at` is unparseable, that is the
            // same broken-payload data error as on the active path (#167, ADR-0043) → ⚠️.
            // `hasBrokenActiveReset` already excludes the idle 5h, so it checks only the real 7-day here.
            if snapshot.hasBrokenActiveReset {
                return .error(
                    fiveHour: fiveToShow, sevenDay: sevenToShow, reset: nil, which: nil)
            }
            let resetToShow: ResetToShow?
            if blocked, let choice = BlockingReset.forBlocked(snapshot: snapshot, now: now) {
                // Every blocking candidate in the idle state is a long (7-day-cadence or monthly)
                // window — the 5h window is gone — so `which` is `.sevenDay`.
                resetToShow = ResetToShow(
                    which: .sevenDay,
                    display: ResetClock.timeToReset(resetsAt: choice.resetsAt, now: now))
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
                    return .error(
                        fiveHour: fiveToShow, sevenDay: sevenToShow, reset: nil, which: nil)
                }
            }
            return .expanded(
                fiveHour: fiveToShow, sevenDay: sevenToShow, resetToShow: resetToShow)
        }

        let five = bar(for: snapshot.fiveHour, window: .fiveHour, now: now, blueAllowed: weeklyHeadroom)
        let fiveResetsAt = ResetClock.parse(snapshot.fiveHour.resetsAt)
        // Mirror of `sevenToShow` above: drop the 5h bar while it is calm under `.fiveHour`. Only the
        // *drawn* bar is elided — `five.severity` still feeds `selectReset` below, exactly as the 7-day
        // side has worked since #94.
        let fiveToShow: BarView? = hideCalmBar.hides(.fiveHour, isCalm: five.isCalm) ? nil : five

        // API data error (#167, ADR-0043): a window the server reports as **active** (real usage) but
        // with a present-yet-unparseable `resets_at` is a malformed payload — surface the ⚠️ error state
        // (glyph + last bars), not a fabricated countdown. Checked on the raw snapshot, *before*
        // `bar(for:)` masks a broken date as `elapsedFraction == 1.0` / `.calm` (which would otherwise
        // hide the inconsistency). Shared with the popup via `UsageSnapshot.hasBrokenActiveReset`.
        if snapshot.hasBrokenActiveReset {
            return .error(fiveHour: fiveToShow, sevenDay: sevenToShow, reset: nil, which: nil)
        }

        // Pick which reset countdown to show (or hide) from the 5h×7d severity table + mode (ADR-0029).
        switch selectReset(
            fiveSeverity: five.severity, fiveResetsAt: fiveResetsAt,
            sevenSeverity: seven.severity, sevenResetsAt: sevenResetsAt,
            now: now, mode: resetMode) {
        case .hide:
            return .expanded(fiveHour: fiveToShow, sevenDay: sevenToShow, resetToShow: nil)
        case .show(let resetToShow):
            return .expanded(
                fiveHour: fiveToShow, sevenDay: sevenToShow, resetToShow: resetToShow)
        case .dataError:
            // Defensive: a chosen (noisy) window with no valid instant. In practice
            // `hasBrokenActiveReset` above already promotes this to `.error` before the severity table
            // runs, but keep the branch coherent — an unparseable date is never a countdown.
            return .error(fiveHour: fiveToShow, sevenDay: sevenToShow, reset: nil, which: nil)
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
    ///   - hideCalmBar: Elide the chosen calm bar on the **healthy/stale** path (ADR-0086) — see the
    ///     plain ``make(from:now:resetMode:hideCalmBar:)``. The error state (⚠️ + stale bars) ignores
    ///     it: both bars are diagnostic there and always kept.
    ///   - showCredits: Whether to compute the money-credits icon (#144). When `false`, the credits
    ///     marker is always `nil` (no icon, no width) regardless of the snapshot — the gate is honoured
    ///     here, at the top, so the whole credits path is skipped rather than computed-then-discarded.
    ///     When `true`, the marker is derived from `snapshot.spend` via ``creditsMarker(for:now:)`` —
    ///     `nil` unless the credits show-trigger fires. Independent of `mode` apart from one rule: it is
    ///     suppressed while the pause icon is drawn, since the two answer "can we work?" with
    ///     contradictory halves (ADR-0090). Default `false` so existing callers and tests are unaffected.
    ///   - monitoringAnything: Whether the user monitors anything at all (#341). `false` overrides
    ///     every other input with ``MenuBarMode/nothingMonitored`` — with no data source switched on
    ///     there is nothing to draw, and a stale snapshot must not stand in for one. Default `true`.
    public static func make(
        from snapshot: UsageSnapshot?, health: UsageHealth, now: Date,
        serviceProblem: ServiceStatus? = nil, resetMode: ResetCountdownMode = .smart,
        hideCalmBar: CalmBarHiding = .never, showCredits: Bool = false,
        monitoringAnything: Bool = true
    ) -> MenuBarLayout {
        // The credits marker rides on the snapshot, which is stale in both new modes (#341) — money
        // state that is no longer being refreshed is not worth an icon.
        let dataIsLive = monitoringAnything && health.isCollectingUsage
        let liveCredits = (showCredits && dataIsLive)
            ? snapshot.flatMap { creditsMarker(for: $0, now: now) } : nil
        let layout = usageMode(from: snapshot, health: health, now: now,
                               resetMode: resetMode, hideCalmBar: hideCalmBar,
                               monitoringAnything: monitoringAnything)
        // Pause icon: drawn whenever the user is fully blocked (`CreditsPacing.isBlocked` — no path to
        // work). On the healthy path that now always means ``MenuBarMode/iconOnlyReset``, where it is
        // the leading element before the countdown; `.expanded` stays listed because the blocked branch
        // falls back to bars when its reset cannot be resolved (a broken `resets_at`), and the icon must
        // still mark that state. The diagnostic `.error` state never carries it (stale bars / cold start
        // are not a "blocked right now" signal). #199, #227, ADR-0090.
        let blockedPause: Bool = {
            guard let snapshot, CreditsPacing.isBlocked(in: snapshot) else { return false }
            switch layout.mode {
            case .expanded, .iconOnlyReset: return true
            // The diagnostic and switched-off states all rest on data that is stale or absent; a
            // pause icon there would assert a "blocked right now" that nothing is confirming (#341).
            case .error, .usagePollingOff, .nothingMonitored: return false
            }
        }()
        // The pause icon and the currency icon are **mutually exclusive** (ADR-0090, restoring the
        // invariant `ui-state-truth.md` already claimed). They could previously draw side by side when
        // the money cap was hit: `isActive` is `enabled || spend_limit_reached`, so the icon showed,
        // while `creditsCanCover` is `enabled && !spend_limit_reached`, so the user was also blocked.
        // Two icons then answered "can we work?" with contradictory halves — the pause wins, because
        // "no path to work" is the answer and a red ¤ is a detail of *why*.
        let credits = blockedPause ? nil : liveCredits
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
        resetMode: ResetCountdownMode, hideCalmBar: CalmBarHiding,
        monitoringAnything: Bool = true
    ) -> MenuBarLayout {
        // #341, checked before anything else: these two states are user choices, not poll outcomes,
        // so no snapshot or failure age can override them. Placing them first is what stops the
        // "switched off" states from decaying into the 30/60-min error phases below — a deliberate
        // choice must not age into a report that something is broken.
        guard monitoringAnything else { return MenuBarLayout(mode: .nothingMonitored) }
        guard health.isCollectingUsage else { return MenuBarLayout(mode: .usagePollingOff) }

        // Healthy, or stale within the grace window: show the (possibly stale) bars unchanged.
        // A healthy state with no snapshot only happens at the very first tick before the first
        // poll resolves; with no data to draw, fall back to the bare ⚠️ error glyph.
        guard let age = health.failureAge(now: now) else {
            return snapshot.map { make(from: $0, now: now, resetMode: resetMode,
                                       hideCalmBar: hideCalmBar) }
                ?? MenuBarLayout(mode: .error(fiveHour: nil, sevenDay: nil, reset: nil, which: nil))
        }
        if let snapshot, age <= UsageHealth.glyphAfter {
            return make(from: snapshot, now: now, resetMode: resetMode, hideCalmBar: hideCalmBar)
        }

        // Failing past the glyph threshold. Keep the bars only in the 30–60 min stale window and
        // only if we have a snapshot; otherwise the glyph stands alone. The countdown here is
        // **diagnostic** ("data is stale, last reset was …"), so it always shows the nearest reset,
        // independent of `resetMode`'s selection table (ADR-0029). Both bars are diagnostic too —
        // rebuild **without** `hideCalmBar` (so it defaults to `.never`) and neither bar is ever elided
        // in the error state, whichever one the user hides while healthy.
        //
        // The bars are rebuilt through ``expandedBars(for:now:resetMode:)`` rather than `make`, which
        // since ADR-0090 can answer "can we work?" with the bars-less ``MenuBarMode/iconOnlyReset``
        // whenever the snapshot is exhausted. Routing through `make` here would silently drop the stale
        // bars for exactly the users who are blocked or paying — the diagnostic window collapsing into
        // the bare-glyph one — and a "blocked right now" claim built on data up to an hour old is
        // precisely what this path must not assert (the same reason `blockedPause` is forced `false`
        // for `.error`).
        let keepBars = snapshot != nil && age <= UsageHealth.hideBarsAfter
        guard keepBars, let snapshot,
              case let .expanded(five, seven, _) = expandedBars(for: snapshot, now: now,
                                                                resetMode: resetMode) else {
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
    /// ``usageMode(from:health:now:resetMode:hideCalmBar:pauseHidesBars:)``.
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
    /// the popup's red badge and the idle-blocked bar, so all three agree), then formats it with the
    /// single ``ResetClock/timeToReset(resetsAt:now:)`` format — one shape for every window since #284
    /// (ADR-0074), so no per-window branch is needed here any more.
    ///
    /// `which` still distinguishes a **5h** reset (`.token(id: 0, …)` — index `0` is the 5h row) from
    /// every longer window (7d, per-model, or credits/monthly): it no longer selects a label format,
    /// but it tells the view which limit the countdown belongs to.
    private static func blockedResetMode(for snapshot: UsageSnapshot, now: Date) -> MenuBarMode? {
        guard let choice = BlockingReset.forBlocked(snapshot: snapshot, now: now) else { return nil }
        return iconOnlyMode(for: choice, now: now)
    }

    /// The bars-less **paying** mode (ADR-0090) for a snapshot whose subscription is exhausted while paid
    /// credits still cover the work, or `nil` when no exhausted token window has a parseable `resets_at`
    /// — the caller then falls back to the normal bars path, exactly as ``blockedResetMode(for:now:)``
    /// does, so a data error surfaces as ⚠️ rather than an icon beside an empty countdown.
    ///
    /// Delegates to ``BlockingReset/forSubscriptionExhausted(snapshot:now:)``, which is the same reset
    /// the **popup** paints red for this state (#193) — so both surfaces name the same moment: when the
    /// plan quota returns and credits stop being spent. The credits window is never a candidate there
    /// (credits are what is covering right now, so their month-end reset is not what the user waits on).
    private static func paidResetMode(for snapshot: UsageSnapshot, now: Date) -> MenuBarMode? {
        guard let choice = BlockingReset.forSubscriptionExhausted(snapshot: snapshot, now: now)
        else { return nil }
        return iconOnlyMode(for: choice, now: now)
    }

    /// Format a resolved ``BlockingReset/Choice`` into ``MenuBarMode/iconOnlyReset(reset:which:)`` —
    /// shared by the blocked and paying paths so both label the countdown identically.
    private static func iconOnlyMode(for choice: BlockingReset.Choice, now: Date) -> MenuBarMode {
        // Popup row index `0` is the 5h window; every other id (7d, per-model) and the credits case are
        // longer-cadence. `.credits` cannot occur on the paying path (it passes `creditsReset: nil`).
        let isFiveHour: Bool = { if case .token(0, _) = choice { return true } else { return false } }()
        return .iconOnlyReset(
            reset: ResetClock.timeToReset(resetsAt: choice.resetsAt, now: now),
            which: isFiveHour ? .fiveHour : .sevenDay)
    }

    /// One `BarView` for a window, combining its bar geometry and its exhausted flag
    /// (`limitIndicator`, `.critical` when usage truncates to 100).
    private static func bar(for window: UsageWindow, window kind: LimitWindow, now: Date,
                            blueAllowed: Bool) -> BarView {
        let resetsAt = ResetClock.parse(window.resetsAt) ?? now  // unparseable → elapsedFraction = 1.0
        let layout = PacingModel.barLayout(
            utilization: window.utilization,
            resetsAt: resetsAt,
            now: now,
            window: kind,
            blueAllowed: blueAllowed
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
        now: Date, mode: ResetCountdownMode
    ) -> ResetSelection {
        if mode == .never { return .hide }

        // "Noisy" = worth forcing a countdown for: only orange (`.ahead`) and red (`.exhausted`).
        // Tested explicitly rather than as `!= .calm` so the calmer-than-green `.farBehind` (blue,
        // deep behind pace) is NOT treated as noisy — a deeply-behind window must never force a
        // countdown. This keeps behaviour identical to before `.farBehind` existed.
        let fiveNoisy = fiveSeverity == .ahead || fiveSeverity == .exhausted
        let sevenNoisy = sevenSeverity == .ahead || sevenSeverity == .exhausted

        // Format a chosen window's reset — one format for both windows since #284 (ADR-0074). A chosen
        // window with no valid instant is a data error, not a countdown.
        func display(_ window: LimitWindow, _ resetsAt: Date?) -> ResetSelection {
            guard let at = resetsAt else { return .dataError(window) }
            return .show(ResetToShow(
                which: window, display: ResetClock.timeToReset(resetsAt: at, now: now)))
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
