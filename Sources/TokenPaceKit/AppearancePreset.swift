import Foundation

// MARK: - AppearancePreset (#215)

/// A named, one-click bundle of every **Appearance** pane setting — the menu-bar widget toggles, the
/// reset-countdown mode, the bar presentation style, and the dropdown's section visibility (#215, #224).
/// Generalises the single "Reset to defaults" row from #214: `.chill` is the calm, quiet look
/// (simplified bars), `.workHarder` is `.chill` plus the coloured far-behind blue, `.controlFreak`
/// turns everything on (dense pacing bars). Applying a preset writes all twelve keys at once via
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
    /// Everything on and loud: calm colours off, all bars/dots/glyphs shown, the dropdown's credits and
    /// per-model sections pinned open (`.always`), the reset countdown always visible, and the dense
    /// **pacing** bars with the time marker (#224).
    case controlFreak = "controlFreak"

    /// The fixed value set this preset writes to the twelve Appearance keys. Stored in the **as-persisted**
    /// sense, matching `PersistedConfig` — note `hideCalmSevenDay` is a *hide* flag (the pane shows it
    /// inverted as "Show …"). `pauseHidesBars` is stored as-is (the pane's toggle is not inverted).
    public var values: AppearancePresetValues {
        switch self {
        case .chill:
            // The calm look: per-model rows on, countdown smart, simplified bars, and — when fully
            // blocked — only the red pause icon (bars hidden). Work harder off — the far-behind blue
            // mutes with the rest of the calm colours.
            return AppearancePresetValues(
                calmColorMode: .yellowGreenBlue,   // greens/yellows AND far-behind blue all mute
                hideCalmSevenDayBar: true,
                pauseHidesBars: true,   // when blocked, show only the pause icon (bars hidden)
                showExtraUsage: true,
                showServiceStatusDot: true,
                awaitingInputInMenuBar: false,   // calm look: awaiting hand stays in the popup only
                // The dropdown stays quiet too: per-model rows and the credits section appear only
                // once one of them turns orange/red (⌥ Option still reveals them on demand).
                modelLimitsVisibility: .nonCalm,
                extraUsageVisibility: .nonCalm,
                resetCountdownModeMenuBar: .smart,
                barStyle: .simple,
                showTicks: false,   // the quiet look drops the under-bar tick ruler too
                farBehindInterval: .off)   // …and no blue far-behind zone
        case .workHarder:
            // `.chill` with Work harder on and the **mixed** bar style (pace-only menu bar, pace & time
            // in the dropdown); far-behind blue stays coloured under calm colours; ticks on. When
            // blocked, keep the bars beside the pause icon.
            return AppearancePresetValues(
                calmColorMode: .yellowGreen,   // greens/yellows mute; far-behind blue stays coloured
                hideCalmSevenDayBar: true,
                pauseHidesBars: false,   // when blocked, keep the bars beside the pause icon
                showExtraUsage: true,
                showServiceStatusDot: true,
                awaitingInputInMenuBar: true,   // work harder: surface the awaiting hand in the menu bar
                // Same quiet dropdown as `.chill` — the extra loudness of this preset is in the menu
                // bar (blue far-behind, ticks), not in permanently expanded popup sections.
                modelLimitsVisibility: .nonCalm,
                extraUsageVisibility: .nonCalm,
                resetCountdownModeMenuBar: .smart,
                barStyle: .mixed,
                showTicks: true,
                farBehindInterval: .medium)
        case .controlFreak:
            // Show everything: calm off; nothing hidden; every glyph/dot/credits/per-model row on;
            // countdown always; dense pacing bars. Work harder on so the far-behind blue stays loud too.
            // When blocked, keep the bars beside the pause icon.
            return AppearancePresetValues(
                calmColorMode: .off,   // nothing muted — every state keeps its colour (loud)
                hideCalmSevenDayBar: false,
                pauseHidesBars: false,   // when blocked, keep the bars beside the pause icon
                showExtraUsage: true,
                showServiceStatusDot: true,
                awaitingInputInMenuBar: true,   // control freak: everything on, incl. the awaiting hand
                // Nothing in the dropdown is ever folded away — every row on screen, always.
                modelLimitsVisibility: .always,
                extraUsageVisibility: .always,
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

/// The twelve Appearance-pane values a preset sets, in the same **as-persisted** sense as
/// `PersistedConfig` (`hideCalmSevenDayBar` is the stored *hide* form, not the pane's inverted "Show …";
/// `pauseHidesBars` is stored as-is).
public struct AppearancePresetValues: Sendable, Equatable {
    public let calmColorMode: CalmColorMode
    public let hideCalmSevenDayBar: Bool
    /// When the user is fully blocked (`CreditsPacing.isBlocked`), whether the red pause icon **hides**
    /// the pacing bars (`true` → icon only) or keeps them beside it (`false` → icon + bars). The pause
    /// icon itself is always drawn when blocked, independent of this flag (#199, #227).
    public let pauseHidesBars: Bool
    public let showExtraUsage: Bool
    public let showServiceStatusDot: Bool
    /// Whether the awaiting-input `hand.raised` indicator is shown in the menu bar (#233). The popup
    /// always shows it while the feature is on; this only governs the menu-bar copy. Meaningful only
    /// when the master toggle (`awaitingInputEnabled`, in Extra features) is on.
    public let awaitingInputInMenuBar: Bool
    /// When the **dropdown** lists the per-model / per-service 7-day rows (#211). Was a boolean opt-out
    /// before the tri-state; the calmer presets now use `.nonCalm` so the rows surface only when one of
    /// them turns orange/red (or ⌥ is held).
    public let modelLimitsVisibility: PopupSectionVisibility
    /// When the **dropdown** shows the "Extra usage" credits section. Independent of
    /// ``showExtraUsage``, which governs the menu-bar credits icon.
    public let extraUsageVisibility: PopupSectionVisibility
    public let resetCountdownModeMenuBar: ResetCountdownMode
    public let barStyle: BarStyle
    public let showTicks: Bool
    public let farBehindInterval: FarBehindInterval

    public init(
        calmColorMode: CalmColorMode,
        hideCalmSevenDayBar: Bool,
        pauseHidesBars: Bool,
        showExtraUsage: Bool,
        showServiceStatusDot: Bool,
        awaitingInputInMenuBar: Bool,
        modelLimitsVisibility: PopupSectionVisibility,
        extraUsageVisibility: PopupSectionVisibility,
        resetCountdownModeMenuBar: ResetCountdownMode,
        barStyle: BarStyle,
        showTicks: Bool,
        farBehindInterval: FarBehindInterval
    ) {
        self.calmColorMode = calmColorMode
        self.hideCalmSevenDayBar = hideCalmSevenDayBar
        self.pauseHidesBars = pauseHidesBars
        self.showExtraUsage = showExtraUsage
        self.showServiceStatusDot = showServiceStatusDot
        self.awaitingInputInMenuBar = awaitingInputInMenuBar
        self.modelLimitsVisibility = modelLimitsVisibility
        self.extraUsageVisibility = extraUsageVisibility
        self.resetCountdownModeMenuBar = resetCountdownModeMenuBar
        self.barStyle = barStyle
        self.showTicks = showTicks
        self.farBehindInterval = farBehindInterval
    }
}
