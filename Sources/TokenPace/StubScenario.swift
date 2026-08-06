import Foundation
import TokenPaceKit

/// Every `TOKENPACE_STUB` data-source scenario, as a flat catalogue the dev tools (#187) can enumerate,
/// describe, and switch between live. Each case carries the exact env id (`rawValue`), a human label,
/// a one-line note of what it verifies, and the transport it drives — so the launch-time env path and
/// the Development-tools dropdown share **one** source of truth (no duplicated case list).
///
/// Modeled on ``ColorRole``: a `CaseIterable` registry with computed display metadata. The `rawValue`
/// of every case is the literal string a user would pass in `TOKENPACE_STUB=…`, so
/// `StubScenario(rawValue:)` round-trips env compatibility for free. ``realNetwork`` (`"real"`) is the
/// no-stub production path: the real usage API over `URLSession.shared`.
///
/// Env resolution goes through ``resolve(env:isAppBundle:)`` — **never** `init(rawValue:)` directly.
/// A bare `init(rawValue:)` cannot tell "nothing was asked for" from "something bogus was asked for",
/// and collapsing the latter into the live network is exactly the #267 bug: a run meant to be stubbed
/// silently polled the real API and read the real `~/.claude` trees.
///
/// The `summary` strings are lifted from the inline stub docs in `startPolling` and the
/// `docs/guides/ui-verification.md` table — keep them in sync with the `StubUsageTransport.Mode`
/// bodies when a scenario's behaviour changes.
enum StubScenario: String, CaseIterable {

    /// No stub — the production path: real usage API over the live network, Keychain token, live
    /// refresher. Selecting this from the dropdown tears down the stub pipeline and polls the real API.
    ///
    /// Its id is a **non-empty** `"real"` on purpose (#267): while the empty string meant "live", an
    /// absent `TOKENPACE_STUB` and an explicit request for the live network were indistinguishable, so
    /// a typo'd id fell through to production data. Live is now something you have to ask for by name.
    case realNetwork = "real"

    case climbing = "1"
    case screenshot = "screenshot"
    case authError = "error"
    case staleError = "stale-error"
    case idle = "idle"
    case idleBlocked = "idle-blocked"
    case activeBlocked = "active-blocked"
    case optimisticReset = "optimistic-reset"
    case brokenReset = "broken-reset"
    case fiveOrange = "5h-orange"
    case bothOrange = "both-orange"
    case bothRed = "both-red"
    case redOrange = "red-orange"
    case redGreen = "red-green"
    case calm5Orange7 = "calm5-orange7"
    case nearReset = "near-reset"
    case calmBoth = "calm-both"
    case farBehind = "far-behind"
    case nearZero = "near-zero"
    case edgeExtremes = "edge-extremes"
    case calmDegraded = "calm-degraded"
    case allGreen = "all-green"
    case creditsActive = "credits-active"
    case creditsLimitReached = "credits-limit-reached"
    case creditsNoLimit = "credits-no-limit"
    case justUnblocked = "just-unblocked"
    case creditsOnset = "credits-onset"
    case resetGrace = "reset-grace"
    case colorCycle = "color-cycle"
    case incidentActive = "incident-active"
    case incidentGreen = "incident-green"
    case incidentTwo = "incident-two"
    case incidentRecovery = "incident-recovery"

    /// The env id (`TOKENPACE_STUB` value), including `"real"` for ``realNetwork``.
    var id: String { rawValue }

    // MARK: - Env resolution (#267)

    /// The outcome of reading `TOKENPACE_STUB`: which scenario to run, whether the choice was made
    /// **explicitly**, and the bogus value if one was supplied.
    struct Resolution: Equatable {
        /// The scenario to drive the data source with.
        let scenario: StubScenario

        /// Whether this scenario was *asked for* — a recognized `TOKENPACE_STUB` value, or a plain
        /// `.app` launch with no env at all (production's normal mode). False only when we fell back
        /// after a bad value, or when a dev build defaulted to the screenshot frame.
        ///
        /// Gates the awaiting-input watcher (#259): it reads the **live** `~/.claude` trees, so it must
        /// never come up on a live network nobody deliberately selected.
        let isExplicit: Bool

