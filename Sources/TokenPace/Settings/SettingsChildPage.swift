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

    var id: Int { rawValue }

    /// The section this page belongs under. Drilling never changes the section, so this is also the
    /// row the sidebar keeps highlighted while the page shows.
    var section: SettingsSection {
        switch self {
        case .providersClaude: return .providers
        }
    }

    /// The page's name — the navigator row's title on the parent page, and the title the toolbar
    /// shows while the page is open (the same slot a section's own name uses).
    var title: String {
        switch self {
        case .providersClaude: return "Claude"
        }
    }

    /// The child pages that belong to `section`, in the order their navigator rows are drawn.
    static func pages(of section: SettingsSection) -> [SettingsChildPage] {
        allCases.filter { $0.section == section }
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
