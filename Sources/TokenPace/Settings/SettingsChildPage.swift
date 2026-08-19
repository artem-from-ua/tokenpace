import SwiftUI
import TokenPaceKit

// MARK: - SettingsChildPage (#341, ADR-0084)

/// A page drilled into from a section's own page, reached by a ``SettingsNavigationRow`` and left by
/// the toolbar's ‹. The sidebar has no row of its own for these — it stays on the parent section
/// (System Settings behaves the same way), which is why they are a separate type rather than more
/// `SettingsSection` cases.
///
/// The raw `Int` extends the `TOKENPACE_SETTINGS_SECTION` dev-hook space so a child page can be
/// opened straight from a launch, the same as a pane. The numbering sits above the real panes and
/// below the scroll-test filler (``SettingsSection/fillerBase``, 100), leaving room for both to grow
/// without a collision.
enum SettingsChildPage: Int, CaseIterable, Identifiable {
    /// Providers › Claude — what TokenPace collects and watches for Claude.
    case providersClaude = 50
    /// Appearance › Menu bar — everything that configures the menu-bar widget.
    case appearanceMenuBar = 51
    /// Appearance › Dropdown — everything that configures the popup.
    case appearanceDropdown = 52
    /// Appearance › Legend — the visual language explained (#261): what a bar's colour says, how each
    /// style is read, what every glyph means.
    ///
    /// A child of `Appearance` rather than a sidebar row of its own: it explains the marks the other
    /// two pages configure, so it belongs to the same topic. It is the one page under this section
    /// that **sets nothing** — reference, not control — which is why its row sits in a section of its
    /// own above the presets rather than beside the two surfaces.
    case appearanceLegend = 53

    var id: Int { rawValue }

    /// The section this page belongs under. Drilling never changes the section, so this is also the
    /// row the sidebar keeps highlighted while the page shows.
    var section: SettingsSection {
        switch self {
        case .providersClaude: return .providers
        case .appearanceMenuBar, .appearanceDropdown, .appearanceLegend: return .appearance
        }
    }

    /// Whether this page configures one of the app's **surfaces**, and so belongs in the unlabelled
    /// section of navigator rows its parent draws for them.
    ///
    /// `Legend` is the one child page that does not: it sets nothing. Its row sits in a section of its
    /// own, above the presets, so the divider says what the two groups are — read the marks here,
    /// change them below. Without this the `pages(of:)` filter would file it beside `Menu bar` and
    /// `Dropdown`, where a reader would reasonably expect it to have controls too.
    var configuresSurface: Bool { self != .appearanceLegend }

    /// The page's name — the navigator row's title on the parent page, and the title the toolbar
    /// shows while the page is open (the same slot a section's own name uses).
    var title: String {
        switch self {
        case .providersClaude: return "Claude"
        case .appearanceMenuBar: return "Menu bar"
        case .appearanceDropdown: return "Dropdown"
        case .appearanceLegend: return "Legend"
        }
    }

    /// The SF Symbol on the navigator row's leading chip, or `nil` for a row that carries none.
    ///
    /// The two surface pages keep the glyphs they wore as sidebar rows (#333) — the lone bar of the
    /// menu bar, and a page of rows for the dropdown, both picked by rendering the candidates rather
    /// than by name. `Claude` is the exception in the other direction: its chip is a **brand** badge
    /// built from a colour rather than from this table (``SettingsRowBadge/claude``), because a
    /// provider row identifies a company and these two identify a surface.
    var symbol: String? {
        switch self {
        case .providersClaude: return nil
        case .appearanceMenuBar: return "distribute.vertical"
        case .appearanceDropdown: return "chart.bar.horizontal.page"
        // A map's legend is the direct reading of the page's name, and the page is a key to marks
        // rather than a set of instructions — which ruled out the `book`/`questionmark` family, whose
        // glyphs promise reading material or troubleshooting the page does not give. Verified to
        // resolve on macOS 15 (17×15 pt) with `NSImage(systemSymbolName:)`, the check that caught
        // `zzz.circle` not existing (#341).
        //
        // The glyph is tied to the name: rename the page and the metaphor stops supporting anything.
        case .appearanceLegend: return "map.fill"
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
    /// it holds at every chip size — which is what let the band survive the move from a sidebar chip
    /// to this larger row badge unchanged.
    var trimsOuterRules: Bool { self == .appearanceMenuBar }

    /// The two endpoints of the chip's gradient, in the same `CapsuleTint` the sidebar chips use.
    ///
    /// The two surfaces are flat black and white rather than a hue: the chips *depict* what they
    /// configure — the dark strip along the top of the screen, and the light panel that drops below
    /// it. Fixed tones, not semantic ones: flipping them with the appearance would destroy the only
    /// thing they say. The white chip needs a hairline to exist on a light form row.
    var tint: CapsuleTint? {
        switch self {
        case .providersClaude: return nil
        case .appearanceMenuBar: return CapsuleTint(flat: 0x000000)
        case .appearanceDropdown: return CapsuleTint(flat: 0xFFFFFF, glyph: .black, needsBorder: true)
        // **About's blue**, the sidebar's reference colour — not a third flat tone.
        //
        // The two flats above are literal: each chip *depicts* the surface it configures, the dark
        // strip and the light panel. Legend depicts nothing, because it configures nothing, so a flat
        // would be inventing a surface that does not exist. Borrowing the blue that marks the other
        // page in this app whose job is to inform (`SettingsSection.about`) says the true thing
        // instead — and, sitting in its own section above the presets, it never appears beside the
        // two flats for the difference to read as inconsistency.
        case .appearanceLegend: return CapsuleTint(dark: 0x0D81FA, light: 0x41A6FF)
        }
    }

    /// The child pages that belong to `section`, in the order their navigator rows are drawn.
    ///
    /// **Surface pages only** — see ``configuresSurface``. The one caller is the unlabelled section a
    /// parent draws for the surfaces it owns, and `Legend` is placed by hand elsewhere on the page;
    /// returning it here would put it in both.
    static func pages(of section: SettingsSection) -> [SettingsChildPage] {
        allCases.filter { $0.section == section && $0.configuresSurface }
    }
}

// MARK: - SettingsRoute

/// Where the Settings window is: a section, plus the child page drilled into from it, if any.
/// The rules (drilling keeps the section, a section change pops to the root, parent and child are
/// distinct history stops) live in the kit's generic ``NavigationRoute``, where they are unit-tested
/// — the app target has no test target.
typealias SettingsRoute = NavigationRoute<SettingsSection, SettingsChildPage>

extension NavigationRoute where Section == SettingsSection, Child == SettingsChildPage {

    /// The name the toolbar shows: the child page's while one is open, otherwise the section's.
    var title: String { child?.title ?? section.title }
}
