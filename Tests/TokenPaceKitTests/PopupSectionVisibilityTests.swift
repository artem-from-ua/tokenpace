import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - PopupSectionVisibility (#211)

@Suite("PopupSectionVisibility.shows")
struct PopupSectionVisibilityShowsTests {

    /// `.always` ignores every input — all eight cells of the truth table are `true`.
    @Test(arguments: [false, true], [false, true])
    func alwaysShowsRegardless(isNonCalm: Bool, isAboveZero: Bool) {
        for optionHeld in [false, true] {
            #expect(PopupSectionVisibility.always.shows(
                isNonCalm: isNonCalm, isAboveZero: isAboveZero, optionHeld: optionHeld))
        }
    }

    /// `.nonCalm` is the interesting one: severity **or** ⌥ reveals the group, and only the
    /// calm-and-no-modifier cell hides it.
    @Test func nonCalmShowsOnSeverityOrOption() {
        let mode = PopupSectionVisibility.whenItNeedsAttention
        #expect(!mode.shows(isNonCalm: false, isAboveZero: false, optionHeld: false))  // calm → hidden
        #expect(mode.shows(isNonCalm: true, isAboveZero: false, optionHeld: false))    // orange/red
        #expect(mode.shows(isNonCalm: false, isAboveZero: false, optionHeld: true))    // ⌥ escape hatch
        #expect(mode.shows(isNonCalm: true, isAboveZero: true, optionHeld: true))
    }

    /// `.aboveZero` gates on the **value** — anything non-zero in the group — or ⌥.
    @Test func aboveZeroShowsOnValueOrOption() {
        let mode = PopupSectionVisibility.onceUsed
        #expect(!mode.shows(isNonCalm: false, isAboveZero: false, optionHeld: false))  // flat zero
        #expect(mode.shows(isNonCalm: false, isAboveZero: true, optionHeld: false))    // used at all
        #expect(mode.shows(isNonCalm: false, isAboveZero: false, optionHeld: true))    // ⌥ escape hatch
        #expect(mode.shows(isNonCalm: true, isAboveZero: true, optionHeld: true))
    }

    /// The two data predicates are read by **different** modes and never substitute for each other.
    /// Both mixed cells are real states, and each one is the reason the other mode exists:
    ///
    /// - non-calm but zero: an unlimited-cap credits section has no bar, so no severity — while
    ///   per-model rows early in a 7-day window pace `.ahead` at a few percent;
    /// - above zero but calm: the ordinary mid-week row, spending steadily and on pace.
    @Test func theTwoPredicatesAreIndependent() {
        #expect(!PopupSectionVisibility.onceUsed.shows(
            isNonCalm: true, isAboveZero: false, optionHeld: false))   // severity does not feed aboveZero
        #expect(!PopupSectionVisibility.whenItNeedsAttention.shows(
            isNonCalm: false, isAboveZero: true, optionHeld: false))   // value does not feed nonCalm
    }

    /// ⌥ reveals the group under **every** mode — the property that made the retired `⌥ Option`-only
    /// case redundant (#374, removed in #381). Worth pinning: it is the reason no mode can leave a group
    /// unreachable, so the popup always has an escape hatch.
    @Test func optionAlwaysReveals() {
        for mode in PopupSectionVisibility.allCases {
            #expect(mode.shows(isNonCalm: false, isAboveZero: false, optionHeld: true))
        }
    }
}

@Suite("PopupSectionVisibility storage")
struct PopupSectionVisibilityStorageTests {

    /// Raw values are stable storage identifiers. Renamed in #381 along with the cases, which is exactly
    /// why ``legacyRawValues`` exists — a rename without it silently resets everybody's choice.
    @Test func rawValuesAreStable() {
        #expect(PopupSectionVisibility.whenItNeedsAttention.rawValue == "whenItNeedsAttention")
        #expect(PopupSectionVisibility.onceUsed.rawValue == "onceUsed")
        #expect(PopupSectionVisibility.always.rawValue == "always")
    }

