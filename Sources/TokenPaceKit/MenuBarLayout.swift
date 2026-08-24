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
    /// Animation identity for this bar when ``window`` cannot name it — a Codex window whose length is
    /// neither 5 h nor 7 d (`CodexQuotaNormalizer.title`, e.g. `"3-hour"`). `nil` on every Claude bar,
    /// where `window.id` already is the identity. The pair `(provider, rowID)` is what keeps two
    /// providers' colour transitions apart (``TweenKey``).
    public let rowID: String?
    // No `weeklyHeadroom` here since #381: the idle "ready to start" fill is **green** whatever the week
    // is doing, so the fill no longer needs the weekly verdict carried alongside an inert layout. The
    // gate itself is untouched — `PacingModel.weeklyHasHeadroom` still decides `blueAllowed` for the
    // *active* 5-hour bar, which is what ADR-0081 was actually about.

    public init(
        layout: BarLayout, indicator: LimitIndicator, window: LimitWindow,
        idle: Bool = false, blocked: Bool = false, rowID: String? = nil
    ) {
        self.layout = layout
        self.indicator = indicator
        self.window = window
        self.idle = idle
        self.blocked = blocked
        self.rowID = rowID
    }

    /// The row half of this bar's ``TweenKey`` — ``rowID`` when it names the window, `window.id`
    /// otherwise.
    public var tweenRow: String { rowID ?? window.id }

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

// MARK: - ProviderBlock

/// One provider's share of the widget: its pacing bars, stacked in the order given, plus the
/// per-provider decorations that used to belong to the whole item.
///
/// **`bars` comes from the data, never from a fixed pair.** Claude reports two windows and Codex one;
/// a provider that grows a third gets a third bar with no change here. The count is what
/// `StatusItemView.drawBlock` lays out, so `n = 2` keeps the geometry the two-bar stack has always
/// had (ADR-0128).
///
/// Never empty — a provider with nothing to draw is left out of ``MenuBarMode/expanded(blocks:)``
/// instead of contributing a blank column.
public struct ProviderBlock: Sendable, Equatable {
    /// Whose bars these are. Blocks are ordered by ``ProviderID/displayIndex``, the same order the
    /// Settings list and the popup plates use, and it is the **only** cue to identity in the widget —
    /// nothing is drawn to name the provider (ADR-0128).
    public let provider: ProviderID
    /// The bars, top to bottom. Non-empty.
    public let bars: [BarView]
    /// This provider's pause glyph, drawn leading its own bars: `true` when it has no path to work.
    public let blockedPause: Bool
    /// This provider's money-credits marker, drawn leading its own bars, or `nil` for no icon.
    public let credits: CreditsMarker?

    public init(provider: ProviderID, bars: [BarView], blockedPause: Bool = false,
                credits: CreditsMarker? = nil) {
        self.provider = provider
        self.bars = bars
        self.blockedPause = blockedPause
        self.credits = credits
    }
}

// MARK: - MenuBarMode

