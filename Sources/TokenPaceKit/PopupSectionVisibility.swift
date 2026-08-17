import Foundation

// MARK: - PopupSectionVisibility

/// How the **dropdown popup** decides whether to show one of its optional row groups — the per-model /
/// per-service limit rows and the Extra-usage credits section. Chosen per group by a segmented control
/// in Settings → Appearance › Dropdown and threaded into `PopupViewController`, which owns the live ⌥
/// Option state.
///
/// Generalises the old boolean `showModelSpecificLimits` opt-out: "off" forced a group to be invisible
/// even when it was the thing you needed to see, while "on" kept quiet rows on screen permanently. The
/// hiding modes show a group only while it is actually worth looking at, which is the same "quiet until
/// it matters" idea the menu bar already applies via ``TopBarHiding``.
///
/// ## Two ways to be "worth looking at"
/// The two hiding modes gate on opposite sides of the pacing model, and that is the whole point of
/// having both:
///
/// - ``onceUsed`` reads the **value** — has this group been touched at all? A group sitting at a flat
///   zero is not something the user needs on screen; the first byte spent (or the first cent) is.
/// - ``whenItNeedsAttention`` reads the model's **verdict** — has the pacing turned orange or red?
///
/// Value-in, colour-out: a percentage says *what happened*, a severity says *what we think of it*. They
/// are not interchangeable, and the gap between them is why ``onceUsed`` exists. A 7-day window early
/// in its cycle paces as `.ahead` (orange) at 2–4 % usage — formally correct, but it drags the whole
/// per-model group on screen at the exact moment the numbers are least interesting. ``onceUsed`` keeps
/// the group folded until something is actually in it.
///
/// Not every group can offer both. The Extra-usage section drops ``whenItNeedsAttention`` from its
/// Settings control: its severity comes from `credits.bar`, which is `nil` on an **unlimited** money
/// cap, so that mode would leave a paying user with no cap permanently blind to their own spend. And
/// when a cap *does* exist, "spent > 0" always precedes orange — so for money the mode had no reachable
/// behaviour of its own. The case stays in this enum (the per-model row offers it), it is simply not
/// offered there.
///
/// ## What "needs attention" means here
/// **Orange or red** — `PacingSeverity.ahead` or `.exhausted`, i.e. ``PacingSeverity/isNonCalm``.
/// Deliberately *not* `!BarLayout.isCalm`: that would also catch `.farBehind` (blue), which is *calmer*
/// than green and must never force a group on screen.
///
/// The label is shared with the menu bar's `Until it needs attention` (``TopBarHiding``) on purpose
/// (#381): both sit on this same threshold, from opposite sides — one decides when to reveal a section,
/// the other when to stop hiding a bar. One threshold, one wording, two pages.
///
/// ## ⌥ Option is always an escape hatch
/// Holding ⌥ reveals the group even when everything is quiet — the popup's established "⌥ reveals more"
/// idiom (`PopupViewController.rebuild`'s `showStatusRows` / `showAge` and the service-component filter
/// all read `optionHeld || <problem>`). Since #374 there is no strict "⌥ only" mode: it offered nothing
/// of its own except *hiding the group when the data had turned interesting*, and #381 removed the case
/// outright — the legacy raw now resolves through ``legacyRawValues`` like any other renamed value.
///
/// Stored raw-string in `UserDefaults` under `dropdown.showPerModelLimits` /
/// `dropdown.showExtraUsage` (like ``ColorAdvice`` / `BarStyle`) with a forward-compatible decode, so a
/// newer build's value never makes an older build fail.
public enum PopupSectionVisibility: String, Sendable, Equatable, Codable, CaseIterable {
    /// **Default for model & service limits.** Show the group while any of its rows is orange/red — or
    /// while ⌥ Option is held. Not offered for Extra usage (see the type's note on unlimited caps).
    ///
    /// Declared first because the on-screen order is quiet-first (#381): the leftmost segment is the one
    /// that puts **less** on screen.
    case whenItNeedsAttention = "whenItNeedsAttention"
    /// **Default for Extra usage.** Show the group once anything in it is non-zero — any per-model row
    /// past 0 %, or any money spent — or while ⌥ Option is held.
    case onceUsed = "onceUsed"
    /// Always show the group, whatever its severity and whether or not ⌥ is held.
    case always = "always"

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
        case .always:               return true
        case .onceUsed:             return isAboveZero || optionHeld
        case .whenItNeedsAttention: return isNonCalm || optionHeld
        }
    }

    /// The segment label shown in Settings → Appearance › Dropdown. English UI string.
    ///
    /// These carry the whole explanation — the Dropdown rows deliberately have **no** `SettingsHint`
    /// beneath them, so the labels must be self-describing.
    ///
    /// **"Once used"**, not the pre-#374 "Above zero": both name the same rule, but a threshold phrase
    /// describes the *mechanism* — a number crossing zero — while the reader is choosing a behaviour:
    /// show me this limit from the moment I start using it.
    ///
    /// **"When it needs attention"**, not the pre-#381 "Non-calm only": "non-calm" is a double negative
    /// built on a term of art. The new wording names the threshold the way this file's own
    /// ``PacingSeverity/isNonCalm`` does — "worth attention" — and matches the menu bar's segment for the
    /// same threshold.
    public var displayName: String {
        switch self {
        case .whenItNeedsAttention: return "When it needs attention"
        case .onceUsed:             return "Once used"
        case .always:               return "Always"
        }
    }

    /// The modes the **Extra usage** row can actually show — `.whenItNeedsAttention` is not among them
    /// (see the type's note on unlimited caps), so anything that reaches that row has to be folded onto
    /// ``onceUsed`` first.
    ///
    /// Lives here rather than in the pane because three separate paths feed that row — the key migration,
    /// the `UserDefaults` getter, and an imported config — and a value the control does not offer opens it
    /// with **no segment highlighted**. Keeping the rule beside the enum is what lets all three agree; the
    /// pane's own segment list is built from `creditsOffered` for the same reason.
    public static let creditsOffered: [PopupSectionVisibility] = [.onceUsed, .always]

    /// `self` if the Extra-usage row can show it, else ``onceUsed`` — the surviving intent of the one mode
    /// it cannot ("stay folded until there is something in here").
    public var foldedForCredits: PopupSectionVisibility {
        PopupSectionVisibility.creditsOffered.contains(self) ? self : .onceUsed
    }

    /// The pre-#381 raw values, mapped onto the current cases. Consulted by ``init(from:)`` **before**
    /// the default fallback, so a rename never silently downgrades a stored choice.
    ///
    /// `optionOnly` is here because the case itself is gone (#381, finishing what #374 started): it is
    /// mapped to ``onceUsed``, the closest surviving intent — "stay folded until there is something in
    /// here" — and, unlike ``whenItNeedsAttention``, a mode both rows offer. This replaces the dedicated
    /// `migrateOptionOnlyVisibilityIfNeeded()` migration: one legacy table instead of a table plus a
    /// marker-keyed rewrite.
    public static let legacyRawValues: [String: PopupSectionVisibility] = [
        "aboveZero": .onceUsed,
        "nonCalm": .whenItNeedsAttention,
        "optionOnly": .onceUsed,
    ]

    /// Forward-compatible decode: a pre-#381 raw resolves through ``legacyRawValues``, and anything else
    /// unrecognised falls back to ``whenItNeedsAttention`` (the per-model default) instead of throwing.
    /// Mirrors ``ColorAdvice`` / `BarStyle`.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PopupSectionVisibility(rawValue: raw)
            ?? PopupSectionVisibility.legacyRawValues[raw]
            ?? .whenItNeedsAttention
    }
}

// MARK: - PacingSeverity + needs attention

extension PacingSeverity {
    /// Whether this severity is "worth attention" — **orange or red**. The single definition behind
    /// every ``PopupSectionVisibility/whenItNeedsAttention`` gate, so the popup's groups and any future
    /// caller agree on what counts as noisy. `.farBehind` (blue) is calmer than green and is
    /// deliberately excluded.
    ///
    /// Keeps the `isNonCalm` name although the UI dropped the word: "calm" remains the model's own term
    /// for the state (``PacingSeverity/calm``), and this property is a statement about the model, not a
    /// control label.
    public var isNonCalm: Bool { self == .ahead || self == .exhausted }
}
