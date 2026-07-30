import AppKit

/// Every named UI colour the app draws, as a flat catalogue the dev color tuner (#185) can enumerate,
/// describe, and override live. Each case carries its shipped default (mirroring the literal that used
/// to live in the two private `Palette` enums), the functional group it belongs to, an exhaustive note
/// of where it is drawn, and — when the on-screen pixel is **not** the raw constant — a description of
/// the transform our own code applies on top (lighten, desaturate, alpha, calm-mode swap).
///
/// The tuner reads this catalogue for its dropdown, its captions, and its reset-to-default action; the
/// two `Palette` enums read the *live* value for each role through ``ColorStore``. Outside a dev-tools
/// run (`TOKENPACE_DEVTOOLS` unset) the store always returns ``defaultColor``, so this type is inert on
/// a normal launch — it is purely a registry, it draws nothing itself.
///
/// Keep the raw values here in exact sync with the draw sites. When a `Palette` colour changes, change
/// its ``defaultColor`` here in the same commit.
enum ColorRole: String, CaseIterable {

    // MARK: Menu-bar palette (StatusItemView) — fixed sRGB, non-template image

    case menuGapGreen
    case menuDotGreen
    case menuIndicatorStroke
    case menuIdleBlue
    case menuIdleCalmGrey
    case menuForeground
    case menuCalmWhite
    case menuStatusYellow
    case menuStatusOrange
    case menuStatusRed
    case menuStatusBlue
    case menuStatusGray

    // MARK: Popup palette (PopupBarView) — appearance-aware / system, except the three ahead sRGB

    case popupGapGreen
    case popupIdleBlue
    case popupGapRed
    case popupGapYellow
    case popupGapOrange
    case popupIndicatorStroke
    case popupTick
    case popupMonochromeGrey

    // MARK: Popup extras (outside the Palette enum)

    case popupClaudeBrand
    case popupDimmedLabel

    // MARK: - Grouping

    enum Group: String, CaseIterable {
        case pacing = "Pacing"
        case service = "Service status"
        case chrome = "Chrome / background"
        case text = "Text / foreground"
        case calm = "Calm mode"
        case brand = "Brand"
    }

    var group: Group {
        switch self {
        case .menuGapGreen, .menuDotGreen, .popupGapGreen,
             .popupGapRed, .popupGapYellow, .popupGapOrange:
            return .pacing
        case .menuStatusYellow, .menuStatusOrange, .menuStatusRed, .menuStatusBlue, .menuStatusGray:
            return .service
        case .menuIndicatorStroke, .menuIdleBlue, .popupIdleBlue,
             .popupIndicatorStroke, .popupTick, .popupMonochromeGrey:
            return .chrome
        case .menuForeground, .popupDimmedLabel:
            return .text
        case .menuIdleCalmGrey, .menuCalmWhite:
            return .calm
        case .popupClaudeBrand:
            return .brand
        }
    }

    // MARK: - Display

    /// Human label for the dropdown, prefixed by surface so the two palettes never collide by eye.
    var displayName: String {
        switch self {
        case .menuGapGreen:        return "Menu-bar · gap green"
        case .menuDotGreen:        return "Menu-bar · dot green"
        case .menuIndicatorStroke: return "Menu-bar · indicator ring"
        case .menuIdleBlue:        return "Menu-bar · idle blue"
        case .menuIdleCalmGrey:    return "Menu-bar · idle calm grey"
        case .menuForeground:      return "Menu-bar · foreground"
        case .menuCalmWhite:       return "Menu-bar · calm white"
        case .menuStatusYellow:    return "Menu-bar · status yellow (degraded)"
        case .menuStatusOrange:    return "Menu-bar · status orange (partial outage)"
        case .menuStatusRed:       return "Menu-bar · status red (major outage)"
        case .menuStatusBlue:      return "Menu-bar · status blue (maintenance)"
        case .menuStatusGray:      return "Menu-bar · status grey (unknown / operational)"
        case .popupGapGreen:       return "Popup · gap green"
        case .popupIdleBlue:       return "Popup · idle blue"
        case .popupGapRed:         return "Popup · gap red"
        case .popupGapYellow:      return "Popup · gap yellow (amber)"
        case .popupGapOrange:      return "Popup · gap orange"
        case .popupIndicatorStroke: return "Popup · indicator ring"
        case .popupTick:           return "Popup · tick ruler"
        case .popupMonochromeGrey: return "Popup · base grey"
        case .popupClaudeBrand:    return "Popup · Claude brand"
        case .popupDimmedLabel:    return "Popup · dimmed label"
        }
    }