/// What the menu-bar item should currently show — the discriminated result `StatusItemView`
/// switches on when drawing.
public enum MenuBarMode: Sendable, Equatable {
    /// Full widget: one ``ProviderBlock`` per provider with usage to show, left to right in
    /// ``ProviderID/displayOrder``, and **no countdown**, ever (ADR-0091). Shown whenever work is
    /// running on a subscription, at any `utilization` below the cap — the widget never collapses to a
    /// compact glyph (ADR-0015).
    ///
    /// **Invariant: `blocks` is non-empty and no block has empty bars.** A provider whose only bar was
    /// elided — `TopBarHiding` while calm (ADR-0086), or a poll that returned nothing — is dropped
    /// whole rather than left as a gap, so the widget never renders empty and the view's "no bars"
    /// branch stays unreachable.
    ///
    /// **No countdown field, by construction** (ADR-0091). A countdown only ever accompanies the
    /// bars-less answers below, so "bars *and* a number" is not representable — the invariant is held
    /// by the type rather than by a rule someone has to remember.
    case expanded(blocks: [ProviderBlock])
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
    /// A red "100 %" bar would carry no pacing information: the blocking window is what gates work, and
    /// a 5h bar refilling underneath a blocking 7d window changes nothing — you keep paying until the
    /// *blocking* window resets, which is exactly the countdown shown.
    ///
    /// - Parameters:
    ///   - provider: Whose quota blocks the work. The widget draws nothing to name it — the popup does
    ///     — but it is what a screen reader speaks (``MenuBarLayout/spokenDescription``), and with two
    ///     providers "you are blocked" is unusable without it.
    ///   - reset: The formatted countdown to the reset that ends this state.
    case iconOnlyReset(provider: ProviderID, reset: String)
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
    /// - Parameter provider: Whose exhausted window has the missing reset. Spoken, never drawn.
    case exhaustedUnknownReset(provider: ProviderID)
    /// There is no usable data: polling has been failing long enough to surface the no-data glyph, or
    /// it is a cold start before the first poll resolves (token expired, API unreachable).
    ///
    /// **No payload.** Data stale enough to reach this state is not shown at all rather than shown
    /// with a warning beside it (ADR-0091), so the glyph is the whole widget.
    case error
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
    ///
    /// - Parameter provider: Whose weekly window has no reset. Spoken, never drawn.
    case weeklyResetUnknown(provider: ProviderID)
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
/// On the healthy path the result is always ``MenuBarMode/expanded(blocks:)`` — there is no
/// compact/idle collapse (ADR-0015 removed it). The only mode variation is the error state
/// (issue #12). The session-idle state (#100, ADR-0027) stays `expanded` too: it only recolours the
/// 5h bar (``BarView/idle``) — the bars never disappear.
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
    /// no width is reserved for it. **Placement** is view-side (`StatusItemView`): in `.iconOnlyReset`
    /// it is a **leading** element between the pause icon and the countdown (#227); in the diagnostic
    /// `.error` state it stays **trailing** (before the service dot).
    ///
    /// **`nil` in ``MenuBarMode/expanded(blocks:)``** — there the marker rides Claude's own
    /// ``ProviderBlock/credits``, because with more than one block a widget-level ¤ would not say whose
    /// money it is. ``moneyMarker`` reads whichever place holds it.
    public let credits: CreditsMarker?

    /// Whether to draw the red "pause" glyph as the **leading** element (#199, #227). Set `true`
    /// **whenever** the snapshot is `CreditsPacing.isBlocked` (every limit exhausted **and** paid credits
    /// can't cover — no path to work), always — the icon is not user-optional. The view draws it left of
    /// the countdown in ``MenuBarMode/iconOnlyReset(provider:reset:)`` (#194). Never `true` for the
    /// diagnostic ``MenuBarMode/error`` state. Computed at the health-aware `make` seam like `credits`.
    /// When `false`, no glyph is drawn and no width is reserved.
    ///
    /// **`false` in ``MenuBarMode/expanded(blocks:)``** — there the glyph rides its provider's own
    /// ``ProviderBlock/blockedPause``, since a widget-level pause left of everything would claim every
    /// provider is blocked.
    public let blockedPause: Bool

    /// The Claude Code sessions awaiting user input to advertise with the `hand.raised` indicator
    /// (#233, ADR-0066), or `nil` to draw nothing. `nil` whenever the feature is off, the count is
    /// `0`, or the watcher isn't running — the view reserves no width then. When non-`nil` (count
    /// `≥ 1`) the menu bar draws the **bare icon** (no count — the count is popup-only), tinted by
    /// ``AwaitingSessions/urgency`` (red/orange/neutral by soonest deletion). Sourced by the shell
    /// from `AwaitingInputWatcher`, independent of the usage snapshot, so it's grafted on like
    /// `credits`/`blockedPause` rather than computed in `make`.
    public let awaitingInput: AwaitingSessions?
    /// Providers whose quota read contradicted itself, so they contribute **no block**: the numbers
    /// that would have drawn one were withheld as untrustworthy.
    ///
    /// **Speech only.** Nothing is drawn for it — a glyph would claim widget width for a provider the
    /// widget cannot say anything true about, and the popup carries the explanation. But silence is
    /// exactly what a screen-reader user cannot tell apart from a provider that is simply off, so the
    /// spoken description names the fault.
    public let quotaFaults: Set<ProviderID>

