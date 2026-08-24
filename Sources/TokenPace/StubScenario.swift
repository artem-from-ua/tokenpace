import Foundation
import TokenPaceKit

/// Every `TOKENPACE_STUB` data-source scenario, as a flat catalogue the dev tools (#187) can enumerate,
/// describe, and switch between live. Each case carries the exact env id (`rawValue`), a human label,
/// a one-line note of what it verifies, and the transport it drives — so the launch-time env path and
/// the Development-tools dropdown share **one** source of truth.
///
/// The `rawValue` of every case is the literal string passed in `TOKENPACE_STUB=…`, so
/// `StubScenario(rawValue:)` round-trips env compatibility for free. ``realNetwork`` (`"real"`) is the
/// no-stub production path: the real usage API over `URLSession.shared`.
///
/// Env resolution goes through ``resolve(env:isAppBundle:)`` — **never** `init(rawValue:)` directly. A
/// bare `init(rawValue:)` cannot tell "nothing was asked for" from "something bogus was asked for",
/// and collapsing the latter into the live network means a run meant to be stubbed silently polls the
/// real API and reads the real `~/.claude` trees.
enum StubScenario: String, CaseIterable {

    /// No stub — the production path: real usage API over the live network, Keychain token, live
    /// refresher. Its id is a **non-empty** `"real"` on purpose: an absent `TOKENPACE_STUB` and an
    /// explicit request for the live network must stay distinguishable, so a typo'd id cannot fall
    /// through to production data.
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
    case standByFloor = "standby-floor"
    case midBandReset = "mid-band-reset"
    case calmBoth = "calm-both"
    case farBehind = "far-behind"
    case weeklyGate = "weekly-gate"
    case weeklyInterp = "weekly-interp"
    case weeklyResetBlackout = "weekly-reset-blackout"
    case weeklyResetUnknown = "weekly-reset-unknown"
    case idleWeekHot = "idle-week-hot"
    case pressureSweep = "pressure-sweep"
    case balanceSweep = "balance-sweep"
    case barExtremes = "bar-extremes"
    case nearZero = "near-zero"
    case edgeExtremes = "edge-extremes"
    case calmDegraded = "calm-degraded"
    case allGreen = "all-green"
    // GitHub provider (#454): the first three isolate its own section; the fourth exists because
    // there are two providers — the interesting bugs live in the interaction.
    case githubGreen = "github-green"
    case githubDegraded = "github-degraded"
    case githubOutage = "github-outage"
    case githubClaudeDown = "github-claude-down"
    case codexGreen = "codex-green"
    case codexDegraded = "codex-degraded"
    case codexCLIOutage = "codex-cli-outage"
    case codexIncident = "codex-incident"
    case codexIncidentsUnavailable = "codex-incidents-unavailable"
    // The quota half (#504). All of them serve their snapshot from a canned source — **no `codex`
    // process is spawned under any stub**, so none depends on the machine having it installed.
    case codexQuotaGreen = "codex-quota-green"
    case codexQuotaOrange = "codex-quota-orange"
    case codexQuotaExhausted = "codex-quota-exhausted"
    case codexTwoWindows = "codex-two-windows"
    case codexQuotaNotStarted = "codex-quota-not-started"
    case codexQuotaReached = "codex-quota-reached"
    case codexNotSignedIn = "codex-not-signed-in"
    case codexCLIMissing = "codex-cli-missing"
    case codexCLIOld = "codex-cli-old"
    case allThreeProviders = "all-three-providers"
    case menuBarClaudeOnly = "menubar-claude-only"
    case menuBarClaudeCodex = "menubar-claude-codex"
    case menuBarCodexOnly = "menubar-codex-only"
    case menuBarCodexOneWindow = "menubar-codex-one-window"
    case menuBarProviderFailing = "menubar-provider-failing"
    case menuBarProvidersDeselected = "menubar-providers-deselected"
    case creditsActive = "credits-active"
    case creditsLimitReached = "credits-limit-reached"
    case creditsNoLimit = "credits-no-limit"
    case creditsNoLimitSpent = "credits-no-limit-spent"
    case creditsZeroSpent = "credits-zero-spent"
    case creditsWideAmounts = "credits-wide-amounts"
    case creditsMaxHeader = "credits-max-header"
    case creditsMaxDetail = "credits-max-detail"
    case allExhaustedCreditsBlock = "all-exhausted-credits-block"
    case allExhaustedTokenBlocks = "all-exhausted-token-blocks"
    case creditsMonthEnd = "credits-month-end"
    case justUnblocked = "just-unblocked"
    case subscriptionResetOnCredits = "subscription-reset-on-credits"
    case creditsOnset = "credits-onset"
    case resetGrace = "reset-grace"
    case colorCycle = "color-cycle"
    case incidentActive = "incident-active"
    case incidentGreen = "incident-green"
    case incidentTwo = "incident-two"
    case incidentRecovery = "incident-recovery"
    case incidentWrapped = "incident-wrapped"
    case incidentSpacing = "incident-spacing"

    /// The env id (`TOKENPACE_STUB` value), including `"real"` for ``realNetwork``.
    var id: String { rawValue }

    // MARK: - Env resolution (#267)

    /// The outcome of reading `TOKENPACE_STUB`: which scenario to run, whether the choice was made
    /// **explicitly**, and the bogus value if one was supplied.
    struct Resolution: Equatable {
        let scenario: StubScenario

        /// Whether this scenario was *asked for* — a recognized `TOKENPACE_STUB` value, or a plain
        /// `.app` launch with no env at all. False only after a bad value, or a dev build defaulting
        /// to the screenshot frame. Gates the awaiting-input watcher (#259): it reads the **live**
        /// `~/.claude` trees, so it must never come up on a live network nobody deliberately selected.
        let isExplicit: Bool

        /// The unrecognized `TOKENPACE_STUB` value that triggered the fallback, or `nil`. Non-nil
        /// means the caller should warn.
        let unknownValue: String?
    }

