import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - CalmColorMode (#224)

@Suite("CalmColorMode")
struct CalmColorModeTests {

    /// Three modes ship; the raw values are stable identifiers persisted in UserDefaults.
    @Test func casesAndRawValues() {
        #expect(CalmColorMode.allCases == [.off, .yellowGreen, .yellowGreenBlue])
        #expect(CalmColorMode.off.rawValue == "off")
        #expect(CalmColorMode.yellowGreen.rawValue == "yellowGreen")
        #expect(CalmColorMode.yellowGreenBlue.rawValue == "yellowGreenBlue")
    }

    /// `mutesCalm` is false only for `.off`; `mutesBlue` is true only for `.yellowGreenBlue`. These two
    /// derived flags are what the render layer reads (they map the old `calmMenuBarColors` / `!workHarder`
    /// pair): off → neither muted; yellowGreen → calm muted but blue stays coloured (old "work harder");
    /// yellowGreenBlue → both muted (quietest).
    @Test func derivedFlags() {
        #expect(!CalmColorMode.off.mutesCalm)
        #expect(!CalmColorMode.off.mutesBlue)

        #expect(CalmColorMode.yellowGreen.mutesCalm)
        #expect(!CalmColorMode.yellowGreen.mutesBlue)

        #expect(CalmColorMode.yellowGreenBlue.mutesCalm)
        #expect(CalmColorMode.yellowGreenBlue.mutesBlue)
    }

    /// The idle pill honours the same blue exemption the pacing bars get (#343).
    ///
    /// The full truth table. Only one cell distinguishes this from a bare `mutesCalm` test — the
    /// **blue** pill under `.yellowGreen` — and that cell is the bug: the segment is labelled
    /// "Yellow + Green" precisely to say blue is *not* included, yet the idle path used to mute it.
    ///
    /// The **green** pill (idle with no weekly headroom, ADR-0081 §4) must keep muting in both muting
    /// modes: green is exactly what these modes are named after. Exempting the whole idle bar rather
    /// than just its blue would break that.
    @Test func idlePillHonoursTheBlueExemption() {
        // Nothing is muted at all.
        #expect(!CalmColorMode.off.mutesIdlePill(isBlue: true))
        #expect(!CalmColorMode.off.mutesIdlePill(isBlue: false))

        // "Yellow + Green": green mutes, blue stays coloured.
        #expect(!CalmColorMode.yellowGreen.mutesIdlePill(isBlue: true))
        #expect(CalmColorMode.yellowGreen.mutesIdlePill(isBlue: false))

        // "+ Blue": the quietest look mutes both.
        #expect(CalmColorMode.yellowGreenBlue.mutesIdlePill(isBlue: true))
        #expect(CalmColorMode.yellowGreenBlue.mutesIdlePill(isBlue: false))
    }

    /// The idle rule is the pacing rule (`gapColorTarget`) restricted to idle: substitute `isCalm` =
    /// true (an idle bar is always calm) and `severity == .farBehind` = `isBlue`, and the two
    /// expressions coincide. Pinning the equivalence keeps the two paths from drifting apart again —
    /// they already did once, which is what #343 was.
    @Test func idleRuleMatchesThePacingRule() {
        for mode in CalmColorMode.allCases {
            for isBlue in [true, false] {
                let pacing = mode.mutesCalm && !(isBlue && !mode.mutesBlue)
                #expect(mode.mutesIdlePill(isBlue: isBlue) == pacing)
            }
        }
    }

    /// A known raw value round-trips through `Codable`.
    @Test func decodesKnownRawValue() throws {
        let data = Data(#""yellowGreen""#.utf8)
        let mode = try JSONDecoder().decode(CalmColorMode.self, from: data)
        #expect(mode == .yellowGreen)
    }

    /// Forward-compatible decode: an unrecognised raw string (a newer build's value) falls back to
    /// `.yellowGreenBlue` — the shipped calm default — instead of throwing, so an older build never trips.
    @Test func decodesUnknownRawValueToYellowGreenBlue() throws {
        let data = Data(#""rainbow""#.utf8)
        let mode = try JSONDecoder().decode(CalmColorMode.self, from: data)
        #expect(mode == .yellowGreenBlue)
    }
}
