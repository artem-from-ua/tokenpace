import AppKit

/// Every named UI colour the app draws, as a flat catalogue the dev color tuner (#185) can enumerate,
/// describe, and override live. Roles are **surface-neutral**: one role per semantic hue, shared by
/// both the menu bar and the popup (and by both pacing gaps and service-status dots). Each case carries
/// its shipped default, the functional group it belongs to, an exhaustive note of where it is drawn,
/// and — when the on-screen pixel is **not** the raw constant — a description of the transform our own
/// code applies on top (alpha, calm-mode swap).
///
/// The tuner reads this catalogue for its dropdown, its captions, and its reset-to-default action; the
/// two `Palette` enums read the *live* value for each role through ``ColorStore``. Outside a dev-tools
/// run (`devToolsEnabled` defaults key unset) the store always returns ``defaultColor``, so this type is inert on
/// a normal launch — it is purely a registry, it draws nothing itself.
///
/// Keep the raw values here in exact sync with the draw sites. When a `Palette` colour changes, change
/// its ``defaultColor`` here in the same commit.
enum ColorRole: String, CaseIterable {

    // MARK: Semantic hues — one role per hue, shared by BOTH surfaces (menu bar + popup) and by BOTH
    // pacing gaps AND service/status dots. `.system*` defaults flip light/dark + honour Increase Contrast.

    case green
    case yellow
    case orange
    case red
    case blue
    case gray

    // MARK: Bar / chrome — track, ring, ticks, pill fill (shared where identical across surfaces)

    // The neutral grey track of a pacing bar (both surfaces) — used head + future/unused tail, one flat
    // tone so both flanks read identical; also the blocked-idle fill. labelColor at 22 % alpha.
    case barTrack
    case indicatorRing
    case tick
    case centreTick
    case inUsePill

    // MARK: Text / foreground

    case foreground
    case dimmedLabel
    case label
    case link
    // White text drawn on the popup pills (both the "in use" and blocking-reset badge fills).
    case pillText

    // MARK: Calm mode (menu-bar)

    case calmWhite
    case idleCalmGrey

    // MARK: Brand (Claude accent stays sRGB)

    case claudeBrand

    // MARK: - Grouping

    enum Group: String, CaseIterable {
        case semantic = "Semantic colours"
        case chrome = "Bar / chrome"
        case text = "Text / foreground"
        case calm = "Calm mode"
        case brand = "Brand"
    }

    var group: Group {
        switch self {
        case .green, .yellow, .orange, .red, .blue, .gray:
            return .semantic
        case .barTrack, .indicatorRing, .tick, .centreTick, .inUsePill:
            return .chrome
        case .foreground, .dimmedLabel, .label, .link, .pillText:
            return .text
        case .calmWhite, .idleCalmGrey:
            return .calm
        case .claudeBrand:
            return .brand
        }
    }

    // MARK: - Display

    /// Human label for the dropdown; surface-neutral now that both surfaces share one role per hue.
    var displayName: String {
        switch self {
        case .green:         return "Green (on-pace / operational)"
        case .yellow:        return "Yellow (mild ahead / degraded)"
        case .orange:        return "Orange (strong ahead / partial outage)"
        case .red:           return "Red (exhausted / major outage)"
        case .blue:          return "Blue (far behind / idle / maintenance)"
        case .gray:          return "Grey (unknown status)"
        case .barTrack:      return "Bar track"
        case .indicatorRing: return "Indicator ring"
        case .tick:          return "Tick ruler"
        case .centreTick:    return "Gauge centre tick"
        case .inUsePill:     return "\"In use\" pill"
        case .foreground:    return "Foreground"
        case .dimmedLabel:   return "Dimmed label"
        case .label:         return "Label"
        case .link:          return "Link"
        case .pillText:      return "Pill text"
        case .calmWhite:     return "Calm neutral"
        case .idleCalmGrey:  return "Idle calm grey"
        case .claudeBrand:   return "Claude brand"
        }
    }