        /// The unrecognized `TOKENPACE_STUB` value that triggered the fallback, or `nil` on every
        /// normal path. Non-nil means the caller should warn — the run is *not* what was requested.
        let unknownValue: String?
    }

    /// Every id a maintainer can actually pass in `TOKENPACE_STUB=…`, in registry order — built from
    /// `allCases`, so it can never drift from the enum.
    static var validIDs: [String] {
        // Debug-only guard on the registry's own shape: an empty or duplicated id makes "absent env"
        // and "this id" the same string, which is precisely how #267 happened. The unit tests cover the
        // rule (`StubResolutionTests`) but live in the Kit target and can't see this enum — so the
        // registry itself is checked here, where it is defined. Compiled out of release builds.
        assert(StubResolution.idsAreResolvable(allCases.map(\.rawValue)),
               "StubScenario ids must be non-empty and unique — an empty id resurrects #267")
        return allCases.map(\.id)
    }

    /// Map a raw `TOKENPACE_STUB` value onto the scenario to run.
    ///
    /// The whole point is that an **unrecognized** value must not resolve to the live network (#267).
    /// A stubbed run that silently polls production looks stubbed in every visible respect while
    /// reporting real data, which is worse than failing outright. So a bad value degrades *away* from
    /// live, onto the frozen ``screenshot`` frame, and says so via `unknownValue`.
    ///
    /// The rule itself lives in ``StubResolution`` (pure, unit-tested, ADR-0009); this is the thin
    /// binding that feeds it the registry's ids and maps the answer back onto a case.
    ///
    /// - Parameters:
    ///   - env: the raw `TOKENPACE_STUB` value; `nil` when the variable is absent entirely. Note that
    ///     an empty string is *present but bogus* — it is no longer ``realNetwork``'s id.
    ///   - isAppBundle: whether this is an installed `.app` (`LaunchAtLoginController.isAppBundle`).
    ///     A production bundle with no env is the one path that stays live by default — otherwise a
    ///     real user would see a canned frame instead of their own limits.
    static func resolve(env: String?, isAppBundle: Bool) -> Resolution {
        let outcome = StubResolution.resolve(
            env: env,
            isAppBundle: isAppBundle,
            liveID: StubScenario.realNetwork.id,
            fallbackID: StubScenario.screenshot.id,
            knownIDs: validIDs
        )
        // `outcome.id` is always one of `validIDs`, so the lookup cannot fail; fall back to the frozen
        // frame rather than force-unwrapping — never to the live network.
        return Resolution(
            scenario: StubScenario(rawValue: outcome.id) ?? .screenshot,
            isExplicit: outcome.isExplicit,
            unknownValue: outcome.unknownValue
        )
    }

    // MARK: - Display

