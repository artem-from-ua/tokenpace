import Foundation

// MARK: - CalmBarHiding

/// Which of the two menu-bar pacing bars is dropped from the widget **while it is calm** — chosen by a
/// segmented control in Settings → Menu bar ("Hide the calm bar") and threaded into
/// ``MenuBarLayout/make(from:now:resetMode:hideCalmBar:pauseHidesBars:)``.
///
/// Generalises the boolean `hideCalmSevenDayBar` opt-out of ADR-0034 / #94, which could only ever hide
/// the **7-day** bar. The need is symmetric: someone pacing against the weekly budget wants the 7-day bar
/// on screen and the 5-hour one out of the way while it has nothing to say. So the choice is no longer
/// "hide the calm 7-day: yes/no" but "which calm bar gets hidden", with ``never`` as the always-two-bars
/// escape hatch.
///
/// ## What "calm" means here
/// ``BarView/isCalm`` — `.calm` **or** `.farBehind`. The far-behind blue counts as calm and is hidden
/// along with green and yellow (ADR-0061), so this deliberately is *not* the `.ahead`/`.exhausted` test
/// that `MenuBarLayout.selectReset` and `PopupSectionVisibility` use. Only orange and red keep a bar on
/// screen. An **idle** 5-hour bar reports `.calm` unconditionally (``BarView/severity``), so ``fiveHour``
/// hides it between sessions too — a deliberate choice, not an oversight: see the note on the invariant
/// below and ADR-0086.
///
/// ## Invariant: at most one bar is ever elided
/// ``hides(_:isCalm:)`` matches its argument against the *single* window this value names, so the set of
/// windows it can hide has at most one element (`{.fiveHour}`, `{.sevenDay}`, or `∅`). Whatever the two
/// severities are, at least one bar therefore survives and `MenuBarMode.expanded` always carries a
/// non-nil bar — the widget can never render empty. This is a property of the type rather than a check
/// in `MenuBarLayout`, so it cannot drift out of sync with the call site.
///
/// Stored raw-string in `UserDefaults` (like `ResetCountdownMode` / `CalmColorMode` / `BarStyle`) with a
/// forward-compatible decode, so a newer build's value never makes an older build fail.
public enum CalmBarHiding: String, Sendable, Equatable, Codable, CaseIterable {
    /// **Default** (`.chill` / `.workHarder`). Hide the 5-hour bar while it is calm, leaving the 7-day
    /// bar as the single, vertically-centred bar — including in the session-idle state, where the 5-hour
    /// bar is the inert "ready to start" placeholder and counts as calm.
    case fiveHour = "fiveHour"
    /// Hide the 7-day bar while it is calm, leaving the 5-hour bar alone. The pre-#94 behaviour of the
    /// boolean this enum replaces, and what an explicit `hideCalmSevenDayBar = true` migrates to.
    case sevenDay = "sevenDay"
    /// Never hide either bar — both are always drawn, whatever their severity (`.controlFreak`).
    case never = "never"

    /// The window whose bar this value hides while calm, or `nil` for ``never``. The single source of the
    /// "at most one" invariant documented above — everything else derives from it.
    public var hiddenWindow: LimitWindow? {
        switch self {
        case .fiveHour: return .fiveHour
        case .sevenDay: return .sevenDay
        case .never:    return nil
        }
    }

    /// Whether the bar for `window` should be dropped from the widget right now.
    ///
    /// - Parameters:
    ///   - window: Which bar is being decided.
    ///   - isCalm: ``BarView/isCalm`` for that bar — green/yellow on-pace **or** far-behind blue. An idle
    ///     5-hour bar is always calm.
    public func hides(_ window: LimitWindow, isCalm: Bool) -> Bool {
        isCalm && hiddenWindow == window
    }

    /// The segment label shown in Settings → Menu bar. English UI string.
    ///
    /// The labels name the bar that gets **hidden**, which is what makes the row read as one sentence:
    /// "Hide the calm bar — 7-day". "Never" (rather than "Off" or "Both") matches the neighbouring
    /// "Show reset countdown: Always / Smart / Never" row and keeps that reading intact.
    public var displayName: String {
        switch self {
        case .fiveHour: return "5-hour"
        case .sevenDay: return "7-day"
        case .never:    return "Never"
        }
    }

    /// Carry the pre-#94 boolean `hideCalmSevenDayBar` onto this enum: `true` hid the calm 7-day bar, and
    /// `false` kept both. Each maps onto exactly what the user was looking at, so an upgrade never
    /// changes the widget for someone who *did* make a choice.
    ///
    /// Lives here rather than in `PersistedConfig` so it is unit-testable from `TokenPaceKitTests` and
    /// shared by both readers of the legacy value — the `UserDefaults` migration and
    /// `AppearancePresetValues`' decode of an exported config — the same split `BarStyle`'s
    /// `legacySurfaceStyles(for:)` uses. Someone who never touched the old toggle has no stored value at
    /// all, so nothing is migrated and they pick up the current preset default (``fiveHour``).
    public static func migrated(fromLegacyHide hideCalmSevenDay: Bool) -> CalmBarHiding {
        hideCalmSevenDay ? .sevenDay : .never
    }

    /// Forward-compatible decode: an unrecognised raw string falls back to ``sevenDay`` instead of
    /// throwing. Mirrors `ResetCountdownMode` / `CalmColorMode` / `BarStyle` / `PopupSectionVisibility`.
    ///
    /// The fallback is ``sevenDay`` — the *old* semantics — rather than the current default ``fiveHour``,
    /// because decoding serves configs written by **other or older** builds. A dump that predates this
    /// enum described a 7-day-hiding world, so resolving an unknown value to today's factory default
    /// would quietly rewrite what that config meant.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CalmBarHiding(rawValue: raw) ?? .sevenDay
    }
}