    /// Exhaustive note of where this colour is drawn — the caption shown beside the picker.
    var usageDescription: String {
        switch self {
        case .green:
            return "On-pace / behind pacing gap AND the time-indicator marker in that state, on both the "
                 + "menu bar and popup; also the credits ¤ icon and the operational service-status dot."
        case .yellow:
            return "Mild ahead-of-pace pacing gap / marker (lead below the dynamic threshold) on both "
                 + "surfaces, and the degraded service-status dot."
        case .orange:
            return "Strong ahead-of-pace pacing gap / marker (lead at/above threshold, or little time to "
                 + "reset) on both surfaces; and the partial-outage service dot."
        case .red:
            return "Exhausted-limit pacing gap / marker on both surfaces; the major-outage service dot "
                 + "(and the update-menu \"update failed\" dot); the blocking reset-time pill; the popup ⚠️ "
                 + "error banner text; and the menu-bar blocked pause glyph."
        case .blue:
            return "Every blue in the widget, on both surfaces: the far-behind pacing gap / marker "
                 + "(surplus above the behind-threshold, past the 20-min start override, base 5h/7d rows "
                 + "only); the idle 5-hour bar fill (ready to start); the maintenance service dot (and "
                 + "the update-menu \"new version available\" dot). The pacing blue used to be a separate "
                 + "`paceBlue` role, but both defaulted to the same system blue and the split only let "
                 + "one drift from the other."
        case .gray:
            return "Unknown / operational service-status dot on both surfaces."
        case .barTrack:
            return "The neutral grey track of a pacing bar on both surfaces — the whole-bar background "
                 + "under the coloured gap (used head + future/unused tail), plus the blocked-idle fill. "
                 + "One flat tone so both flanks read identical. labelColor at 22 % alpha."
        case .indicatorRing:
            return "Edge outline down the time-indicator marker's left/right sides, only where it overlaps "
                 + "the bar, on both surfaces. Default quaternaryLabelColor."
        case .tick:
            return "Tick-ruler marks below the popup bar. Default tertiaryLabelColor."
        case .centreTick:
            return "The Gauge style's centre tick on the MENU BAR only (#326) — the fixed zero its "
                 + "ribbon grows out of, drawn 1 pt wide under the track so only its ends show. The "
                 + "popup's Gauge tick is the ruler above, not this. Default secondaryLabelColor: "
                 + "brighter than the ruler, because on a 34 pt bar every reading is relative to it."
        case .inUsePill:
            return "Popup \"in use\" plaque beside the Extra usage heading while credits are actively "
                 + "spending (#146, #254). The currency glyph is knocked out of this fill, so the popup "
                 + "background shows through the symbol. Default labelColor — deliberately not a status "
                 + "colour: it states a mode, not a severity (ADR-0068)."
        case .foreground:
            return "Menu-bar idle glyph, reset label, and the ⚠️ palette glyph. Follows labelColor "
                 + "(re-alpha'd by bright())."
        case .dimmedLabel:
            return "Popup secondary / dimmed labels."
        case .label:
            return "Popup primary titles and value text. Default labelColor."
        case .link:
            return "Popup service-status word rendered as a link to the status page. Default linkColor."
        case .pillText:
            return "White text on the popup pills — the \"active\" in-use badge (#146) and the blocking "
                 + "reset-time badge (#158). Drawn on both the blue and red pill fills. Default white."
        case .calmWhite:
            return "Calm-mode neutral for on-pace marker / gap / credits / degraded status dot in the "
                 + "menu bar. Follows labelColor (re-alpha'd by bright())."
        case .idleCalmGrey:
            return "Calm-mode replacement for the idle blue on a ready idle bar."
        case .claudeBrand:
            return "Popup \"Claude Code\" header accent (#d97757)."
        }
    }

    /// When our code distorts this colour before drawing, describe the transform — the tuner surfaces
    /// this prominently so it's clear the on-screen pixel is **not** the raw value picked here. `nil`
    /// means the colour is drawn as-is.
    var distortion: String? {
        switch self {
        case .green, .yellow, .orange, .red, .blue, .gray,
             .indicatorRing, .tick, .centreTick, .inUsePill, .link, .label, .foreground,
             .calmWhite, .idleCalmGrey:
            return "Default is a dynamic system colour (flips light/dark, honours Increase Contrast); "
                 + "a picked colour replaces it flat and loses that adaptation."
        case .barTrack:
            return "Default is labelColor at 22 % alpha — translucent, so it composites against the bar's "
                 + "material (it breathes the wallpaper / menu tint); a picked colour replaces it flat and "
                 + "loses that adaptation."
        case .dimmedLabel:
            return "Default is tertiaryLabelColor blended 50 % toward secondaryLabelColor (per-appearance)."
        case .claudeBrand, .pillText:
            return nil
        }
    }

    // MARK: - Shipped defaults

    @MainActor
    var defaultColor: NSColor {
        switch self {
        // One flat catalogue shared by BOTH surfaces (menu bar + popup). The semantic hues are system
        // colours only, so they flip light/dark and carry accessibility (Increase Contrast) variants
        // automatically, like the battery/Wi-Fi icons — no fixed sRGB, no theme-specific tones. The bar
        // **track** is `labelColor` at 22 % alpha (translucent — dims *and* breathes the wallpaper/menu
        // material); the **bright** mono tones (reset text, ⚠️, tick) are `labelColor` re-alpha'd at the
        // draw site to the system text opacity (`StatusItemView.bright(_:)`). Claude brand is the one
        // deliberate sRGB constant (no system twin for the terracotta).
        case .green:         return .systemGreen
        case .yellow:        return .systemYellow
        case .orange:        return .systemOrange
        case .red:           return .systemRed
        case .blue:          return .systemBlue
        case .gray:          return .systemGray
        case .barTrack:      return NSColor.labelColor.withAlphaComponent(0.22)   // the moon: a ~22% labelColor silhouette; the bar shows through 78%, so it dims AND breathes the wallpaper/menu tint
        case .indicatorRing: return .quaternaryLabelColor
        case .tick:          return .tertiaryLabelColor
        case .centreTick:    return .secondaryLabelColor
        case .inUsePill:     return .labelColor           // #254: a mode marker, not a status colour
        case .foreground:    return .labelColor            // reset text / ⚠️ — re-alpha'd by bright()
        case .dimmedLabel:   return PopupViewController.defaultDimmedLabel
        case .label:         return .labelColor
        case .link:          return .linkColor
        case .pillText:      return .white
        case .calmWhite:     return .labelColor            // calm neutral — re-alpha'd by bright()
        case .idleCalmGrey:  return .secondaryLabelColor   // calm idle track — quiet, still flips
        case .claudeBrand:   return NSColor(srgbRed: 0xd9/255, green: 0x77/255, blue: 0x57/255, alpha: 1)
        }
    }
}
