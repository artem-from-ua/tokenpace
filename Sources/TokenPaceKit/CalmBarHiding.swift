import Foundation

// MARK: - CalmBarHiding

/// Which of the two menu-bar pacing bars is dropped from the widget **while it is calm** — chosen by a
/// segmented control in Settings → Menu bar ("Hide the calm bar") and threaded into
/// ``MenuBarLayout/make(from:now:resetMode:hideCalmBar:)``.
///
/// Replaced the boolean `hideCalmSevenDayBar` opt-out of ADR-0034 / #94, which could only ever hide the
/// **7-day** bar; ADR-0086 briefly made the choice three-way, and ADR-0090 settled it on the one window
/// worth naming: the 5-hour bar steps aside while calm, leaving the weekly context on screen, or nothing
/// is hidden at all. Hiding the *7-day* bar instead was dropped along with the third segment — the row
/// then reads as one sentence ("Hide 5h (top) bar — When it's calm") instead of naming a window twice.
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
/// windows it can hide has at most one element (`{.fiveHour}` or `∅`). Whatever the two severities are,
/// at least one bar therefore survives and `MenuBarMode.expanded` always carries a non-nil bar — the
/// widget can never render empty. This is a property of the type rather than a check in `MenuBarLayout`,
/// so it cannot drift out of sync with the call site.
///
/// Stored raw-string in `UserDefaults` (like `ResetCountdownMode` / `CalmColorMode` / `BarStyle`) with a
/// forward-compatible decode, so a newer build's value never makes an older build fail.
public enum CalmBarHiding: String, Sendable, Equatable, Codable, CaseIterable {
    /// **Default** (`.chill` / `.workHarder`). Hide the 5-hour bar while it is calm, leaving the 7-day
    /// bar as the single, vertically-centred bar — including in the session-idle state, where the 5-hour
    /// bar is the inert "ready to start" placeholder and counts as calm.
    ///
    /// Declared first because the order here *is* the on-screen segment order (`UIPanes` builds the
    /// control from `allCases`), and the row reads as a scale of how much the widget keeps: hide the
    /// top bar while it is quiet, or keep everything.
    case fiveHour = "fiveHour"
    /// Never hide either bar — both are always drawn, whatever their severity (`.controlFreak`).
    case never = "never"

    /// The window whose bar this value hides while calm, or `nil` for ``never``. The single source of the
    /// "at most one" invariant documented above — everything else derives from it.
    public var hiddenWindow: LimitWindow? {
        switch self {
        case .fiveHour: return .fiveHour
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
    /// The row names the bar ("Hide 5h (top) bar"), so the segments only have to say *when* — which is
    /// why they read as a condition rather than a window (ADR-0090). "Never" matches the neighbouring
    /// "Show reset countdown: Always / Smart / Never" row and keeps that reading intact.
    public var displayName: String {
        switch self {
        case .fiveHour: return "When it's calm"
        case .never:    return "Never"
        }
    }

    /// Carry the pre-#94 boolean `hideCalmSevenDayBar` onto this enum: `true` hid the calm 7-day bar,
    /// `false` kept both.
    ///
    /// `true` maps to ``fiveHour`` rather than to a 7-day mode, which no longer exists (ADR-0090). That
    /// user asked for **fewer** bars in the calm state, and ``fiveHour`` still grants that — one bar
    /// while calm, both back on orange/red. ``never`` would grant the opposite of the request (two bars,
    /// always), which is why the mapping does not simply drop to the "nothing is hidden" case.
    ///
    /// Lives here rather than in `PersistedConfig` so it is unit-testable from `TokenPaceKitTests` and
    /// shared by both readers of the legacy value — the `UserDefaults` migration and
    /// `AppearancePresetValues`' decode of an exported config — the same split `BarStyle`'s
    /// `legacySurfaceStyles(for:)` uses. Someone who never touched the old toggle has no stored value at
    /// all, so nothing is migrated and they pick up the current preset default (``fiveHour``).
    public static func migrated(fromLegacyHide hideCalmSevenDay: Bool) -> CalmBarHiding {
        hideCalmSevenDay ? .fiveHour : .never
    }

    /// Forward-compatible decode: an unrecognised raw string falls back to ``fiveHour`` instead of
    /// throwing. Mirrors `ResetCountdownMode` / `CalmColorMode` / `BarStyle` / `PopupSectionVisibility`.
    ///
    /// The fallback resolves the retired `"sevenDay"` raw as well, and lands on the same value its
    /// migration does: a config written when that mode existed described a *one bar while calm* world,
    /// which ``fiveHour`` still is — the surviving bar differs, but the amount of ink does not, and
    /// ``never`` would misread the dump as "show everything".
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CalmBarHiding(rawValue: raw) ?? .fiveHour
    }
}
