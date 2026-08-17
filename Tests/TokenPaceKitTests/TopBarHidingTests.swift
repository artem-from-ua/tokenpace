import Testing
import Foundation
@testable import TokenPaceKit

/// `TopBarHiding` — the tri-state that replaced the boolean `hideCalmSevenDayBar` (ADR-0086, supersedes
/// ADR-0034 / #94). These cover the type in isolation: the `hides` truth table, the "at most one bar is
/// ever elided" invariant that keeps the widget from rendering empty, the legacy-boolean mapping shared
/// by the `UserDefaults` migration and the config import, and the forward-compatible decode.
@Suite("TopBarHiding")
struct TopBarHidingTests {

    // MARK: hides

    @Test func fiveHourHidesOnlyTheCalmFiveHourBar() {
        let mode = TopBarHiding.untilItNeedsAttention
        #expect(mode.hides(.fiveHour, isCalm: true))
        #expect(!mode.hides(.fiveHour, isCalm: false))   // orange/red 5h always stays
        #expect(!mode.hides(.sevenDay, isCalm: true))    // the other bar is never touched
        #expect(!mode.hides(.sevenDay, isCalm: false))
    }

    @Test func neverHidesNothing() {
        for window in [LimitWindow.fiveHour, .sevenDay] {
            for isCalm in [true, false] {
                #expect(!TopBarHiding.never.hides(window, isCalm: isCalm))
            }
        }
    }

    // MARK: the invariant

    /// The property the whole design leans on: whatever the value and whatever the two severities, the
    /// two bars can never both be hidden — so `MenuBarMode.expanded` always carries at least one bar and
    /// the widget cannot render empty. Proved here over the full matrix rather than trusted from the
    /// `MenuBarLayout` call site, so a future edit to `hides` trips this test first.
    @Test func atMostOneBarIsEverHidden() {
        for mode in TopBarHiding.allCases {
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
        #expect(TopBarHiding.untilItNeedsAttention.hiddenWindow == .fiveHour)
        #expect(TopBarHiding.never.hiddenWindow == nil)
    }

    // MARK: legacy mapping

    /// `true` hid the calm 7-day bar; `false` kept both. The 7-day mode is gone (ADR-0090), so `true`
    /// lands on `.fiveHour`: that user asked for **fewer** bars while calm, and this still grants it —
    /// one bar in the calm state, both back on orange/red.
    @Test func legacyTrueMapsToFiveHourAndFalseToNever() {
        #expect(TopBarHiding.migrated(fromLegacyHide: true) == .untilItNeedsAttention)
        #expect(TopBarHiding.migrated(fromLegacyHide: false) == .never)
    }

    /// The direction that matters: an explicit "hide the calm bar" must never migrate into the
    /// show-everything case. Guards against a future edit that reads the retired 7-day mode as "no
    /// longer expressible → hide nothing", which would hand those users the opposite of their request.
    @Test func legacyHideNeverYieldsShowEverything() {
        #expect(TopBarHiding.migrated(fromLegacyHide: true) != .never)
    }

    // MARK: coding

    @Test func roundTripsThroughJSON() throws {
        for mode in TopBarHiding.allCases {
            let data = try JSONEncoder().encode(mode)
            #expect(try JSONDecoder().decode(TopBarHiding.self, from: data) == mode)
        }
    }

    @Test func encodesAsItsRawString() throws {
        let data = try JSONEncoder().encode(TopBarHiding.untilItNeedsAttention)
        #expect(String(decoding: data, as: UTF8.self) == "\"untilItNeedsAttention\"")
    }

    /// Forward compatibility: a value written by a newer build must not make this one throw.
    @Test func unknownRawFallsBackToHiding() throws {
        let data = Data("\"someFutureMode\"".utf8)
        #expect(try JSONDecoder().decode(TopBarHiding.self, from: data) == .untilItNeedsAttention)
    }

    /// The pre-#381 raw decodes onto the renamed case **through `legacyRawValues`**, not through the
    /// unknown-value fallback. Both land in the same place here, which is exactly why the distinction
    /// needs its own test: an accidental reliance on the fallback would look correct until the fallback
    /// changed.
    @Test func decodesLegacyRawValues() throws {
        #expect(TopBarHiding.legacyRawValues["fiveHour"] == .untilItNeedsAttention)
        let data = Data("\"fiveHour\"".utf8)
        #expect(try JSONDecoder().decode(TopBarHiding.self, from: data) == .untilItNeedsAttention)
        // Neither legacy raw is a current case — a stale entry here would shadow its own case.
        #expect(TopBarHiding(rawValue: "fiveHour") == nil)
    }

    /// The retired `"sevenDay"` raw (ADR-0090) decodes the same way, and must land where its migration
    /// does: a dump written when that mode existed described one bar while quiet, which
    /// `.untilItNeedsAttention` still is — `.never` would misread it as "show everything".
    @Test func retiredSevenDayRawDecodesAsHiding() throws {
        let data = Data("\"sevenDay\"".utf8)
        #expect(try JSONDecoder().decode(TopBarHiding.self, from: data) == .untilItNeedsAttention)
    }

    // MARK: UI labels

    @Test func displayNamesMatchTheSettingsSegments() {
        // The row names the bar ("Hide the top 5h bar"), so the segments only say *when*. #381 replaced
        // "When it's calm": "calm" is a term of art here, and the segment has to stand alone now that the
        // row's hint no longer restates the hiding rule.
        #expect(TopBarHiding.untilItNeedsAttention.displayName == "Until it needs attention")
        #expect(TopBarHiding.never.displayName == "Never")
    }

    /// `UIPanes` builds the segmented control from `allCases`, so the declaration order *is* the
    /// on-screen order: hide the top bar while it is quiet, then the opt-out.
    @Test func caseOrderDrivesSegmentOrder() {
        #expect(TopBarHiding.allCases == [.untilItNeedsAttention, .never])
    }
}