    /// Declaration order — **quietest to loudest** since #381, matching the on-screen order of every
    /// segmented control in Appearance. Neither control renders `allCases` (the Extra-usage row omits
    /// `.whenItNeedsAttention`), so both are spelled out in `DropdownPane`; this pins the enum's own
    /// order so the two never disagree about direction.
    @Test func casesAreInPaneOrder() {
        #expect(PopupSectionVisibility.allCases == [.whenItNeedsAttention, .onceUsed, .always])
    }

    /// The labels carry the whole explanation (these rows have no `SettingsHint`), so each has to stand
    /// alone.
    ///
    /// `.onceUsed` reads "Once used" rather than the pre-#374 "Above zero": the row is a choice about
    /// behaviour, and "once" names the onset that a threshold phrase only implies.
    ///
    /// `.whenItNeedsAttention` replaced "Non-calm only" in #381 — a double negative built on a term of
    /// art. The new wording is what this file's own `PacingSeverity.isNonCalm` calls the threshold
    /// ("worth attention"), and it matches the menu bar's segment for the same threshold.
    @Test func displayNames() {
        #expect(PopupSectionVisibility.whenItNeedsAttention.displayName == "When it needs attention")
        #expect(PopupSectionVisibility.onceUsed.displayName == "Once used")
        #expect(PopupSectionVisibility.always.displayName == "Always")
    }

    /// The pre-#381 raws decode onto the renamed cases **explicitly**, through `legacyRawValues` rather
    /// than through the unknown-value fallback — the difference between carrying a stored choice over and
    /// quietly resetting it.
    ///
    /// `optionOnly` is in that table although its case is gone: it lands on `.onceUsed`, the closest
    /// surviving intent ("stay folded until there is something in here"). That mapping is what let #381
    /// delete the dedicated marker-keyed migration #374 had needed.
    @Test func decodesLegacyRawValues() throws {
        let expected: [(String, PopupSectionVisibility)] = [
            ("aboveZero", .onceUsed),
            ("nonCalm", .whenItNeedsAttention),
            ("optionOnly", .onceUsed),
        ]
        for (raw, mode) in expected {
            let data = Data("\"\(raw)\"".utf8)
            #expect(try JSONDecoder().decode(PopupSectionVisibility.self, from: data) == mode)
        }
    }

    /// The legacy table covers exactly the retired raws — a current raw listed there would shadow its own
    /// case, and a missing one would fall through to the default.
    @Test func legacyTableCoversOnlyTheRetiredRaws() {
        #expect(Set(PopupSectionVisibility.legacyRawValues.keys)
            == ["aboveZero", "nonCalm", "optionOnly"])
        for key in PopupSectionVisibility.legacyRawValues.keys {
            #expect(PopupSectionVisibility(rawValue: key) == nil)
        }
    }

    /// Forward-compatible decode: a value written by a newer build must not make this one throw — it
    /// falls back to the default instead. Mirrors `ColorAdvice` / `BarStyle`.
    @Test func unknownRawDecodesToDefault() throws {
        let decoded = try JSONDecoder().decode(
            PopupSectionVisibility.self, from: Data("\"whenTheMoonIsFull\"".utf8))
        #expect(decoded == .whenItNeedsAttention)
    }

    @Test func roundTripsThroughJSON() throws {
        for mode in PopupSectionVisibility.allCases {
            let data = try JSONEncoder().encode(mode)
            #expect(try JSONDecoder().decode(PopupSectionVisibility.self, from: data) == mode)
        }
    }
}

// MARK: - PacingSeverity.isNonCalm

@Suite("PacingSeverity.isNonCalm")
struct PacingSeverityNonCalmTests {

    /// Orange and red are "worth attention"; green **and blue** are not. The blue case is the whole
    /// point of having a separate predicate from `!BarLayout.isCalm` — `.farBehind` is *calmer* than
    /// green (a surplus), so it must never force a folded group open.
    @Test func onlyAheadAndExhaustedAreNonCalm() {
        #expect(PacingSeverity.ahead.isNonCalm)
        #expect(PacingSeverity.exhausted.isNonCalm)
        #expect(!PacingSeverity.calm.isNonCalm)
        #expect(!PacingSeverity.farBehind.isNonCalm)
    }
}
