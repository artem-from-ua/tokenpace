import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - AppearancePreset (#215, #224)

@Suite("AppearancePreset value sets")
struct AppearancePresetTests {

    /// Chill = the calm look: every menu-bar Bool on, the dropdown's two sections folded away until
    /// they turn orange/red, countdown smart, simplified bars (#224). Guards against a preset value
    /// drifting from the documented matrix.
    @Test func chillIsCalmLook() {
        let v = AppearancePreset.chill.values
        #expect(v.calmColorMode == .yellowGreenBlue)   // greens/yellows AND far-behind blue all mute
        #expect(v.hideCalmSevenDayBar)
        #expect(v.pauseHidesBars)   // Chill: when blocked, show only the pause icon (bars hidden)
        #expect(v.showExtraUsage)
        #expect(v.showServiceStatusDot)
        #expect(!v.awaitingInputInMenuBar)   // Chill: awaiting hand stays in the popup only (#233)
        #expect(v.modelLimitsVisibility == .nonCalm)   // quiet dropdown: fold until orange/red (#211)
        #expect(v.extraUsageVisibility == .nonCalm)
        #expect(v.resetCountdownModeMenuBar == .smart)
        #expect(v.menuBarStyle == .pressure)   // the quietest style, and on both surfaces (#329)
        #expect(v.dropdownStyle == .pressure)
        #expect(!v.showTicks)   // the quiet look drops the tick ruler
        #expect(v.farBehindInterval == .off)   // …and no blue far-behind zone
    }

    /// Work harder! = Chill but with Work harder on, ticks on, and **Gauge** bars. The calm menu-bar
    /// toggles / countdown / per-model rows all still match `.chill`.
    @Test func workHarderIsChillPlusWorkHarderTicksAndGauge() {
        let wh = AppearancePreset.workHarder.values
        let chill = AppearancePreset.chill.values
        #expect(wh.calmColorMode == .yellowGreen)       // difference 1 — far-behind blue stays coloured
        #expect(chill.calmColorMode == .yellowGreenBlue)
        #expect(wh.showTicks)          // difference 2 — ticks on for every preset but Chill
        #expect(!chill.showTicks)
        // Difference 3 — Gauge on both surfaces (#329; was the per-surface `.mixed` pair before).
        #expect(wh.menuBarStyle == .gauge)
        #expect(wh.dropdownStyle == .gauge)
        #expect(chill.menuBarStyle == .pressure)
        #expect(!wh.pauseHidesBars)    // difference 5 — Work harder keeps the bars beside the pause icon
        #expect(chill.pauseHidesBars)  // …Chill hides them (icon only)
        // The rest matches Chill.
        #expect(wh.hideCalmSevenDayBar == chill.hideCalmSevenDayBar)
        #expect(wh.showExtraUsage == chill.showExtraUsage)
        #expect(wh.showServiceStatusDot == chill.showServiceStatusDot)
        #expect(wh.awaitingInputInMenuBar)          // difference 6 — Work harder shows the hand in the menu bar
        #expect(!chill.awaitingInputInMenuBar)      // …Chill keeps it popup-only (#233)
        #expect(wh.modelLimitsVisibility == chill.modelLimitsVisibility)   // both .nonCalm (#211)
        #expect(wh.extraUsageVisibility == chill.extraUsageVisibility)
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
        #expect(!v.pauseHidesBars)   // Control freak: when blocked, keep the bars beside the pause icon
        #expect(v.showExtraUsage)
        #expect(v.showServiceStatusDot)
        #expect(v.awaitingInputInMenuBar)   // Control freak: awaiting hand in the menu bar too (#233)
        // Nothing in the dropdown folds away — both sections pinned open (#211).
        #expect(v.modelLimitsVisibility == .always)
        #expect(v.extraUsageVisibility == .always)
        #expect(v.resetCountdownModeMenuBar == .always)
        #expect(v.menuBarStyle == .progress)
        #expect(v.dropdownStyle == .progress)
        #expect(v.showTicks)
    }

    /// Every preset gives both surfaces the **same** style (#329). The presets are the three coherent
    /// looks, so one that disagreed with itself across the menu bar and the dropdown would be a fourth;
    /// mixing the two is what dropping out to "Custom" is for. Also means the three presets cover the
    /// three styles exactly once, so no style is unreachable from the preset row alone.
    @Test func everyPresetUsesOneStyleOnBothSurfaces() {
        for preset in AppearancePreset.allCases {
            let v = preset.values
            #expect(v.menuBarStyle == v.dropdownStyle, "\(preset)")
        }
        #expect(Set(AppearancePreset.allCases.map(\.values.menuBarStyle)) == Set(BarStyle.allCases))
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
            pauseHidesBars: chill.pauseHidesBars,
            showExtraUsage: chill.showExtraUsage,
            showServiceStatusDot: chill.showServiceStatusDot,
            awaitingInputInMenuBar: chill.awaitingInputInMenuBar,
            modelLimitsVisibility: chill.modelLimitsVisibility,
            extraUsageVisibility: chill.extraUsageVisibility,
            resetCountdownModeMenuBar: chill.resetCountdownModeMenuBar,
            // Only the *dropdown* is flipped: Chill is Pressure on both, so this mismatched pair is
            // off every preset — and it is the mix a preset can no longer express (#329).
            menuBarStyle: chill.menuBarStyle,
            dropdownStyle: .progress,
            showTicks: chill.showTicks,
            farBehindInterval: chill.farBehindInterval)
        #expect(AppearancePreset.matching(custom) == nil)
    }
}
