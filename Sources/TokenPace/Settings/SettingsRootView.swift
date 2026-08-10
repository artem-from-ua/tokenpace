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
    /// The window's floor: 857 wide (pinned — the width never changes) and, since ADR-0069, the
    /// smallest height it can be dragged to. The hosting view has no intrinsic size for a
    /// `NavigationSplitView`, so the root asks to fill at least the window — otherwise the whole
    /// SwiftUI content lays out narrower than the window and the split's columns shrink with it (a
    /// too-narrow sidebar that truncates, plus dead space on the right of the detail).
    ///
    /// `minHeight` must match the window's `contentMinSize.height`, and `SettingsWindowController`
    /// passes both explicitly so they cannot drift: if the window could be dragged shorter than this,
    /// SwiftUI would clip the detail pane instead of letting its grouped `Form` scroll.
    var minWidth: CGFloat = 857
    var minHeight: CGFloat = 480

    var body: some View {
        NavigationSplitView {
            // Grouped so dividers separate About (top) and Extra features (bottom) from the standard
            // panes in the middle — a `.sidebar` List renders the gap between `Section`s as the divider.
            List(selection: $model.selection) {
                ForEach(Array(SettingsSection.groups.enumerated()), id: \.offset) { _, group in
                    Section {
                        ForEach(group) { sidebarRow($0) }
                    }
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
            // No header row here: the ‹ › buttons and the pane name live in the window's toolbar,
            // where System Settings keeps them (`SettingsToolbarController`). The column therefore
            // starts straight at the `Form`, whose own top inset is left at the system default — the
            // negative offsets this used to need existed only to cancel the strip an empty toolbar
            // reserved above the old header row.
            detailPane
                // The grouped `Form` opens with more headroom than System Settings leaves: measured
                // pixel-for-pixel against a real VPN pane at the same size, its first card starts at
                // y=52 pt where ours started at 72. `.contentMargins` is the supported way to
                // override a scrollable's own inset.
                .contentMargins(.top, Metrics.formTopMargin, for: .scrollContent)
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

    private enum Metrics {
        /// Top inset for the grouped `Form`, replacing its default. Measured against the system's VPN
        /// pane: its first card's top edge sits at y=52 pt, ours at 72, so this removes the extra 20.
        static let formTopMargin: CGFloat = -20
    }

    @ViewBuilder
    private var detailPane: some View {
        switch model.selection {
        case .about:             AboutPane(model: model)
        case .general:           GeneralPane(model: model)
        case .appearance:        AppearancePane(model: model)
        case .notifications:     NotificationsPane(model: model)
        case .extraFeatures:     ExtraFeaturesPane(model: model)
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