    /// Human label for the dropdown item.
    var displayName: String {
        switch self {
        case .realNetwork:         return "Real network (no stub)"
        case .climbing:            return "Climbing utilisation"
        case .screenshot:          return "Screenshot (frozen frame)"
        case .authError:           return "Auth error (401 + degraded)"
        case .staleError:          return "Stale-while-erroring"
        case .idle:                return "Idle (no active 5h session)"
        case .idleBlocked:         return "Idle + blocked (7d exhausted)"
        case .activeBlocked:       return "Active + blocked (7d exhausted)"
        case .optimisticReset:     return "Optimistic reset (~20 s out)"
        case .brokenReset:         return "Broken resets_at (null)"
        case .fiveOrange:          return "Pacing · 5h orange"
        case .bothOrange:          return "Pacing · both orange"
        case .bothRed:             return "Pacing · both red"
        case .redOrange:           return "Pacing · 5h red, 7d orange"
        case .redGreen:            return "Pacing · 5h red, 7d green"
        case .calm5Orange7:        return "Pacing · 5h calm, 7d orange"
        case .nearReset:           return "Pacing · near-reset override"
        case .calmBoth:            return "Pacing · both calm"
        case .farBehind:           return "Pacing · both far behind (blue)"
        case .nearZero:            return "Pacing · near-zero (pill caps)"
        case .edgeExtremes:        return "Pacing · edge extremes (5h 0 %, 7d 100 %)"
        case .calmDegraded:        return "Calm bars + degraded dot"
        case .allGreen:            return "All services green (⌥ reveals)"
        case .creditsActive:       return "Credits · active (paced)"
        case .creditsLimitReached: return "Credits · limit reached (red)"
        case .creditsNoLimit:      return "Credits · no limit (neutral)"
        case .justUnblocked:       return "Back to work! edge"
        case .creditsOnset:        return "Extra Usage Credit onset"
        case .resetGrace:          return "Reset-boundary idle grace"
        case .colorCycle:          return "Colour transitions (frozen bars)"
        case .incidentActive:      return "Incident · one active (⌥ shows it)"
        case .incidentGreen:       return "Incident · open but components green"
        case .incidentTwo:         return "Incident · two at once"
        case .incidentRecovery:    return "Incident · silent recovery"
        }
    }

