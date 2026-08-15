import Foundation

// MARK: - PopupSectionVisibility

/// How the **dropdown popup** decides whether to show one of its optional row groups — the per-model /
/// per-service limit rows and the Extra-usage credits section. Chosen per group by a segmented control
/// in Settings → Appearance → *Dropdown Widget* and threaded into `PopupViewController`, which owns the
/// live ⌥ Option state.
///
/// Generalises the old boolean `showModelSpecificLimits` opt-out: "off" forced a group to be invisible
/// even when it was the thing you needed to see, while "on" kept calm rows on screen permanently. The
/// hiding modes show a group only while it is actually worth looking at, which is the same "quiet until
/// it matters" idea the menu bar already applies via ``CalmBarHiding``.
///
/// ## Two ways to be "worth looking at"
/// The two middle modes gate on opposite sides of the pacing model, and that is the whole point of
/// having both:
///
/// - ``aboveZero`` reads the **value** — has this group been touched at all? A group sitting at a flat
///   zero is not something the user needs on screen; the first byte spent (or the first cent) is.
/// - ``nonCalm`` reads the model's **verdict** — has the pacing turned orange or red?
///
/// Value-in, colour-out: a percentage says *what happened*, a severity says *what we think of it*. They
/// are not interchangeable, and the gap between them is why ``aboveZero`` exists. A 7-day window early
/// in its cycle paces as `.ahead` (orange) at 2–4 % usage — formally correct, but it drags the whole
/// per-model group on screen at the exact moment the numbers are least interesting. ``aboveZero`` keeps
/// the group folded until something is actually in it.
///
/// Not every group can offer both. The Extra-usage section drops ``nonCalm`` from its Settings control:
/// its severity comes from `credits.bar`, which is `nil` on an **unlimited** money cap, so `nonCalm`
/// would leave a paying user with no cap permanently blind to their own spend. And when a cap *does*
/// exist, "spent > 0" always precedes orange — so for money the mode had no reachable behaviour of its
/// own. The case stays in this enum (old stored values must keep decoding), it is simply not offered.
///
/// ## What "non-calm" means here
/// **Orange or red** — `PacingSeverity.ahead` or `.exhausted`. Deliberately *not* `!BarLayout.isCalm`:
/// that would also catch `.farBehind` (blue), which is *calmer* than green and must never force a group
/// on screen. The same `.ahead`/`.exhausted` test the menu bar's `CalmBarHiding` inverts, keying off
/// for exactly the same reason (see `PacingModel`'s note on `isCalm`).
///
/// ## ⌥ Option is always an escape hatch
/// In ``nonCalm``, holding ⌥ reveals the group even when everything is calm — the popup's established
/// "⌥ reveals more" idiom (`PopupViewController.rebuild`'s `showStatusRows` / `showAge` and the
/// service-component filter all read `optionHeld || <problem>`). ``optionOnly`` is the strict form: the
/// group is hidden regardless of severity and only ⌥ brings it up.
///
/// Stored raw-string in `UserDefaults` (like `CalmColorMode` / `BarStyle`) with a
/// forward-compatible decode, so a newer build's value never makes an older build fail — an unknown raw
/// falls back to ``nonCalm``.
public enum PopupSectionVisibility: String, Sendable, Equatable, Codable, CaseIterable {
    /// Always show the group, whatever its severity and whether or not ⌥ is held.
    case always = "always"
    /// **Default for Extra usage.** Show the group once anything in it is non-zero — any per-model row
    /// past 0 %, or any money spent — or while ⌥ Option is held.
    case aboveZero = "aboveZero"
    /// **Default for model & service limits.** Show the group while any of its rows is orange/red — or
    /// while ⌥ Option is held. Not offered for Extra usage (see the type's note on unlimited caps).
    case nonCalm = "nonCalm"
    /// Never show the group on its own; only while ⌥ Option is held.
    ///
    /// **Retired from both Settings controls** (#374), for a reason visible in ``shows(isNonCalm:isAboveZero:optionHeld:)``
    /// below: ⌥ is OR'd into every other mode, so holding it already reveals the group whatever the mode.
    /// That left this case offering nothing of its own except *hiding the group when the data is
    /// interesting* — the one thing none of the others do, and not a thing anyone chose on purpose.
    ///
    /// The case stays here because old stored values must keep decoding — the same treatment
    /// ``nonCalm`` gets on the Extra-usage row (see the type's note). `PersistedConfig` migrates anyone
    /// holding it to ``aboveZero``, so nothing reaches a control that no longer offers it.
    case optionOnly = "optionOnly"

    /// Whether the group is drawn right now.
    ///
    /// Both data predicates are always passed, even though any one call uses at most one of them: the
    /// caller has both to hand from ``PopupLayout``, and taking them unconditionally keeps this a total
    /// function of the mode. Neither gets a default value — a defaulted parameter would let a new call
    /// site silently pass a permanently-`false` predicate and quietly break a mode.
    ///
    /// - Parameters:
    ///   - isNonCalm: Whether any row in this group is orange/red (`.ahead` / `.exhausted`).
    ///   - isAboveZero: Whether anything in this group is non-zero (usage past 0 %, or money spent).
    ///   - optionHeld: Whether ⌥ Option is currently held (ADR-0020's modifier-poll timer).
    public func shows(isNonCalm: Bool, isAboveZero: Bool, optionHeld: Bool) -> Bool {
        switch self {
        case .always:     return true
        case .aboveZero:  return isAboveZero || optionHeld
        case .nonCalm:    return isNonCalm || optionHeld
        case .optionOnly: return optionHeld
        }
    }

    /// The segment label shown in Settings → Appearance. English UI string.
    ///
    /// These carry the whole explanation — the Dropdown-Widget rows deliberately have **no**
    /// `SettingsHint` beneath them, so the labels must be self-describing. Hence "only" on the non-calm
    /// segment: without it, "Non-calm" reads as *also* showing when non-calm rather than *only* then.
    ///
    /// **"Once used"**, not the shipped "Above zero" (#374). Both name the same rule, but a threshold
    /// phrase describes the *mechanism* — a number crossing zero — while the reader is choosing a
    /// behaviour: show me this limit from the moment I start using it. "Once" carries the onset the
    /// mechanism only implies. Dropping the retired ⌥ segment freed the width that made "Above zero"
    /// have to stay two short words.
    ///
    /// ``optionOnly`` keeps a label although no control offers it any more: `displayName` is a total
    /// function over the enum, and a case that can still arrive from stored data should still be able to
    /// name itself in a log line or an exported config.
    public var displayName: String {
        switch self {
        case .always:     return "Always"
        case .aboveZero:  return "Once used"
        case .nonCalm:    return "Non-calm only"
        case .optionOnly: return "With ⌥ Option"
        }
    }

    /// Forward-compatible decode: an unrecognised raw string falls back to ``nonCalm`` (the default)
    /// instead of throwing. Mirrors `CalmColorMode` / `BarStyle`.
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
