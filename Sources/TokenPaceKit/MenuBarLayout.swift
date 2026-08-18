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
    /// active session, ``UsageSnapshot/sessionIdle``, #100). When `true` the view draws the **knobless
    /// zero pill** — grey track plus a green pill at zero, no zones (ADR-0078); Progress additionally
    /// parks its time marker there. Grey instead of green when `blocked`; the
    /// `layout`/`indicator` are inert placeholders (`usage 0 / time 0`, `.neutral`) that the idle draw
    /// path ignores. `false` on every normal bar, including a genuine 0 %-with-valid-reset 5h window.
    public let idle: Bool
    /// Whether this **idle** 5-hour bar is also **blocked** — the 7-day limit is exhausted and paid
    /// credits cannot cover, so there is no path to start a session (#158, `CreditsPacing.isBlocked`).
    /// When `true` the view draws the idle pill in **grey** (not the "ready" green), meaning
    /// "waiting for a limit to reset" rather than "ready to start". Only ever `true` alongside
    /// ``idle``; `false` on every normal bar and on a non-blocked idle bar.
    public let blocked: Bool
    // No `weeklyHeadroom` here since #381: the idle "ready to start" fill is **green** whatever the week
    // is doing, so the fill no longer needs the weekly verdict carried alongside an inert layout. The
    // gate itself is untouched — `PacingModel.weeklyHasHeadroom` still decides `blueAllowed` for the
    // *active* 5-hour bar, which is what ADR-0081 was actually about.

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
    /// an inert placeholder `layout` (`usage 0 / time 0`) and means "ready to start", never a pacing
    /// concern — so it must not drive the countdown. Only the 7-day bar
    /// decides in the idle state.
    public var severity: PacingSeverity { idle ? .calm : layout.severity }

    /// Whether this bar is "calm" (blue/green/yellow — not worth flagging). Derived from ``severity``
    /// (idle → always calm); both `.calm` and the calmer-than-green `.farBehind` (blue) count, matching
    /// ``BarLayout/isCalm``. Its only consumer is `TopBarHiding` — whether the bar is *drawn*; no
    /// countdown hangs off it, since bars never carry one (ADR-0091).
    public var isCalm: Bool { severity == .calm || severity == .farBehind }
}

// MARK: - MenuBarMode