    public init(mode: MenuBarMode, serviceProblem: ServiceStatus? = nil, credits: CreditsMarker? = nil,
                blockedPause: Bool = false, awaitingInput: AwaitingSessions? = nil,
                quotaFaults: Set<ProviderID> = []) {
        self.mode = mode
        self.serviceProblem = serviceProblem
        self.credits = credits
        self.blockedPause = blockedPause
        self.awaitingInput = awaitingInput
        self.quotaFaults = quotaFaults
    }

    // MARK: make

    /// Build the menu-bar layout from one usage snapshot at instant `now`.
    ///
    /// Steps, all delegating to tested pure logic:
    /// 1. Compute the 5h and 7d `BarLayout` + `LimitIndicator` via `PacingModel`.
    /// 2. Return ``MenuBarMode/expanded(blocks:)`` carrying **Claude's block** — the healthy path
    ///    always shows its bars (there is no idle/compact collapse; ADR-0015) and **never a countdown**
    ///    (ADR-0091). Other providers' blocks are merged onto the result by ``withProviderBlocks(_:)``,
    ///    which is the shell's call: this function only ever sees a Claude snapshot.
    ///
    /// A past-boundary window is rolled forward before formatting (`optimisticReset`), so no
    /// "reset now" placeholder is ever needed.
    ///
    /// **Session-idle (#100, ADR-0027).** When `snapshot.sessionIdle` (the 5h window does not exist
    /// server-side — no active session), the mode is still ``MenuBarMode/expanded(blocks:)`` with both bars
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
    /// ``MenuBarMode/iconOnlyReset(provider:reset:)`` — the countdown to the reset that ends the state,
    /// since a red 100 % bar carries no pacing information either way (ADR-0090). When that reset cannot
    /// be resolved (every exhausted window has a broken `resets_at`) the answer is
    /// ``MenuBarMode/exhaustedUnknownReset(provider:)`` — the same glyph with a ⚠️ where the number goes.
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
            return MenuBarLayout(mode: .weeklyResetUnknown(provider: .claude))
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
        // Falling through would draw a red 100 % bar to surface the data error, which is exactly what
        // "an exhausted window is never a bar" forbids.
        if CreditsPacing.isBlocked(in: snapshot) {
            return MenuBarLayout(mode: blockedResetMode(for: snapshot, now: now)
                ?? .exhaustedUnknownReset(provider: .claude))
        }
        // Paying: the subscription is spent but credits still cover, so work continues — on money. The
        // countdown is the moment the plan quota returns and credits stop being spent, which is the one
        // thing the user can act on. Deliberately **not** keyed on the credits *icon*'s predicate
        // (`shouldShowIcon` rests on `anyBaseLimitExhausted`, which counts per-model sub-windows that do
        // not gate work at all — an exhausted Opus window must not hide the 5h/7d bars).
        if CreditsPacing.subscriptionExhaustedWhileCovered(in: snapshot) {
            return MenuBarLayout(mode: paidResetMode(for: snapshot, now: now)
                ?? .exhaustedUnknownReset(provider: .claude))
        }