    /// Built from `allCases`, so it can never drift from the enum.
    static var validIDs: [String] {
        // Debug-only guard: an empty or duplicated id makes "absent env" and "this id" the same
        // string. Checked here since the registry is defined here and the Kit-side unit test
        // (`StubResolutionTests`) can't see this enum. Compiled out of release builds.
        assert(StubResolution.idsAreResolvable(allCases.map(\.rawValue)),
               "StubScenario ids must be non-empty and unique — an empty id resurrects #267")
        return allCases.map(\.id)
    }

    /// The whole point is that an **unrecognized** value must not resolve to the live network — a bad
    /// value degrades *away* from live, onto the frozen ``screenshot`` frame, and says so via
    /// `unknownValue`. The rule itself lives in ``StubResolution`` (pure, unit-tested, ADR-0009); this
    /// is the thin binding that feeds it the registry's ids and maps the answer back onto a case.
    static func resolve(env: String?, isAppBundle: Bool) -> Resolution {
        let outcome = StubResolution.resolve(
            env: env,
            isAppBundle: isAppBundle,
            liveID: StubScenario.realNetwork.id,
            fallbackID: StubScenario.screenshot.id,
            knownIDs: validIDs
        )
        // `outcome.id` is always one of `validIDs`; fall back to the frozen frame rather than
        // force-unwrapping — never to the live network.
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
        case .standByFloor:        return "Pacing · 7d stand-by below floor"
        case .midBandReset:        return "Pacing · reset 4 h 41 m out (mid band)"
        case .calmBoth:            return "Pacing · both calm"
        case .farBehind:           return "Pacing · both far behind (blue)"
        case .weeklyGate:          return "Pacing · 5h far behind, week spent (gate)"
        case .weeklyInterp:        return "Pacing · 7d interpolated from the 5h counter"
        case .weeklyResetBlackout: return "Reset · 7d blackout, reconstructed from the last one"
        case .weeklyResetUnknown:  return "Reset · 7d unknown (cold start, nothing to roll)"
        case .idleWeekHot:         return "Idle · week ahead of pace (popup wording)"
        case .pressureSweep:       return "Pacing · Pressure scale (sharp 5h + clipped 7d)"
        case .balanceSweep:          return "Pacing · Balance scale (full-left 5h + short-right 7d)"
        case .barExtremes:         return "Pacing · fill extremes (full blue 5h + 1 % green 7d)"
        case .nearZero:            return "Pacing · near-zero (pill caps)"
        case .edgeExtremes:        return "Pacing · edge extremes (5h 0 %, 7d 100 %)"
        case .calmDegraded:        return "Calm bars + degraded dot"
        case .allGreen:            return "All services green (⌥ reveals)"
        case .githubGreen:         return "GitHub — all green"
        case .githubDegraded:      return "GitHub — Actions degraded"
        case .githubOutage:        return "GitHub — Git operations down"
        case .githubClaudeDown:    return "GitHub green, Claude down"
        case .codexGreen:          return "Codex — all green"
        case .codexDegraded:       return "Codex — Web degraded"
        case .codexCLIOutage:      return "Codex — CLI down"
        case .codexIncident:       return "Codex — incident without components"
        case .codexIncidentsUnavailable: return "Codex — incidents endpoint down"
        case .codexQuotaGreen:     return "Codex quota — on pace"
        case .codexQuotaOrange:    return "Codex quota — ahead of pace"
        case .codexQuotaExhausted: return "Codex quota — limit reached"
        case .codexTwoWindows:     return "Codex quota — two windows"
        case .codexQuotaNotStarted: return "Codex quota — window not started"
        case .codexQuotaReached:   return "Codex quota — self-contradicting read"
        case .codexNotSignedIn:    return "Codex quota — not signed in"
        case .codexCLIMissing:     return "Codex quota — codex not installed"
        case .codexCLIOld:         return "Codex quota — codex too old"
        case .allThreeProviders:   return "All three providers at once"
        case .menuBarClaudeOnly:   return "Menu bar · Claude alone (regression guard)"
        case .menuBarClaudeCodex:  return "Menu bar · Claude + Codex"
        case .menuBarCodexOnly:    return "Menu bar · Codex alone"
        case .menuBarCodexOneWindow: return "Menu bar · Codex, one window"
        case .menuBarProviderFailing: return "Menu bar · Codex read failing"
        case .menuBarProvidersDeselected: return "Menu bar · Codex unticked"
        case .creditsActive:       return "Credits · active (paced)"
        case .creditsLimitReached: return "Credits · limit reached (red)"
        case .creditsNoLimit:      return "Credits · no limit (neutral)"
        case .creditsNoLimitSpent: return "Credits · no limit, spent out"
        case .creditsZeroSpent:    return "Credits · nothing spent yet"
        case .creditsWideAmounts:  return "Credits · wide amounts (⌥ drops reset)"
        case .creditsMaxHeader:    return "Credits · widest header line"
        case .creditsMaxDetail:    return "Credits · widest detail line"
        case .allExhaustedCreditsBlock: return "All spent · credits free you first"
        case .allExhaustedTokenBlocks:  return "All spent · 7-day frees you last"
        case .creditsMonthEnd:     return "Credits · late in the month (time marker near the end)"
        case .justUnblocked:       return "Back to work! edge"
        case .subscriptionResetOnCredits: return "Back to work! edge · while credits cover"
        case .creditsOnset:        return "Extra usage credits onset"
        case .resetGrace:          return "Reset-boundary idle grace"
        case .colorCycle:          return "Colour transitions (frozen bars)"
        case .incidentActive:      return "Incident · one active (⌥ shows it)"
        case .incidentGreen:       return "Incident · open but components green"
        case .incidentTwo:         return "Incident · two at once"
        case .incidentRecovery:    return "Incident · silent recovery"
        case .incidentWrapped:     return "Incident · chip on its own line"
        case .incidentSpacing:     return "Incident · row spacing vs services"
        }
    }

    /// What this scenario verifies — shown beside the dropdown so a maintainer can tell the states
    /// apart.
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
            return "The honest \"no active 5h session\" state (#100): the 5h bar is the knobless green "
                 + "idle pill, no phantom reset, menu-bar time falls back to the 7-day reset. Since "
                 + "#381 the pill is green for every ready idle state, so this frame is NOT "
                 + "distinguishable from `idle-week-hot` in the menu bar — only the popup wording "
                 + "differs."
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
        case .standByFloor:
            return "Stand-by floor: 7d orange with only a 16-min wait to green, so the ⌥ "
                 + "stand-by line stays hidden."
        case .midBandReset:
            return "One format for every distance (#284): the 5h reset is 4 h 41 m out — the band "
                 + "that used to print a wall clock (\"20:40\") and now reads \"5h\", the same number "
                 + "the popup leads with."
        case .calmBoth:
            return "Both bars calm (#94): with \"Hide 7-day bar when calm\" on, the 7-day bar is "
                 + "dropped and a lone green 5h bar sits centred."
        case .farBehind:
            return "Both base bars far behind pace (ADR-0061): a big surplus past the behind-threshold "
                 + "→ blue. Set \"Colors tell me\" to `Slow down or speed up` to keep the blue coloured."
        case .weeklyGate:
            return "The weekly-capacity gate. 5h is deep behind pace (u = 5 %, t = 60 %) — a 55 pp "
                 + "surplus, far past the 40 pp threshold, so it WOULD be blue — but the 7-day window "
                 + "is exhausted (100 %). Blue advises \"there's room to push\", which a spent week "
                 + "cannot fund, so the 5h bar must be GREEN, not blue (and not yellow: its own pace is "
                 + "calm). Check both surfaces, and the popup's 5h row saying \"on pace\" rather than "
                 + "\"far behind pace\". Compare with `far-behind`, where the week is calm and the blue "
                 + "stays."
        case .weeklyInterp:
            return "The 7-day reconstruction (#386), as a **sequence** — watch it over ~20 polls "
                 + "rather than as one frame. The weekly counter stays a whole number throughout (61, "
                 + "then 62 from poll 8), exactly as the API behaves, while the 5-hour one climbs "
                 + "1 pp per poll — so every movement of the 7-day bar is the reconstruction's, since "
                 + "there is no other source. Polls 0–7 run on an inherited anchor: the value creeps "
                 + "from the bucket centre to its ceiling and holds. Poll 8 brings the single bump, "
                 + "which firms the anchor at the new bucket's lower edge — and must not move the bar, "
                 + "because the old ceiling and the new floor are the same point. Polls 9+ creep "
                 + "61.5 → 62.5 in 0.1 pp steps, then hold (`clipped`) rather than overtake the next "
                 + "quantum. Troubleshoot discloses both numbers throughout. What to check: nothing "
                 + "ever steps backwards, least of all at the two handovers."
        case .weeklyResetBlackout:
            return "The weekly API blackout (ADR-0107), as a **sequence** — step it with \"Refresh "
                 + "now\". The first two polls carry a real `seven_day.resets_at`, which seeds the "
                 + "anchor; every poll after that returns the body the server actually sends for 4-6 "
                 + "hours after each weekly reset — `seven_day: null` with a `weekly_all` entry that "
                 + "has no date either, so both sources of the reset vanish at once. What to check: "
                 + "**the 7-day countdown stops moving** from poll 2 on. Before this change it "
                 + "stepped ~10 minutes forward on every refresh, because the fallback re-estimated "
                 + "`now + 7d` each time, and the time marker stayed pinned at the left edge for the "
                 + "whole blackout. Now the date holds and the marker advances."
        case .weeklyResetUnknown:
            return "The cold start (ADR-0107): the same blackout body on every poll, with **no** "
                 + "anchor to roll forward — a fresh install that has never spent a token. Clear the "
                 + "stored anchor first (`defaults delete TokenPace lastSevenDayReset`), or the app "
                 + "will reconstruct from it and you will see ordinary bars. What to check: the menu "
                 + "bar shows the no-data symbol — **not** the ⚠️, which is reserved for data that "
                 + "contradicts itself — and the popup withholds every limit row, showing only "
                 + "\"Weekly reset time unknown\" and the line that says what will fix it. No "
                 + "countdown anywhere: the whole point is that nothing is invented."
        case .idleWeekHot:
            return "Idle 5h while the week runs ahead of pace (u = 70 %, t = 29 %). No active session, "
                 + "so the 5h bar is the knobless idle pill — GREEN, like every ready idle state since "
                 + "#381 (ADR-0105 dropped the \"ready to start\" blue: it was a second claim, \"there "
                 + "is room to burn\", riding the same mark). The status word stays \"ready to "
                 + "start\". The pill no longer tells this frame apart from `idle` — check the POPUP "
                 + "wording instead; `idle-blocked` (7d exhausted, no credits) is still the only idle "
                 + "frame with a different colour: grey, \"waiting for limit reset\"."
        case .pressureSweep:
            return "Pressure scale (#307, rescaled by ADR-0101): 5h three points from exhaustion with "
                 + "7 % of the window left — 4 % of the bar on the old window scale (below the min "
                 + "pill), 57 % now. 7d sits in the yellow band at 11 %, just clear of the min pill, so "
                 + "the two rows show yellow and orange holding clearly different widths — and the 7d "
                 + "row is the tightest case for that. Switch Bar style across Pressure / Balance / "
                 + "Progress: Progress must look exactly as before, and the 7d ribbon must not move "
                 + "between Pressure and Balance (Pressure IS Balance's ahead half)."
        case .barExtremes:
            return "Both ends of the fill range at once, for judging the strip's CORNER RADIUS "
                 + "(#326). 5h: a 75 pp surplus (t = 80 %, u = 5 %) — far past the far-behind "
                 + "threshold, so blue, and under Balance it fills the entire left half. 7d: a hair of "
                 + "a lead (t = 30 %, u = 31.25 %) → 1.4 % of the ahead half, floored to the minimum "
                 + "pill. Check: the strip's corners match the grey track's (1.5 pt) on BOTH rows — "
                 + "a full strip must not bulge past the track's own corners, and the tiny one must "
                 + "not read as a capsule lozenge sitting on a rectangle. Worth a pass in every Bar "
                 + "style: the radius is shared by all four."
        case .balanceSweep:
            return "Balance scale (#326): one row each side of the centre. 5h sits deep behind pace "
                 + "(t = 90 %, u = 70 %) — a surplus twice the time left, so the left half is FULL; "
                 + "every other style draws this as the minimum pill. 7d holds the mild lead "
                 + "(t = 30 %, u = 38 %) → a short ribbon right of centre. Check: (1) the centre tick "
                 + "is present in every state, including idle, and only its ends show above and below "
                 + "the track; (2) switching Pressure ↔ Balance leaves the 7d (ahead) ribbon at the very "
                 + "same length — since ADR-0101 Pressure IS this scale's ahead half, so the two "
                 + "cannot disagree; (3) on Balance the 5h row is the widest thing on screen, on "
                 + "Pressure it is the narrowest; (4) with \"Colors tell me\" on `Slow down`, direction is the only cue "
                 + "left — that is the case that decides whether the trade-off is acceptable."
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
            return "Calm bars + a `degraded_performance` service. Since #410 all three surfaces draw "
                 + "this dot the SAME yellow — menu bar, popup and the Legend page (ADR-0111): the "
                 + "escalating scale grey → yellow → orange → red is what carries the meaning, so the "
                 + "menu bar no longer drops its middle step. Check them side by side — any difference "
                 + "is a regression — and check the yellow on a LIGHT theme against the real menu bar: "
                 + "loud enough to notice beside the system icons, not loud enough to read as an alert. "
                 + "No setting moves it: `Colors tell me` governs the pacing bars only (ADR-0105 §1)."
        case .allGreen:
            return "Calm bars + every service operational (all green): the popup shows no status rows by "
                 + "default; hold ⌥ Option to reveal the four green rows (API, Code, Web/Desktop, Cowork). "
                 + "Most stubs are all-operational too — this one names the ⌥ reveal as its subject."
        case .githubGreen:
            return "GitHub monitored and healthy: the section shows its header dot and no rows — the "
                 + "state that would otherwise be an empty section (#454)."
        case .githubDegraded:
            return "GitHub with Actions degraded: one row under the GitHub header, the header dot "
                 + "yellow, Claude untouched."
        case .githubOutage:
            return "GitHub with Git operations down and API requests degraded: worst-of-5 puts the "
                 + "header dot red; the menu-bar dot follows worst-of-all."
        case .githubClaudeDown:
            return "Both providers at once, in opposite states — GitHub green while Claude Code is "
                 + "down. Proves the sections and their dots are independent (#454)."
        case .codexGreen:
            return "Codex monitored and healthy: the plate shows its header dot and no rows — the "
                 + "state that would otherwise be an empty plate. Check the wordmark colour with "
                 + "Digital Color Meter in sRGB (#5871C0) on BOTH themes; no screenshot is a source "
                 + "of colour."
        case .codexDegraded:
            return "Codex with `Codex Web` degraded: one row under the Codex header, the header dot "
                 + "yellow, the other providers untouched."
        case .codexCLIOutage:
            return "Codex with `CLI` down — the component that decides the feed choice. `CLI` sits "
                 + "at position 29 of `components.json` and is absent from `summary.json` entirely, "
                 + "so a row here is proof the poll reads the right endpoint."
        case .codexIncident:
            return "A Codex incident whose affected component is monitored, with `CLI` degraded so "
                 + "the plate has rows too. Hold ⌥ to swap the rows for the incident: it carries no "
                 + "shortlink (the proxy feed has none), so the row's stage word is NOT a link — "
                 + "that is correct, not a bug."
        case .codexIncidentsUnavailable:
            return "The degradation path: components 200, incidents 500. Statuses and their dots "
                 + "keep rendering (they come from the other endpoint) and the incident rows are "
                 + "simply absent under ⌥. `CLI` is degraded, so there IS something the missing "
                 + "incident would have explained."
        case .codexQuotaGreen:
            return "The Codex plate with its quota half on: a 7-day bar under the wordmark, the plan "
                 + "word beside it. Check there is NO 5-hour row — the server reports one window and "
                 + "a second would be invented."
        case .codexQuotaOrange:
            return "Codex quota ahead of pace — the bar orange, its own colour transition running "
                 + "independently of Claude's identically-titled `7-day` row above it."
        case .codexQuotaExhausted:
            return "Codex quota at 100 %. The reset line stays PLAIN — the red blocking badge is "
                 + "Claude's alone (it answers which reset unblocks Claude work), so an exhausted "
                 + "Codex window must not paint one here or on any Claude row."
        case .codexTwoWindows:
            return "Two Codex windows at once — the only way to see the N>1 path before the server "
                 + "ever sends a `secondary`. Both bars sit on the Codex plate; neither renumbers "
                 + "Claude's rows above."
        case .codexQuotaNotStarted:
            return "The state right after a Codex reset: `usedPercent` 0 and a `resetsAt` the "
                 + "server recomputes as now + 7d on EVERY read, so a rendered countdown would "
                 + "slide forward and never tick down. The row must show NO second line — no "
                 + "\"0%\", no reset, no \"resetting…\" — just `7-day  ready to start` over a "
                 + "green knobless bar. Troubleshoot still carries the raw epoch under "
                 + "`Reported resets`, and it advances between reads."
        case .codexQuotaReached:
            return "The SAME spotless reading, with the account flagged reached — a payload that "
                 + "contradicts itself, since 'limit reached' and 'nothing used' cannot both hold. "
                 + "The Codex plate must show NO BAR at all for that window: in its place a red "
                 + "⚠️ block reading `Codex reset time bug` over a line saying the numbers cannot "
                 + "be trusted. The MENU BAR must show no Codex bar either. Compare with "
                 + "`codex-quota-not-started`, whose only difference is the flag: identical "
                 + "numbers, one draws a green ready-to-start bar and this one draws none."
        case .codexNotSignedIn:
            return "Codex installed but signed out: the plate keeps its status half and shows no "
                 + "bars. Troubleshoot carries the reason; the popup shows no warning banner, since "
                 + "that banner is Claude's."
        case .codexCLIMissing:
            return "No `codex` on this Mac. Troubleshoot lists the candidate paths that were tried "
                 + "rather than a bare not-found."
        case .codexCLIOld:
            return "A `codex` that predates `account/rateLimits/read` — the -32600 detection, which "
                 + "keys on the code AND the method name in the message, since -32600 alone is also "
                 + "what a malformed params struct returns."
        case .menuBarClaudeOnly:
            return "The REGRESSION GUARD for #505: Claude's two bars and nothing else, the frame every "
                 + "existing user sees. Its geometry must be byte-identical to a `main` build — check "
                 + "by pixel diff of the real menu bar, not by eye; a 0.5 pt drift is invisible in "
                 + "review and obvious in a diff."
        case .menuBarClaudeCodex:
            return "Two blocks: Claude's 5h+7d pair, then Codex's single week, alphabetical, separated "
                 + "by a gap. The bars carry NO brand tint — a bar's colour is the pacing verdict, and "
                 + "provider identity in the widget is positional only."
        case .menuBarCodexOnly:
            return "Claude unticked, so Codex's block stands alone: one bar, vertically centred exactly "
                 + "where a lone Claude bar sits. Proves the geometry follows the bar COUNT, not which "
                 + "provider owns the bars."
        case .menuBarCodexOneWindow:
            return "Codex's week beside Claude's pair while a service is degraded — the block count "
                 + "and the trailing dot at once. The dot is the LAST element, after every block."
        case .menuBarProviderFailing:
            return "Codex's quota read fails while Claude's is healthy: Codex's block disappears "
                 + "entirely rather than freezing at its last percentage, and Claude's is untouched."
        case .menuBarProvidersDeselected:
            return "Codex collecting but unticked under Appearance → Menu bar (forced by the stub, so "
                 + "your real setting is untouched): the widget is back to Claude's width."
        case .allThreeProviders:
            return "All three plates at once, each in its own state. Read the order top to bottom: "
                 + "Claude, then Codex, then GitHub (`displayName` order, Claude pinned first), with "
                 + "an equal gap between each pair."
        case .creditsActive:
            return "Credits ¤ icon (#144): enabled €15 limit, €10.77 spent (~72 %) → paced icon "
                 + "colour. 7-day pinned at 100 % so the icon shows — and since credits cover the "
                 + "exhausted 7-day limit, the popup badges the 7-day reset RED (#193)."
        case .creditsLimitReached:
            return "Credits ¤ icon (#144): spend_limit_reached (€5 limit below €10.77 spent) → RED "
                 + "icon."
        case .creditsNoLimit:
            return "Credits ¤ icon (#144): unlimited limit (limit: null) → NEUTRAL (foreground) icon."
        case .creditsNoLimitSpent:
            return "No cap AND the credits spent out (`limit: null` + `spend_limit_reached: true`, so "
                 + "the server has disabled them). The one place the header itself goes red: the row "
                 + "has no second line — no ceiling means no reset to wait for — so there is no reset "
                 + "badge to carry the red instead. Compare `credits-limit-reached`, where a cap exists: "
                 + "there the header says \"limit reached\" in plain text and the RED sits on the reset "
                 + "badge below it, because the reset is what actually unblocks. One filled red per row, "
                 + "always on the thing you are waiting for."
        case .creditsZeroSpent:
            return "Credits enabled, €15 cap, nothing spent yet (amount_minor: 0) → the resting money "
                 + "line reads \"€0 of €15\" (⌥ → \"spent €0.00 of €15.00\"); bar sits at zero. The cap "
                 + "stays on the line at zero spend: without it the row would read like the unlimited "
                 + "one, which is a different billing configuration."
        case .creditsWideAmounts:
            return "The widest money line a real payload can produce: €1,234.56 of a €2,000 cap, 322 pt "
                 + "under ⌥. Since the column went to 320 pt (#396) this one FITS — both halves stay, "
                 + "and so does plain `credits-active` (281 pt), which used to lose its reset. The fit "
                 + "gate is not gone, it just moved out to the genuine extreme: a four-figure cap paired "
                 + "with the longest reset phrase (\"spent $5,000.00 of $5,000.00\" + \"resets in 20d "
                 + "next Wednesday\", 376 pt) still drops the reset rather than truncating to an "
                 + "ellipsis. 7d is left un-exhausted on purpose: a blocking reset is a red badge and is "
                 + "never dropped."
        case .creditsMaxHeader:
            return "The widest FIRST line the section can produce (#396), and the case that set the "
                 + "popup's width. Credits are enabled but not yet covering an exhausted plan limit, so "
                 + "the header carries the wide `available` badge rather than the narrow currency glyph; "
                 + "the spend is far enough ahead of the month's pace for \"well ahead of pace\", the "
                 + "longest status phrase. \"Extra usage progress … [available] well ahead of pace\" "
                 + "measures 318 pt against the 320 pt column — 12 pt of headroom, and nothing in this "
                 + "row may be allowed to grow past it. Check the two halves do not touch."
        case .creditsMaxDetail:
            return "The widest SECOND line: a four-figure cap spent to the last cent, so both money "
                 + "halves carry grouping separators and the same glyph count — \"spent $5,000.00 of "
                 + "$5,000.00\". Paired with the longest reset phrase this overflows even the 320 pt "
                 + "column, so the fit gate DROPS the whole reset half rather than truncating either "
                 + "one to an ellipsis. This is the gate's remaining job after the widening; the header "
                 + "above it reads \"limit reached\" and carries NO badge (once the cap is reached the "
                 + "server disables credits, so nothing is actively spending)."
        case .allExhaustedCreditsBlock:
            return "EVERYTHING is spent — 5h, 7d and the €15 money cap all at 100 % — and the token "
                 + "windows reset AFTER the month does (7d in 40 d). By the last-stand rule "
                 + "(`BlockingReset.select`) the credits reset is then the first way back, so it is the "
                 + "blocker: the RED reset badge sits on the **Extra usage** line and nowhere else. "
                 + "Both token rows read \"limit reached\" with their resets as plain dimmed text, "
                 + "despite being just as exhausted. Extra usage carries no state badge either — with "
                 + "the cap spent the red belongs to the reset below, not the header. Compare against "
                 + "`all-exhausted-token-blocks`, which differs ONLY in when the tokens reset."
        case .allExhaustedTokenBlocks:
            return "The same three limits exhausted, but the 7-day window resets LAST (in 24 d, past "
                 + "the month boundary) instead of first. The red badge moves to the **7-day** row and "
                 + "the Extra usage reset goes plain — the money frees you before the plan does, so "
                 + "the plan is what you are actually waiting on. Run it back to back with "
                 + "`all-exhausted-credits-block`: identical utilizations, identical amounts, one "
                 + "red badge each, on different rows."
        case .creditsMonthEnd:
            return "The Extra-usage bar's captioned month ruler with the time marker near its right "
                 + "end: same €15 cap and €10.77 spent as `credits-active`, but the clock is pinned to "
                 + "Jan 28 (~90 % of the month elapsed), so the marker sits close to the \"Jan 31\" "
                 + "caption. Checks that the two never collide and that the caption stays readable "
                 + "beside the marker's glow — the crowded end of this bar's geometry."
        case .justUnblocked:
            return "Back-to-work edge (#160): first poll blocked (7d 100 %), then workable → fires the "
                 + "\"Back to work!\" notification once (quiet hours + authorization permitting)."
        case .subscriptionResetOnCredits:
            return "Back-to-work edge while credits cover the gap (#161): first poll 7d 100 % **with "
                 + "credits enabled** — work never stops, but the subscription is spent — then 7d 40 %. "
                 + "The notification tracks the subscription, so the reset fires it once even though "
                 + "work was possible throughout. This is the case the old \"can I work?\" signal "
                 + "stayed silent on."
        case .creditsOnset:
            return "Extra-usage onset: first poll not on credits (7d 40 %), then 7d 100 % with credits "
                 + "enabled → work overflows onto paid credit, firing the \"Now using Extra usage "
                 + "credits\" notification once (€10.77 of €15.00; quiet hours + authorization permitting)."
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
        case .incidentWrapped:
            return "Three incidents chosen for how their names WRAP (#351) — every placement the chip "
                 + "can take. Hold \u{2325} Option: the first ends its last line early, so `2h7m · "
                 + "identified` SHARES that line; the second wraps to two lines and pushes `13m · "
                 + "investigating` onto a third; the third fits on ONE line yet still has no room, so "
                 + "`6m · investigating` sits ALONE on line two — the clearest form, with a wide gap "
                 + "after the name. Every chip must be flush RIGHT; the wrapped ones fell to the left."
        case .incidentSpacing:
            return "Two degraded services and two SHORT, single-line incidents — the frame for judging "
                 + "vertical rhythm (#351). Tap \u{2325} Option on and off: two rows swap for two rows of "
                 + "the same height, so the gaps must not change. All four must match — incident to "
                 + "incident, incident to subscribe, service to service, service to subscribe. Until "
                 + "#351 the incident gaps were 8 pt against the services' 3 pt."
        }
    }

    // MARK: - Transport

    /// A fresh ``StubUsageTransport`` per stub case, or the live `URLSession.shared` for
    /// ``realNetwork``. Constructing a fresh stub resets its per-poll `calls` counter, so re-selecting
    /// a call-sequence scenario replays it from the first poll.
    ///
    /// `now` is the base clock every stub `resets_at` is stamped against — pass the same provider the
    /// App renders with (``clock(realNow:)``) so the transport's reset instants and the layout's
    /// countdowns stay in lock-step.
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
        case .standByFloor:        return StubUsageTransport(mode: .pacing(.standByFloor), now: now)
        case .midBandReset:        return StubUsageTransport(mode: .pacing(.midBandReset), now: now)
        case .calmBoth:            return StubUsageTransport(mode: .pacing(.calmBoth), now: now)
        case .farBehind:           return StubUsageTransport(mode: .pacing(.farBehind), now: now)
        case .weeklyGate:          return StubUsageTransport(mode: .pacing(.weeklyGate), now: now)
        case .weeklyInterp:        return StubUsageTransport(mode: .weeklyInterp, now: now)
        case .weeklyResetBlackout: return StubUsageTransport(mode: .weeklyResetBlackout, now: now)
        case .weeklyResetUnknown:  return StubUsageTransport(mode: .weeklyResetUnknown, now: now)
        case .idleWeekHot:         return StubUsageTransport(mode: .idleWeekHot, now: now)
        case .pressureSweep:       return StubUsageTransport(mode: .pacing(.pressureSweep), now: now)
        case .balanceSweep:          return StubUsageTransport(mode: .pacing(.balanceSweep), now: now)
        case .barExtremes:         return StubUsageTransport(mode: .pacing(.barExtremes), now: now)
        case .nearZero:            return StubUsageTransport(mode: .pacing(.nearZero), now: now)
        case .edgeExtremes:        return StubUsageTransport(mode: .pacing(.edgeExtremes), now: now)
        case .calmDegraded:        return StubUsageTransport(mode: .calmDegraded, now: now)
        case .allGreen:            return StubUsageTransport(mode: .allGreen, now: now)
        case .githubGreen:         return StubUsageTransport(mode: .githubGreen, now: now)
        case .githubDegraded:      return StubUsageTransport(mode: .githubDegraded, now: now)
        case .githubOutage:        return StubUsageTransport(mode: .githubOutage, now: now)
        case .githubClaudeDown:    return StubUsageTransport(mode: .githubClaudeDown, now: now)
        case .codexGreen:          return StubUsageTransport(mode: .codexGreen, now: now)
        case .codexDegraded:       return StubUsageTransport(mode: .codexDegraded, now: now)
        case .codexCLIOutage:      return StubUsageTransport(mode: .codexCLIOutage, now: now)
        case .codexIncident:       return StubUsageTransport(mode: .codexIncident, now: now)
        case .codexIncidentsUnavailable:
            return StubUsageTransport(mode: .codexIncidentsUnavailable, now: now)
        // The quota scenarios keep the network side calm — their subject is the Codex plate's bars,
        // and a busy Claude stack above would compete for the eye.
        case .codexQuotaGreen, .codexQuotaOrange, .codexQuotaExhausted, .codexTwoWindows,
             .codexQuotaNotStarted, .codexQuotaReached,
             .codexNotSignedIn, .codexCLIMissing, .codexCLIOld:
            return StubUsageTransport(mode: .codexGreen, now: now)
        case .allThreeProviders:   return StubUsageTransport(mode: .allThreeProviders, now: now)
        // The menu-bar scenarios keep Claude calm: their subject is how many blocks there are and
        // where they sit, and a busy Claude stack would compete for the eye.
        case .menuBarClaudeOnly, .menuBarClaudeCodex, .menuBarCodexOnly, .menuBarProviderFailing,
             .menuBarProvidersDeselected:
            return StubUsageTransport(mode: .pacing(.calmBoth), now: now)
        // Degraded, so the trailing dot is on screen at the same time as two blocks.
        case .menuBarCodexOneWindow:
            return StubUsageTransport(mode: .calmDegraded, now: now)
        case .creditsActive:       return StubUsageTransport(mode: .credits(.active), now: now)
        case .creditsLimitReached: return StubUsageTransport(mode: .credits(.limitReached), now: now)
        case .creditsNoLimit:      return StubUsageTransport(mode: .credits(.noLimit), now: now)
        case .creditsNoLimitSpent: return StubUsageTransport(mode: .credits(.noLimitSpent), now: now)
        case .creditsZeroSpent:    return StubUsageTransport(mode: .credits(.zeroSpent), now: now)
        case .creditsWideAmounts:  return StubUsageTransport(mode: .credits(.wideAmounts), now: now)
        case .creditsMaxHeader:    return StubUsageTransport(mode: .credits(.maxHeader), now: now)
        case .creditsMaxDetail:    return StubUsageTransport(mode: .credits(.maxDetail), now: now)
        case .allExhaustedCreditsBlock:
            return StubUsageTransport(mode: .credits(.allExhaustedCreditsBlock), now: now)
        case .allExhaustedTokenBlocks:
            return StubUsageTransport(mode: .credits(.allExhaustedTokenBlocks), now: now)
        case .creditsMonthEnd:     return StubUsageTransport(mode: .credits(.active), now: now)
        case .justUnblocked:       return StubUsageTransport(mode: .justUnblocked, now: now)
        case .subscriptionResetOnCredits:
            return StubUsageTransport(mode: .subscriptionResetOnCredits, now: now)
        case .creditsOnset:        return StubUsageTransport(mode: .creditsOnset, now: now)
        case .resetGrace:          return StubUsageTransport(mode: .resetGrace, now: now)
        // Driven by `AppDelegate`'s own timer overlaying the retained snapshot (ADR-0070); the
        // transport only needs to supply a plain, stable frame.
        case .colorCycle:          return StubUsageTransport(mode: .pacing(.calmBoth), now: now)
        case .incidentActive:      return StubUsageTransport(mode: .incident(.active), now: now)
        case .incidentGreen:       return StubUsageTransport(mode: .incident(.green), now: now)
        case .incidentTwo:         return StubUsageTransport(mode: .incident(.two), now: now)
        case .incidentRecovery:    return StubUsageTransport(mode: .incident(.recovery), now: now)
        case .incidentWrapped:     return StubUsageTransport(mode: .incident(.wrapped), now: now)
        case .incidentSpacing:     return StubUsageTransport(mode: .incident(.spacing), now: now)
        }
    }

    /// Only ``realNetwork`` reads the real Keychain / spawns the live refresher.
    var usesStubToken: Bool { self != .realNetwork }

    /// The quota source for this scenario. **`nil` for every stub except the quota ones, and a canned
    /// source — never `CodexAppServer` — for those**: no scenario may spawn `codex`, since a stub must
    /// render the same on a machine that has never installed it.
    ///
    /// `.realNetwork` is the only case that returns the real collector.
    func codexQuotaSource(now: @escaping @Sendable () -> Date = { Date() })
        -> (any CodexQuotaSource)? {
        switch self {
        case .realNetwork:
            return CodexAppServer(now: now)
        case .codexQuotaGreen:
            return StubCodexQuotaSource(.windows([(4, 604_800)]), now: now)
        case .codexQuotaOrange:
            return StubCodexQuotaSource(.windows([(62, 604_800)]), now: now)
        case .codexQuotaExhausted:
            return StubCodexQuotaSource(.windows([(100, 604_800)]), now: now)
        // A 5-hour window beside the week — the shape the server does not send today. The only way to
        // exercise the N>1 path before it does.
        case .codexTwoWindows:
            return StubCodexQuotaSource(.windows([(37, 604_800), (12, 18_000)]), now: now)
        // Its reset is derived from the scenario clock at read time, so it moves with `now` the way
        // the server's does — the defect is only visible when the value is recomputed per read.
        case .codexQuotaNotStarted:
            return StubCodexQuotaSource(.notStarted([604_800]), now: now)
        // The same reading with the account flagged reached — the self-contradicting payload. It
        // cannot be produced on a live account on demand, and it is the one the gate exists for.
        case .codexQuotaReached:
            return StubCodexQuotaSource(.notStartedReached([604_800]), now: now)
        // One week, the shape the server actually sends today.
        case .menuBarClaudeCodex, .menuBarCodexOnly, .menuBarCodexOneWindow,
             .menuBarProvidersDeselected:
            return StubCodexQuotaSource(.windows([(41, 604_800)]), now: now)
        // A failed read drops the rows, so Codex contributes no block at all.
        case .menuBarProviderFailing:
            return StubCodexQuotaSource(.failure(.notSignedIn), now: now)
        case .codexNotSignedIn:
            return StubCodexQuotaSource(.failure(.notSignedIn), now: now)
        case .codexCLIMissing:
            return StubCodexQuotaSource(.failure(.cliNotFound), now: now)
        case .codexCLIOld:
            return StubCodexQuotaSource(
                .failure(.methodUnsupported(method: CodexAppServer.rateLimitsMethod)), now: now)
        default:
            return nil
        }
    }

    /// Whether this scenario collects a Codex quota **regardless of the Settings switch**.
    ///
    /// The switch is off by default and writing it is the maintainer's alone, so without this a
    /// menu-bar scenario would render as Claude-only on his machine and quietly pass. A stub asserts
    /// its own preconditions; it does not ask him to set them up first.
    var forcesCodexQuota: Bool { self != .realNetwork && codexQuotaSource() != nil }

    /// Providers whose menu-bar block this scenario hides, standing in for the "Providers to display"
    /// checkboxes without touching the stored setting.
    var menuBarHiddenProviders: Set<ProviderID> {
        switch self {
        case .menuBarProvidersDeselected: return [.codex]
        case .menuBarCodexOnly:           return [.claude]
        default:                          return []
        }
    }

    // MARK: - Clock

    /// A **fixed** instant this scenario's canned data is anchored to, or `nil` to run off the wall
    /// clock. Stubs are decoupled from today's date by default so a frozen frame is reproducible — the
    /// exception is scenarios whose behaviour *is* the passage of real time (``usesRealClock``).
    ///
    /// Most stubs share one anchor (a fixed Wednesday midday, UTC); ``screenshot`` uses a late-month
    /// instant so its extra-usage bar reads as a long green with a matching "<1d" reset line.
    var stubClock: Date? {
        guard !usesRealClock, self != .realNetwork else { return nil }
        switch self {
        case .screenshot:      return Self.screenshotAnchor
        case .creditsMonthEnd: return Self.monthEndAnchor
        default:               return Self.defaultAnchor
        }
    }

    /// Whether this scenario must run off the **real** wall clock because its observable behaviour is
    /// the clock advancing: ``optimisticReset`` arms a one-shot timer for a reset ~20 s out;
    /// ``resetGrace`` holds the 5h bar "ready" across empty polls via a real-time freshness window;
    /// ``colorCycle``'s whole point is a colour changing over time;
    /// ``codexQuotaNotStarted`` and ``codexQuotaReached`` recompute their reset from `now` at every
    /// read, so the raw epoch in Troubleshoot only advances — the symptom being suppressed — while
    /// the clock does. Every other stub is driven purely by the poll counter, so a frozen clock
    /// reproduces it.
    var usesRealClock: Bool {
        switch self {
        case .optimisticReset, .resetGrace, .colorCycle, .codexQuotaNotStarted, .codexQuotaReached:
            return true
        default:
            return false
        }
    }

    /// Badges before the scenario's name in the dropdown: **⚡** = real usage API (``realNetwork``),
    /// **⏱** = real wall clock (``usesRealClock``), **⏭** = advances one step per poll
    /// (``advancesPerPoll``). Empty string when nothing to flag.
    var badges: String {
        var out = ""
        if self == .realNetwork { out += "⚡" }
        if usesRealClock { out += "⏱" }
        if advancesPerPoll { out += "⏭" }
        return out.isEmpty ? "" : out + " "
    }

    /// Whether this scenario is a **sequence** whose state advances one step per poll, rather than a
    /// frozen frame — **Refresh now** in Troubleshoot is the control that steps it (each click is one
    /// more poll). Flagged with **⏭** in the dropdown since a frozen frame looks identical after a
    /// refresh, while these look wrong until you keep going.
    var advancesPerPoll: Bool {
        switch self {
        case .weeklyInterp, .standByFloor, .optimisticReset, .resetGrace,
             .justUnblocked, .subscriptionResetOnCredits, .creditsOnset, .staleError,
             // Seeds the anchor on its first two polls, then blacks out — the countdown *stops*
             // moving across the handover.
             .weeklyResetBlackout:
            return true
        default:
            return false
        }
    }

    /// One provider feeds both the App's render and the stub transport so their instants agree.
    func clock(realNow: @escaping @Sendable () -> Date = { Date() }) -> @Sendable () -> Date {
        if let fixed = stubClock { return { fixed } }
        return realNow
    }

    /// **2026-01-14 12:00:00 UTC**, a Wednesday midday — a stable, unambiguous weekday/clock.
    private static let defaultAnchor = Date(timeIntervalSince1970: 1_768_392_000)

    /// **2026-01-31 22:00:00 UTC** — late in the month (≈99% elapsed) so the extra-usage bar is a
    /// long green with a matching "<1d" reset line.
    private static let screenshotAnchor = Date(timeIntervalSince1970: 1_769_896_800)

    /// **2026-01-28 21:36:00 UTC** — exactly **90%** through January, so the Extra-usage bar's time
    /// marker lands near (but not on) the "Jan 31" caption.
    private static let monthEndAnchor = Date(timeIntervalSince1970: 1_769_636_160)
}