    /// One-line description of what this scenario verifies — shown beside the dropdown so a maintainer
    /// can tell the ~25 states apart. Sourced from the same stub docs the transport bodies were built
    /// from.
    var summary: String {
        switch self {
        case .realNetwork:
            return "Production path: the real usage API over the live network (Keychain token, live "
                 + "refresher). No canned data."
        case .climbing:
            return "Climbing utilisation — exercises the adaptive poll cadence on screen. Two scoped "
                 + "per-model rows (Fable / Mythos) plus a rising 7-day window."
        case .screenshot:
            return "Frozen, hand-picked values — a stable frame for the README screenshot."
        case .authError:
            return "401 auth failure + both Claude services degraded → the popup warning block."
        case .staleError:
            return "First poll valid (full bars + Extra usage), then every later poll times out → the "
                 + "⚠️ connectivity banner above the held bars (spacing check)."
        case .idle:
            return "The honest \"no active 5h session\" state (#100): solid-blue 5h bar, no phantom "
                 + "reset, menu-bar time falls back to the 7-day reset."
        case .idleBlocked:
            return "Blocked idle (#158): idle 5h + 7-day exhausted (100 %), no credits → the idle bar "
                 + "goes grey and the 7-day reset is painted red."
        case .activeBlocked:
            return "Active blocked (#177): a live 5h window (48 %) while 7-day is exhausted → normal "
                 + "5h row but a red blocking-reset badge on the 7-day reset."
        case .optimisticReset:
            return "Reset-boundary flow (#36): the 5h window resets ~20 s after launch, so the bar "
                 + "flips 60 % → 0 % (no ⏰) and a forced refresh follows."
        case .brokenReset:
            return "Noisy 5h (100 %) with resets_at: null (#167) → the ⚠️ error state, not a "
                 + "fabricated \"<1m\". The 7-day window stays calm."
        case .fiveOrange:
            return "Fixed pacing frame (#103): 5h orange, 7d calm — for the reset-countdown table."
        case .bothOrange:
            return "Fixed pacing frame (#103): both windows orange."
        case .bothRed:
            return "Fixed pacing frame (#103): both windows over the red pacing threshold."
        case .redOrange:
            return "Fixed pacing frame (#103): 5h red, 7d orange."
        case .redGreen:
            return "Fixed pacing frame (#103): 5h red, 7d green."
        case .calm5Orange7:
            return "The lone days-away 7d-orange cell (#103) where the reset-countdown mode "
                 + "(smart vs never) changes what's shown."
        case .nearReset:
            return "20-min override (ADR-0044): 5h only ~2 pts ahead but resets in 12 min → forced "
                 + "orange."
        case .calmBoth:
            return "Both bars calm (#94): with \"Hide 7-day bar when calm\" on, the 7-day bar is "
                 + "dropped and a lone green 5h bar sits centred."
        case .farBehind:
            return "Both base bars far behind pace (ADR-0061): a big surplus past the behind-threshold "
                 + "→ blue. Turn \"Work harder\" on with Calm colours to keep the blue coloured."
        case .nearZero:
            return "Near-zero fill on fresh windows: tiny usage (5h 0 %, 7d 4 %, Fable/Mythos ~1–4 %) "
                 + "with barely any time elapsed → a hairline pacing gap. Exercises the min-strip pill "
                 + "geometry: the coloured part must render as a rounded pill flush inside the track "
                 + "(both ends rounded), never a sliver overhanging the track's cap. Menu bar + popup."
        case .edgeExtremes:
            return "Both ends of the scale at once: 5h at 0 % and 7d at 100 % on fresh windows. The 7d "
                 + "bar must fill the track end to end — its caps flush against the track's rounded ends, "
                 + "with no grey sliver left past the fill — while 5h shows a pill at the very start."
        case .calmDegraded:
            return "Calm bars + a degraded (yellow) service dot: with \"Calm colours\" (#105) off the "
                 + "dot is yellow; turn Calm on and it mutes to white."
        case .allGreen:
            return "Calm bars + every service operational (all green): the popup shows no status rows by "
                 + "default; hold ⌥ Option to reveal the four green rows (API, Code, Web/Desktop, Cowork). "
                 + "Most stubs are all-operational too — this one names the ⌥ reveal as its subject."
        case .creditsActive:
            return "Credits ¤ icon (#144): enabled €15 limit, €10.77 spent (~72 %) → paced icon "
                 + "colour. 7-day pinned at 100 % so the icon shows — and since credits cover the "
                 + "exhausted 7-day limit, the popup badges the 7-day reset RED (#193)."
        case .creditsLimitReached:
            return "Credits ¤ icon (#144): spend_limit_reached (€5 limit below €10.77 spent) → RED "
                 + "icon."
        case .creditsNoLimit:
            return "Credits ¤ icon (#144): unlimited limit (limit: null) → NEUTRAL (foreground) icon."
        case .justUnblocked:
            return "Back-to-work edge (#160): first poll blocked (7d 100 %), then workable → fires the "
                 + "\"Back to work!\" notification once (quiet hours + authorization permitting)."
        case .creditsOnset:
            return "Extra-usage onset: first poll not on credits (7d 40 %), then 7d 100 % with credits "
                 + "enabled → work overflows onto paid credit, firing the \"Now using Extra Usage "
                 + "Credit\" notification once (€10.77 of €15.00; quiet hours + authorization permitting)."
        case .resetGrace:
            return "Reset-boundary idle grace (ADR-0041): active → post-reset empty five_hour → active "
                 + "again. The 5h bar stays \"ready\" across the empty polls — no flicker."
        case .colorCycle:
            return "Colour-transition check (ADR-0070): the 5-hour bar and one service dot walk the "
                 + "pacing palette — blue → green → yellow → orange → red and back — pausing 5 s on "
                 + "each. Bar geometry is FROZEN (strip pinned at half the track, no time marker), so "
                 + "the only thing moving is the colour. The 7-day bar stays put as a reference."
        case .incidentActive:
            return "One active incident affecting Code + API (both degraded). Default view: the two "
                 + "service rows. Hold \u{2325} Option and the rows are REPLACED by the incident — its name "
                 + "wrapping across lines with `2h \u{00B7} identified` flush right on the last one."
        case .incidentGreen:
            return "An incident still formally open (`monitoring`) while every monitored component is "
                 + "back to `operational` — the measured 66-minute gap. Nothing about it may render: no "
                 + "service rows, and \u{2325} Option shows no incident section at all. The highest-value "
                 + "frame of the four, because \"nothing renders\" is the easy thing to get wrong."
        case .incidentTwo:
            return "Two simultaneous incidents listing the same degraded components — the real "
                 + "2026-08-05 14:00 shape. \u{2325} Option stacks both rows, each with its own dot, age "
                 + "and link, above ONE subscribe row: a subscription covers the episode, not a ticket."
        case .incidentRecovery:
            return "Silent recovery: the first two polls carry a degraded incident with an update, then "
                 + "the components go `operational` with NO further update — the `mgp99sn4ynd4` case an "
                 + "updates-driven listener would have missed for 43 minutes. Watch the rows vanish."
        }
    }

