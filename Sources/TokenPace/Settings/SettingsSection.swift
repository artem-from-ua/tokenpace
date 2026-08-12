import SwiftUI

// MARK: - SettingsSection (#168, ADR-0042)

/// The Settings window's sidebar sections. The raw `Int` is the index the
/// `TOKENPACE_SETTINGS_SECTION` dev hook selects — this enum is the single source of truth for that
/// mapping, so the sidebar, the detail switch, and the docs (`ui-verification.md`) all agree.
///
/// **Raw values are stable identifiers, not display order** (#333): `groups` below owns the order.
/// Keeping them fixed means a rearranged sidebar doesn't silently repoint every documented
/// verification recipe at a different pane. `uiPresets` keeps `2` because it is what the Appearance
/// pane became.
enum SettingsSection: Int, CaseIterable, Identifiable {
    case about = 0
    case general = 1
    /// Presets and the config-copy button — what the Appearance pane was left holding once the two
    /// surfaces moved out to panes of their own.
    case uiPresets = 2
    case notifications = 3
    case extraFeatures = 4
    /// Everything that configures the menu-bar widget (#333).
    case menuBar = 5
    /// Everything that configures the dropdown popup (#333).
    case dropdown = 6

    // Scroll-test filler (`TOKENPACE_SIDEBAR_FILLER`). Raw values start at `fillerBase` so they sit
    // clear of the real panes and of the `TOKENPACE_SETTINGS_SECTION` indices those panes own.
    case filler1 = 100
    case filler2 = 101
    case filler3 = 102
    case filler4 = 103
    case filler5 = 104
    case filler6 = 105
    case filler7 = 106
    case filler8 = 107
    case filler9 = 108

    /// Whether this is a throwaway scroll-test row rather than a real pane.
    var isFiller: Bool { rawValue >= Self.fillerBase }

    var id: Int { rawValue }

    /// The sidebar groups, **in display order** — a divider is drawn between each (a `.sidebar` List
    /// renders the gap between `Section`s as the divider). `About` sits alone at the top, the app's own
    /// settings next, then the three UI pages as a group of their own, and `Extra features` alone at the
    /// bottom. (Monitored Services is no longer a sidebar pane — it moved into the Extra features pane
    /// as a section, #242.)
    ///
    /// The UI trio is grouped rather than drilled into (#333): the sidebar is short enough to carry
    /// three more rows, and a divider says "these three belong together" without costing the extra
    /// click a parent page would.
    static let groups: [[SettingsSection]] = [
        [.about],
        [.general, .notifications],
        [.uiPresets, .menuBar, .dropdown],
        [.extraFeatures] + filler,
    ]

    /// Nine throwaway rows appended after `Extra features` when `TOKENPACE_SIDEBAR_FILLER` is set.
    ///
    /// The sidebar is otherwise too short to scroll at any supported window height, so the separator
    /// that is *supposed* to appear under the titlebar when the list scrolls under it cannot be
    /// exercised — and neither can the bug where it appears on a plain window drag instead (#312
    /// follow-up). These rows give the list something to scroll.
    ///
    /// Behind an environment flag rather than a build flag so it can be switched on for one launch
    /// without touching the shipping list: `SettingsSection` is also the source of truth for the
    /// `TOKENPACE_SETTINGS_SECTION` dev-hook indices, and the filler deliberately takes raw values
    /// above every real pane so those indices keep pointing at the same panes.
    static let filler: [SettingsSection] =
        ProcessInfo.processInfo.environment["TOKENPACE_SIDEBAR_FILLER"] == nil
            ? []
            : (1...9).compactMap { SettingsSection(rawValue: fillerBase + $0 - 1) }

    /// First raw value handed to a filler row, chosen well clear of the real panes so adding one
    /// later cannot collide.
    static let fillerBase = 100

    /// The sidebar row title, which is also the title shown in the detail pane's toolbar (#156 §2 —
    /// HIG: "Update the window's title to reflect the currently visible pane"). The window's own
    /// title bar carries no text of its own — the name is drawn as a toolbar item beside the ‹ ›
    /// buttons, where System Settings draws it (`SettingsToolbarController`), retiring ADR-0035's
    /// static "TokenPace Settings" window title.
    var title: String {
        switch self {
        case .about: return "About"
        case .general: return "General"
        case .uiPresets: return "UI presets"
        case .menuBar: return "Menu bar"
        case .dropdown: return "Dropdown"
        case .notifications: return "Notifications"
        case .extraFeatures: return "Extra features"
        default: return "ITEM_\(rawValue - Self.fillerBase + 1)"
        }
    }

