import AppKit

/// Every named UI colour the app draws, as a flat catalogue the dev color tuner (#185) can enumerate,
/// describe, and override live. Each case carries its shipped default (mirroring the literal that used
/// to live in the two private `Palette` enums), the functional group it belongs to, an exhaustive note
/// of where it is drawn, and — when the on-screen pixel is **not** the raw constant — a description of
/// the transform our own code applies on top (lighten, desaturate, alpha, calm-mode swap).
///
/// The tuner reads this catalogue for its dropdown, its captions, and its reset-to-default action; the
/// two `Palette` enums read the *live* value for each role through ``ColorStore``. Outside a dev-tools
/// run (`devToolsEnabled` defaults key unset) the store always returns ``defaultColor``, so this type is inert on
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
    // Orange "pause" glyph drawn left of the bars when fully blocked and the bars are kept visible.
    case menuPauseOrange
    // Menu-bar ahead-of-pace pacing (previously shared with the popup via aheadColor; now independent).
    case menuGapRed
    case menuGapYellow
    case menuGapOrange

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
    case popupWarningRed
    case popupInUsePill
    case popupLink
    case popupLabel
    // Popup service-status dots — appearance-aware `.system*`, distinct from the fixed-sRGB menu dots.
    case popupServiceGreen
    case popupServiceYellow
    case popupServiceOrange
    case popupServiceRed
    case popupServiceBlue
    case popupServiceGray

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
        case .menuGapGreen, .menuDotGreen, .menuGapRed, .menuGapYellow, .menuGapOrange,
             .popupGapGreen, .popupGapRed, .popupGapYellow, .popupGapOrange:
            return .pacing
        case .menuStatusYellow, .menuStatusOrange, .menuStatusRed, .menuStatusBlue, .menuStatusGray,
             .menuPauseOrange,
             .popupServiceGreen, .popupServiceYellow, .popupServiceOrange,
             .popupServiceRed, .popupServiceBlue, .popupServiceGray,
             .popupWarningRed:
            return .service
        case .menuIndicatorStroke, .menuIdleBlue, .popupIdleBlue,
             .popupIndicatorStroke, .popupTick, .popupMonochromeGrey, .popupInUsePill:
            return .chrome
        case .menuForeground, .popupDimmedLabel, .popupLink, .popupLabel:
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
        case .menuPauseOrange:     return "Menu-bar · blocked pause"
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
        case .menuGapRed:          return "Menu-bar · gap red"
        case .menuGapYellow:       return "Menu-bar · gap yellow (amber)"
        case .menuGapOrange:       return "Menu-bar · gap orange"
        case .popupWarningRed:     return "Popup · warning red (⚠️)"
        case .popupInUsePill:      return "Popup · \"in use\" pill"
        case .popupLink:           return "Popup · link"
        case .popupLabel:          return "Popup · label"
        case .popupServiceGreen:   return "Popup · service green (operational)"
        case .popupServiceYellow:  return "Popup · service yellow (degraded)"
        case .popupServiceOrange:  return "Popup · service orange (partial outage)"
        case .popupServiceRed:     return "Popup · service red (major outage)"
        case .popupServiceBlue:    return "Popup · service blue (maintenance)"
        case .popupServiceGray:    return "Popup · service grey (unknown)"
        }
    }

    /// Exhaustive note of where this colour is drawn — the caption shown beside the picker.
    var usageDescription: String {
        switch self {
        case .menuGapGreen:
            return "Menu-bar pacing gap when on pace or behind (via calmedGapColor). Ahead-of-pace "
                 + "colours are the separate Menu-bar gap red/yellow/orange roles."
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
        case .menuPauseOrange:
            return "Menu-bar orange pause glyph drawn left of the bars when all limits are gone "
                 + "(CreditsPacing.isBlocked) and the bars are kept visible in that state (#199)."
        case .popupGapGreen:
            return "Popup bar pacing gap and indicator when on pace. Default is systemGreen."
        case .popupIdleBlue:
            return "Popup idle 5-hour bar fill (ready-to-start). Blocked idle uses the base grey instead."
        case .popupGapRed:
            return "Popup pacing gap when the limit is exhausted; also the blocking reset-time pill (#158)."
        case .popupGapYellow:
            return "Popup pacing gap for a mild ahead-of-pace lead (< threshold)."
        case .popupGapOrange:
            return "Popup pacing gap for a strong ahead-of-pace lead / little time to reset."
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
        case .menuGapRed:
            return "Menu-bar pacing gap / indicator when the limit is exhausted (ahead-of-pace red)."
        case .menuGapYellow:
            return "Menu-bar pacing gap / indicator for a mild ahead-of-pace lead (< threshold)."
        case .menuGapOrange:
            return "Menu-bar pacing gap / indicator for a strong ahead-of-pace lead / little time to reset."
        case .popupWarningRed:
            return "Popup error banner: the ⚠️ title and message text when a poll is failing. Default systemRed."
        case .popupInUsePill:
            return "Popup \"in use\" pill fill beside the header when credits are actively spending (#146). "
                 + "Default controlAccentColor."
        case .popupLink:
            return "Popup service-status word rendered as a link to the status page. Default linkColor."
        case .popupLabel:
            return "Popup primary titles and value text. Default labelColor."
        case .popupServiceGreen:
            return "Popup service-status dot: operational. Default systemGreen."
        case .popupServiceYellow:
            return "Popup service-status dot: degraded. Default systemYellow."
        case .popupServiceOrange:
            return "Popup service-status dot: partial outage. Default systemOrange."
        case .popupServiceRed:
            return "Popup service-status dot: major outage. Default systemRed."
        case .popupServiceBlue:
            return "Popup service-status dot: under maintenance. Default systemBlue."
        case .popupServiceGray:
            return "Popup service-status dot: unknown. Default systemGray."
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
        case .menuGapRed, .menuGapYellow, .menuGapOrange:
            return "Lightened ~10% toward white at the menu-bar draw site (aheadColor → lightened)."
        case .popupIndicatorStroke:
            return "Default carries alpha (0.4 dark / 0.65 light) and is appearance-aware; a picked colour "
                 + "replaces the provider flat."
        case .popupTick, .popupMonochromeGrey:
            return "Default is appearance-aware (per-theme grey); a picked colour replaces the provider flat."
        case .popupDimmedLabel:
            return "Default is tertiaryLabelColor blended 50% toward secondaryLabelColor (per-appearance)."
        case .menuForeground:
            return "Default is the dynamic labelColor; a picked colour replaces it flat."
        case .popupLink, .popupLabel, .popupInUsePill, .popupWarningRed,
             .popupServiceGreen, .popupServiceYellow, .popupServiceOrange,
             .popupServiceRed, .popupServiceBlue, .popupServiceGray:
            return "Default is a dynamic system colour; a picked colour replaces it flat."
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
        case .menuPauseOrange:     return NSColor(srgbRed: 240/255, green: 140/255, blue: 40/255, alpha: 1)
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
        // Menu-bar ahead-of-pace pacing — start from the same values the popup uses (they were shared
        // until now); tune independently from here. Fixed sRGB (non-template menu-bar image).
        case .menuGapRed:          return NSColor(srgbRed: 225/255, green: 45/255, blue: 35/255, alpha: 1)
        case .menuGapYellow:       return NSColor(srgbRed: 230/255, green: 180/255, blue: 25/255, alpha: 1)
        case .menuGapOrange:       return NSColor(srgbRed: 248/255, green: 118/255, blue: 15/255, alpha: 1)
        // Popup extras / system colours.
        case .popupWarningRed:     return .systemRed
        case .popupInUsePill:      return .controlAccentColor
        case .popupLink:           return .linkColor
        case .popupLabel:          return .labelColor
        case .popupServiceGreen:   return .systemGreen
        case .popupServiceYellow:  return .systemYellow
        case .popupServiceOrange:  return .systemOrange
        case .popupServiceRed:     return .systemRed
        case .popupServiceBlue:    return .systemBlue
        case .popupServiceGray:    return .systemGray
        }
    }
}
