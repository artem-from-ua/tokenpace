import AppKit

/// Every named UI colour the app draws, as one flat catalogue both surfaces read from.
///
/// Roles are **surface-neutral**: one role per semantic hue, shared by the menu bar and the popup
/// (and by both pacing gaps and service-status dots), so the two surfaces cannot drift apart. The
/// two private `Palette` enums (`StatusItemView.Palette`, `PopupViewController.Palette`) are thin
/// aliases over ``defaultColor`` — this type is the single storage site for a colour value, and
/// `Settings` reads it directly too (`AboutPane`'s update dots, the Claude row badge).
///
/// The roles stay separate because they name **different signals**, not because a tool once put a
/// slider on each: the live colour tuner that introduced this catalogue was removed in ADR-0106,
/// and the roles outlived it on their own merits.
///
/// Keep the values here in exact sync with what the draw sites expect — this is the only copy.
enum ColorRole {

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

    // MARK: Brand (Claude accent stays sRGB)

    case claudeBrand

    // MARK: - Shipped defaults

    /// The colour each role draws as.
    ///
    /// `@MainActor` because `.dimmedLabel` resolves through `PopupViewController.defaultDimmedLabel`,
    /// which is MainActor-isolated — **not** a leftover of the removed override layer. Both `Palette`
    /// enums carry the annotation for the same reason; dropping it is a build error, not a cleanup.
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
        case .centreTick:    return .labelColor           // the calm fill's tone (see .calmWhite) — re-alpha'd by bright() at the draw site
        case .inUsePill:     return .labelColor           // #254: a mode marker, not a status colour
        case .foreground:    return .labelColor            // reset text / ⚠️ — re-alpha'd by bright()
        case .dimmedLabel:   return PopupViewController.defaultDimmedLabel
        case .label:         return .labelColor
        case .link:          return .linkColor
        case .pillText:      return .white
        case .calmWhite:     return .labelColor            // calm neutral — re-alpha'd by bright()
        case .claudeBrand:   return NSColor(srgbRed: 0xd9/255, green: 0x77/255, blue: 0x57/255, alpha: 1)
        }
    }
}
