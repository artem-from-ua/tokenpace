import Testing
@testable import TokenPaceKit

// MARK: - ResetCountdownMode fold/decompose (#168, ADR-0041)

@Suite("ResetCountdownMode radio fold/decompose")
struct ResetCountdownModeRadioTests {

    @Test func decomposeMapsEveryCase() {
        #expect(ResetCountdownMode.decompose(.always)        == (.always, true))
        #expect(ResetCountdownMode.decompose(.showDistant7d) == (.smart, true))
        #expect(ResetCountdownMode.decompose(.hideDistant7d) == (.smart, false))
        #expect(ResetCountdownMode.decompose(.never)         == (.never, true))
    }

    @Test func recomposeMapsEveryRadioChoice() {
        #expect(ResetCountdownMode.recompose(radio: .always, includeDistant7d: true)  == .always)
        #expect(ResetCountdownMode.recompose(radio: .always, includeDistant7d: false) == .always)
        #expect(ResetCountdownMode.recompose(radio: .never,  includeDistant7d: true)  == .never)
        #expect(ResetCountdownMode.recompose(radio: .smart,  includeDistant7d: true)  == .showDistant7d)
        #expect(ResetCountdownMode.recompose(radio: .smart,  includeDistant7d: false) == .hideDistant7d)
    }

    /// Every mode round-trips through decompose → recompose. This is the invariant the Settings UI
    /// relies on: opening the pane (decompose) then re-committing (recompose) must not change the mode.
    @Test func roundTripPreservesEveryMode() {
        for mode in ResetCountdownMode.allCases {
            let (radio, include) = ResetCountdownMode.decompose(mode)
            #expect(ResetCountdownMode.recompose(radio: radio, includeDistant7d: include) == mode)
        }
    }
}
