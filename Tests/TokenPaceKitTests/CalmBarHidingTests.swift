import Testing
import Foundation
@testable import TokenPaceKit

/// `CalmBarHiding` — the tri-state that replaced the boolean `hideCalmSevenDayBar` (ADR-0086, supersedes
/// ADR-0034 / #94). These cover the type in isolation: the `hides` truth table, the "at most one bar is
/// ever elided" invariant that keeps the widget from rendering empty, the legacy-boolean mapping shared
/// by the `UserDefaults` migration and the config import, and the forward-compatible decode.
@Suite("CalmBarHiding")
struct CalmBarHidingTests {

    // MARK: hides

    @Test func fiveHourHidesOnlyTheCalmFiveHourBar() {
        let mode = CalmBarHiding.fiveHour
        #expect(mode.hides(.fiveHour, isCalm: true))
        #expect(!mode.hides(.fiveHour, isCalm: false))   // orange/red 5h always stays
        #expect(!mode.hides(.sevenDay, isCalm: true))    // the other bar is never touched
        #expect(!mode.hides(.sevenDay, isCalm: false))
    }

    @Test func sevenDayHidesOnlyTheCalmSevenDayBar() {
        let mode = CalmBarHiding.sevenDay
        #expect(mode.hides(.sevenDay, isCalm: true))
        #expect(!mode.hides(.sevenDay, isCalm: false))
        #expect(!mode.hides(.fiveHour, isCalm: true))
        #expect(!mode.hides(.fiveHour, isCalm: false))
    }

    @Test func neverHidesNothing() {
        for window in [LimitWindow.fiveHour, .sevenDay] {
            for isCalm in [true, false] {
                #expect(!CalmBarHiding.never.hides(window, isCalm: isCalm))
            }
        }
    }

    // MARK: the invariant

    /// The property the whole design leans on: whatever the value and whatever the two severities, the
    /// two bars can never both be hidden — so `MenuBarMode.expanded` always carries at least one bar and
    /// the widget cannot render empty. Proved here over the full matrix rather than trusted from the
    /// `MenuBarLayout` call site, so a future edit to `hides` trips this test first.
    @Test func atMostOneBarIsEverHidden() {
        for mode in CalmBarHiding.allCases {
            for fiveCalm in [true, false] {
                for sevenCalm in [true, false] {
                    let hidesFive = mode.hides(.fiveHour, isCalm: fiveCalm)
                    let hidesSeven = mode.hides(.sevenDay, isCalm: sevenCalm)
                    #expect(!(hidesFive && hidesSeven),
                            "\(mode) hid both bars (5h calm: \(fiveCalm), 7d calm: \(sevenCalm))")
                }
            }
        }
    }

    /// The same invariant one level down, at its source: each value names at most one window.
    @Test func hiddenWindowNamesAtMostOneWindow() {
        #expect(CalmBarHiding.fiveHour.hiddenWindow == .fiveHour)
        #expect(CalmBarHiding.sevenDay.hiddenWindow == .sevenDay)
        #expect(CalmBarHiding.never.hiddenWindow == nil)
    }

    // MARK: legacy mapping

    @Test func legacyTrueMapsToSevenDayAndFalseToNever() {
        // `true` hid the calm 7-day bar; `false` kept both. Each preserves what the user was looking at.
        #expect(CalmBarHiding.migrated(fromLegacyHide: true) == .sevenDay)
        #expect(CalmBarHiding.migrated(fromLegacyHide: false) == .never)
    }

    /// The new default is deliberately *not* reachable by migrating an explicit legacy value — it is what
    /// someone with no stored value picks up from the preset. Guards against a future "helpful" edit that
    /// maps `true` onto the new default and silently flips the widget for people who chose the old one.
    @Test func legacyMappingNeverYieldsTheNewDefault() {
        #expect(CalmBarHiding.migrated(fromLegacyHide: true) != .fiveHour)
        #expect(CalmBarHiding.migrated(fromLegacyHide: false) != .fiveHour)
    }

    // MARK: coding

    @Test func roundTripsThroughJSON() throws {
        for mode in CalmBarHiding.allCases {
            let data = try JSONEncoder().encode(mode)
            #expect(try JSONDecoder().decode(CalmBarHiding.self, from: data) == mode)
        }
    }

    @Test func encodesAsItsRawString() throws {
        let data = try JSONEncoder().encode(CalmBarHiding.fiveHour)
        #expect(String(decoding: data, as: UTF8.self) == "\"fiveHour\"")
    }

    /// Forward compatibility: a value written by a newer build must not make this one throw. Falls back
    /// to `.sevenDay` — the semantics any pre-enum dump described — rather than to today's default.
    @Test func unknownRawFallsBackToSevenDay() throws {
        let data = Data("\"someFutureMode\"".utf8)
        #expect(try JSONDecoder().decode(CalmBarHiding.self, from: data) == .sevenDay)
    }

    // MARK: UI labels

    @Test func displayNamesMatchTheSettingsSegments() {
        #expect(CalmBarHiding.fiveHour.displayName == "5-hour")
        #expect(CalmBarHiding.sevenDay.displayName == "7-day")
        #expect(CalmBarHiding.never.displayName == "Never")
    }

    /// `UIPanes` builds the segmented control from `allCases`, so the declaration order *is* the on-screen
    /// order: the two windows first, the opt-out last.
    @Test func caseOrderDrivesSegmentOrder() {
        #expect(CalmBarHiding.allCases == [.fiveHour, .sevenDay, .never])
    }
}
