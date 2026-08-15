import Foundation

// MARK: - AppearancePreset (#215)

/// A named, one-click bundle of every **Appearance** pane setting — the menu-bar widget toggles, the
/// the bar presentation style of each surface, and the dropdown's section
/// visibility (#215, #224, #329).
/// Generalises the single "Reset to defaults" row from #214: `.chill` is the calm, quiet look
/// (simplified bars), `.workHarder` is `.chill` plus the coloured far-behind blue, `.controlFreak`
/// turns everything on (dense pacing bars). Applying a preset writes all seven keys at once via
/// `PersistedConfig.apply(_:)`.
///
/// Each preset picks **one** ``BarStyle`` and gives it to both surfaces (#329) — the presets are the
/// three coherent looks, so a preset that disagreed with itself across the menu bar and the dropdown
/// would be a fourth. Mixing the two surfaces is exactly what dropping out to "Custom" is for.
///
/// The preset **values** live here in the kit (not the AppKit/SwiftUI shell) so they are unit-testable
/// without a UI. The shell owns only presentation: the segmented control that calls `apply` and the
/// ``displayName`` shown on it. ``matching(_:)`` powers the control's "Custom" indicator segment: it
/// lights up when the live config matches no preset.
public enum AppearancePreset: String, Sendable, CaseIterable {
    /// The calm, quiet look: every menu-bar toggle calm and the left-anchored
    /// **Pressure** ribbon on both surfaces (#224) — the quietest of the three styles, since every
    /// calm state collapses onto one minimum pill.
    case chill = "chill"
    /// Exactly `.chill`, but with **Work harder** on: the far-behind blue stays coloured under calm
    /// colours (a nudge that you're well under pace) while everything else stays calm. Sits between
    /// `.chill` and `.controlFreak`. The **default** preset, and so the source of every Appearance
    /// default — including **Gauge** bars on both surfaces (#329).
    case workHarder = "workHarder"
    /// Everything on and loud: calm colours off, all bars/dots/glyphs shown, the dropdown's credits and
    /// per-model sections pinned open (`.always`), and the dense
    /// **Progress** bars with the time marker (#224).
    case controlFreak = "controlFreak"

    /// The fixed value set this preset writes to the seven Appearance keys. Stored in the **as-persisted**
    /// sense, matching `PersistedConfig`. Since ADR-0086 every value here is stored exactly as the pane
    /// shows it — the old `hideCalmSevenDayBar` was the last inverted one ("Show …" in the UI, *hide* in
    /// storage), and its tri-state replacement `calmBarHiding` names the hidden bar directly.
    public var values: AppearancePresetValues {
        switch self {
        case .chill:
            // The calm look: per-model rows on, simplified bars, and — when fully
            // blocked — only the red pause icon (bars hidden). Work harder off — the far-behind blue
            // mutes with the rest of the calm colours.
            return AppearancePresetValues(
                calmColorMode: .yellowGreenBlue,   // greens/yellows AND far-behind blue all mute
                calmBarHiding: .fiveHour,   // quiet 5h steps aside; the weekly bar is the one that stays
                showServiceStatusDot: true,
                // The dropdown stays quiet too, but the two groups are quiet about different things:
                // per-model rows wait for orange/red, credits only for the first cent actually spent
                // (money has no calm/loud reading, and an unlimited cap has no severity at all).
                // ⌥ Option still reveals either on demand.
                modelLimitsVisibility: .nonCalm,
                extraUsageVisibility: .aboveZero,
                menuBarStyle: .pressure,
                dropdownStyle: .pressure)
        case .workHarder:
            // `.chill` with Work harder on and **Gauge** bars on both surfaces (#329) — the style that
            // renders the underpace half, so an unspendable surplus is visible rather than flattened;
            // far-behind blue stays coloured under calm colours. When blocked, keep the bars
            // beside the pause icon.
            return AppearancePresetValues(
                calmColorMode: .yellowGreen,   // greens/yellows mute; far-behind blue stays coloured
                calmBarHiding: .fiveHour,   // same quiet default as `.chill` — and the factory default
                showServiceStatusDot: true,
                // Same quiet dropdown as `.chill` — the extra loudness of this preset is in the menu
                // bar (blue far-behind), not in permanently expanded popup sections.
                modelLimitsVisibility: .nonCalm,
                extraUsageVisibility: .aboveZero,
                menuBarStyle: .gauge,
                dropdownStyle: .gauge)
        case .controlFreak:
            // Show everything: calm off; nothing hidden; every glyph/dot/credits/per-model row on;
            // dense pacing bars. Work harder on so the far-behind blue stays loud too.
            // When blocked, keep the bars beside the pause icon.
            return AppearancePresetValues(
                calmColorMode: .off,   // nothing muted — every state keeps its colour (loud)
                calmBarHiding: .never,   // both bars always on screen, however calm
                showServiceStatusDot: true,
                // Nothing in the dropdown is ever folded away — every row on screen, always.
                modelLimitsVisibility: .always,
                extraUsageVisibility: .always,
                menuBarStyle: .progress,
                dropdownStyle: .progress)
        }
    }