/// What the menu-bar item should currently show — the discriminated result `StatusItemView`
/// switches on when drawing.
///
/// Cases:
/// - ``expanded(fiveHour:sevenDay:)``: the normal widget — two stacked bars (5h top, 7d bottom) and
///   **no countdown**, ever (ADR-0091). Shown whenever work is running on the subscription, at any
///   `utilization` below the cap — the widget never collapses to a compact glyph (ADR-0015 supersedes
///   the earlier idle mode).
/// - ``error(fiveHour:sevenDay:reset:which:)``: there is no usable data to show — polling has been
///   failing long enough to surface a ⚠️ glyph (issue #12), **or** it is a cold start before the
///   first poll resolves (e.g. token expired, API unreachable). The bars are **optional**: present
///   during the 30–60 min "stale" phase (⚠️ drawn alongside the last known bars), `nil` past 60 min
///   or on a cold start (⚠️ alone).
public enum MenuBarMode: Sendable, Equatable {
    /// Full widget: 5h bar, 7d bar, and an optional reset countdown.
    ///
    /// Either bar may be `nil` — whichever one the user chose to hide while it is calm
    /// (``TopBarHiding``, ADR-0086; the boolean predecessor could only ever hide the 7-day one).
    /// A `nil` here **never** means "no data": both windows always resolve on this path, so it means
    /// "deliberately not drawn". That is the opposite of ``error``, where `nil` *is* absent data.
    ///
    /// **Invariant: at most one of the two is `nil`.** `TopBarHiding` names a single window, so it can
    /// elide at most one bar whatever the severities are — the widget never renders empty, and the view's
    /// "no bars at all" branch is unreachable. See `TopBarHiding`'s own note for the argument.
    ///
    /// - Parameters:
    ///   - fiveHour: The 5-hour bar (drawn on top), or `nil` when it is **hidden** because it is calm
    ///     and the user picked `TopBarHiding.untilItNeedsAttention`. An **idle** 5-hour bar counts as calm, so it is
    ///     hidden too — between sessions the widget then shows the 7-day bar alone.
    ///   - sevenDay: The 7-day bar (drawn below). Never elided since ADR-0090 — the calm-hiding choice
    ///     names only the 5-hour bar — but kept optional so the shape still mirrors ``error``, whose
    ///     `nil` means absent data.
    ///
    /// **No countdown field, by construction** (ADR-0091). A countdown only ever accompanies the
    /// bars-less answers below, so "bars *and* a number" is not representable — the invariant is
    /// held by the type rather than by a rule someone has to remember. This replaced a
    /// `resetToShow:` parameter fed by `selectReset`'s 5h×7d severity table (#103, ADR-0029),
    /// which the countdown rule made permanently `nil`.
    case expanded(fiveHour: BarView?, sevenDay: BarView?)
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
    /// The error/stale path never produces it (see ``usageMode``).
    ///
    /// - Parameters:
    ///   - reset: The formatted countdown to the reset that ends this state.
    ///   - which: Which window drives it (`.fiveHour` for a 5h-cadence reset, `.sevenDay` for a
    ///     7-day-cadence or credits/monthly reset). Informational since ADR-0074 made the label
    ///     format identical on both surfaces.
    case iconOnlyReset(reset: String, which: LimitWindow)
    /// A main window is exhausted while its `resets_at` is missing or unparseable (#167, ADR-0091): the
    /// state is known but its end is not. Drawn as a **lone ⚠️** — no bars, and no pause or currency
    /// glyph beside it.
    ///
    /// Suppressing the glyph is deliberate, and it is the one place this case differs from
    /// ``iconOnlyReset`` in more than its label. A pause icon asserts "you are blocked" while the ⚠️
    /// asserts "do not trust this"; nothing on screen says the distrust covers only the *time*, so the
    /// pair reads as a malfunction instead of a state. Contradictory data gets one signal, and the
    /// honest one is the warning.
    ///
    /// Still distinct from ``error`` despite looking identical: that case means the data is stale or
    /// absent, this one that a fresh snapshot contradicts itself. They differ in what the app should do
    /// next (retry vs. report), and `.error` uses a different symbol, so the two never collide visually.
    ///
    /// - Parameter which: Which exhausted window the missing reset belongs to, or `nil` when several
    ///   are exhausted and none has a usable date. Informational only — the view draws no label.
    case exhaustedUnknownReset(which: LimitWindow?)
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
    /// The weekly window has no reset instant and none can be reconstructed (ADR-0107): the no-data
    /// glyph alone, no bars, no countdown.
    ///
    /// Distinct from ``error`` because the data does not contradict itself — the server coherently
    /// reports that no weekly window exists yet, which is true until the first token spend. ⚠️ is
    /// reserved for the opposite case (a window provably exhausted while its reset is missing), and
    /// spending it here would blur the one distinction that glyph carries.
    ///
    /// Bars are withheld rather than drawn from what survives: the five-hour window is idle in this
    /// state too, and the per-model windows inherit the empty weekly reset, so there is nothing left
    /// whose position on a track would mean anything.
    case weeklyResetUnknown
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
/// - `BlockingReset` + `ResetClock.timeToReset(...)` → the countdown of the bars-less modes
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
    /// bars-less answer `make` already chose before this decoration. Never `true`
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
    /// 2. Return ``MenuBarMode/expanded`` — the healthy path always shows both bars (there is no
    ///    idle/compact collapse; ADR-0015), and **never a countdown** (ADR-0091).
    ///
    /// A past-boundary window is rolled forward before formatting (`optimisticReset`), so no
    /// "reset now" placeholder is ever needed.
    ///
    /// **Session-idle (#100, ADR-0027).** When `snapshot.sessionIdle` (the 5h window does not exist
    /// server-side — no active session), the mode is still ``MenuBarMode/expanded`` with **both** bars
    /// (ADR-0015's "bars never collapse" still holds), and the 5h bar is built ``BarView/idle`` `= true`
    /// (inert `usage 0 / time 0` layout; the view draws a knobless track — **no** synthesized
    /// `now + 5h` phantom reset, the bug this fixes).
    ///
    /// - Parameters:
    ///   - snapshot: A decoded usage poll (`UsageClient`/#9).
    ///   - now: Current instant — inject for deterministic tests; never call `Date()` here.
    ///   - hideTopBar: Which bar to drop while it is **calm** (`BarView.isCalm` — green on-pace/behind,
    ///     mild-ahead yellow, or far-behind blue), leaving the other one as the single, vertically-centred
    ///     bar (ADR-0086, `PersistedConfig.hideTop5hBar`). An orange/red bar is always kept, and at most
    ///     one bar is ever elided, so the widget never ends up empty. Default `.never` (both bars) so
    ///     existing callers and tests are unaffected. In the session-idle state the inert 5h bar counts
    ///     as calm and is dropped under `.untilItNeedsAttention`, leaving the 7-day bar alone.
    ///
    /// Both bars-less answers to "can we work?" are produced here: being blocked
    /// (`CreditsPacing.isBlocked`) or paying (`CreditsPacing.subscriptionExhaustedWhileCovered`) returns
    /// ``MenuBarMode/iconOnlyReset(reset:which:)`` — the countdown to the reset that ends the state,
    /// since a red 100 % bar carries no pacing information either way (ADR-0090). When that reset cannot
    /// be resolved (every exhausted window has a broken `resets_at`) the answer is
    /// ``MenuBarMode/exhaustedUnknownReset(which:)`` — the same glyph with a ⚠️ where the number goes.
    /// It does **not** fall back to bars: an exhausted window is never drawn as a bar (ADR-0091).
    public static func make(
        from snapshot: UsageSnapshot, now: Date,
        hideTopBar: TopBarHiding = .never
    ) -> MenuBarLayout {
        // No weekly reset **and nothing spent** (ADR-0107) — the cold start, before the first token
        // spend has opened a weekly window. Checked before everything else because every path below
        // assumes a weekly clock exists: without one, `elapsedFraction` answers `1.0` for the 7-day
        // window and for the per-model windows that inherit its date, so each would draw a marker
        // jammed against the right edge — a confident claim that the week is spent, from a snapshot
        // saying nothing has been spent at all.
        //
        // The `utilization == 0` half matters. A blank date beside **real usage** is a different
        // state: the numbers are still worth drawing, and hiding them would throw away the one thing
        // the widget does know. That case keeps its bars and simply has no countdown, exactly as it
        // did before this change.
        if snapshot.sevenDay.resetsAt.isEmpty, snapshot.sevenDay.utilization == 0 {
            return MenuBarLayout(mode: .weeklyResetUnknown)
        }

        // "Can we work?" — the two answers that are not "yes, on the subscription" produce the same
        // bars-less shape (ADR-0090). Both are checked before the idle/active bar-building branches so
        // they short-circuit both.
        //
        // The order between them is immaterial — `isBlocked` and `subscriptionExhaustedWhileCovered`
        // are complements on an exhausted main window (`CreditsPacing`, split on `creditsCanCover`), so
        // they are never both true. They are written blocked-first to match the reading order of the
        // question.
        //
        // **No bars, unconditionally** — and, since ADR-0091, with no escape hatch: a broken
        // `resets_at` yields `.exhaustedUnknownReset` rather than falling through to the bars path.
        // Falling through used to be how the data error surfaced, but it drew a red 100 % bar to do
        // it, which is exactly what "an exhausted window is never a bar" forbids.
        if CreditsPacing.isBlocked(in: snapshot) {
            return MenuBarLayout(mode: blockedResetMode(for: snapshot, now: now)
                ?? .exhaustedUnknownReset(which: exhaustedWindowWithoutReset(in: snapshot)))
        }
        // Paying: the subscription is spent but credits still cover, so work continues — on money. The
        // countdown is the moment the plan quota returns and credits stop being spent, which is the one
        // thing the user can act on. Deliberately **not** keyed on the credits *icon*'s predicate
        // (`shouldShowIcon` rests on `anyBaseLimitExhausted`, which counts per-model sub-windows that do
        // not gate work at all — an exhausted Opus window must not hide the 5h/7d bars).
        if CreditsPacing.subscriptionExhaustedWhileCovered(in: snapshot) {
            return MenuBarLayout(mode: paidResetMode(for: snapshot, now: now)
                ?? .exhaustedUnknownReset(which: exhaustedWindowWithoutReset(in: snapshot)))
        }

        return MenuBarLayout(mode: expandedBars(for: snapshot, now: now, hideTopBar: hideTopBar))
    }

