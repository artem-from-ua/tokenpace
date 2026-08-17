import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - AppearancePreset (#215, #224)

@Suite("AppearancePreset value sets")
struct AppearancePresetTests {

    /// Chill = the calm look: every menu-bar Bool on, the dropdown's two sections folded away until
    /// they turn orange/red, simplified bars (#224). Guards against a preset value
    /// drifting from the documented matrix.
    @Test func chillIsCalmLook() {
        let v = AppearancePreset.chill.values
        #expect(v.colorsTell == .slowDown)   // greens/yellows AND far-behind blue all mute
        #expect(v.hideTop5hBar == .untilItNeedsAttention)   // quiet 5h steps aside; the weekly bar stays (ADR-0086)
        #expect(v.showServiceStatusDot)
        #expect(v.modelLimitsVisibility == .whenItNeedsAttention)   // quiet dropdown: fold until orange/red (#211)
        // Credits fold until money is actually spent, not until they turn orange: an unlimited cap has
        // no bar and hence no severity, so `.whenItNeedsAttention` would hide the spend forever.
        #expect(v.extraUsageVisibility == .onceUsed)
        #expect(v.menuBarStyle == .pressure)   // the quietest style, and on both surfaces (#329)
        #expect(v.dropdownStyle == .pressure)
    }

    /// Work harder! = Chill but with Work harder on and **Gauge** bars. The calm menu-bar
    /// toggles and per-model rows all still match `.chill`.
    @Test func workHarderIsChillPlusWorkHarderAndGauge() {
        let wh = AppearancePreset.workHarder.values
        let chill = AppearancePreset.chill.values
        #expect(wh.colorsTell == .slowDownOrSpeedUp)       // difference 1 — far-behind blue stays coloured
        #expect(chill.colorsTell == .slowDown)
        // Difference 2 — Gauge on both surfaces (#329; was the per-surface `.mixed` pair before).
        #expect(wh.menuBarStyle == .gauge)
        #expect(wh.dropdownStyle == .gauge)
        #expect(chill.menuBarStyle == .pressure)
        // The rest matches Chill.
        #expect(wh.hideTop5hBar == chill.hideTop5hBar)   // both `.untilItNeedsAttention` (ADR-0086)
        #expect(wh.showServiceStatusDot == chill.showServiceStatusDot)
        #expect(wh.modelLimitsVisibility == chill.modelLimitsVisibility)   // both .whenItNeedsAttention (#211)
        #expect(wh.extraUsageVisibility == chill.extraUsageVisibility)
        #expect(wh.extraUsageVisibility == .onceUsed)   // pinned, not just "same as Chill"
    }

    /// Control freak = everything loud: calm off, nothing hidden, every glyph/dot/credits/per-model
    /// row on, dense pacing bars.
    @Test func controlFreakShowsEverything() {
        let v = AppearancePreset.controlFreak.values
        #expect(v.colorsTell == .howItsGoing)   // nothing muted — every state loud
        #expect(v.hideTop5hBar == .never)   // both bars always on screen, however calm
        #expect(v.showServiceStatusDot)
        // Nothing in the dropdown folds away — both sections pinned open (#211).
        #expect(v.modelLimitsVisibility == .always)
        #expect(v.extraUsageVisibility == .always)
        #expect(v.menuBarStyle == .progress)
        #expect(v.dropdownStyle == .progress)
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
            colorsTell: chill.colorsTell,
            hideTop5hBar: chill.hideTop5hBar,
            showServiceStatusDot: chill.showServiceStatusDot,
            modelLimitsVisibility: chill.modelLimitsVisibility,
            extraUsageVisibility: chill.extraUsageVisibility,
            // Only the *dropdown* is flipped: Chill is Pressure on both, so this mismatched pair is
            // off every preset — and it is the mix a preset can no longer express (#329).
            menuBarStyle: chill.menuBarStyle,
            dropdownStyle: .progress)
        #expect(AppearancePreset.matching(custom) == nil)
    }

    /// The three presets stay **pairwise distinct**, which is what makes `matching(_:)` able to name
    /// one — and the "Custom" segment able to mean anything.
    ///
    /// Worth its own test since ADR-0090: the value set keeps losing fields — three there
    /// (`pauseHidesBars`, `awaitingInputInMenuBar`, `showExtraUsage`), then `showTicks` when the tick
    /// ruler stopped being optional. `Chill` and `Work harder!` are now separated by palette and bar
    /// style alone. Retire one more and the two presets collapse into the same value set, at which point
    /// `matching` silently returns whichever comes first in `allCases` and the control starts lying
    /// about which preset is active.
    @Test func presetsRemainPairwiseDistinct() {
        for a in AppearancePreset.allCases {
            for b in AppearancePreset.allCases where a != b {
                #expect(a.values != b.values, "\(a.rawValue) and \(b.rawValue) have identical values")
            }
        }
    }
}
