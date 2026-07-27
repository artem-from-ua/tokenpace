import SwiftUI

// MARK: - SettingsRootView (#168, ADR-0041)

/// The SwiftUI root of the Settings window: a `NavigationSplitView` with a source-list sidebar of
/// sections and a detail pane that swaps to the selected section's `Form`. Modelled on macOS System
/// Settings — a sidebar of sections + a grouped-form detail area. Hosted in the fixed-size `NSWindow`
/// by `SettingsWindowController`. The root asks to fill the window (`.frame(minWidth:…)`) and the
/// sidebar column is width-constrained; the detail `Form` then gets its system-default insets — no
/// hand-tuned card/row/padding metrics (the whole point of moving to `Form.formStyle(.grouped)`).
struct SettingsRootView: View {
    @Bindable var model: SettingsModel
    /// The window's fixed content size (857×480). The hosting view has no intrinsic size for a
    /// `NavigationSplitView`, so the root asks to fill at least the window — otherwise the whole
    /// SwiftUI content lays out narrower than the window and the split's columns shrink with it (a
    /// too-narrow sidebar that truncates, plus dead space on the right of the detail).
    var minWidth: CGFloat = 857
    var minHeight: CGFloat = 480

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $model.selection) { section in
                Label {
                    Text(section.title)
                        .font(.system(size: model.sidebarIcons.label))
                } icon: {
                    SidebarChip(symbol: section.symbol, tint: section.tint, metrics: model.sidebarIcons)
                }
                .tag(section)
            }
            .listStyle(.sidebar)
            // `.navigationSplitViewColumnWidth` is unreliable for a `.sidebar` List (it leaves the
            // sidebar at SwiftUI's narrow default, truncating "Monitored Services"). Constrain the
            // List's own width instead so it holds the longest label; the width tracks the system
            // sidebar-icon-size bucket, like System Settings.
            .frame(width: model.sidebarIcons.sidebarWidth)
            // A menu-bar Settings window has no collapsible sidebar (System Settings doesn't either);
            // suppress the automatic sidebar toggle so only the fixed split shows.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detailPane
        }
        .frame(minWidth: minWidth, maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity)
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

/// The coloured rounded-rect chip behind a sidebar section's SF Symbol, matching System Settings —
/// a white glyph on a tinted rounded rect. Chip/symbol sizes follow the system "Sidebar icon size"
/// via `SidebarIconMetrics` (no single hardcoded size).
private struct SidebarChip: View {
    let symbol: String
    let tint: Color
    var metrics: SidebarIconMetrics

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: metrics.symbol, weight: .regular))
            .foregroundStyle(.white)
            .frame(width: metrics.chip, height: metrics.chip)
            // Fixed 5 pt corner radius, matching the previous AppKit ChipView (System Settings' chip).
            .background(tint, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
