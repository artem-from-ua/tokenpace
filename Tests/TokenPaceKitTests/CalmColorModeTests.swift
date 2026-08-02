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
