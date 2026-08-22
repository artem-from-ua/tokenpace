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
    /// The window's floor: pinned width, and since ADR-0069 the smallest height it can be dragged to.
    /// The hosting view has no intrinsic size for a `NavigationSplitView`, so the root asks to fill at
    /// least the window — otherwise the columns shrink with it (a too-narrow sidebar, dead space on
    /// the detail's right). Must match the window's `contentMinSize`, passed explicitly by
    /// `SettingsWindowController`; the defaults here are only a fallback for previews.
    var minWidth: CGFloat = 792
    var minHeight: CGFloat = 470

    var body: some View {
        NavigationSplitView {
            // Grouped so dividers separate About (top) and Notifications (bottom) from the standard
            // panes — a `.sidebar` List renders the gap between `Section`s as the divider. Bound
            // straight to `selection`, which keeps the parent row highlighted while a child page is
            // open. Clicking the *already-highlighted* row is handled by the row's own gesture
            // instead — a binding cannot see that click, since the List doesn't report an unchanged
            // selection. See `sidebarRow(_:)`.
            List(selection: $model.selection) {
                ForEach(Array(SettingsSection.groups.enumerated()), id: \.offset) { _, group in
                    Section {
                        ForEach(group) { sidebarRow($0) }
                    }
                }
            }
            .listStyle(.sidebar)
            // Keeps the List from laying out narrower than its column. The column's real width is
            // settled in AppKit on the `NSSplitViewItem` — neither SwiftUI lever works here
            // (`.navigationSplitViewColumnWidth` is unreliable for a `.sidebar` List). See
            // `SettingsWindowController.pinSidebarSplit()`.
            .frame(width: model.sidebarIcons.sidebarWidth)
            // A menu-bar Settings window has no collapsible sidebar (System Settings doesn't either);
            // suppress the automatic sidebar toggle so only the fixed split shows.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            // No header row here: the ‹ › buttons and the pane name live in the window's toolbar
            // (`SettingsToolbarController`).
            //
            // The top margin lands the first card at System Settings' own offset. The grouped `Form`
            // keeps 18 pt of its own leading padding inside its scroll document (measured; no public
            // API removes it), so the inset is trimmed to 52 − 18 = 34.
            //
            // Managing the inset by hand kills AppKit's automatic titlebar separator, but it was dead
            // anyway — measured, it never tracked the bridged scroll view. Driven explicitly instead:
            // `SettingsWindowController.driveDetailTitlebarSeparator()`.
            detailPane
                .contentMargins(.top, Metrics.formTopMargin, for: .scrollContent)
        }
        .frame(minWidth: minWidth, maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity)
    }

    private enum Metrics {
        /// The form's document carries 18 pt of its own leading padding, so 52 − 18 puts the first
        /// card at System Settings' measured 52 pt.
        static let formTopMargin: CGFloat = -18
    }

    private func sidebarRow(_ section: SettingsSection) -> some View {
        Label {
            Text(section.title)
                .font(.system(size: model.sidebarIcons.label))
        } icon: {
            SidebarChip(section: section, metrics: model.sidebarIcons)
        }
        // SwiftUI's default Label gap is ~half the System Settings sidebar gap; set it explicitly.
        .labelStyle(SidebarLabelStyle(gap: model.sidebarIcons.chipLabelGap))
        // Clicking the **already-selected** row pops out of its child page (#374) — handled in AppKit,
        // not here: `List(selection:)` does not write the binding when the selection is unchanged, and
        // `simultaneousGesture` only fires for a row that was *not* already selected. See
        // `SettingsWindowController.watchSidebarClicks(in:)`.
        .tag(section)
    }

    /// The detail column's content — the child page when one is drilled into, else the section's pane.
    /// Two sections are parents rather than leaves: `Providers` (ADR-0084) grows a child page per
    /// provider, `Appearance` has two (one per rendered surface).
    ///
    /// The child branch is checked **first and in the same switch**, so a drilled-in page replaces the
    /// section's pane rather than stacking with it: `.contentMargins` has to land on the pane's own
    /// scroll view, so nothing may wrap the panes in a container here.
    @ViewBuilder
    private var detailPane: some View {
        if let child = model.childPage {
            switch child {
            case .providersClaude:      ProvidersClaudePane(model: model)
            case .providersGitHub:      ProvidersGitHubPane(model: model)
            case .appearanceMenuBar:    MenuBarPane(model: model)
            case .appearanceDropdown:   DropdownPane(model: model)
            case .appearanceLegend:     LegendPane()
            }
        } else {
            switch model.selection {
            case .about:             AboutPane(model: model)
            case .general:           GeneralPane(model: model)
            case .appearance:        AppearancePane(model: model)
            case .notifications:     NotificationsPane(model: model)
            case .providers:         ProvidersPane(model: model)
            // Scroll-test filler rows (`TOKENPACE_SIDEBAR_FILLER`) have no pane of their own; they
            // exist only to make the sidebar long enough to scroll.
            default:                 Text(model.selection.title).foregroundStyle(.secondary)
            }
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
    let section: SettingsSection
    var metrics: SidebarIconMetrics
    /// Sidebar labels are vibrant and dim automatically when the window resigns key, but the chip is
    /// a flat tint that never participates in vibrancy. System Settings dims the two chip layers
    /// separately: the capsule drops to ~half strength, while the glyph is redrawn in a solid neutral
    /// tone rather than composited white-over-tint — a tone that differs per appearance, see
    /// `Metrics.inactiveGlyph`.
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        glyph
            .foregroundStyle(glyphColor)
            // The system artwork's glyph carries a hairline dark edge separating it from the tint; a
            // sub-point shadow reproduces it.
            .shadow(color: Metrics.glyphEdge, radius: Metrics.glyphEdgeRadius, y: Metrics.glyphEdgeOffset)
            .frame(width: metrics.chip, height: metrics.chip)
            .background(capsuleStyle, in: Self.shape)
            // Only the white chip asks for one — it's the single capsule lighter than the sidebar
            // material behind it, so without a hairline its edge simply is not there.
            .overlay { if section.tint.needsBorder { Self.shape.stroke(Metrics.chipBorder, lineWidth: 1) } }
    }

    private static let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)

    /// The inactive-window treatment only applies to chips whose glyph is white: the system redraws
    /// those in a neutral tone, which on the **white** capsule would paint the glyph invisible.
    private var glyphColor: Color {
        guard section.tint.glyph == .white else { return section.tint.glyph }
        return appearsActive ? .white : Metrics.inactiveGlyph(for: colorScheme)
    }

    /// Shared with the navigator-row badge (``SymbolTrim``) so one measured band serves both chips.
    @ViewBuilder
    private var glyph: some View {
        if section.trimsOuterRules, let trimmed = SymbolTrim.middleBand(section.symbol, size: metrics.symbol) {
            Image(nsImage: trimmed)
        } else {
            Image(systemName: section.symbol).font(.system(size: metrics.symbol, weight: .regular))
        }
    }

    /// System Settings capsules are not flat: a gradient runs from `tint.dark` at the bottom-right to
    /// `tint.light` at the top-left (see `SettingsSection.tint` for the per-pane values).
    private var capsuleStyle: AnyShapeStyle {
        let gradient = LinearGradient(
            colors: [section.tint.light, section.tint.dark],
            startPoint: Metrics.gradientLightPoint,
            endPoint: Metrics.gradientDarkPoint
        )
        return appearsActive
            ? AnyShapeStyle(gradient)
            : AnyShapeStyle(gradient.opacity(Metrics.inactiveTintAlpha))
    }

    private enum Metrics {
        /// Measured with Digital Color Meter (sRGB) on System Settings — separately per appearance,
        /// since the system does not dim the glyph the same way in both: dark mode drops to a mid
        /// gray (0x909090), light mode stays near-white (0xf8f8f8). A shared constant would read as a
        /// dark, dirty glyph on a light sidebar.
        static func inactiveGlyph(for scheme: ColorScheme) -> Color {
            let white = scheme == .dark ? 0x90 / 255.0 : 0xF8 / 255.0
            return Color(.sRGB, white: white, opacity: 1)
        }
        static let inactiveTintAlpha: Double = 0.5
        static let gradientLightPoint = UnitPoint(x: 0.25, y: 0)
        static let gradientDarkPoint = UnitPoint(x: 0.75, y: 1)
        static let glyphEdge = Color.black.opacity(0.25)
        static let glyphEdgeRadius: CGFloat = 0.5
        static let glyphEdgeOffset: CGFloat = 0.5
        static let chipBorder = Color(nsColor: .separatorColor)
    }
}
