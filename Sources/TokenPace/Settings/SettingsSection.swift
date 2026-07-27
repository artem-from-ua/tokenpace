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
    case monitoredServices = 3
    case notifications = 4
    case sessionLogs = 5

    var id: Int { rawValue }

    /// The sidebar row title (also the pane's `Form` context; the window title stays the static
    /// "TokenPace Settings", ADR-0035 — HIG's per-pane title is a separate open item, #156 §2).
    var title: String {
        switch self {
        case .about: return "About"
        case .general: return "General"
        case .appearance: return "Appearance"
        case .monitoredServices: return "Monitored Services"
        case .notifications: return "Notifications"
        case .sessionLogs: return "Session Logs"
        }
    }

    /// SF Symbol for the sidebar chip. Names match the real System Settings panes read from their
    /// `.appex` Info.plist (#156): General uses `gear` (not `gearshape`); Notifications is a red bell.
    var symbol: String {
        switch self {
        case .about: return "info.circle"
        case .general: return "gear"
        case .appearance: return "menubar.rectangle"
        case .monitoredServices: return "dot.radiowaves.left.and.right"
        case .notifications: return "bell.badge.fill"
        case .sessionLogs: return "folder"
        }
    }

    /// Tint of the sidebar icon chip, matching the corresponding System Settings pane colour (#156).
    var tint: Color {
        switch self {
        case .about: return .blue
        case .general: return .gray
        case .appearance: return .indigo
        case .monitoredServices: return .green
        case .notifications: return .red
        case .sessionLogs: return .orange
        }
    }
}
