import SwiftUI

// MARK: - SettingsSection (#168, ADR-0042)

/// The Settings window's sidebar sections, in display order. The raw `Int` is the **0-based index**
/// that the `TOKENPACE_SETTINGS_SECTION` dev hook selects (0 = About … 5 = Session Logs) — this enum
/// is the single source of truth for that order and mapping, so the sidebar, the detail switch, and
/// the docs (`ui-verification.md`) all agree. Changing the order here changes the dev-hook indices.
enum SettingsSection: Int, CaseIterable, Identifiable {
    case about = 0
    case general = 1
    case appearance = 2
    case notifications = 3
    case extraFeatures = 4

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

    /// The sidebar groups, in order — a divider is drawn between each group (a `.sidebar` List renders
    /// the gap between `Section`s as the divider). `About` sits alone at the top, the standard panes in
    /// the middle, and `Extra features` alone at the bottom. (Monitored Services is no longer a sidebar
    /// pane — it moved into the Extra features pane as a section, #242.)
    static let groups: [[SettingsSection]] = [
        [.about],
        [.general, .appearance, .notifications],
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
        case .appearance: return "Appearance"
        case .notifications: return "Notifications"
        case .extraFeatures: return "Extra features"
        default: return "ITEM_\(rawValue - Self.fillerBase + 1)"
        }
    }

    /// SF Symbol for the sidebar chip. Names match the real System Settings panes read from their
    /// `.appex` Info.plist (#156): General uses `gear` (not `gearshape`); Notifications is a red bell.
    var symbol: String {
        switch self {
        case .about: return "info.circle"
        case .general: return "gear"
        case .appearance: return "menubar.rectangle"
        case .notifications: return "bell.badge.fill"
        case .extraFeatures: return "puzzlepiece.extension.fill"
        default: return "circle.dashed"
        }
    }

    /// Tint of the sidebar icon chip, matching the corresponding System Settings pane colour (#156).
    var tint: Color {
        switch self {
        case .about: return .blue
        case .general: return .gray
        case .appearance: return .green
        case .notifications: return .red
        case .extraFeatures: return .orange
        default: return .secondary
        }
    }
}
