import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - AppearancePreset (#215, #224)

@Suite("AppearancePreset value sets")
struct AppearancePresetTests {

    /// Chill = the calm look: every menu-bar Bool on, per-model rows on, countdown smart, simplified
    /// bars (#224). Guards against a preset value drifting from the documented matrix.
    @Test func chillIsCalmLook() {
        let v = AppearancePreset.chill.values
        #expect(v.calmColorMode == .yellowGreenBlue)   // greens/yellows AND far-behind blue all mute
        #expect(v.hideCalmSevenDayBar)
        #expect(v.hideBarsWhenBlocked)
        #expect(v.showBlockedPause)
        #expect(v.showExtraUsage)
        #expect(v.showServiceStatusDot)
        #expect(v.showModelSpecificLimits)
        #expect(v.resetCountdownModeMenuBar == .smart)
        #expect(v.barStyle == .simple)
        #expect(!v.showTicks)   // the quiet look drops the tick ruler
        #expect(v.farBehindInterval == .off)   // …and no blue far-behind zone
    }

    /// Work harder! = Chill but with Work harder on, ticks on, and the **mixed** bar style. The calm
    /// menu-bar toggles / countdown / per-model rows all still match `.chill`.
    @Test func workHarderIsChillPlusWorkHarderTicksAndMixed() {
        let wh = AppearancePreset.workHarder.values
        let chill = AppearancePreset.chill.values
        #expect(wh.calmColorMode == .yellowGreen)       // difference 1 — far-behind blue stays coloured
        #expect(chill.calmColorMode == .yellowGreenBlue)
        #expect(wh.showTicks)          // difference 2 — ticks on for every preset but Chill
        #expect(!chill.showTicks)
        #expect(wh.barStyle == .mixed) // difference 3 — mixed bars (Chill is .simple)
        #expect(chill.barStyle == .simple)
        // The rest matches Chill.
        #expect(wh.hideCalmSevenDayBar == chill.hideCalmSevenDayBar)
        #expect(wh.hideBarsWhenBlocked == chill.hideBarsWhenBlocked)
        #expect(wh.showBlockedPause == chill.showBlockedPause)
        #expect(wh.showExtraUsage == chill.showExtraUsage)
        #expect(wh.showServiceStatusDot == chill.showServiceStatusDot)
        #expect(wh.showModelSpecificLimits == chill.showModelSpecificLimits)
        #expect(wh.resetCountdownModeMenuBar == chill.resetCountdownModeMenuBar)
        #expect(wh.farBehindInterval == .medium)   // difference 4 — Chill is .off (no blue)
        #expect(chill.farBehindInterval == .off)
    }

    /// Control freak = everything loud: calm off, nothing hidden, every glyph/dot/credits/per-model
    /// row on, countdown always, dense pacing bars.
    @Test func controlFreakShowsEverything() {
        let v = AppearancePreset.controlFreak.values
        #expect(v.calmColorMode == .off)   // nothing muted — every state loud
        #expect(!v.hideCalmSevenDayBar)
        #expect(!v.hideBarsWhenBlocked)
        #expect(v.showBlockedPause)
        #expect(v.showExtraUsage)
        #expect(v.showServiceStatusDot)
        #expect(v.showModelSpecificLimits)
        #expect(v.resetCountdownModeMenuBar == .always)
        #expect(v.barStyle == .pacing)
        #expect(v.showTicks)
    }

    /// `.default` is the factory default preset — Work harder! (#224), the fallback when no keys stored.
    @Test func defaultPresetIsWorkHarder() {
        #expect(AppearancePreset.default == .workHarder)
        #expect(AppearancePreset.defaultValues == AppearancePreset.workHarder.values)
    }

    @Test func displayNames() {
        #expect(AppearancePreset.chill.displayName == "Chill")
        #expect(AppearancePreset.workHarder.displayName == "Work harder!")
        #expect(AppearancePreset.controlFreak.displayName == "Control freak")
    }

    /// Three presets ship in order; the raw values are stable identifiers (not renamed with the UI label).
    @Test func casesAndRawValues() {
        #expect(AppearancePreset.allCases == [.chill, .workHarder, .controlFreak])
        #expect(AppearancePreset.chill.rawValue == "chill")
        #expect(AppearancePreset.workHarder.rawValue == "workHarder")
        #expect(AppearancePreset.controlFreak.rawValue == "controlFreak")
    }

    // MARK: matching (#224) — powers the preset control's active segment

    /// Each preset's own value set matches itself.
    @Test func matchingIdentifiesEachPreset() {
        #expect(AppearancePreset.matching(AppearancePreset.chill.values) == .chill)
        #expect(AppearancePreset.matching(AppearancePreset.workHarder.values) == .workHarder)
        #expect(AppearancePreset.matching(AppearancePreset.controlFreak.values) == .controlFreak)
    }

    /// A config that matches no preset (Chill with one field flipped) is "Custom" — `matching` is nil.
    @Test func matchingReturnsNilForCustom() {
        let chill = AppearancePreset.chill.values
        let custom = AppearancePresetValues(
            calmColorMode: chill.calmColorMode,
            hideCalmSevenDayBar: chill.hideCalmSevenDayBar,
            hideBarsWhenBlocked: chill.hideBarsWhenBlocked,
            showBlockedPause: chill.showBlockedPause,
            showExtraUsage: chill.showExtraUsage,
            showServiceStatusDot: chill.showServiceStatusDot,
            showModelSpecificLimits: chill.showModelSpecificLimits,
            resetCountdownModeMenuBar: chill.resetCountdownModeMenuBar,
            barStyle: .pacing,   // Chill uses .simple → this is off every preset
            showTicks: chill.showTicks,
            farBehindInterval: chill.farBehindInterval)
        #expect(AppearancePreset.matching(custom) == nil)
    }
}
