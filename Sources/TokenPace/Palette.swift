import AppKit

/// Every named UI colour the app draws, as one flat catalogue both surfaces read from.
///
/// Roles are **surface-neutral**: one role per semantic hue, shared by the menu bar and the popup
/// (and by both pacing gaps and service-status dots), so the two surfaces cannot drift apart. The
/// two private `Palette` enums (`StatusItemView.Palette`, `PopupViewController.Palette`) are thin
/// aliases over ``defaultColor`` — this type is the single storage site for a colour value, and
/// `Settings` reads it directly too (`AboutPane`'s update dots, the Claude row badge).
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
    /// GitHub's mark (#454). Black, GitHub's brand colour, is a **fixed sRGB literal**: a semantic
    /// colour would invert with the appearance and destroy the only thing a brand mark says. Pure
    /// `#000000` on the Settings badge; the popup's header mark uses ``githubBrandInk`` instead
    /// since black ink is unreadable on the dropdown's dark material.
    case githubBrand
    /// The popup's GitHub wordmark: a light neutral that reads as the same mark on both materials.
    /// Not `.labelColor` (the header would stop reading as a brand mark), not black either.
    case githubBrandInk

    // MARK: - Shipped defaults

    /// `@MainActor` because `.dimmedLabel` resolves through `PopupViewController.defaultDimmedLabel`,
    /// which is MainActor-isolated — dropping the annotation is a build error, not a cleanup.
    @MainActor
    var defaultColor: NSColor {
        switch self {
        // The semantic hues are system colours only, so they flip light/dark and carry accessibility
        // (Increase Contrast) variants automatically. The bar **track** is `labelColor` at 22% alpha
        // (translucent); the **bright** mono tones are `labelColor` re-alpha'd at the draw site to the
        // system text opacity (`StatusItemView.bright(_:)`).
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
        case .githubBrand:   return NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        // `#1F2328` — GitHub's own foreground ink. Fixed on light, near-white on dark.
        case .githubBrandInk:
            return NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return isDark
                    ? NSColor(srgbRed: 0xE6/255, green: 0xED/255, blue: 0xF3/255, alpha: 1)
                    : NSColor(srgbRed: 0x1F/255, green: 0x23/255, blue: 0x28/255, alpha: 1)
            }
        }
    }
}
