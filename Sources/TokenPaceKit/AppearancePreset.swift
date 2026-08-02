import Foundation

// MARK: - AppearancePreset (#215)

/// A named, one-click bundle of every **Appearance** pane setting — the menu-bar widget toggles, the
/// reset-countdown mode, and the dropdown's per-model toggle (#215). Generalises the single "Reset to
/// defaults" row from #214: `.chill` is exactly the shipped defaults (what the old Reset produced),
/// `.controlFreak` turns everything on. Applying a preset writes all nine keys at once via
/// `PersistedConfig.apply(_:)`.
///
/// The preset **values** live here in the kit (not the AppKit/SwiftUI shell) so they are unit-testable
/// without a UI. The shell owns only presentation: the buttons that call `apply` and the
/// ``displayName`` shown on them.
public enum AppearancePreset: String, Sendable, CaseIterable {
    /// The shipped defaults — the calm, quiet out-of-the-box look. Identical to the value set the
    /// #214 "Reset appearance to defaults" row produced (every menu-bar toggle on, countdown `.smart`).
    case chill = "chill"
    /// Everything on and loud: calm colours off, all bars/dots/glyphs/credits/per-model rows shown,
    /// the reset countdown always visible.
    case controlFreak = "controlFreak"

    /// The fixed value set this preset writes to the nine Appearance keys. Stored in the **as-persisted**
    /// sense, matching `PersistedConfig` — note `hideCalmSevenDay` / `hideBarsWhenBlocked` are *hide*
    /// flags (the pane shows them inverted as "Show …").
    public var values: AppearancePresetValues {
        switch self {
        case .chill:
            // The opt-out defaults: every menu-bar Bool on, per-model rows on, countdown smart.
            // Work harder off — the far-behind blue mutes with the rest of the calm colours.
            return AppearancePresetValues(
                calmMenuBarColors: true,
                workHarderColors: false,
                hideCalmSevenDayBar: true,
                hideBarsWhenBlocked: true,
                showBlockedPause: true,
                showExtraUsage: true,
                showServiceStatusDot: true,
                showModelSpecificLimits: true,
                resetCountdownModeMenuBar: .smart)
        case .controlFreak:
            // Show everything: calm off; nothing hidden; every glyph/dot/credits/per-model row on;
            // countdown always. Work harder on so the far-behind blue stays loud too.
            return AppearancePresetValues(
                calmMenuBarColors: false,
                workHarderColors: true,
                hideCalmSevenDayBar: false,
                hideBarsWhenBlocked: false,
                showBlockedPause: true,
                showExtraUsage: true,
                showServiceStatusDot: true,
                showModelSpecificLimits: true,
                resetCountdownModeMenuBar: .always)
        }
    }

    /// The button label shown in Settings → Appearance. English UI string.
    public var displayName: String {
        switch self {
        case .chill:        return "Chill"
        case .controlFreak: return "Control freak"
        }
    }
}

// MARK: - AppearancePresetValues

/// The nine Appearance-pane values a preset sets, in the same **as-persisted** sense as
/// `PersistedConfig` (the two `hide…` flags are the stored *hide* form, not the pane's inverted "Show …").
public struct AppearancePresetValues: Sendable, Equatable {
    public let calmMenuBarColors: Bool
    public let workHarderColors: Bool
    public let hideCalmSevenDayBar: Bool
    public let hideBarsWhenBlocked: Bool
    public let showBlockedPause: Bool
    public let showExtraUsage: Bool
    public let showServiceStatusDot: Bool
    public let showModelSpecificLimits: Bool
    public let resetCountdownModeMenuBar: ResetCountdownMode

    public init(
        calmMenuBarColors: Bool,
        workHarderColors: Bool,
        hideCalmSevenDayBar: Bool,
        hideBarsWhenBlocked: Bool,
        showBlockedPause: Bool,
        showExtraUsage: Bool,
        showServiceStatusDot: Bool,
        showModelSpecificLimits: Bool,
        resetCountdownModeMenuBar: ResetCountdownMode
    ) {
        self.calmMenuBarColors = calmMenuBarColors
        self.workHarderColors = workHarderColors
        self.hideCalmSevenDayBar = hideCalmSevenDayBar
        self.hideBarsWhenBlocked = hideBarsWhenBlocked
        self.showBlockedPause = showBlockedPause
        self.showExtraUsage = showExtraUsage
        self.showServiceStatusDot = showServiceStatusDot
        self.showModelSpecificLimits = showModelSpecificLimits
        self.resetCountdownModeMenuBar = resetCountdownModeMenuBar
    }
}
