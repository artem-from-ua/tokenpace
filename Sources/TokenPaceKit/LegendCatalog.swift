import Foundation

// MARK: - LegendCatalog (#261)

/// The specimen states the **Legend** pane illustrates, and nothing else — no colours, no glyphs, no
/// layout. Those live in the app target, which has no test target; this does, which is the whole
/// reason the split exists (the same argument `NavigationRoute` records at its own head).
///
/// Every state is built through ``PacingModel/barLayout(utilization:resetsAt:now:window:blueAllowed:)``
/// rather than written out as a `BarLayout` literal. The two preview renderers already state why —
/// "hand-writing their results is how a specimen drifts away from what the app would actually draw"
/// — and it matters more here than there: this pane's entire claim is that it shows the real thing,
/// so a literal that quietly disagreed with the model would make the page lie about itself.
///
/// **The states are fixed, not read from the user's data or settings** (ADR: static specimens). A
/// legend that changed with the account would answer "what is happening right now", which the widget
/// and the dropdown already answer; this page answers "what do these marks mean", and that answer
/// must not move. The cost is that the pane can show a colour the reader's own menu bar never draws
/// — accepted, because the alternative is a reference that is silent about half its own vocabulary.
public enum LegendCatalog {

    // MARK: Time base

    /// The instant every specimen is computed against.
    ///
    /// A constant rather than `Date()`, so the pane renders identically on every launch and in every
    /// test. `PacingModel.barLayout` takes `now` explicitly for exactly this reason.
    public static let now = Date(timeIntervalSinceReferenceDate: 0)

    /// `resetsAt` for a five-hour window that is `fraction` elapsed.
    ///
    /// The specimens are written in terms of *elapsed fraction* because that is what the reader sees
    /// — the marker's position on the track — while the model takes a reset instant. Deriving one
    /// from the other here keeps the tables below readable as "u = 62 %, t = 45 %", which is how the
    /// design mock states them and how a reviewer checks them.
    static func fiveHourReset(elapsed fraction: Double) -> Date {
        now.addingTimeInterval((1 - fraction) * Double(LimitWindow.fiveHour.durationSeconds))
    }

    // MARK: Pacing tiers

    /// One row of the "what a bar's colour says" section.
    public struct Tier: Sendable, Equatable {
        /// The status word the dropdown prints for this state — taken from the popup's own vocabulary
        /// rather than invented here, so a reader who saw it there recognises it.
        public let word: String
        /// The specimen the colour is computed from.
        public let layout: BarLayout
    }

    /// The five pacing colours, in the order the pane lists them: calmest first.
    ///
    /// **Five states, not five enum cases.** `PacingSeverity` has four — `.calm` covers both the green
    /// "on pace" and the yellow "mild lead", and the split into two colours happens in the render
    /// layer (`PopupBarView.aheadColor`/`behindColor`). So the tiers are enumerated as *data* the
    /// model grades, which is also what keeps this honest: each row's colour is computed, and a
    /// threshold change moves the swatch without anyone editing this file.
    ///
    /// Every state is checked against the thresholds it is meant to land in:
    ///
    /// | word | u | t | lands where |
    /// |---|---|---|---|
    /// | far behind pace | 10 % | 60 % | surplus 0.50 > the 5h behind-threshold (0.20) |
    /// | on pace | 35 % | 50 % | surplus 0.15, under that threshold |
    /// | ahead of pace | 55 % | 50 % | lead 0.05 < `0.16·(1−t)` = 0.08 |
    /// | well ahead of pace | 72 % | 45 % | lead 0.27 ≥ `0.16·(1−t)` = 0.088 |
    /// | limit reached | 100 % | 80 % | exhausted; checked before every other branch |
    ///
    /// The first four sit clear of their boundaries on purpose. A specimen *on* a threshold renders
    /// whichever side floating-point noise picks — the fragility `BarStylePreviewRenderer` documents
    /// having hit, where a 5-hour surplus landed exactly on 0.40.
    public static let tiers: [Tier] = [
        Tier(word: "far behind pace",
             layout: PacingModel.barLayout(utilization: 10, resetsAt: fiveHourReset(elapsed: 0.60),
                                           now: now, window: .fiveHour)),
        Tier(word: "on pace",
             layout: PacingModel.barLayout(utilization: 35, resetsAt: fiveHourReset(elapsed: 0.50),
                                           now: now, window: .fiveHour)),
        Tier(word: "ahead of pace",
             layout: PacingModel.barLayout(utilization: 55, resetsAt: fiveHourReset(elapsed: 0.50),
                                           now: now, window: .fiveHour)),
        Tier(word: "well ahead of pace",
             layout: PacingModel.barLayout(utilization: 72, resetsAt: fiveHourReset(elapsed: 0.45),
                                           now: now, window: .fiveHour)),
        Tier(word: "limit reached",
             layout: PacingModel.barLayout(utilization: 100, resetsAt: fiveHourReset(elapsed: 0.80),
                                           now: now, window: .fiveHour)),
    ]