    // MARK: - Transport

    /// The transport this scenario drives: a fresh ``StubUsageTransport`` per stub case, or the live
    /// `URLSession.shared` for ``realNetwork``. Constructing a fresh stub resets its per-poll `calls`
    /// counter, so re-selecting a call-sequence scenario (stale-error, reset-grace, …) replays it from
    /// the first poll.
    ///
    /// `now` is the base clock every stub `resets_at` is stamped against — pass the same provider the
    /// App renders with (``clock(realNow:)``) so the transport's reset instants and the layout's
    /// countdowns stay in lock-step. Defaults to the wall clock (`realNetwork` ignores it).
    func makeTransport(now: @escaping @Sendable () -> Date = { Date() }) -> UsageTransport {
        switch self {
        case .realNetwork:         return URLSession.shared
        case .climbing:            return StubUsageTransport(mode: .climbing, now: now)
        case .screenshot:          return StubUsageTransport(mode: .screenshot, now: now)
        case .authError:           return StubUsageTransport(mode: .authError, now: now)
        case .staleError:          return StubUsageTransport(mode: .staleError, now: now)
        case .idle:                return StubUsageTransport(mode: .idle, now: now)
        case .idleBlocked:         return StubUsageTransport(mode: .idleBlocked, now: now)
        case .activeBlocked:       return StubUsageTransport(mode: .activeBlocked, now: now)
        case .optimisticReset:     return StubUsageTransport(mode: .optimisticReset, now: now)
        case .brokenReset:         return StubUsageTransport(mode: .brokenReset, now: now)
        case .fiveOrange:          return StubUsageTransport(mode: .pacing(.fiveOrange), now: now)
        case .bothOrange:          return StubUsageTransport(mode: .pacing(.bothOrange), now: now)
        case .bothRed:             return StubUsageTransport(mode: .pacing(.bothRed), now: now)
        case .redOrange:           return StubUsageTransport(mode: .pacing(.redOrange), now: now)
        case .redGreen:            return StubUsageTransport(mode: .pacing(.redGreen), now: now)
        case .calm5Orange7:        return StubUsageTransport(mode: .pacing(.calmFiveOrangeSeven), now: now)
        case .nearReset:           return StubUsageTransport(mode: .pacing(.nearResetFiveHour), now: now)
        case .calmBoth:            return StubUsageTransport(mode: .pacing(.calmBoth), now: now)
        case .farBehind:           return StubUsageTransport(mode: .pacing(.farBehind), now: now)
        case .nearZero:            return StubUsageTransport(mode: .pacing(.nearZero), now: now)
        case .edgeExtremes:        return StubUsageTransport(mode: .pacing(.edgeExtremes), now: now)
        case .calmDegraded:        return StubUsageTransport(mode: .calmDegraded, now: now)
        case .allGreen:            return StubUsageTransport(mode: .allGreen, now: now)
        case .creditsActive:       return StubUsageTransport(mode: .credits(.active), now: now)
        case .creditsLimitReached: return StubUsageTransport(mode: .credits(.limitReached), now: now)
        case .creditsNoLimit:      return StubUsageTransport(mode: .credits(.noLimit), now: now)
        case .justUnblocked:       return StubUsageTransport(mode: .justUnblocked, now: now)
        case .creditsOnset:        return StubUsageTransport(mode: .creditsOnset, now: now)
        case .resetGrace:          return StubUsageTransport(mode: .resetGrace, now: now)
        // The colour walk is driven by `AppDelegate`'s own timer overlaying the retained snapshot, so
        // the transport only has to supply a plain, stable frame for it to repaint (ADR-0070).
        case .colorCycle:          return StubUsageTransport(mode: .pacing(.calmBoth), now: now)
        case .incidentActive:      return StubUsageTransport(mode: .incident(.active), now: now)
        case .incidentGreen:       return StubUsageTransport(mode: .incident(.green), now: now)
        case .incidentTwo:         return StubUsageTransport(mode: .incident(.two), now: now)
        case .incidentRecovery:    return StubUsageTransport(mode: .incident(.recovery), now: now)
        }
    }

