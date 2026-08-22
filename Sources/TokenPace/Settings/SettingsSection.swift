import SwiftUI

// MARK: - SettingsSection (#168, ADR-0042)

/// The Settings window's sidebar sections. The raw `Int` is the index the
/// `TOKENPACE_SETTINGS_SECTION` dev hook selects — this enum is the single source of truth for that
/// mapping, so the sidebar, the detail switch, and the docs (`ui-verification.md`) all agree.
///
/// **Raw values are stable identifiers, not display order** (#333): `groups` below owns the order.
/// Keeping them fixed means a rearranged sidebar doesn't silently repoint every documented
/// verification recipe at a different pane. `appearance` keeps `2` throughout: it is the pane the
/// presets were split out of, and the pane they came back to.
enum SettingsSection: Int, CaseIterable, Identifiable {
    case about = 0
    case general = 1
    /// How the widget looks: the presets and the config-copy button on the page itself, with the two
    /// surfaces as child pages drilled into from it.
    case appearance = 2
    case notifications = 3
    // Raw values `4`, `5`, `6` are retired and deliberately **not** reused: documented verification
    // recipes and dev-hook invocations still carry them, and pointing an old
    // `TOKENPACE_SETTINGS_SECTION=N` at some unrelated pane would be a recipe that lies rather than
    // fails. `5`/`6` (`Menu bar`/`Dropdown`) now live as `SettingsChildPage` indices instead.
    /// What TokenPace monitors, per provider (#341) — a parent page whose provider rows drill into
    /// their own child pages.
    case providers = 7

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
    /// renders the gap between `Section`s as the divider). `About` sits alone at the top, then
    /// `General` and `Providers` as the app-wide pair, then `Appearance` and `Notifications`.
    ///
    /// `Providers` sits beside `General` because it answers the same class of question — what the app
    /// does, rather than how it looks.
    ///
    /// `Menu bar` and `Dropdown` are **not** rows here: they are child pages of `Appearance`, reached
    /// by drilling in from it — the sidebar names the topic, the page names its surfaces.
    ///
    /// `Notifications` shares the group with `Appearance`: both remaining rows answer "how does the
    /// app present itself".
    static let groups: [[SettingsSection]] = [
        [.about],
        [.general, .providers],
        [.appearance, .notifications] + filler,
    ]

    /// Nine throwaway rows appended after `Notifications` when `TOKENPACE_SIDEBAR_FILLER` is set —
    /// the last group, wherever that happens to be. The sidebar is otherwise too short to scroll at
    /// any supported window height; these rows give the list something to scroll so the titlebar
    /// separator can be exercised. Raw values sit above every real pane so the `TOKENPACE_SETTINGS_SECTION`
    /// dev-hook indices keep pointing at the same panes with or without the flag.
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
        case .appearance: return "Appearance"
        case .notifications: return "Notifications"
        case .providers: return "Providers"
        default: return "ITEM_\(rawValue - Self.fillerBase + 1)"
        }
    }

    /// Whether the live dropdown preview rides beside the window while this section (or a page under
    /// it) is showing — ADR-0083, narrowed from "always" to this.
    ///
    /// `Appearance` and its two surface pages are the sections whose controls change what the preview
    /// draws, and the preview is a second window claiming real width beside Settings: on `About` or
    /// `Notifications` it costs that space to answer a question nothing on the page asked. A section
    /// that later grows a control the dropdown reflects — a Guide/Legend page (#261) — turns it on
    /// here, in one line.
    var showsDropdownPreview: Bool { self == .appearance }

    /// SF Symbol for the sidebar chip. Names match the real System Settings panes read from their
    /// `.appex` Info.plist (#156): General uses `gear` (not `gearshape`); Notifications is a red bell.
    ///
    /// `Appearance` keeps the brush it has always carried — the pane repaints everything, whichever
    /// surface the option ends up on. The glyphs the two surfaces used as sidebar rows (#333) moved
    /// with them onto their navigator rows (``SettingsChildPage/symbol``).
    var symbol: String {
        switch self {
        case .about: return "info.circle"
        case .general: return "gear"
        case .appearance: return "paintbrush.fill"
        case .notifications: return "bell.badge.fill"
        // Providers are the services TokenPace plugs into — a puzzle piece slotting in, not the
        // cloud they happen to run on. Verified to resolve on macOS 15 with
        // `NSImage(systemSymbolName:)`, which returns nil for a name that does not exist.
        case .providers: return "puzzlepiece.extension.fill"
        default: return "circle.dashed"
        }
    }

    /// Whether the chip draws only the **middle** of its symbol, dropping the rules above and below.
    ///
    /// No sidebar row asks for this since `Menu bar` became a child page (its glyph is the one that
    /// needs the trim — see ``SettingsChildPage/trimsOuterRules``), but the property stays on the
    /// protocol both chips share: the trim is a property of a *glyph*, and the next section to pick a
    /// symbol whose outer strokes are unwanted gets it here rather than re-deriving the band.
    var trimsOuterRules: Bool { false }

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
        // The measured Appearance green, darkened by ~23% on both endpoints — which holds the hue and
        // the gradient's spread while letting the chip sit less brightly among its neighbours.
        case .appearance: return CapsuleTint(dark: 0x23A238, light: 0x4DB45C)
        case .notifications: return CapsuleTint(dark: 0xFB4439, light: 0xFB7A71)
        // The same measured gray as `General`, on purpose: both are app-wide settings rather than one
        // of the UI surfaces, and the sidebar says so by giving them one capsule colour.
        case .providers: return CapsuleTint(dark: 0x5E5E5F, light: 0xC0C0C4)
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
