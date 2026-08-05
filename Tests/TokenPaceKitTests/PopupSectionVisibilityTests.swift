import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - PopupSectionVisibility (#211)

@Suite("PopupSectionVisibility.shows")
struct PopupSectionVisibilityShowsTests {

    /// `.always` ignores both inputs — the whole truth table is `true`.
    @Test(arguments: [false, true], [false, true])
    func alwaysShowsRegardless(isNonCalm: Bool, optionHeld: Bool) {
        #expect(PopupSectionVisibility.always.shows(isNonCalm: isNonCalm, optionHeld: optionHeld))
    }

    /// `.nonCalm` is the interesting one: severity **or** ⌥ reveals the group, and only the
    /// calm-and-no-modifier cell hides it.
    @Test func nonCalmShowsOnSeverityOrOption() {
        let mode = PopupSectionVisibility.nonCalm
        #expect(!mode.shows(isNonCalm: false, optionHeld: false))   // calm, no ⌥ → hidden
        #expect(mode.shows(isNonCalm: true, optionHeld: false))     // orange/red → shown
        #expect(mode.shows(isNonCalm: false, optionHeld: true))     // ⌥ is the escape hatch
        #expect(mode.shows(isNonCalm: true, optionHeld: true))
    }

    /// `.optionOnly` ignores severity entirely — only ⌥ reveals the group. This is what the old
    /// boolean "off" migrates to, so a user who hid the rows does not get them back when they turn red.
    @Test func optionOnlyIgnoresSeverity() {
        let mode = PopupSectionVisibility.optionOnly
        #expect(!mode.shows(isNonCalm: false, optionHeld: false))
        #expect(!mode.shows(isNonCalm: true, optionHeld: false))    // still hidden while red
        #expect(mode.shows(isNonCalm: false, optionHeld: true))
        #expect(mode.shows(isNonCalm: true, optionHeld: true))
    }
}

@Suite("PopupSectionVisibility storage")
struct PopupSectionVisibilityStorageTests {

    /// Raw values are stable storage identifiers — renaming one silently resets everybody's choice.
    @Test func rawValuesAreStable() {
        #expect(PopupSectionVisibility.always.rawValue == "always")
        #expect(PopupSectionVisibility.nonCalm.rawValue == "nonCalm")
        #expect(PopupSectionVisibility.optionOnly.rawValue == "optionOnly")
    }

    /// The segment order in Settings — loudest to quietest.
    @Test func casesAreInPaneOrder() {
        #expect(PopupSectionVisibility.allCases == [.always, .nonCalm, .optionOnly])
    }

    /// The labels carry the whole explanation (these two rows have no `SettingsHint`), so "only" on
    /// the middle segment is load-bearing: without it the label reads as "also when non-calm".
    @Test func displayNames() {
        #expect(PopupSectionVisibility.always.displayName == "Always")
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