        return MenuBarLayout(mode: expandedBars(for: snapshot, now: now, hideTopBar: hideTopBar))
    }

    /// The **bars** half of ``make(from:now:hideTopBar:)`` — everything after the two bars-less answers
    /// to "can we work?". Returns ``MenuBarMode/expanded(blocks:)`` carrying Claude's one block, or
    /// ``MenuBarMode/error`` when the payload contradicts itself; **never** a bars-less quota shape.
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
            if snapshot.hasBrokenActiveReset { return .error }
            return claudeBlockMode(fiveHour: fiveToShow, sevenDay: sevenToShow)
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
        if snapshot.hasBrokenActiveReset { return .error }

        return claudeBlockMode(fiveHour: fiveToShow, sevenDay: sevenToShow)
    }

    /// Claude's block from its two optional bars, in the fixed 5h-above-7d order.
    ///
    /// A `nil` bar was elided while calm (``TopBarHiding``), never absent data. Both `nil` cannot
    /// happen — `TopBarHiding` names one window — but it is answered anyway with ``MenuBarMode/error``
    /// rather than an empty block, because `expanded` promises every block has bars.
    public static func claudeBlockMode(fiveHour: BarView?, sevenDay: BarView?) -> MenuBarMode {
        let bars = [fiveHour, sevenDay].compactMap { $0 }
        guard !bars.isEmpty else { return .error }
        return .expanded(blocks: [ProviderBlock(provider: .claude, bars: bars)])
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
        // invariant `ui-state-truth.md` already claimed). Without that rule they could draw side by
        // side when the money cap is hit: `isActive` is `enabled || spend_limit_reached`, so the icon
        // would show, while `creditsCanCover` is `enabled && !spend_limit_reached`, so the user would
        // also be blocked. Two icons would then answer "can we work?" with contradictory halves — the
        // pause wins, because "no path to work" is the answer and a red ¤ is a detail of *why*.
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
                ?? MenuBarLayout(mode: .error)
        }
        if let snapshot, age <= UsageHealth.glyphAfter(for: health) {
            return make(from: snapshot, now: now, hideTopBar: hideTopBar)
        }

        // Past the grace window: the bare ⚠️, with no bars and no countdown (ADR-0091).
        //
        // Deliberately not ⚠️ *beside* the last bars rebuilt through `expandedBars`: bars whose data
        // may be a quarter of an hour old invite exactly the reading they cannot support ("this is
        // where I stand"), and the popup already explains the failure in words. Showing nothing is the
        // honest answer.
        return MenuBarLayout(mode: .error)
    }

    /// A copy of this layout carrying `serviceProblem`, `credits`, and `blockedPause` — the
    /// decorations grafted onto the usage `mode` computed by
    /// ``usageMode(from:health:now:hideTopBar:monitoringAnything:)``.
    ///
    /// In ``MenuBarMode/expanded(blocks:)`` the pause glyph and the money marker are folded **into
    /// Claude's block** and cleared from the layout: with more than one block they are per-provider
    /// facts, and a widget-level pause left of everything would claim both providers are blocked. Every
    /// other mode draws one provider's answer, so they stay on the layout there.
    func with(serviceProblem: ServiceStatus?, credits: CreditsMarker?, blockedPause: Bool,
              awaitingInput: AwaitingSessions? = nil) -> MenuBarLayout {
        guard case let .expanded(blocks) = mode else {
            return MenuBarLayout(mode: mode, serviceProblem: serviceProblem, credits: credits,
                                 blockedPause: blockedPause, awaitingInput: awaitingInput)
        }
        let decorated = blocks.map { block in
            block.provider == .claude
                ? ProviderBlock(provider: .claude, bars: block.bars,
                                blockedPause: blockedPause, credits: credits)
                : block
        }
        return MenuBarLayout(mode: .expanded(blocks: decorated), serviceProblem: serviceProblem,
                             credits: nil, blockedPause: false, awaitingInput: awaitingInput)
    }

    /// A copy of this layout with the awaiting-input count grafted on, everything else unchanged
    /// (#233). The shell calls this on the `make(...)` result so the awaiting indicator — sourced
    /// from `AwaitingInputWatcher`, not the usage snapshot — doesn't have to thread through `make`.
    public func withAwaitingInput(_ awaitingInput: AwaitingSessions?) -> MenuBarLayout {
        MenuBarLayout(mode: mode, serviceProblem: serviceProblem, credits: credits,
                      blockedPause: blockedPause, awaitingInput: awaitingInput)
    }

    /// The money-credits marker actually drawn, wherever it lives: on Claude's block in
    /// ``MenuBarMode/expanded(blocks:)``, on the layout in every bars-less mode. One reader for both,
    /// so "is the ¤ on screen?" is never a question about which mode you are in.
    public var moneyMarker: CreditsMarker? {
        if case let .expanded(blocks) = mode {
            return blocks.first { $0.provider == .claude }?.credits
        }
        return credits
    }

    // MARK: Satellite providers

    /// A copy of this layout with `blocks` merged into ``MenuBarMode/expanded(blocks:)``, ordered by
    /// ``ProviderID/displayIndex`` — the same order the Settings list and the popup plates use.
    ///
    /// A no-op unless the mode is already `expanded`: the bars-less answers are Claude's own, and
    /// hanging another provider's bars off a pause glyph would put bars and a countdown on screen
    /// together, which the type exists to forbid (ADR-0091).
    ///
    /// Blocks with no bars are dropped rather than merged, so `expanded`'s invariant holds however
    /// empty the caller's data turns out to be.
    /// A copy naming the providers whose quota read contradicted itself. Spoken, never drawn.
    public func withQuotaFaults(_ faults: Set<ProviderID>) -> MenuBarLayout {
        MenuBarLayout(mode: mode, serviceProblem: serviceProblem, credits: credits,
                      blockedPause: blockedPause, awaitingInput: awaitingInput,
                      quotaFaults: faults)
    }

    public func withProviderBlocks(_ blocks: [ProviderBlock]) -> MenuBarLayout {
        guard case let .expanded(existing) = mode else { return self }
        let merged = (existing + blocks.filter { !$0.bars.isEmpty })
            .sorted { $0.provider.displayIndex < $1.provider.displayIndex }
        return MenuBarLayout(mode: .expanded(blocks: merged), serviceProblem: serviceProblem,
                             credits: credits, blockedPause: blockedPause,
                             awaitingInput: awaitingInput, quotaFaults: quotaFaults)
    }

    /// A copy of this layout without the blocks the user unchecked under Appearance → Menu bar
    /// (ADR-0128).
    ///
    /// **Unchecking every provider leaves the last block standing**, rather than emptying the widget:
    /// `expanded` promises at least one block, and an item that draws nothing is indistinguishable from
    /// a crashed one. The checkboxes are a width control, not an off switch — usage collection has its
    /// own, on the Providers page.
    public func hidingMenuBarProviders(_ hidden: Set<ProviderID>) -> MenuBarLayout {
        guard case let .expanded(blocks) = mode, !hidden.isEmpty else { return self }
        let kept = blocks.filter { !hidden.contains($0.provider) }
        let survivors = kept.isEmpty ? Array(blocks.prefix(1)) : kept
        return MenuBarLayout(mode: .expanded(blocks: survivors), serviceProblem: serviceProblem,
                             credits: credits, blockedPause: blockedPause,
                             awaitingInput: awaitingInput, quotaFaults: quotaFaults)
    }

    /// One satellite provider's block from the popup rows its plate already draws, or `nil` when it has
    /// none.
    ///
    /// Reading the rows rather than the raw quota keeps the two surfaces on one normalization: the
    /// widget's bar and the plate's bar are the same `BarLayout`, computed once. `LimitRow.title`
    /// becomes the bar's ``BarView/rowID`` so a window Claude has no name for still animates as itself.
    ///
    /// `window:` is `.sevenDay` on every row whose length is not five hours. It is the wrong question
    /// for a provider whose windows are lengths rather than a fixed pair, and it decides nothing here —
    /// the drawn geometry comes from `bar`, and the animation identity from `(provider, rowID)`.
    public static func block(for provider: ProviderID, rows: [LimitRow]) -> ProviderBlock? {
        guard !rows.isEmpty else { return nil }
        let bars = rows.map { row in
            BarView(layout: row.bar, indicator: row.indicator,
                    window: row.title == "5-hour" ? .fiveHour : .sevenDay,
                    idle: row.sessionIdle, blocked: row.sessionBlocked, rowID: row.title)
        }
        return ProviderBlock(provider: provider, bars: bars)
    }

    // MARK: Accessibility

    /// What VoiceOver speaks for the status item — the one channel that can name a provider, since the
    /// widget itself distinguishes them only by position and a screen reader conveys no position.
    ///
    /// Each block is spoken as `"<Provider>: <window> <n> percent, <pacing>; …"`, blocks separated by a
    /// full stop, and the service dot named last when it is drawn. Pure, so the whole string is
    /// testable without an accessibility client.
    public var spokenDescription: String {
        var parts: [String] = []
        switch mode {
        case let .expanded(blocks):
            parts += blocks.map { block in
                let bars = block.bars.map(Self.spokenBar).joined(separator: "; ")
                let prefix = block.blockedPause ? "\(block.provider.displayName), all limits reached: "
                                                : "\(block.provider.displayName): "
                return prefix + bars
            }
        case let .iconOnlyReset(provider, reset):
            parts.append("\(provider.displayName): limit reached, resets in \(reset)")
        case let .exhaustedUnknownReset(provider):
            parts.append("\(provider.displayName): limit reached, reset time unknown")
        case .error:
            parts.append("No usage data")
        case .usagePollingOff:
            parts.append("Usage monitoring off")
        case .nothingMonitored:
            parts.append("Monitoring off")
        case let .weeklyResetUnknown(provider):
            parts.append("\(provider.displayName): weekly reset time unknown")
        }
        // The same words the popup's warning block uses, so the two surfaces name one fault once —
        // the rule `weeklyResetUnknownTitle` follows for its own state.
        parts += quotaFaults.sorted { $0.displayIndex < $1.displayIndex }
            .map { "\($0.displayName): reset time bug, quota numbers unavailable" }
        if let serviceProblem, serviceProblem != .operational {
            parts.append("Services \(Self.spokenStatus(serviceProblem))")
        }
        if awaitingInput != nil { parts.append("A session is waiting for input") }
        return parts.joined(separator: ". ")
    }

    /// One bar as VoiceOver reads it: the window, its percentage, and the pacing verdict the colour
    /// carries on screen — the verdict is the point of the bar, and colour is exactly what does not
    /// survive into speech.
    private static func spokenBar(_ bar: BarView) -> String {
        let name = bar.rowID ?? (bar.window == .fiveHour ? "5-hour" : "7-day")
        if bar.idle { return "\(name) \(bar.blocked ? "waiting for reset" : "ready to start")" }
        let percent = Int((bar.layout.usageFraction * 100).rounded())
        return "\(name) \(percent) percent, \(Self.spokenPacing(bar.severity))"
    }

    /// The pacing verdict in words — the same four tiers the bar's colour carries.
    private static func spokenPacing(_ severity: PacingSeverity) -> String {
        switch severity {
        case .farBehind: return "well within pace"
        case .calm:      return "on pace"
        case .ahead:     return "ahead of pace"
        case .exhausted: return "limit reached"
        }
    }

    /// The service dot's state in words.
    private static func spokenStatus(_ status: ServiceStatus) -> String {
        switch status {
        case .operational:      return "operational"
        case .degraded:         return "degraded"
        case .partialOutage:    return "partially down"
        case .majorOutage:      return "down"
        case .underMaintenance: return "under maintenance"
        case .unknown:          return "status unknown"
        }
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

    /// Format a resolved ``BlockingReset/Choice`` into ``MenuBarMode/iconOnlyReset(provider:reset:)``
    /// — shared by the blocked and paying paths so both label the countdown identically. Claude is the
    /// only provider that reaches either path: a `BlockingReset.Choice` is built from a Claude snapshot.
    private static func iconOnlyMode(for choice: BlockingReset.Choice, now: Date) -> MenuBarMode {
        .iconOnlyReset(provider: .claude,
                       reset: ResetClock.timeToReset(resetsAt: choice.resetsAt, now: now))
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