    /// The radio label shown in Settings → Appearance. English UI string.
    public var displayName: String {
        switch self {
        case .chill:        return "Chill"
        case .workHarder:   return "Work harder!"
        case .controlFreak: return "Control freak"
        }
    }

    /// The line under the radio label: **which signals this preset makes loudest**, which is the one
    /// question three adjective-like names cannot answer on their own (`Chill` vs `Work harder!` reads
    /// as a mood, not as a behaviour).
    ///
    /// Each sentence describes what the user will *see*, derived from ``values`` rather than from the
    /// preset's mood — a description that outran the value set would be worse than none:
    ///
    /// - `.chill` mutes every calm colour (`.yellowGreenBlue`), hides the quiet 5-hour bar and keeps the
    ///   per-model rows folded until one turns orange (`.nonCalm`), so nothing speaks until a limit
    ///   actually presses.
    /// - `.workHarder` differs from `.chill` in exactly two things, and both are about seeing the
    ///   *underspend*: the far-behind blue stays coloured (`.yellowGreen`), and `Gauge` draws the
    ///   below-pace half instead of flattening it to a minimum pill.
    /// - `.controlFreak` turns muting off entirely, pins both bars on screen (`.never`) and both popup
    ///   sections open (`.always`).
    /// Each line describes **behaviour the user can picture**, and each stands on its own: an earlier
    /// draft of `.workHarder` opened "Like Chill, but…", which made the middle option unreadable
    /// without first reading the one above it — in a list, every entry is someone's first.
    ///
    /// `.controlFreak` states the trade rather than only the benefit. Turning off every mute is what
    /// puts the whole picture on screen, and it is also what makes the picture take longer to read:
    /// when nothing is quiet, nothing stands out. Naming that is the difference between a description
    /// and a sales pitch.
    ///
    /// It deliberately does **not** promise "the full picture without holding ⌥". The modifier reveals
    /// hidden rows and captions; it never swaps the bar style, so a Pressure bar stays Pressure under
    /// ⌥ — a line implying otherwise would describe a swap the key does not perform.
    public var summary: String {
        switch self {
        case .chill:
            return "Stays quiet until a limit actually needs your attention."
        case .workHarder:
            return "Quiet too, but tells you when you're leaving tokens unused."
        case .controlFreak:
            return "Maximum info, but signals take a bit longer to spot."
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

/// The seven Appearance-pane values a preset sets, in the same **as-persisted** sense as
/// `PersistedConfig` — which is also exactly what each pane row shows (the inverted
/// `hideCalmSevenDayBar` was the last exception, retired with ADR-0086).
public struct AppearancePresetValues: Sendable, Equatable {
    public let calmColorMode: CalmColorMode
    /// Which menu-bar bar steps aside while it is calm (ADR-0086). Replaced the boolean that could only
    /// hide the 7-day one; the calmer presets now hide the **5-hour** bar, so the weekly context is what
    /// stays on screen when nothing needs attention.
    public let calmBarHiding: CalmBarHiding
    public let showServiceStatusDot: Bool
    /// When the **dropdown** lists the per-model / per-service 7-day rows (#211). Was a boolean opt-out
    /// before the tri-state; the calmer presets now use `.nonCalm` so the rows surface only when one of
    /// them turns orange/red (or ⌥ is held).
    public let modelLimitsVisibility: PopupSectionVisibility
    /// When the **dropdown** shows the "Extra usage" credits section. Independent of
    /// the menu-bar credits icon, which is data-driven and has no user gate (ADR-0090).
    public let extraUsageVisibility: PopupSectionVisibility
    /// How the **menu-bar** widget draws its bars (#329). Chosen independently of ``dropdownStyle``:
    /// the compact bar and the roomy popup can carry different presentations, which is what the old
    /// single `barStyle` key could only express through its one `mixed` case.
    public let menuBarStyle: BarStyle
    /// How the **dropdown** popup draws its bars (#329). Also decides that surface's tick ruler —
    /// window subdivisions off the window scale mean nothing, so the ruler falls back to the one
    /// landmark the chosen scale has. The ruler itself is not optional: it draws in every dropdown
    /// bar, and the style only picks which landmarks it carries.
    public let dropdownStyle: BarStyle

    public init(
        calmColorMode: CalmColorMode,
        calmBarHiding: CalmBarHiding,
        showServiceStatusDot: Bool,
        modelLimitsVisibility: PopupSectionVisibility,
        extraUsageVisibility: PopupSectionVisibility,
        menuBarStyle: BarStyle,
        dropdownStyle: BarStyle
    ) {
        self.calmColorMode = calmColorMode
        self.calmBarHiding = calmBarHiding
        self.showServiceStatusDot = showServiceStatusDot
        self.modelLimitsVisibility = modelLimitsVisibility
        self.extraUsageVisibility = extraUsageVisibility
        self.menuBarStyle = menuBarStyle
        self.dropdownStyle = dropdownStyle
    }
}
