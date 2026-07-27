import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - ResetCountdownMode ↔ ResetRadio (#168, ADR-0042)

@Suite("ResetCountdownMode radio mapping")
struct ResetCountdownModeRadioTests {

    @Test func modeToRadio() {
        #expect(ResetCountdownMode.always.radio == .always)
        #expect(ResetCountdownMode.smart.radio == .smart)
        #expect(ResetCountdownMode.never.radio == .never)
    }

    @Test func radioToMode() {
        #expect(ResetCountdownMode.from(radio: .always) == .always)
        #expect(ResetCountdownMode.from(radio: .smart) == .smart)
        #expect(ResetCountdownMode.from(radio: .never) == .never)
    }

    /// Every mode round-trips through radio → mode. Opening the Settings picker then re-committing
    /// must not change the stored mode.
    @Test func roundTripPreservesEveryMode() {
        for mode in ResetCountdownMode.allCases {
            #expect(ResetCountdownMode.from(radio: mode.radio) == mode)
        }
    }

    /// The removed legacy raw values decode to the default (smart).
    @Test func legacyRawValuesDecodeToDefault() throws {
        for raw in ["show_distant_7d", "hide_distant_7d", "bogus"] {
            let decoded = try JSONDecoder().decode(ResetCountdownMode.self, from: Data("\"\(raw)\"".utf8))
            #expect(decoded == .smart)
        }
    }

    /// A days-away ahead-of-pace 7d countdown is shown for every mode except `never`.
    @Test func showsSevenDayAheadExceptNever() {
        #expect(ResetCountdownMode.always.showsSevenDayAheadWhenFar)
        #expect(ResetCountdownMode.smart.showsSevenDayAheadWhenFar)
        #expect(!ResetCountdownMode.never.showsSevenDayAheadWhenFar)
    }
}