    // MARK: Anatomy specimens

    /// The state both marker-less styles are drawn from — `u = 62 %, t = 45 %`, an orange lead.
    ///
    /// **One state for both**, deliberately. Balance and Pressure measure the same quantity from
    /// different zeros (`pressureLength ≡ max(0, balanceOffset)`, ADR-0101), and two pictures of one
    /// number is the only way to show that; two different numbers would invite the reader to blame
    /// the difference on the data.
    ///
    /// Its signed lead is `(0.62 − 0.45) / 0.55 ≈ 0.309`, so Balance draws just under a third of its
    /// right half and Pressure the same length from the left edge — both comfortably wider than the
    /// minimum pill, which a calmer state would have collapsed into.
    public static let markerlessSpecimen = PacingModel.barLayout(
        utilization: 62, resetsAt: fiveHourReset(elapsed: 0.45), now: now, window: .fiveHour)

    /// Exactly on pace — `u = t = 50 %`.
    ///
    /// The tie is the point: `balanceOffset` and `pressureLength` are both **zero** here, which both
    /// renderers floor to a minimum pill. That is what the "dot at the zero" rule demonstrates, and it
    /// only reads as a dot if the state really is degenerate rather than merely small.
    public static let onPaceSpecimen = PacingModel.barLayout(
        utilization: 50, resetsAt: fiveHourReset(elapsed: 0.50), now: now, window: .fiveHour)

    /// Spent — `u = 100 %, t = 80 %`.
    ///
    /// `usageFraction >= 1` is checked before every other branch, in the colour grading and in
    /// `pressureLength` alike, so this is red and full at any elapsed fraction. The 80 % is only so the
    /// Progress specimen has a marker position distinct from the capsule's far edge.
    public static let exhaustedSpecimen = PacingModel.barLayout(
        utilization: 100, resetsAt: fiveHourReset(elapsed: 0.80), now: now, window: .fiveHour)

    /// The state Progress is drawn from — `u = 35 %, t = 50 %`, behind pace and green.
    ///
    /// Behind rather than ahead, so the marker sits to the **right** of the capsule. That is the
    /// arrangement the section's first reading rule names, and a specimen that showed the other one
    /// would make the rule's example contradict the picture above it.
    public static let progressSpecimen = PacingModel.barLayout(
        utilization: 35, resetsAt: fiveHourReset(elapsed: 0.50), now: now, window: .fiveHour)

    // MARK: Menu-bar specimens

    /// The five-hour bar in the menu-bar section: calm, and therefore the one that can be hidden.
    ///
    /// The pair is chosen so the two renders read as **one story rather than two pictures**: the
    /// seven-day bar is identical in both, and the only thing that changes is whether the calm
    /// five-hour bar is there. That is exactly what `TopBarHiding.untilItNeedsAttention` does, so the
    /// second render is the first one's next frame rather than an unrelated example.
    public static let menuBarFiveHour = PacingModel.barLayout(
        utilization: 30, resetsAt: fiveHourReset(elapsed: 0.50), now: now, window: .fiveHour)

    /// The seven-day bar in the menu-bar section: ahead of pace, and therefore never hidden.
    ///
    /// Computed on the **five-hour** window on purpose, despite standing in for the weekly one. The
    /// section is about how many bars appear, not about window lengths, and the 7-day window's own
    /// thresholds would need a different utilisation to land on the same orange — a difference that
    /// would show up as a different ribbon length for no reason the section explains.
    public static let menuBarSevenDay = PacingModel.barLayout(
        utilization: 72, resetsAt: fiveHourReset(elapsed: 0.45), now: now, window: .fiveHour)
}
