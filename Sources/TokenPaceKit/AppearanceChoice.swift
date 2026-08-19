import Foundation

// MARK: - AppearanceChoice

/// Which row of the Appearance preset list is selected: one of the three named presets, or the user's
/// own stored configuration.
///
/// The list is four rows, but they are not four of a kind. The three presets are things to **try on** —
/// clicking one previews it on the live widget and writes nothing. ``mySetup`` is the configuration
/// that is actually stored, and the one the widget returns to when Settings closes. Modelling that as
/// an explicit case (rather than as `AppearancePreset?`, where `nil` silently meant "the user's own")
/// is what keeps the two meanings from being mistaken for each other — the previous design had one row
/// standing for the live config and a hidden snapshot at the same time.
public enum AppearanceChoice: Hashable, Sendable {
    case preset(AppearancePreset)
    /// The stored configuration — whatever the pages under Appearance were last set to.
    case mySetup

    /// Which row to select, given what is stored and what (if anything) is being previewed.
    ///
    /// A preview always wins the selection: it is what the widget is currently drawing, so the list has
    /// to agree with the screen. With no preview the answer is always ``mySetup``, *even when the stored
    /// configuration happens to equal a preset* — the user is on their own saved setup, which merely
    /// looks like `Chill` today. Selecting the `Chill` row there would claim the widget follows that
    /// preset and would keep following it, which is not true: editing any option leaves the preset
    /// behind while the stored setup simply changes.
    ///
    /// That equality is not lost, only demoted: ``storedPresetName(_:)`` hands it to the row as a
    /// suffix instead of as a selection.
    public static func selected(
        stored: AppearancePresetValues, previewing: AppearancePreset?
    ) -> AppearanceChoice {
        if let previewing { return .preset(previewing) }
        return .mySetup
    }

    /// The preset the **stored** configuration equals, if any — the `· same as Chill preset` suffix on
    /// the "My setup" row.
    ///
    /// Deliberately reads the stored values rather than the live ones: during a preview the live values
    /// are the preset being tried on, and a row that named *that* would tell the user their saved setup
    /// had become whatever they last clicked.
    public static func storedPresetName(_ stored: AppearancePresetValues) -> AppearancePreset? {
        AppearancePreset.matching(stored)
    }

    /// Whether the `Apply` button on a preset row can do anything: there is something to apply, i.e. the
    /// previewed preset differs from what is already stored.
    ///
    /// Clicking `Chill` while the stored configuration already equals `Chill` previews a no-op, and the
    /// button says so by being disabled rather than by disappearing — a control that vanishes makes the
    /// row it sits in change height, and the rows below it move under the pointer.
    public static func canApply(stored: AppearancePresetValues, previewing: AppearancePreset?) -> Bool {
        guard let previewing else { return false }
        return previewing.values != stored
    }
}
