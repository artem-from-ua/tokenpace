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
    /// The window's floor: its pinned width (the width never changes) and, since ADR-0069, the
    /// smallest height it can be dragged to. The hosting view has no intrinsic size for a
    /// `NavigationSplitView`, so the root asks to fill at least the window — otherwise the whole
    /// SwiftUI content lays out narrower than the window and the split's columns shrink with it (a
    /// too-narrow sidebar that truncates, plus dead space on the right of the detail).
    ///
    /// Both must match the window's `contentMinSize`, and `SettingsWindowController` passes them
    /// explicitly so they cannot drift: if the window could be dragged shorter than this, SwiftUI would
    /// clip the detail pane instead of letting its grouped `Form` scroll. The defaults here are only a
    /// fallback for previews — the live values come from `Metrics`.
    var minWidth: CGFloat = 792
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
            // Keeps the List itself from laying out narrower than the column it sits in. The column's
            // real width — and the fact that its divider cannot be dragged — is settled in AppKit, on
            // the `NSSplitViewItem`: neither SwiftUI lever works here (`.navigationSplitViewColumnWidth`
            // is unreliable for a `.sidebar` List, and `.frame` alone snaps between a few fixed states
            // rather than scaling). See `SettingsWindowController.pinSidebarSplit()`.
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

    /// One sidebar row for a section — the tinted chip plus the title, tagged for selection. Shared
    /// by every sidebar group.
    private func sidebarRow(_ section: SettingsSection) -> some View {
        Label {
            Text(section.title)
                .font(.system(size: model.sidebarIcons.label))
        } icon: {
            SidebarChip(section: section, metrics: model.sidebarIcons)
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

    /// The detail column's content — the selected section's pane.
    ///
    /// The panes sit at one level: the UI trio (presets, menu bar, dropdown) are sidebar rows of their
    /// own rather than pages drilled into from a parent (#333). The sidebar has room for them, and a
    /// divider already says they belong together — a parent page would only add a click.
    @ViewBuilder
    private var detailPane: some View {
        switch model.selection {
        case .about:             AboutPane(model: model)
        case .general:           GeneralPane(model: model)
        case .uiPresets:         UIPresetsPane(model: model)
        case .menuBar:           MenuBarPane(model: model)
        case .dropdown:          DropdownPane(model: model)
        case .notifications:     NotificationsPane(model: model)
        case .extraFeatures:     ExtraFeaturesPane(model: model)
        // Scroll-test filler rows (`TOKENPACE_SIDEBAR_FILLER`) have no pane of their own; they
        // exist only to make the sidebar long enough to scroll.
        default:                 Text(model.selection.title).foregroundStyle(.secondary)
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
    /// Sidebar labels are vibrant, so the material dims them automatically when the window resigns
    /// key — but the chip is a flat tint that never participates in vibrancy, so it kept full color
    /// in an inactive window. System Settings dims the two chip layers separately: the tinted
    /// capsule drops to ~half strength (α ≈ 0.5 against the sidebar background), while the glyph is
    /// redrawn in a solid neutral tone rather than composited white-over-tint, which would leave it
    /// tinted. That tone is *not* the same in both appearances — see `Metrics.inactiveGlyph`.
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        glyph
            .foregroundStyle(glyphColor)
            // A per-section nudge, for the one glyph whose mass sits off-centre in its own box.
            .offset(y: section.glyphOffsetY)
            // The system artwork's glyph carries a hairline dark edge that separates it from the
            // tint (visible as a thin gray outline hugging the glyph, strongest below it); a
            // sub-point shadow reproduces it.
            .shadow(color: Metrics.glyphEdge, radius: Metrics.glyphEdgeRadius, y: Metrics.glyphEdgeOffset)
            .frame(width: metrics.chip, height: metrics.chip)
            // Fixed 5 pt corner radius, matching the previous AppKit ChipView (System Settings' chip).
            .background(capsuleStyle, in: Self.shape)
            // Only the white chip asks for one — it is the single capsule lighter than the sidebar
            // material behind it, so without a hairline its edge simply is not there.
            .overlay { if section.tint.needsBorder { Self.shape.stroke(Metrics.chipBorder, lineWidth: 1) } }
    }

    /// The capsule outline, shared by the fill and the optional border so the two cannot drift.
    private static let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)

    /// The glyph's colour. The inactive-window treatment only applies to chips whose glyph is white:
    /// the system redraws those in a neutral tone, which on the **white** capsule would paint the
    /// glyph into invisibility. A chip that already carries a dark glyph keeps it.
    private var glyphColor: Color {
        guard section.tint.glyph == .white else { return section.tint.glyph }
        return appearsActive ? .white : Metrics.inactiveGlyph(for: colorScheme)
    }

    /// The symbol, drawn whole — or, for a section that asks for it, only the middle band of it.
    ///
    /// The trim happens on the rendered `NSImage`, not through SwiftUI transforms: the band is cut
    /// out and the result handed over as a plain image, so it lays out as exactly what it is. The
    /// `.scaleEffect` + `.mask` spelling looks equivalent and is not — the scale moves the glyph's
    /// centre relative to the mask, so the surviving strip is not the one that was measured.
    @ViewBuilder
    private var glyph: some View {
        if section.trimsOuterRules, let trimmed = Self.trimmedSymbol(section.symbol, size: metrics.symbol) {
            Image(nsImage: trimmed)
        } else {
            Image(systemName: section.symbol).font(.system(size: metrics.symbol, weight: .regular))
        }
    }

    /// Render `name` at `size` and keep only `SettingsSection.trimmedBand` of its height.
    ///
    /// `distribute.vertical` is a rounded rectangle between two full-width rules, and only the
    /// rectangle is wanted — one bar, which is what a menu bar is. No SF Symbol draws that shape
    /// alone (checked), and the rules sit in bands the rectangle never enters, so the cut is exact.
    /// The image is left as a template so the chip's own `foregroundStyle` still tints it, including
    /// the inactive-window tone.
    private static func trimmedSymbol(_ name: String, size: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        guard let full = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let band = SettingsSection.trimmedBand
        let kept = NSSize(width: full.size.width, height: full.size.height * (band.upperBound - band.lowerBound))
        guard kept.height > 0 else { return nil }
        let out = NSImage(size: kept)
        out.lockFocus()
        // Draw the whole glyph shifted down by the discarded lower band, so the kept slice lands in
        // the canvas and everything outside it falls off the edges.
        full.draw(in: NSRect(x: 0, y: -full.size.height * band.lowerBound,
                             width: full.size.width, height: full.size.height))
        out.unlockFocus()
        out.isTemplate = true
        return out
    }

    /// System Settings capsules are not flat: a gradient runs from the measured `tint.dark` at the
    /// bottom-right up to the measured `tint.light` at the top-left (see `SettingsSection.tint` for
    /// the per-pane Digital Color Meter values). The axis is tilted off vertical toward the
    /// top-left corner, but shallower than the full 45° diagonal. The inactive window keeps the
    /// same gradient at the dimmed opacity.
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
        /// Glyph color in an inactive window, measured with Digital Color Meter (sRGB) on System
        /// Settings — separately per appearance, because the system does not dim the glyph the same
        /// way in both. Dark mode drops it to a mid gray (0x909090); light mode keeps it essentially
        /// white (0xf8f8f8), only a hair off the active glyph. A single shared constant therefore
        /// cannot serve both: the dark-mode gray reads as a dark, dirty glyph on a light sidebar.
        static func inactiveGlyph(for scheme: ColorScheme) -> Color {
            let white = scheme == .dark ? 0x90 / 255.0 : 0xF8 / 255.0
            return Color(.sRGB, white: white, opacity: 1)
        }
        /// Capsule tint opacity in an inactive window; matches System Settings' ~half-strength dim.
        static let inactiveTintAlpha: Double = 0.5
        /// Gradient axis: light at the top-left, dark at the bottom-right — tilted off vertical,
        /// but shallower than the corner-to-corner 45° diagonal.
        static let gradientLightPoint = UnitPoint(x: 0.25, y: 0)
        static let gradientDarkPoint = UnitPoint(x: 0.75, y: 1)
        /// The glyph's hairline dark edge (screenshot pixels dip ~10–25% below the capsule
        /// gradient in a 1–2 device-pixel ring under the glyph).
        static let glyphEdge = Color.black.opacity(0.25)
        static let glyphEdgeRadius: CGFloat = 0.5
        static let glyphEdgeOffset: CGFloat = 0.5
        /// Hairline around the white capsule — the system separator colour, so it tracks the
        /// appearance the way every other divider in the window does.
        static let chipBorder = Color(nsColor: .separatorColor)
    }
}
