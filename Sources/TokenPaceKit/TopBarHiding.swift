import Foundation

// MARK: - TopBarHiding (ADR-0086, narrowed by ADR-0090, renamed in #381)

/// Whether the **top (5-hour)** pacing bar steps aside while it has nothing to say — chosen by the
/// segmented control in Settings → Appearance › Menu bar → **"Hide the top 5h bar"** and threaded into
/// ``MenuBarLayout/make(from:now:hideTopBar:)``.
///
/// Renamed from `CalmBarHiding` in #381 along with the row and its segments: the word "calm" is a
/// project term for a data state (``PacingSeverity/calm``), and a control label is not the place to
/// require it. The type now reads off the row it draws.
///
/// Replaced the boolean `hideCalmSevenDayBar` opt-out of ADR-0034 / #94, which could only ever hide the
/// **7-day** bar; ADR-0086 briefly made the choice three-way, and ADR-0090 settled it on the one window
/// worth naming: the 5-hour bar steps aside while quiet, leaving the weekly context on screen, or
/// nothing is hidden at all.
///
/// ## What "needs attention" means here
/// ``BarView/isCalm`` — `.calm` **or** `.farBehind`. The far-behind blue counts as quiet and is hidden
/// along with green and yellow (ADR-0061), so this deliberately is *not* the `.ahead`/`.exhausted` test
/// that `PopupSectionVisibility` uses — though the two now share a **label** (`When it needs attention`
/// there, `Until it needs attention` here), because they sit on the same threshold from opposite sides:
/// one decides when to reveal a section, the other when to stop hiding a bar. An **idle** 5-hour bar
/// reports `.calm` unconditionally (``BarView/severity``), so ``untilItNeedsAttention`` hides it between
/// sessions too — deliberate, not an oversight: see the invariant below and ADR-0086.
///
/// ## Invariant: at most one bar is ever elided
/// ``hides(_:isCalm:)`` matches its argument against the *single* window this value names, so the set of
/// windows it can hide has at most one element (`{.fiveHour}` or `∅`). Whatever the two severities are,
/// at least one bar therefore survives and `MenuBarMode.expanded` always carries a non-nil bar — the
/// widget can never render empty. This is a property of the type rather than a check in `MenuBarLayout`,
/// so it cannot drift out of sync with the call site.
///
/// Stored raw-string in `UserDefaults` under `menuBar.hideTop5hBar` (like ``ColorAdvice`` / `BarStyle`)
/// with a forward-compatible decode, so a newer build's value never makes an older build fail.
public enum TopBarHiding: String, Sendable, Equatable, Codable, CaseIterable {
    /// **Default** (`.chill` / `.workHarder`). Hide the 5-hour bar until it needs attention, leaving the
    /// 7-day bar as the single, vertically-centred bar — including in the session-idle state, where the
    /// 5-hour bar is the inert "ready to start" placeholder and counts as quiet.
    ///
    /// Declared first because the row reads as a scale of how much the widget keeps: hide the top bar
    /// while it is quiet (less ink), or keep everything (more).
    case untilItNeedsAttention = "untilItNeedsAttention"
    /// Never hide either bar — both are always drawn, whatever their severity (`.controlFreak`).
    case never = "never"

    /// The window whose bar this value hides while quiet, or `nil` for ``never``. The single source of
    /// the "at most one" invariant documented above — everything else derives from it.
    public var hiddenWindow: LimitWindow? {
        switch self {
        case .untilItNeedsAttention: return .fiveHour
        case .never:                 return nil
        }
    }

    /// Whether the bar for `window` should be dropped from the widget right now.
    ///
    /// - Parameters:
    ///   - window: Which bar is being decided.
    ///   - isCalm: ``BarView/isCalm`` for that bar — green on-pace/behind, mild-ahead yellow, or
    ///     far-behind blue. An idle 5-hour bar is always calm.
    public func hides(_ window: LimitWindow, isCalm: Bool) -> Bool {
        isCalm && hiddenWindow == window
    }

    /// The segment label shown in Settings → Appearance › Menu bar. English UI string.
    ///
    /// The row names the bar ("Hide the top 5h bar"), so the segments only have to say *when*. #381
    /// replaced `When it's calm` with **`Until it needs attention`**: "calm" is a term of art in this
    /// codebase, and the segment has to stand on its own — the row carries no `SettingsHint` about the
    /// hiding rule any more. "Until" also states the reversibility that "when" leaves implicit: the bar
    /// comes back on its own.
    ///
    /// Ordered quiet-first, matching every other segmented control on the page (#381): the leftmost
    /// option is the one that puts **less** on screen.
    public var displayName: String {
        switch self {
        case .untilItNeedsAttention: return "Until it needs attention"
        case .never:                 return "Never"
        }
    }

    /// Carry the pre-#94 boolean `hideCalmSevenDayBar` onto this enum: `true` hid the calm 7-day bar,
    /// `false` kept both.
    ///
    /// `true` maps to ``untilItNeedsAttention`` rather than to a 7-day mode, which no longer exists
    /// (ADR-0090). That user asked for **fewer** bars in the quiet state, and this case still grants
    /// that — one bar while quiet, both back on orange. ``never`` would grant the opposite of the
    /// request (two bars, always), which is why the mapping does not simply drop to "nothing is hidden".
    ///
    /// Lives here rather than in `PersistedConfig` so it is unit-testable from `TokenPaceKitTests` and
    /// shared by both readers of the legacy value — the `UserDefaults` migration and
    /// `AppearancePresetValues`' decode of an exported config — the same split `BarStyle`'s
    /// `legacySurfaceStyles(for:)` uses. Someone who never touched the old toggle has no stored value at
    /// all, so nothing is migrated and they pick up the current preset default.
    public static func migrated(fromLegacyHide hideCalmSevenDay: Bool) -> TopBarHiding {
        hideCalmSevenDay ? .untilItNeedsAttention : .never
    }

    /// The pre-#381 raw values, mapped onto the current cases. Consulted by ``init(from:)`` **before**
    /// the default fallback, so a stored choice is never silently downgraded by a rename.
    ///
    /// `sevenDay` is here too: it names a mode retired by ADR-0090, and it decodes to
    /// ``untilItNeedsAttention`` for the reason recorded there — a config written when that mode existed
    /// described a *one bar while quiet* world, which this case still is. The surviving bar differs, but
    /// the amount of ink does not, and ``never`` would misread the dump as "show everything".
    public static let legacyRawValues: [String: TopBarHiding] = [
        "fiveHour": .untilItNeedsAttention,
        "sevenDay": .untilItNeedsAttention,
    ]

    /// Forward-compatible decode: a pre-#381 raw resolves through ``legacyRawValues``, and anything
    /// else unrecognised falls back to ``untilItNeedsAttention``. Mirrors ``ColorAdvice`` / `BarStyle` /
    /// `PopupSectionVisibility`.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TopBarHiding(rawValue: raw) ?? TopBarHiding.legacyRawValues[raw] ?? .untilItNeedsAttention
    }
}
