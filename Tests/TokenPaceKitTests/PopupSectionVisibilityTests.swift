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
        let mode = PopupSectionVisibility.nonCalm
        #expect(!mode.shows(isNonCalm: false, isAboveZero: false, optionHeld: false))  // calm → hidden
        #expect(mode.shows(isNonCalm: true, isAboveZero: false, optionHeld: false))    // orange/red
        #expect(mode.shows(isNonCalm: false, isAboveZero: false, optionHeld: true))    // ⌥ escape hatch
        #expect(mode.shows(isNonCalm: true, isAboveZero: true, optionHeld: true))
    }

    /// `.aboveZero` gates on the **value** — anything non-zero in the group — or ⌥.
    @Test func aboveZeroShowsOnValueOrOption() {
        let mode = PopupSectionVisibility.aboveZero
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
        #expect(!PopupSectionVisibility.aboveZero.shows(
            isNonCalm: true, isAboveZero: false, optionHeld: false))   // severity does not feed aboveZero
        #expect(!PopupSectionVisibility.nonCalm.shows(
            isNonCalm: false, isAboveZero: true, optionHeld: false))   // value does not feed nonCalm
    }

    /// `.optionOnly` ignores both data predicates — only ⌥ reveals the group. This is what the old
    /// boolean "off" migrates to, so a user who hid the rows does not get them back when they turn red.
    @Test func optionOnlyIgnoresData() {
        let mode = PopupSectionVisibility.optionOnly
        #expect(!mode.shows(isNonCalm: false, isAboveZero: false, optionHeld: false))
        #expect(!mode.shows(isNonCalm: true, isAboveZero: true, optionHeld: false))  // hidden while red
        #expect(mode.shows(isNonCalm: false, isAboveZero: false, optionHeld: true))
        #expect(mode.shows(isNonCalm: true, isAboveZero: true, optionHeld: true))
    }
}

@Suite("PopupSectionVisibility storage")
struct PopupSectionVisibilityStorageTests {

    /// Raw values are stable storage identifiers — renaming one silently resets everybody's choice.
    @Test func rawValuesAreStable() {
        #expect(PopupSectionVisibility.always.rawValue == "always")
        #expect(PopupSectionVisibility.aboveZero.rawValue == "aboveZero")
        #expect(PopupSectionVisibility.nonCalm.rawValue == "nonCalm")
        #expect(PopupSectionVisibility.optionOnly.rawValue == "optionOnly")
    }

    /// Declaration order — loudest to quietest — which the model-limits control renders as-is. The
    /// credits control offers a subset (no `.nonCalm`) but keeps this relative order; both lists live
    /// in `DropdownPane`.
    @Test func casesAreInPaneOrder() {
        #expect(PopupSectionVisibility.allCases == [.always, .aboveZero, .nonCalm, .optionOnly])
    }

    /// The labels carry the whole explanation (these rows have no `SettingsHint`), so "only" on the
    /// non-calm segment is load-bearing: without it the label reads as "also when non-calm".
    @Test func displayNames() {
        #expect(PopupSectionVisibility.always.displayName == "Always")
        #expect(PopupSectionVisibility.aboveZero.displayName == "Above zero")
        #expect(PopupSectionVisibility.nonCalm.displayName == "Non-calm only")
        #expect(PopupSectionVisibility.optionOnly.displayName == "With ⌥ Option")
    }

    /// Forward-compatible decode: a value written by a newer build must not make this one throw — it
    /// falls back to the default instead. Mirrors `ResetCountdownMode` / `CalmColorMode` / `BarStyle`.
    @Test func unknownRawDecodesToDefault() throws {
        let decoded = try JSONDecoder().decode(
            PopupSectionVisibility.self, from: Data("\"whenTheMoonIsFull\"".utf8))
        #expect(decoded == .nonCalm)
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