    /// SF Symbol for the sidebar chip. Names match the real System Settings panes read from their
    /// `.appex` Info.plist (#156): General uses `gear` (not `gearshape`); Notifications is a red bell.
    ///
    /// The three UI panes picture what they configure: a brush for the presets that repaint
    /// everything, the lone bar of the menu bar, and a page of rows for the dropdown. Chosen by
    /// rendering the candidates rather than by name (#333) — `rectangle.inset.filled` variants read
    /// as record buttons, not popups.
    ///
    /// `menuBar` is the one glyph we do not draw as-is: see ``trimsOuterRules``.
    var symbol: String {
        switch self {
        case .about: return "info.circle"
        case .general: return "gear"
        case .uiPresets: return "paintbrush.fill"
        case .menuBar: return "distribute.vertical"
        case .dropdown: return "chart.bar.horizontal.page"
        case .notifications: return "bell.badge.fill"
        case .extraFeatures: return "puzzlepiece.extension.fill"
        default: return "circle.dashed"
        }
    }

    /// Whether the chip draws only the **middle** of its symbol, dropping the rules above and below.
    ///
    /// `distribute.vertical` is three shapes — a rounded rectangle between two full-width rules — and
    /// only the rectangle is wanted: one bar, which is what a menu bar is. There is no SF Symbol of
    /// just that shape (checked), and the two rules sit in bands the rectangle never enters, so a
    /// clip keeps exactly the part we want.
    ///
    /// Measured on the rendered glyph at 64 pt (91×68 px): rules at y 5–9 and 59–63, rectangle at
    /// y 23–45, with clean gaps between. Expressed as fractions of the glyph box rather than pixels so
    /// it holds at every sidebar icon size.
    var trimsOuterRules: Bool { self == .menuBar }

    /// The slice of the symbol's height the chip keeps when ``trimsOuterRules`` is set — the band
    /// between the two rules, generous enough to clear the rectangle's rounded corners at any size.
    static let trimmedBand: ClosedRange<CGFloat> = 0.28...0.72

    /// Vertical nudge for the glyph inside its chip, in points, negative = up.
    ///
    /// `puzzlepiece.extension.fill` carries its tab on the **left edge** and its mass low, so centred
    /// on the glyph box it reads as sitting below centre in the capsule. A small lift puts the body
    /// where the eye expects it. Kept per-section rather than applied to every chip: no other symbol
    /// here needs it, and a blanket offset would push the ones that are already right.
    var glyphOffsetY: CGFloat { self == .extraFeatures ? -1 : 0 }

    /// Capsule gradient endpoints of the sidebar icon chip, matching System Settings (#156).
    /// The system capsules are baked icon artwork, not dynamic colors — each pane has its own
    /// hand-picked dark→light pair (the spread ranges from ~25% toward white for blue/green up to
    /// ~61% for gray, so no single formula derives one end from the other), and the artwork does
    /// not change between light and dark mode. Every pair below was measured with Digital Color
    /// Meter (sRGB) on a real System Settings sidebar; `dark` sits at the capsule's bottom-right,
    /// `light` at its top-left.
    var tint: CapsuleTint {
        switch self {
        case .about: return CapsuleTint(dark: 0x0D81FA, light: 0x41A6FF)
        case .general: return CapsuleTint(dark: 0x5E5E5F, light: 0xC0C0C4)
        // UI presets keeps the measured Appearance green — it is what that pane became.
        case .uiPresets: return CapsuleTint(dark: 0x2ED149, light: 0x63E977)
        // The two surfaces are flat black and white rather than a hue: the chips *depict* what they
        // configure — the dark strip along the top of the screen, and the light panel that drops
        // below it. Fixed tones, not semantic ones: flipping them with the appearance would destroy
        // the only thing they say. The white chip needs a hairline to exist on a light sidebar.
        case .menuBar: return CapsuleTint(flat: 0x000000)
        case .dropdown: return CapsuleTint(flat: 0xFFFFFF, glyph: .black, needsBorder: true)
        case .notifications: return CapsuleTint(dark: 0xFB4439, light: 0xFB7A71)
        case .extraFeatures: return CapsuleTint(dark: 0x5E5CE6, light: 0x8C8AFB)
        default: return CapsuleTint(dark: 0x5E5E5F, light: 0xC0C0C4)
        }
    }
}

/// The two measured endpoints of a sidebar capsule's gradient (see `SettingsSection.tint`), plus how
/// the glyph on top of it is drawn.
struct CapsuleTint {
    let dark: Color
    let light: Color
    /// The glyph's colour when the window is active. White on every measured system capsule; black on
    /// the white chip, which would otherwise draw white on white.
    let glyph: Color
    /// Whether the capsule needs a hairline outline to read against the sidebar. Only the white one
    /// does — every other chip is darker than the material behind it.
    let needsBorder: Bool

    init(dark: UInt32, light: UInt32, glyph: Color = .white, needsBorder: Bool = false) {
        self.dark = Self.color(dark)
        self.light = Self.color(light)
        self.glyph = glyph
        self.needsBorder = needsBorder
    }

    /// A capsule with no gradient at all — both endpoints the same colour.
    init(flat hex: UInt32, glyph: Color = .white, needsBorder: Bool = false) {
        self.init(dark: hex, light: hex, glyph: glyph, needsBorder: needsBorder)
    }

    private static func color(_ hex: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1
        )
    }
}
