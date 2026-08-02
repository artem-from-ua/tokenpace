import Foundation

// MARK: - AppearancePreset (#215)

/// A named, one-click bundle of every **Appearance** pane setting — the menu-bar widget toggles, the
/// reset-countdown mode, the bar presentation style, and the dropdown's per-model toggle (#215, #224).
/// Generalises the single "Reset to defaults" row from #214: `.chill` is the calm, quiet look
/// (simplified bars), `.workHarder` is `.chill` plus the coloured far-behind blue, `.controlFreak`
/// turns everything on (dense pacing bars). Applying a preset writes all eleven keys at once via
/// `PersistedConfig.apply(_:)`.
///
/// The preset **values** live here in the kit (not the AppKit/SwiftUI shell) so they are unit-testable
/// without a UI. The shell owns only presentation: the segmented control that calls `apply` and the
/// ``displayName`` shown on it. ``matching(_:)`` powers the control's "Custom" indicator segment: it
/// lights up when the live config matches no preset.
public enum AppearancePreset: String, Sendable, CaseIterable {
    /// The calm, quiet out-of-the-box look: every menu-bar toggle calm, countdown `.smart`, and the
    /// **simplified** left-anchored bar ribbon (#224). Note: since #224 this is no longer identical to
    /// the shipped bar *style* — the app still ships `.pacing` bars by default; `.chill` opts into
    /// `.simple`.
    case chill = "chill"
    /// Exactly `.chill`, but with **Work harder** on: the far-behind blue stays coloured under calm
    /// colours (a nudge that you're well under pace) while everything else stays calm. Sits between
    /// `.chill` and `.controlFreak`.
    case workHarder = "workHarder"
    /// Everything on and loud: calm colours off, all bars/dots/glyphs/credits/per-model rows shown,
    /// the reset countdown always visible, and the dense **pacing** bars with the time marker (#224).
    case controlFreak = "controlFreak"

    /// The fixed value set this preset writes to the eleven Appearance keys. Stored in the **as-persisted**
    /// sense, matching `PersistedConfig` — note `hideCalmSevenDay` / `hideBarsWhenBlocked` are *hide*
    /// flags (the pane shows them inverted as "Show …").
    public var values: AppearancePresetValues {
        switch self {
        case .chill:
            // The calm look: every menu-bar Bool on, per-model rows on, countdown smart, simplified
            // bars. Work harder off — the far-behind blue mutes with the rest of the calm colours.
            return AppearancePresetValues(
                calmColorMode: .yellowGreenBlue,   // greens/yellows AND far-behind blue all mute
                hideCalmSevenDayBar: true,
                hideBarsWhenBlocked: true,
                showBlockedPause: true,
                showExtraUsage: true,
                showServiceStatusDot: true,
                showModelSpecificLimits: true,
                resetCountdownModeMenuBar: .smart,
                barStyle: .simple,
                showTicks: false,   // the quiet look drops the under-bar tick ruler too
                farBehindInterval: .off)   // …and no blue far-behind zone
        case .workHarder:
            // `.chill` with Work harder on and the **mixed** bar style (pace-only menu bar, pace & time
            // in the dropdown); far-behind blue stays coloured under calm colours; ticks on.
            return AppearancePresetValues(
                calmColorMode: .yellowGreen,   // greens/yellows mute; far-behind blue stays coloured
                hideCalmSevenDayBar: true,
                hideBarsWhenBlocked: true,
                showBlockedPause: true,
                showExtraUsage: true,
                showServiceStatusDot: true,
                showModelSpecificLimits: true,
                resetCountdownModeMenuBar: .smart,
                barStyle: .mixed,
                showTicks: true,
                farBehindInterval: .medium)
        case .controlFreak:
            // Show everything: calm off; nothing hidden; every glyph/dot/credits/per-model row on;
            // countdown always; dense pacing bars. Work harder on so the far-behind blue stays loud too.
            return AppearancePresetValues(
                calmColorMode: .off,   // nothing muted — every state keeps its colour (loud)
                hideCalmSevenDayBar: false,
                hideBarsWhenBlocked: false,
                showBlockedPause: true,
                showExtraUsage: true,
                showServiceStatusDot: true,
                showModelSpecificLimits: true,
                resetCountdownModeMenuBar: .always,
                barStyle: .pacing,
                showTicks: true,
                farBehindInterval: .medium)
        }
    }

    /// The segment label shown in Settings → Appearance. English UI string.
    public var displayName: String {
        switch self {
        case .chill:        return "Chill"
        case .workHarder:   return "Work harder!"
        case .controlFreak: return "Control freak"
        }
    }

    /// The preset whose value set exactly equals `values`, or `nil` if the live config matches none of
    /// them (the "Custom" state). Drives the preset segmented control's active segment: after any
    /// manual toggle the config drifts off every preset and this returns `nil`, so the control honestly
    /// shows "Custom" rather than a stale preset. Relies on `AppearancePresetValues: Equatable`.
    public static func matching(_ values: AppearancePresetValues) -> AppearancePreset? {
        allCases.first { $0.values == values }
    }

    /// The **factory default** preset (#224). When no Appearance keys are stored — a fresh install or
    /// after a Reset — every Appearance property falls back to *this* preset's value set, so the
    /// out-of-the-box look is `.workHarder`. This is the single source of the defaults: a newly added
    /// Appearance option automatically defaults to its `.workHarder` value with no separate per-property
    /// default to keep in sync (see `PersistedConfig`'s getters, which read `AppearancePreset.default`).
    public static let `default`: AppearancePreset = .workHarder

    /// The factory-default value set — `default.values`, the fallback every Appearance getter uses when
    /// its key is absent.
    public static var defaultValues: AppearancePresetValues { `default`.values }
}

// MARK: - AppearancePresetValues

/// The eleven Appearance-pane values a preset sets, in the same **as-persisted** sense as
/// `PersistedConfig` (the two `hide…` flags are the stored *hide* form, not the pane's inverted "Show …").
public struct AppearancePresetValues: Sendable, Equatable {
    public let calmColorMode: CalmColorMode
    public let hideCalmSevenDayBar: Bool
    public let hideBarsWhenBlocked: Bool
    public let showBlockedPause: Bool
    public let showExtraUsage: Bool
    public let showServiceStatusDot: Bool
    public let showModelSpecificLimits: Bool
    public let resetCountdownModeMenuBar: ResetCountdownMode
    public let barStyle: BarStyle
    public let showTicks: Bool
    public let farBehindInterval: FarBehindInterval

    public init(
        calmColorMode: CalmColorMode,
        hideCalmSevenDayBar: Bool,
        hideBarsWhenBlocked: Bool,
        showBlockedPause: Bool,
        showExtraUsage: Bool,
        showServiceStatusDot: Bool,
        showModelSpecificLimits: Bool,
        resetCountdownModeMenuBar: ResetCountdownMode,
        barStyle: BarStyle,
        showTicks: Bool,
        farBehindInterval: FarBehindInterval
    ) {
        self.calmColorMode = calmColorMode
        self.hideCalmSevenDayBar = hideCalmSevenDayBar
        self.hideBarsWhenBlocked = hideBarsWhenBlocked
        self.showBlockedPause = showBlockedPause
        self.showExtraUsage = showExtraUsage
        self.showServiceStatusDot = showServiceStatusDot
        self.showModelSpecificLimits = showModelSpecificLimits
        self.resetCountdownModeMenuBar = resetCountdownModeMenuBar
        self.barStyle = barStyle
        self.showTicks = showTicks
        self.farBehindInterval = farBehindInterval
    }
}
