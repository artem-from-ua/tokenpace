import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - AppearancePreset (#215)

@Suite("AppearancePreset value sets")
struct AppearancePresetTests {

    /// Chill = the shipped defaults (what the #214 Reset restored): every menu-bar Bool on, per-model
    /// rows on, countdown smart. Guards against a preset value drifting from the documented matrix.
    @Test func chillIsShippedDefaults() {
        let v = AppearancePreset.chill.values
        #expect(v.calmMenuBarColors)
        #expect(v.hideCalmSevenDayBar)
        #expect(v.hideBarsWhenBlocked)
        #expect(v.showBlockedPause)
        #expect(v.showExtraUsage)
        #expect(v.showServiceStatusDot)
        #expect(v.showModelSpecificLimits)
        #expect(v.resetCountdownModeMenuBar == .smart)
    }

    /// Control freak = everything loud: calm off, nothing hidden, every glyph/dot/credits/per-model
    /// row on, countdown always.
    @Test func controlFreakShowsEverything() {
        let v = AppearancePreset.controlFreak.values
        #expect(!v.calmMenuBarColors)
        #expect(!v.hideCalmSevenDayBar)
        #expect(!v.hideBarsWhenBlocked)
        #expect(v.showBlockedPause)
        #expect(v.showExtraUsage)
        #expect(v.showServiceStatusDot)
        #expect(v.showModelSpecificLimits)
        #expect(v.resetCountdownModeMenuBar == .always)
    }

    @Test func displayNames() {
        #expect(AppearancePreset.chill.displayName == "Chill")
        #expect(AppearancePreset.controlFreak.displayName == "Control freak")
    }

    /// Exactly two presets ship; the raw values are stable identifiers (not renamed with the UI label).
    @Test func casesAndRawValues() {
        #expect(AppearancePreset.allCases == [.chill, .controlFreak])
        #expect(AppearancePreset.chill.rawValue == "chill")
        #expect(AppearancePreset.controlFreak.rawValue == "controlFreak")
    }
}