    /// Exhaustive note of where this colour is drawn — the caption shown beside the picker.
    var usageDescription: String {
        switch self {
        case .menuGapGreen:
            return "Menu-bar pacing gap when on pace or behind (via calmedGapColor). Ahead-of-pace "
                 + "colours come from the popup palette through PopupBarView.aheadColor, not here."
        case .menuDotGreen:
            return "Menu-bar time-indicator dot when on pace; also the credits ¤ icon when on pace / behind."
        case .menuIndicatorStroke:
            return "Dark ring stroked around the menu-bar time-indicator dot."
        case .menuIdleBlue:
            return "Solid fill of the idle 5-hour menu-bar bar (ready-to-start, full quota)."
        case .menuIdleCalmGrey:
            return "Calm-mode replacement for the idle blue on a ready idle bar."
        case .menuForeground:
            return "Menu-bar idle glyph, reset label, and the ⚠️ palette glyph. Follows labelColor by default."
        case .menuCalmWhite:
            return "Calm-mode colour for on-pace dot / gap / credits / degraded status dot in the menu bar."
        case .menuStatusYellow:
            return "Menu-bar service-status dot: degraded (non-calm)."
        case .menuStatusOrange:
            return "Menu-bar service-status dot: partial outage."
        case .menuStatusRed:
            return "Menu-bar service-status dot: major outage."
        case .menuStatusBlue:
            return "Menu-bar service-status dot: under maintenance."
        case .menuStatusGray:
            return "Menu-bar service-status dot: unknown / operational."
        case .popupGapGreen:
            return "Popup bar pacing gap and indicator when on pace. Default is systemGreen."
        case .popupIdleBlue:
            return "Popup idle 5-hour bar fill (ready-to-start). Blocked idle uses the base grey instead."
        case .popupGapRed:
            return "Popup pacing gap when the limit is exhausted; also the blocking reset-time pill (#158). "
                 + "Shared with the menu bar via PopupBarView.aheadColor."
        case .popupGapYellow:
            return "Popup pacing gap for a mild ahead-of-pace lead (< threshold). Shared with the menu bar."
        case .popupGapOrange:
            return "Popup pacing gap for a strong ahead-of-pace lead / little time to reset. Shared with the menu bar."
        case .popupIndicatorStroke:
            return "Soft ring stroked around the popup indicator dot."
        case .popupTick:
            return "Tick-ruler marks below the popup bar."
        case .popupMonochromeGrey:
            return "Popup + menu-bar bar base zones (used + future/unused). Also blocked idle fill."
        case .popupClaudeBrand:
            return "Popup \"Claude Code\" header accent (#d97757)."
        case .popupDimmedLabel:
            return "Popup secondary / dimmed labels."
        }
    }