    /// Whether this scenario feeds the engine a stub token provider (canned responses never validate
    /// the bearer, so the Keychain is skipped). Only ``realNetwork`` reads the real Keychain / spawns
    /// the live refresher.
    var usesStubToken: Bool { self != .realNetwork }

    // MARK: - Clock

    /// A **fixed** instant this scenario's canned data is anchored to, or `nil` to run off the wall
    /// clock. Stubs are decoupled from today's date by default so a frozen frame is reproducible (same
    /// weekday and reset times every launch) — the exception is scenarios whose behaviour *is* the
    /// passage of real time (see ``usesRealClock``), which return `nil`.
    ///
    /// Most stubs share one anchor (a fixed Wednesday midday, UTC); ``screenshot`` uses a late-month
    /// instant so its extra-usage bar reads as a long green (month ≈99 % elapsed vs ~22 % spent) with a
    /// matching "<1d" reset line — bar and text driven by the same clock, so they never disagree.
    var stubClock: Date? {
        guard !usesRealClock, self != .realNetwork else { return nil }
        return self == .screenshot ? Self.screenshotAnchor : Self.defaultAnchor
    }

    /// Whether this scenario must run off the **real** wall clock because its observable behaviour is
    /// the clock advancing: ``optimisticReset`` arms a one-shot timer for a reset ~20 s out and watches
    /// it fire; ``resetGrace`` holds the 5h bar "ready" across empty polls via a real-time freshness
    /// window. Every other stub is driven purely by the poll counter, so a frozen clock reproduces it.
    /// ``colorCycle`` likewise: its whole point is a colour changing *over time*, driven by a real
    /// timer, so a frozen clock would leave every transition unobservable.
    var usesRealClock: Bool {
        switch self {
        case .optimisticReset, .resetGrace, .colorCycle: return true
        default:                                         return false
        }
    }

    /// Emoji badges shown before the scenario's name in the dev-tools dropdown, marking how "live" it
    /// is: **⚡** = real usage API (``realNetwork``), **⏱** = real wall clock (``usesRealClock``). A
    /// fully canned, date-decoupled stub carries neither. Empty string when there is nothing to flag.
    var badges: String {
        var out = ""
        if self == .realNetwork { out += "⚡" }
        if usesRealClock { out += "⏱" }
        return out.isEmpty ? "" : out + " "
    }

    /// This scenario's render/transport clock: the fixed ``stubClock`` when set, else the live `realNow`
    /// (the wall clock, or a scenario on ``usesRealClock``). One provider feeds both the App's render
    /// and the stub transport so their instants agree.
    func clock(realNow: @escaping @Sendable () -> Date = { Date() }) -> @Sendable () -> Date {
        if let fixed = stubClock { return { fixed } }
        return realNow
    }

    /// The shared fixed anchor for date-decoupled stubs: **2026-01-14 12:00:00 UTC**, a Wednesday
    /// midday — a stable, unambiguous weekday/clock for reproducible frames.
    private static let defaultAnchor = Date(timeIntervalSince1970: 1_768_392_000)

    /// The ``screenshot`` anchor: **2026-01-31 22:00:00 UTC** — late in the month (≈99 % elapsed) so the
    /// extra-usage bar is a long green and its reset line reads "<1d", consistent with the bar.
    private static let screenshotAnchor = Date(timeIntervalSince1970: 1_769_896_800)
}
