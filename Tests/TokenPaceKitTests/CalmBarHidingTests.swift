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
        #expect(CalmBarHiding.never.hiddenWindow == nil)
    }

    // MARK: legacy mapping

    /// `true` hid the calm 7-day bar; `false` kept both. The 7-day mode is gone (ADR-0090), so `true`
    /// lands on `.fiveHour`: that user asked for **fewer** bars while calm, and this still grants it —
    /// one bar in the calm state, both back on orange/red.
    @Test func legacyTrueMapsToFiveHourAndFalseToNever() {
        #expect(CalmBarHiding.migrated(fromLegacyHide: true) == .fiveHour)
        #expect(CalmBarHiding.migrated(fromLegacyHide: false) == .never)
    }

    /// The direction that matters: an explicit "hide the calm bar" must never migrate into the
    /// show-everything case. Guards against a future edit that reads the retired 7-day mode as "no
    /// longer expressible → hide nothing", which would hand those users the opposite of their request.
    @Test func legacyHideNeverYieldsShowEverything() {
        #expect(CalmBarHiding.migrated(fromLegacyHide: true) != .never)
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

    /// Forward compatibility: a value written by a newer build must not make this one throw.
    @Test func unknownRawFallsBackToFiveHour() throws {
        let data = Data("\"someFutureMode\"".utf8)
        #expect(try JSONDecoder().decode(CalmBarHiding.self, from: data) == .fiveHour)
    }

    /// The retired `"sevenDay"` raw decodes through the same fallback, and must land where its migration
    /// does: a dump written when that mode existed described one bar while calm, which `.fiveHour` still
    /// is — `.never` would misread it as "show everything".
    @Test func retiredSevenDayRawDecodesAsFiveHour() throws {
        let data = Data("\"sevenDay\"".utf8)
        #expect(try JSONDecoder().decode(CalmBarHiding.self, from: data) == .fiveHour)
    }

    // MARK: UI labels

    @Test func displayNamesMatchTheSettingsSegments() {
        // The row names the bar ("Hide 5h (top) bar"), so the segments only say *when*.
        #expect(CalmBarHiding.fiveHour.displayName == "When it's calm")
        #expect(CalmBarHiding.never.displayName == "Never")
    }

    /// `UIPanes` builds the segmented control from `allCases`, so the declaration order *is* the
    /// on-screen order: hide the top bar while it is quiet, then the opt-out.
    @Test func caseOrderDrivesSegmentOrder() {
        #expect(CalmBarHiding.allCases == [.fiveHour, .never])
    }
}
