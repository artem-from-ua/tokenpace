import Foundation
import TokenPaceKit

/// Every `TOKENPACE_STUB` data-source scenario, as a flat catalogue the dev tools (#187) can enumerate,
/// describe, and switch between live. Each case carries the exact env id (`rawValue`), a human label,
/// a one-line note of what it verifies, and the transport it drives — so the launch-time env path and
/// the Development-tools dropdown share **one** source of truth (no duplicated case list).
///
/// Modeled on ``ColorRole``: a `CaseIterable` registry with computed display metadata. The `rawValue`
/// of every case is the literal string a user would pass in `TOKENPACE_STUB=…`, so
/// `StubScenario(rawValue:)` round-trips env compatibility for free. `realNetwork` (`""`) is the
/// no-stub default: the real usage API over `URLSession.shared`.
///
/// The `summary` strings are lifted from the inline stub docs in `startPolling` and the
/// `docs/guides/ui-verification.md` table — keep them in sync with the `StubUsageTransport.Mode`
/// bodies when a scenario's behaviour changes.
enum StubScenario: String, CaseIterable {

    /// No stub — the production path: real usage API over the live network, Keychain token, live
    /// refresher. Selecting this from the dropdown tears down the stub pipeline and polls the real API.
    case realNetwork = ""

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
    case calmDegraded = "calm-degraded"
    case creditsActive = "credits-active"
    case creditsLimitReached = "credits-limit-reached"
    case creditsNoLimit = "credits-no-limit"
    case justUnblocked = "just-unblocked"
    case creditsOnset = "credits-onset"
    case resetGrace = "reset-grace"

    /// The env id (`TOKENPACE_STUB` value). `realNetwork` maps to the empty string / absent env.
    var id: String { rawValue }

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
        case .calmDegraded:        return "Calm bars + degraded dot"
        case .creditsActive:       return "Credits · active (paced)"
        case .creditsLimitReached: return "Credits · limit reached (red)"
        case .creditsNoLimit:      return "Credits · no limit (neutral)"
        case .justUnblocked:       return "Back to work! edge"
        case .creditsOnset:        return "Extra Usage Credit onset"
        case .resetGrace:          return "Reset-boundary idle grace"
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
        case .calmDegraded:
            return "Calm bars + a degraded (yellow) service dot: with \"Calm colours\" (#105) off the "
                 + "dot is yellow; turn Calm on and it mutes to white."
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
        }
    }

    // MARK: - Transport

    /// The transport this scenario drives: a fresh ``StubUsageTransport`` per stub case, or the live
    /// `URLSession.shared` for ``realNetwork``. Constructing a fresh stub resets its per-poll `calls`
    /// counter, so re-selecting a call-sequence scenario (stale-error, reset-grace, …) replays it from
    /// the first poll.
    func makeTransport() -> UsageTransport {
        switch self {
        case .realNetwork:         return URLSession.shared
        case .climbing:            return StubUsageTransport(mode: .climbing)
        case .screenshot:          return StubUsageTransport(mode: .screenshot)
        case .authError:           return StubUsageTransport(mode: .authError)
        case .staleError:          return StubUsageTransport(mode: .staleError)
        case .idle:                return StubUsageTransport(mode: .idle)
        case .idleBlocked:         return StubUsageTransport(mode: .idleBlocked)
        case .activeBlocked:       return StubUsageTransport(mode: .activeBlocked)
        case .optimisticReset:     return StubUsageTransport(mode: .optimisticReset)
        case .brokenReset:         return StubUsageTransport(mode: .brokenReset)
        case .fiveOrange:          return StubUsageTransport(mode: .pacing(.fiveOrange))
        case .bothOrange:          return StubUsageTransport(mode: .pacing(.bothOrange))
        case .bothRed:             return StubUsageTransport(mode: .pacing(.bothRed))
        case .redOrange:           return StubUsageTransport(mode: .pacing(.redOrange))
        case .redGreen:            return StubUsageTransport(mode: .pacing(.redGreen))
        case .calm5Orange7:        return StubUsageTransport(mode: .pacing(.calmFiveOrangeSeven))
        case .nearReset:           return StubUsageTransport(mode: .pacing(.nearResetFiveHour))
        case .calmBoth:            return StubUsageTransport(mode: .pacing(.calmBoth))
        case .calmDegraded:        return StubUsageTransport(mode: .calmDegraded)
        case .creditsActive:       return StubUsageTransport(mode: .credits(.active))
        case .creditsLimitReached: return StubUsageTransport(mode: .credits(.limitReached))
        case .creditsNoLimit:      return StubUsageTransport(mode: .credits(.noLimit))
        case .justUnblocked:       return StubUsageTransport(mode: .justUnblocked)
        case .creditsOnset:        return StubUsageTransport(mode: .creditsOnset)
        case .resetGrace:          return StubUsageTransport(mode: .resetGrace)
        }
    }

    /// Whether this scenario feeds the engine a stub token provider (canned responses never validate
    /// the bearer, so the Keychain is skipped). Only ``realNetwork`` reads the real Keychain / spawns
    /// the live refresher.
    var usesStubToken: Bool { self != .realNetwork }
}
