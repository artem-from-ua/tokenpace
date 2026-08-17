import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - ColorAdvice (#224, renamed and rescoped in #381)

@Suite("ColorAdvice")
struct ColorAdviceTests {

    /// Three modes ship, quietest first. The raw values are the stable identifiers persisted in
    /// `UserDefaults` — renamed in #381 along with the cases, which is why the legacy decode below
    /// matters.
    @Test func casesAndRawValues() {
        #expect(ColorAdvice.allCases == [.slowDown, .slowDownOrSpeedUp, .howItsGoing])
        #expect(ColorAdvice.slowDown.rawValue == "slowDown")
        #expect(ColorAdvice.slowDownOrSpeedUp.rawValue == "slowDownOrSpeedUp")
        #expect(ColorAdvice.howItsGoing.rawValue == "howItsGoing")
    }

    /// `mutesCalm` is false only for `.howItsGoing`; `mutesBlue` is true only for `.slowDown`. These two
    /// derived flags are what the render layer reads: nothing muted; the calm side muted but the
    /// far-behind blue left coloured; or both muted (the quietest).
    @Test func derivedFlags() {
        #expect(!ColorAdvice.howItsGoing.mutesCalm)
        #expect(!ColorAdvice.howItsGoing.mutesBlue)

        #expect(ColorAdvice.slowDownOrSpeedUp.mutesCalm)
        #expect(!ColorAdvice.slowDownOrSpeedUp.mutesBlue)

        #expect(ColorAdvice.slowDown.mutesCalm)
        #expect(ColorAdvice.slowDown.mutesBlue)
    }

    /// The one case whose flags differ from a plain "muted or not" reading — kept as its own test because
    /// it is the whole difference between the two muting modes, and the reason #381 could not simply
    /// collapse them into a boolean: under Gauge and Progress the below-pace half **saturates** past the
    /// middle of a window (`gaugeOffset` clamps at −1), so colour is the only thing left that separates a
    /// large surplus from a small one.
    @Test func onlyTheQuietestModeMutesBlue() {
        let mutingBlue = ColorAdvice.allCases.filter(\.mutesBlue)
        #expect(mutingBlue == [.slowDown])
    }

    /// A current raw value round-trips through `Codable`.
    @Test func decodesKnownRawValue() throws {
        let data = Data(#""slowDownOrSpeedUp""#.utf8)
        #expect(try JSONDecoder().decode(ColorAdvice.self, from: data) == .slowDownOrSpeedUp)
    }

    /// The pre-#381 raws decode onto the renamed cases **explicitly**, through `legacyRawValues` rather
    /// than through the unknown-value fallback. That distinction is the point of the test: a fallback
    /// would compile, pass a naive round-trip check, and silently move every existing install onto the
    /// quietest mode.
    @Test func decodesLegacyRawValues() throws {
        let expected: [(String, ColorAdvice)] = [
            ("off", .howItsGoing),
            ("yellowGreen", .slowDownOrSpeedUp),
            ("yellowGreenBlue", .slowDown),
        ]
        for (raw, mode) in expected {
            let data = Data("\"\(raw)\"".utf8)
            #expect(try JSONDecoder().decode(ColorAdvice.self, from: data) == mode)
        }
    }

    /// The legacy table covers exactly the three retired raws — no more (a current raw listed there would
    /// shadow the case) and no fewer.
    @Test func legacyTableCoversOnlyTheRetiredRaws() {
        #expect(Set(ColorAdvice.legacyRawValues.keys) == ["off", "yellowGreen", "yellowGreenBlue"])
        for key in ColorAdvice.legacyRawValues.keys {
            #expect(ColorAdvice(rawValue: key) == nil)
        }
    }

    /// Forward-compatible decode: a raw that is neither current nor legacy (a newer build's value) falls
    /// back to `.slowDown` — the quietest mode, matching what the shipped calm default used to be —
    /// instead of throwing, so an older build never trips.
    @Test func decodesUnknownRawValueToQuietest() throws {
        let data = Data(#""rainbow""#.utf8)
        #expect(try JSONDecoder().decode(ColorAdvice.self, from: data) == .slowDown)
    }
}
