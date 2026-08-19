import AppKit
import TokenPaceKit

// MARK: - LegendRenderer (#261)

/// Draws the specimens the **Legend** pane shows — with the real widget and bar code, at runtime,
/// exactly as the two `…PreviewRenderer`s do for the style tiles (ADR-0093, ADR-0097).
///
/// A third renderer rather than an extension of those two, for the reason ADR-0097 gives for keeping
/// *them* apart: each is pinned to the job it illustrates, and the concrete decisions differ. Those
/// two answer "how do the three styles differ" and therefore hold one specimen frame constant across
/// three renders. This one answers "what does each mark mean" and therefore varies the frame per row
/// while holding the style constant. Merging them would mean a parameter for every axis both fix.
///
/// **Every state comes from ``LegendCatalog``**, which builds it through `PacingModel.barLayout`. The
/// alternative — literals written here — is what the other two renderers explicitly refuse, and this
/// page has more reason to refuse it than they do: a legend that disagreed with the model would be a
/// reference that lies about the thing it references.
@MainActor
enum LegendRenderer {

    // MARK: Menu-bar widget

    /// The widget drawn with `fiveHour` above `sevenDay`, either of which may be absent.
    ///
    /// Passing `nil` for the five-hour bar is how the "one bar" render is made, and it is not a trick:
    /// `MenuBarMode.expanded` takes both as optionals precisely because `TopBarHiding` drops the calm
    /// top bar in the live widget. The two Legend renders are therefore the same code path the app
    /// takes, one frame apart, rather than a picture of a state and a picture of a different state.
    ///
    /// Baked under **VibrantDark always**, matching `BarStylePreviewRenderer`: the menu bar is a dark
    /// vibrant surface under a light theme too, and system colours resolve differently there
    /// (`labelColor` α 0.847 in DarkAqua against 0.898 in VibrantDark). A specimen baked for the
    /// window's theme would show the widget against a backing it never has.
    static func menuBarImage(fiveHour: BarLayout?, sevenDay: BarLayout?) -> NSImage {
        let view = StatusItemView(frame: .zero)
        // Without this the widget reserves the awaiting-input slot from `PersistedConfig`, so the
        // specimen's width would depend on a setting the page is not talking about — and the two
        // renders in the Menu bar section would shift relative to each other for an unrelated reason.
        view.isPreviewSpecimen = true
        view.layout = MenuBarLayout(mode: .expanded(
            fiveHour: fiveHour.map { BarView(layout: $0, indicator: .neutral, window: .fiveHour) },
            sevenDay: sevenDay.map { BarView(layout: $0, indicator: .neutral, window: .sevenDay) }))
        // Balance: the default style, and the one that shows *direction* without a marker — which is
        // what this section wants, since it is about how many bars there are, not where the marks sit.
        view.barStyle = .balance
        // Full-strength colour, pinned rather than read from the user's setting: the section explains
        // the calm/loud distinction elsewhere, and a specimen that muted itself here would illustrate
        // the reader's configuration instead of the rule.
        view.colorsTell = .howItsGoing
        // A specimen has no previous value to ease away from, so colours resolve straight to target.
        view.colorAnimator = nil

        // Force-unwrapped for the reason `BarStylePreviewRenderer` states: `.vibrantDark` is a
        // system-defined name that cannot be absent, and an optional-chained call would silently skip
        // the render and leave a blank image with nothing to trace it to.
        let appearance = NSAppearance(named: .vibrantDark)!
        var image = NSImage()
        appearance.performAsCurrentDrawingAppearance { image = view.snapshotImage() }
        return image
    }

    // MARK: Dropdown bars

    /// One popup bar, drawn at `width` with no chrome around it.
    ///
    /// **Width is a parameter here**, unlike in `DropdownBarStylePreviewRenderer` where it is a
    /// constant: the style tiles are a set of like-for-like comparisons and must share a width, while
    /// this page draws a wide anatomy bar above narrow reading-rule bars, and the difference in length
    /// is part of what distinguishes the two kinds of row.
    ///
    /// The scale is inset by `minStripWidth/2` at each end — a constant derived from the bar's height,
    /// not its length — so a narrower bar spends proportionally more of itself on that inset and its
    /// marks shift by up to ~2 % of the width. Measured and accepted in ADR-0097 for the 56 pt tile;
    /// the same holds here. Shapes and their order are identical, which is what the rows are about.
    static func dropdownBarImage(_ layout: BarLayout, style: BarStyle, width: CGFloat,
                                 subdivisions: Int = 0, isBaseLimit: Bool = true,
                                 appearance: NSAppearance? = nil) -> NSImage {
        let view = PopupBarView(frame: .zero)
        view.bar = layout
        view.subdivisions = subdivisions
        view.isBaseLimit = isBaseLimit
        view.barStyle = style
        // `optionHeld` stays false: ⌥ reveals the ruler's explanatory teeth *while held*, so a
        // specimen baked with them on advertises a state the page is not in. The mark that identifies
        // a marker-less style — the zero struck through the track — is drawn unconditionally.

        let size = NSSize(width: width, height: PopupBarView.viewHeight)
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        // Baked under the **current** theme's vibrant appearance, not a pinned one: the dropdown is a
        // card that flips with the system. The caller passes it explicitly because this view can be
        // hosted under a forced appearance, where `NSApp`'s would be the wrong one — and because
        // assigning `NSApp.appearance` does not take effect until the run loop turns, which silently
        // produced two copies of one theme when ADR-0097's author tried it.
        (appearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
            view.render(in: NSRect(origin: .zero, size: size))
        }
        image.unlockFocus()
        // The specimen carries real pacing colour a template mask would strip.
        image.isTemplate = false
        return image
    }

    // MARK: Pacing swatches

    /// The colour a bar in this state draws its ribbon in — the pane's five tier swatches.
    ///
    /// Computed rather than listed, through the **same two functions the live bars call**
    /// (`StatusItemView.gapColorTarget` branches identically). A hand-written list of five hexes would
    /// be a sixth palette to keep in step with the other five, and the first threshold change would
    /// make the legend disagree with the widget it explains.
    static func tierColor(_ layout: BarLayout) -> NSColor {
        layout.pacing == .ahead
            ? PopupBarView.aheadColor(usage: layout.usageFraction, time: layout.timeFraction,
                                      remainingSeconds: layout.remainingSeconds)
            : PopupBarView.behindColor(layout)
    }

    // MARK: Glyphs

    /// One of the widget's own glyphs, at the size and weight the widget draws it.
    ///
    /// The symbol *names* come from ``LegendGlyphs``, which the draw sites read too — so this cannot
    /// advertise a glyph the widget no longer uses. What is duplicated is only the four lines of
    /// `SymbolConfiguration`, because every glyph routine on `StatusItemView` is private and there is
    /// no seam that returns one icon; the alternative, rendering the whole widget per row, would put a
    /// bar and a countdown beside every caption.
    static func glyphImage(_ name: String, tint: NSColor, pointSize: CGFloat = 12) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }

        let image = NSImage(size: symbol.size)
        image.lockFocus()
        symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
        tint.set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
