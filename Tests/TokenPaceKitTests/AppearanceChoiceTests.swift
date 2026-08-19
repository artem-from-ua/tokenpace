import Testing
@testable import TokenPaceKit

/// The rules behind the four-row preset list: which row lights up, what the "My setup" suffix names,
/// and when `Apply` has anything to do.
///
/// These live in the kit rather than beside `SettingsModel` because the model is in the app target,
/// which has no test target at all — extracting the decisions into `AppearanceChoice` is what makes
/// the most confusable part of this screen testable.
struct AppearanceChoiceTests {

    /// A hand-made configuration equal to no preset — `Chill` with one field swapped.
    private var handMade: AppearancePresetValues {
        let chill = AppearancePreset.chill.values
        return AppearancePresetValues(
            colorsTell: chill.colorsTell,
            hideTop5hBar: chill.hideTop5hBar,
            showServiceStatusDot: chill.showServiceStatusDot,
            modelLimitsVisibility: chill.modelLimitsVisibility,
            extraUsageVisibility: chill.extraUsageVisibility,
            menuBarStyle: chill.menuBarStyle,
            dropdownStyle: .progress)   // Chill uses .pressure on both surfaces
    }

    // MARK: Which row is selected

    @Test("with no preview, the stored setup is selected — even when it equals a preset")
    func noPreviewSelectsMySetup() {
        for preset in AppearancePreset.allCases {
            #expect(AppearanceChoice.selected(stored: preset.values, previewing: nil) == .mySetup)
        }
        #expect(AppearanceChoice.selected(stored: handMade, previewing: nil) == .mySetup)
    }

    @Test("a preview always wins the selection — it is what the widget is drawing")
    func previewSelectsItsRow() {
        for preset in AppearancePreset.allCases {
            #expect(AppearanceChoice.selected(stored: handMade, previewing: preset) == .preset(preset))
        }
    }

    @Test("previewing the preset the stored setup already equals still selects the preset row")
    func previewOfTheMatchingPresetStillSelectsIt() {
        let stored = AppearancePreset.chill.values
        #expect(AppearanceChoice.selected(stored: stored, previewing: .chill) == .preset(.chill))
    }

    // MARK: The "· same as X preset" suffix

    @Test("the suffix names the preset the stored values equal")
    func suffixNamesTheStoredMatch() {
        for preset in AppearancePreset.allCases {
            #expect(AppearanceChoice.storedPresetName(preset.values) == preset)
        }
    }

    @Test("a hand-made setup has no suffix")
    func handMadeHasNoSuffix() {
        #expect(AppearanceChoice.storedPresetName(handMade) == nil)
    }

    @Test("a fresh install reads as the factory preset")
    func freshInstallNamesTheDefault() {
        #expect(AppearanceChoice.storedPresetName(AppearancePreset.defaultValues) == .default)
    }

    // MARK: When Apply does something

    @Test("Apply is dead without a preview")
    func applyNeedsAPreview() {
        #expect(AppearanceChoice.canApply(stored: handMade, previewing: nil) == false)
    }

    @Test("Apply is live while previewing something the stored setup does not equal")
    func applyIsLiveOnADifferentPreset() {
        for preset in AppearancePreset.allCases {
            #expect(AppearanceChoice.canApply(stored: handMade, previewing: preset))
        }
    }

    @Test("Apply is dead while previewing the preset the stored setup already equals")
    func applyIsDeadOnAnIdenticalPreset() {
        for preset in AppearancePreset.allCases {
            #expect(AppearanceChoice.canApply(stored: preset.values, previewing: preset) == false)
        }
    }

    @Test("on a fresh install, Apply is dead on the factory preset and live on the others")
    func freshInstallApplyState() {
        let stored = AppearancePreset.defaultValues
        for preset in AppearancePreset.allCases {
            #expect(AppearanceChoice.canApply(stored: stored, previewing: preset) == (preset != .default))
        }
    }
}