    /// When our code distorts this colour before drawing, describe the transform — the tuner surfaces
    /// this prominently so it's clear the on-screen pixel is **not** the raw value picked here. `nil`
    /// means the colour is drawn as-is.
    var distortion: String? {
        switch self {
        case .menuGapGreen:
            return "Lightened ~10% toward white at the draw site (calmedGapColor → lightened)."
        case .menuDotGreen:
            return "Lightened ~10% toward white when used as the on-pace indicator dot (not for the credits icon)."
        case .menuIdleBlue:
            return "The idle 5-hour bar; swapped for the calm grey under Calm colours (not blended)."
        case .popupIdleBlue:
            return "Default is systemBlue desaturated ~15% toward grey, and additionally ~22% toward white "
                 + "on the light theme (computed per-appearance). A picked colour replaces this provider flat."
        case .popupGapRed, .popupGapYellow, .popupGapOrange:
            return "Drawn as-is in the popup; lightened ~10% when it reaches the menu bar via aheadColor."
        case .popupIndicatorStroke:
            return "Default carries alpha (0.4 dark / 0.65 light) and is appearance-aware; a picked colour "
                 + "replaces the provider flat."
        case .popupTick, .popupMonochromeGrey:
            return "Default is appearance-aware (per-theme grey); a picked colour replaces the provider flat."
        case .popupDimmedLabel:
            return "Default is tertiaryLabelColor blended 50% toward secondaryLabelColor (per-appearance)."
        case .menuForeground:
            return "Default is the dynamic labelColor; a picked colour replaces it flat."
        default:
            return nil
        }
    }

    // MARK: - Shipped defaults (mirror the Palette literals 1:1)

    @MainActor
    var defaultColor: NSColor {
        switch self {
        // Menu-bar palette (StatusItemView.swift) — fixed sRGB.
        case .menuGapGreen:        return NSColor(srgbRed: 95/255, green: 175/255, blue: 95/255, alpha: 1)
        case .menuDotGreen:        return NSColor(srgbRed: 143/255, green: 199/255, blue: 143/255, alpha: 1)
        case .menuIndicatorStroke: return NSColor(srgbRed: 24/255, green: 24/255, blue: 24/255, alpha: 1)
        case .menuIdleBlue:        return NSColor(srgbRed: 85/255, green: 130/255, blue: 180/255, alpha: 1)
        case .menuIdleCalmGrey:    return NSColor(srgbRed: 150/255, green: 150/255, blue: 150/255, alpha: 1)
        case .menuForeground:      return .labelColor
        case .menuCalmWhite:       return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case .menuStatusYellow:    return NSColor(srgbRed: 240/255, green: 190/255, blue: 50/255, alpha: 1)
        case .menuStatusOrange:    return NSColor(srgbRed: 240/255, green: 140/255, blue: 40/255, alpha: 1)
        case .menuStatusRed:       return NSColor(srgbRed: 225/255, green: 70/255, blue: 70/255, alpha: 1)
        case .menuStatusBlue:      return NSColor(srgbRed: 70/255, green: 140/255, blue: 230/255, alpha: 1)
        case .menuStatusGray:      return NSColor(srgbRed: 150/255, green: 150/255, blue: 150/255, alpha: 1)
        // Popup palette (PopupViewController.swift) — system / appearance-aware defaults.
        case .popupGapGreen:       return .systemGreen
        case .popupIdleBlue:       return PopupBarView.defaultIdleBlue
        case .popupGapRed:         return NSColor(srgbRed: 225/255, green: 45/255, blue: 35/255, alpha: 1)
        case .popupGapYellow:      return NSColor(srgbRed: 230/255, green: 180/255, blue: 25/255, alpha: 1)
        case .popupGapOrange:      return NSColor(srgbRed: 248/255, green: 118/255, blue: 15/255, alpha: 1)
        case .popupIndicatorStroke: return PopupBarView.defaultIndicatorStroke
        case .popupTick:           return PopupBarView.defaultTick
        case .popupMonochromeGrey: return PopupBarView.defaultMonochromeGrey
        case .popupClaudeBrand:    return NSColor(srgbRed: 0xd9/255, green: 0x77/255, blue: 0x57/255, alpha: 1)
        case .popupDimmedLabel:    return PopupViewController.defaultDimmedLabel
        }
    }
}
