import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - FarBehindInterval (#224)

@Suite("FarBehindInterval")
struct FarBehindIntervalTests {

    /// Four cases ship in order; the raw values are stable identifiers persisted in UserDefaults.
    @Test func casesAndRawValues() {
        #expect(FarBehindInterval.allCases == [.off, .short, .medium, .long])
        #expect(FarBehindInterval.off.rawValue == "off")
        #expect(FarBehindInterval.short.rawValue == "short")
        #expect(FarBehindInterval.medium.rawValue == "medium")
        #expect(FarBehindInterval.long.rawValue == "long")
    }

    /// Multipliers: off → nil (no blue), short/medium/long → 1/2/3.
    @Test func multipliers() {
        #expect(FarBehindInterval.off.multiplier == nil)
        #expect(FarBehindInterval.short.multiplier == 1)
        #expect(FarBehindInterval.medium.multiplier == 2)
        #expect(FarBehindInterval.long.multiplier == 3)
    }

    /// Forward-compatible decode: an unrecognised raw string falls back to `.medium` (the default).
    @Test func decodesUnknownRawValueToMedium() throws {
        let data = Data(#""huge""#.utf8)
        let interval = try JSONDecoder().decode(FarBehindInterval.self, from: data)
        #expect(interval == .medium)
    }
}