    /// Which **main** window is exhausted but has no usable `resets_at` — the `which` for
    /// ``MenuBarMode/exhaustedUnknownReset(which:)``, and `nil` when both are (or when the caller
    /// reached this state some other way). Informational only: the view draws no label for it.
    ///
    /// Mirrors `CreditsPacing.mainWindowExhausted`'s notion of "exhausted" (an idle 5h window is
    /// "ready to start", not exhausted), so the answer never names a window that isn't gating work.
    static func exhaustedWindowWithoutReset(in snapshot: UsageSnapshot) -> LimitWindow? {
        let fiveStuck = !snapshot.sessionIdle && snapshot.fiveHour.utilization >= 100
            && ResetClock.parse(snapshot.fiveHour.resetsAt) == nil
        let sevenStuck = snapshot.sevenDay.utilization >= 100
            && ResetClock.parse(snapshot.sevenDay.resetsAt) == nil
        switch (fiveStuck, sevenStuck) {
        case (true, false): return .fiveHour
        case (false, true): return .sevenDay
        default:            return nil          // both, or neither — no single window to name
        }
    }

    /// The **bars** half of ``make(from:now:hideTopBar:)`` — everything after the two bars-less answers
    /// to "can we work?". Always returns ``MenuBarMode/expanded(fiveHour:sevenDay:)``, **never** a
    /// bars-less shape.
    ///
    /// Reached only when no main window is exhausted, so it never has to decide anything about a red
    /// bar: `make` has already answered that case above (ADR-0091).
    static func expandedBars(
        for snapshot: UsageSnapshot, now: Date,
        hideTopBar: TopBarHiding = .never
    ) -> MenuBarMode {
        // The weekly gate, resolved once for every exit path below: the 5-hour bar may only go blue
        // while the 7-day window itself has headroom (`PacingModel.weeklyHasHeadroom`). The 7-day bar
        // never gates on itself.
        let weeklyHeadroom = PacingModel.weeklyHasHeadroom(in: snapshot, now: now)
        let seven = bar(for: snapshot.sevenDay, window: .sevenDay, now: now, blueAllowed: true)
        // Elide the 7-day bar when it is calm and the user picked it (ADR-0086). The 5h side gets the
        // mirror-image treatment on each path that builds it (active and idle alike).
        let sevenToShow: BarView? = hideTopBar.hides(.sevenDay, isCalm: seven.isCalm) ? nil : seven

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
                indicator: .neutral, window: .fiveHour, idle: true, blocked: blocked)
            // An idle 5h bar reports `.calm` unconditionally (`BarView.severity`), so `.fiveHour` hides
            // it here too — deliberately, with no idle exemption (ADR-0086): between sessions the widget
            // then shows the 7-day bar alone.
            let fiveToShow: BarView? = hideTopBar.hides(.fiveHour, isCalm: five.isCalm) ? nil : five
            // In the idle state the 5h window is legitimately date-less (ADR-0027, not an error), but the
            // 7-day window is real: if it reports usage yet its `resets_at` is unparseable, that is the
            // same broken-payload data error as on the active path (#167, ADR-0043) → ⚠️.
            // `hasBrokenActiveReset` already excludes the idle 5h, so it checks only the real 7-day here.
            // An *exhausted* 7-day never arrives here — `make` answered it before the bars were built —
            // so the bars kept beside the ⚠️ are always calm ones (ADR-0091).
            if snapshot.hasBrokenActiveReset {
                return .error(
                    fiveHour: fiveToShow, sevenDay: sevenToShow, reset: nil, which: nil)
            }
            return .expanded(fiveHour: fiveToShow, sevenDay: sevenToShow)
        }

        let five = bar(for: snapshot.fiveHour, window: .fiveHour, now: now, blueAllowed: weeklyHeadroom)
        // Mirror of `sevenToShow` above: drop the 5h bar while it is calm under `.fiveHour`.
        let fiveToShow: BarView? = hideTopBar.hides(.fiveHour, isCalm: five.isCalm) ? nil : five

        // API data error (#167, ADR-0043): a window the server reports as **active** (real usage) but
        // with a present-yet-unparseable `resets_at` is a malformed payload — surface the ⚠️ error state
        // (glyph + last bars), not a fabricated countdown. Checked on the raw snapshot, *before*
        // `bar(for:)` masks a broken date as `elapsedFraction == 1.0` / `.calm` (which would otherwise
        // hide the inconsistency). Shared with the popup via `UsageSnapshot.hasBrokenActiveReset`.
        //
        // The window in question is necessarily **not** exhausted: `make` answers every exhausted main
        // window before the bars are built (ADR-0091), so a broken date on a *calm or orange* window
        // lands here and keeps its bars, while a broken date on a red one became
        // `.exhaustedUnknownReset` upstream. That split is the whole reason this path may still draw
        // bars beside a ⚠️.
        if snapshot.hasBrokenActiveReset {
            return .error(fiveHour: fiveToShow, sevenDay: sevenToShow, reset: nil, which: nil)
        }

        return .expanded(fiveHour: fiveToShow, sevenDay: sevenToShow)
    }

    // MARK: make (health-aware, issue #12)

    /// Build the menu-bar layout from the **last known** snapshot plus the polling health at `now`.
    ///
    /// This is the entry point the live loop (#13) calls; the plain ``make(from:now:)`` stays the
    /// healthy-path core that this delegates to. Decision order, by how long polling has been
    /// failing (`health.failureAge(now:)`, thresholds in ``UsageHealth``):
    ///
    /// 1. **Healthy** (`!isFailing`) → the normal ``make(from:now:)`` result.
    /// 2. **Failing within the grace window**, snapshot present → still ``make(from:now:)``: the bars
    ///    are stale but fresh enough to show; the menu bar gives no error signal (the popup already warns).
    /// 3. **Failing past it, or no snapshot at all** (cold start) → ``MenuBarMode/error`` with all
    ///    values `nil` (⚠️ alone).
    ///
    /// The old middle phase — ⚠️ *beside* the last bars, 30–60 min — is gone (ADR-0091): data that is
    /// too old to trust is not shown at all, rather than shown with a warning next to it.
    ///
    /// - Parameters:
    ///   - snapshot: The last successfully decoded poll, or `nil` if none has ever succeeded.
    ///   - health: The polling-health context (last success, failure start, reason).
    ///   - now: Current instant — inject for deterministic tests; never call `Date()` here.
    ///   - serviceProblem: The worst non-operational Claude service state (issue #31), or `nil` when
    ///     all services are operational / unknown-cold. Threaded onto the result so the view can draw
    ///     the trailing dot; it does not affect the usage `mode`.
    ///   - hideTopBar: Elide the chosen calm bar on the **healthy/stale** path (ADR-0086) — see the
    ///     plain ``make(from:now:hideTopBar:)``. The error state draws no bars at all, so it is moot there.
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
        serviceProblem: ServiceStatus? = nil,
        hideTopBar: TopBarHiding = .never, showCredits: Bool = false,
        monitoringAnything: Bool = true
    ) -> MenuBarLayout {
        // The credits marker rides on the snapshot, which is stale in both new modes (#341) — money
        // state that is no longer being refreshed is not worth an icon.
        let dataIsLive = monitoringAnything && health.isCollectingUsage
        let liveCredits = (showCredits && dataIsLive)
            ? snapshot.flatMap { creditsMarker(for: $0, now: now) } : nil
        let layout = usageMode(from: snapshot, health: health, now: now,
                               hideTopBar: hideTopBar,
                               monitoringAnything: monitoringAnything)
        // Pause icon: drawn whenever the user is fully blocked (`CreditsPacing.isBlocked` — no path to
        // work). On the healthy path that means ``MenuBarMode/iconOnlyReset``.
        //
        // `.expanded` can no longer be blocked (an exhausted window never reaches the bars path), but it
        // stays listed as a harmless belt-and-braces: `isBlocked` is the authority, and if the two ever
        // disagreed, marking the state is the safer failure.
        //
        // **Not `.exhaustedUnknownReset`**, even though the snapshot there is fresh and the window is
        // provably at 100 %. The pause glyph asserts "you are blocked" and the ⚠️ beside it asserts
        // "don't trust me"; on screen there is nothing to say the distrust covers only the *time*, so
        // the pair reads as a malfunction rather than as a state. One signal, and the honest one for
        // contradictory data is the warning. #199, #227, ADR-0090, ADR-0091.
        let blockedPause: Bool = {
            guard let snapshot, CreditsPacing.isBlocked(in: snapshot) else { return false }
            switch layout.mode {
            case .expanded, .iconOnlyReset: return true
            case .exhaustedUnknownReset, .error, .usagePollingOff, .nothingMonitored,
                 .weeklyResetUnknown:
                return false
            }
        }()
        // The pause icon and the currency icon are **mutually exclusive** (ADR-0090, restoring the
        // invariant `ui-state-truth.md` already claimed). They could previously draw side by side when
        // the money cap was hit: `isActive` is `enabled || spend_limit_reached`, so the icon showed,
        // while `creditsCanCover` is `enabled && !spend_limit_reached`, so the user was also blocked.
        // Two icons then answered "can we work?" with contradictory halves — the pause wins, because
        // "no path to work" is the answer and a red ¤ is a detail of *why*.
        //
        // The currency icon is suppressed in `.exhaustedUnknownReset` for the same reason the pause is
        // (above): a glyph that states the situation, beside a ⚠️ that disowns it, reads as a broken
        // widget. Contradictory data gets the warning alone.
        let credits: CreditsMarker? = {
            if blockedPause { return nil }
            if case .exhaustedUnknownReset = layout.mode { return nil }
            return liveCredits
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
    /// so ``make(from:health:now:serviceProblem:hideTopBar:showCredits:monitoringAnything:)`` can
    /// graft the service dot onto its result.
    private static func usageMode(
        from snapshot: UsageSnapshot?, health: UsageHealth, now: Date,
        hideTopBar: TopBarHiding,
        monitoringAnything: Bool = true
    ) -> MenuBarLayout {
        // #341, checked before anything else: these two states are user choices, not poll outcomes,
        // so no snapshot or failure age can override them. Placing them first is what stops the
        // "switched off" states from decaying into the error phase below — a deliberate choice must
        // not age into a report that something is broken.
        guard monitoringAnything else { return MenuBarLayout(mode: .nothingMonitored) }
        guard health.isCollectingUsage else { return MenuBarLayout(mode: .usagePollingOff) }

        // Healthy, or stale within the grace window: show the (possibly stale) bars unchanged.
        // A healthy state with no snapshot only happens at the very first tick before the first
        // poll resolves; with no data to draw, fall back to the bare ⚠️ error glyph.
        guard let age = health.failureAge(now: now) else {
            return snapshot.map { make(from: $0, now: now, hideTopBar: hideTopBar) }
                ?? MenuBarLayout(mode: .error(fiveHour: nil, sevenDay: nil, reset: nil, which: nil))
        }
        if let snapshot, age <= UsageHealth.glyphAfter(for: health) {
            return make(from: snapshot, now: now, hideTopBar: hideTopBar)
        }

        // Past the grace window: the bare ⚠️, with no bars and no countdown (ADR-0091).
        //
        // There used to be a middle phase here — ⚠️ *beside* the last bars, rebuilt through
        // `expandedBars` — meant as diagnostics. It is gone: bars whose data may be a quarter of an
        // hour old invite exactly the reading they cannot support ("this is where I stand"), and the
        // popup already explains the failure in words. Showing nothing is the honest answer.
        return MenuBarLayout(mode: .error(fiveHour: nil, sevenDay: nil, reset: nil, which: nil))
    }

    /// A copy of this layout carrying `serviceProblem`, `credits`, and `blockedPause` (the `mode` is
    /// unchanged) — the decorations grafted onto the usage `mode` computed by
    /// ``usageMode(from:health:now:hideTopBar:monitoringAnything:)``.
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
}
