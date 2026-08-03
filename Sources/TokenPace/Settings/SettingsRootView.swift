import SwiftUI

// MARK: - SettingsRootView (#168, ADR-0042)

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
            // Two groups so a divider separates the leading Insights section from the rest (the
            // journal it hosts underpins the Insights feature area, #238/#242). A `.sidebar` List
            // renders the gap between `Section`s as the divider — no manual rule needed.
            List(selection: $model.selection) {
                Section {
                    sidebarRow(.insights)
                }
                Section {
                    ForEach(SettingsSection.mainSections) { sidebarRow($0) }
                }
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

    /// One sidebar row for a section — the tinted chip plus the title, tagged for selection. Shared by
    /// both sidebar groups (the leading Insights section and the main list).
    private func sidebarRow(_ section: SettingsSection) -> some View {
        Label {
            Text(section.title)
                .font(.system(size: model.sidebarIcons.label))
        } icon: {
            SidebarChip(symbol: section.symbol, tint: section.tint, metrics: model.sidebarIcons)
        }
        // SwiftUI's default Label gap is ~half the System Settings sidebar gap; set it explicitly.
        .labelStyle(SidebarLabelStyle(gap: model.sidebarIcons.chipLabelGap))
        .tag(section)
    }

    @ViewBuilder
    private var detailPane: some View {
        switch model.selection {
        case .insights:          InsightsPane(model: model)
        case .about:             AboutPane(model: model)
        case .general:           GeneralPane(model: model)
        case .appearance:        AppearancePane(model: model)
        case .monitoredServices: MonitoredServicesPane(model: model)
        case .notifications:     NotificationsPane(model: model)
        case .sessionLogs:       SessionLogsPane(model: model)
        }
    }
}

// MARK: - SidebarLabelStyle

/// A `LabelStyle` that lays out the icon and title with an explicit gap — SwiftUI's default `Label`
/// spacing is narrower than the System Settings sidebar's, and there is no API to request the system
/// sidebar gap, so it's set from the measured `SidebarIconMetrics.chipLabelGap` (ADR-0040 exception).
private struct SidebarLabelStyle: LabelStyle {
    let gap: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: gap) {
            configuration.icon
            configuration.title
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
