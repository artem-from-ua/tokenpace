import Foundation

// MARK: - PopupSectionVisibility

/// How the **dropdown popup** decides whether to show one of its optional row groups — the per-model /
/// per-service limit rows and the Extra-usage credits section. Chosen per group by a segmented control
/// in Settings → Appearance → *Dropdown Widget* and threaded into `PopupViewController`, which owns the
/// live ⌥ Option state.
///
/// Generalises the old boolean `showModelSpecificLimits` opt-out: "off" forced a group to be invisible
/// even when it was the thing you needed to see, while "on" kept calm rows on screen permanently. The
/// middle mode — ``nonCalm`` — shows a group only while it is actually worth attention, which is the
/// same "quiet until it matters" idea the menu bar already applies via `hideCalmSevenDayBar`.
///
/// ## What "non-calm" means here
/// **Orange or red** — `PacingSeverity.ahead` or `.exhausted`. Deliberately *not* `!BarLayout.isCalm`:
/// that would also catch `.farBehind` (blue), which is *calmer* than green and must never force a group
/// on screen. This mirrors `MenuBarLayout.selectReset`, whose "noisy" test keys off `.ahead`/`.exhausted`
/// for exactly the same reason (see `PacingModel`'s note on `isCalm`).
///
/// ## ⌥ Option is always an escape hatch
/// In ``nonCalm``, holding ⌥ reveals the group even when everything is calm — the popup's established
/// "⌥ reveals more" idiom (`PopupViewController.rebuild`'s `showStatusRows` / `showAge` and the
/// service-component filter all read `optionHeld || <problem>`). ``optionOnly`` is the strict form: the
/// group is hidden regardless of severity and only ⌥ brings it up.
///
/// Stored raw-string in `UserDefaults` (like `ResetCountdownMode` / `CalmColorMode` / `BarStyle`) with a
/// forward-compatible decode, so a newer build's value never makes an older build fail — an unknown raw
/// falls back to ``nonCalm``.
public enum PopupSectionVisibility: String, Sendable, Equatable, Codable, CaseIterable {
    /// Always show the group, whatever its severity and whether or not ⌥ is held.
    case always = "always"
    /// **Default.** Show the group while any of its rows is orange/red — or while ⌥ Option is held.
    case nonCalm = "nonCalm"
    /// Never show the group on its own; only while ⌥ Option is held.
    case optionOnly = "optionOnly"

    /// Whether the group is drawn right now.
    ///
    /// - Parameters:
    ///   - isNonCalm: Whether any row in this group is orange/red (`.ahead` / `.exhausted`).
    ///   - optionHeld: Whether ⌥ Option is currently held (ADR-0020's modifier-poll timer).
    public func shows(isNonCalm: Bool, optionHeld: Bool) -> Bool {
        switch self {
        case .always:     return true
        case .nonCalm:    return isNonCalm || optionHeld
        case .optionOnly: return optionHeld
        }
    }

    /// The segment label shown in Settings → Appearance. English UI string.
    ///
    /// These carry the whole explanation — the two Dropdown-Widget rows deliberately have **no**
    /// `SettingsHint` beneath them, so the labels must be self-describing. Hence "only" on the middle
    /// segment: without it, "Non-calm" reads as *also* showing when non-calm rather than *only* then.
    /// "With ⌥ Option" keeps the preposition (the segment is a *condition*, not a key reference) while
    /// the glyph names the key the way every macOS menu does.
    public var displayName: String {
        switch self {
        case .always:     return "Always"
        case .nonCalm:    return "Non-calm only"
        case .optionOnly: return "With ⌥ Option"
        }
    }

    /// Forward-compatible decode: an unrecognised raw string falls back to ``nonCalm`` (the default)
    /// instead of throwing. Mirrors `ResetCountdownMode` / `CalmColorMode` / `BarStyle`.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PopupSectionVisibility(rawValue: raw) ?? .nonCalm
    }
}

// MARK: - PacingSeverity + non-calm

extension PacingSeverity {
    /// Whether this severity is "worth attention" — **orange or red**. The single definition behind
    /// every ``PopupSectionVisibility/nonCalm`` gate, so the popup's groups and any future caller agree
    /// on what counts as noisy. `.farBehind` (blue) is calmer than green and is deliberately excluded.
    public var isNonCalm: Bool { self == .ahead || self == .exhausted }
}
