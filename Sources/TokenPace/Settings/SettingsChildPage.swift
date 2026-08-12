import SwiftUI
import TokenPaceKit

// MARK: - SettingsChildPage (#333, ADR-0082)

/// A page drilled into from a section's own page, reached by a ``SettingsNavigationRow`` and left by
/// the toolbar's ‹. The sidebar has no row of its own for these — it stays on the parent section
/// (System Settings behaves the same way), which is why they are a separate type rather than more
/// `SettingsSection` cases.
///
/// The raw `Int` extends the `TOKENPACE_SETTINGS_SECTION` dev-hook space so a child page can be
/// opened straight from a launch, the same as a pane. The numbering sits above the real panes (0…4)
/// and below the scroll-test filler (``SettingsSection/fillerBase``, 100), leaving room for both to
/// grow without a collision.
enum SettingsChildPage: Int, CaseIterable, Identifiable {
    /// Appearance › Menu bar — everything that configures the menu-bar widget.
    case appearanceMenuBar = 50
    /// Appearance › Dropdown — everything that configures the popup.
    case appearanceDropdown = 51

    var id: Int { rawValue }

    /// The section this page belongs under. Drilling never changes the section, so this is also the
    /// row the sidebar keeps highlighted while the page shows.
    var section: SettingsSection {
        switch self {
        case .appearanceMenuBar, .appearanceDropdown: return .appearance
        }
    }

    /// The page's name — the navigator row's title on the parent page, and the title the toolbar
    /// shows while the page is open (the same slot a section's own name uses).
    var title: String {
        switch self {
        case .appearanceMenuBar: return "Menu bar"
        case .appearanceDropdown: return "Dropdown"
        }
    }

    /// SF Symbol for the navigator row's chip. The pair is deliberately one family: both carry the
    /// same bar across the top, and the dropdown's adds the panel hanging below it — which is
    /// literally the difference between the two surfaces. `menubar.rectangle` is also the sidebar's
    /// own Appearance symbol, so the menu-bar page inherits the section's glyph.
    ///
    /// Chosen by rendering the candidates rather than by name: `rectangle.inset.filled.badge.record`
    /// reads as a record button, not a popup. Both names resolve on macOS 15 — verified with
    /// `NSImage(systemSymbolName:)`, which returns nil (and draws nothing) for a name that does not
    /// exist.
    var symbol: String {
        switch self {
        case .appearanceMenuBar: return "menubar.rectangle"
        case .appearanceDropdown: return "menubar.dock.rectangle"
        }
    }

    /// Capsule fill for the navigator row's chip — **flat, no gradient**, unlike the sidebar's
    /// measured artwork.
    ///
    /// The two are black and white rather than a shared section hue because that is the thing they
    /// depict: the menu bar is the dark strip at the top of the screen, the dropdown is the light
    /// panel below it. A colour would name the section (which the sidebar already does); black and
    /// white name the surface, which is what the choice on these pages is actually about.
    var fill: ChildPageChipFill {
        switch self {
        case .appearanceMenuBar: return .black
        case .appearanceDropdown: return .white
        }
    }

    /// The child pages that belong to `section`, in the order their navigator rows are drawn.
    static func pages(of section: SettingsSection) -> [SettingsChildPage] {
        allCases.filter { $0.section == section }
    }
}

// MARK: - ChildPageChipFill

/// A flat black or white chip for a child page's navigator row, with the glyph in the opposite tone.
///
/// Both tones are fixed rather than semantic (`.label` / `.windowBackground`): they *depict* the two
/// surfaces — the dark menu bar, the light dropdown — so flipping them with the system appearance
/// would destroy the very thing they say. That makes the white chip the one at risk: on a light
/// card it needs a hairline border to read as a chip at all, which the black one never does.
enum ChildPageChipFill {
    case black
    case white

    var capsule: Color { self == .black ? .black : .white }
    var glyph: Color { self == .black ? .white : .black }

    /// Hairline border, drawn only for the white chip and only where it would otherwise disappear.
    /// `separator` is the system's own hairline colour, so it tracks the appearance the way every
    /// other divider in the window does.
    var border: Color? { self == .white ? Color(nsColor: .separatorColor) : nil }
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
