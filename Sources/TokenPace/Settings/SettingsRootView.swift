import SwiftUI

// MARK: - SettingsRootView (#168, ADR-0041)

/// The SwiftUI root of the Settings window: a `NavigationSplitView` with a source-list sidebar of
/// sections and a detail pane that swaps to the selected section's `Form`. Modelled on macOS System
/// Settings (a sidebar of sections + a detail area). Hosted in the fixed-size `NSWindow` by
/// `SettingsWindowController`.
struct SettingsRootView: View {
    @Bindable var model: SettingsModel
    /// The fixed sidebar width, matching System Settings (258 pt) — locked so the sidebar never resizes.
    let sidebarWidth: CGFloat

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $model.selection) { section in
                Label {
                    Text(section.title)
                } icon: {
                    SidebarChip(symbol: section.symbol, tint: section.tint)
                }
                .tag(section)
            }
            .navigationSplitViewColumnWidth(sidebarWidth)
            .listStyle(.sidebar)
        } detail: {
            detailPane
        }
        .navigationSplitViewStyle(.balanced)
        // A menu-bar Settings window has no collapsible sidebar (System Settings doesn't either);
        // suppress the automatic sidebar toggle so only the fixed split shows.
        .toolbar(removing: .sidebarToggle)
    }

    @ViewBuilder
    private var detailPane: some View {
        switch model.selection {
        case .about:             AboutPane(model: model)
        case .general:           GeneralPane(model: model)
        case .appearance:        AppearancePane(model: model)
        case .monitoredServices: MonitoredServicesPane(model: model)
        case .notifications:     NotificationsPane(model: model)
        case .sessionLogs:       SessionLogsPane(model: model)
        }
    }
}

// MARK: - SidebarChip

/// The coloured rounded-rect chip behind a sidebar section's SF Symbol, matching System Settings.
/// A white glyph on a tinted rounded rect (the standard System Settings sidebar icon treatment).
private struct SidebarChip: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(tint, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
