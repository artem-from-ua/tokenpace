import AppKit
import TokenPaceKit

// MARK: - LegendRenderer (#261)

/// Draws the specimens the **Legend** pane shows — with the real widget and bar code, at runtime,
/// exactly as the two `…PreviewRenderer`s do for the style tiles (ADR-0093, ADR-0097).
///
/// A third renderer rather than an extension of those two: those answer "how do the three styles
/// differ" and hold one specimen frame constant across three renders; this one answers "what does
/// each mark mean" and varies the frame per row while holding the style constant.
///
/// **Every state comes from ``LegendCatalog``**, built through `PacingModel.barLayout` — literals
/// written here would risk a legend that disagrees with the model it explains.
@MainActor
enum LegendRenderer {

    // MARK: Menu-bar widget

    /// The widget drawn with `fiveHour` above `sevenDay`, either of which may be absent. Passing
    /// `nil` for the five-hour bar is not a trick — `MenuBarMode.expanded` takes both as optionals
    /// precisely because `TopBarHiding` drops the calm top bar in the live widget.
    ///
    /// Baked under **VibrantDark always**, matching `BarStylePreviewRenderer`: the menu bar is a dark
    /// vibrant surface under a light theme too, and system colours resolve differently there. A
    /// specimen baked for the window's theme would show the widget against a backing it never has.
    static func menuBarImage(fiveHour: BarLayout?, sevenDay: BarLayout?) -> NSImage {
        let view = StatusItemView(frame: .zero)
        // Without this the widget reserves the awaiting-input slot from `PersistedConfig`, so the
        // specimen's width would depend on a setting the page is not talking about.
        view.isPreviewSpecimen = true
        view.layout = MenuBarLayout(mode: .expanded(
            fiveHour: fiveHour.map { BarView(layout: $0, indicator: .neutral, window: .fiveHour) },
            sevenDay: sevenDay.map { BarView(layout: $0, indicator: .neutral, window: .sevenDay) }))
        // Balance: shows *direction* without a marker, which is what this section wants — how many
        // bars there are, not where the marks sit.
        view.barStyle = .balance
        // Full-strength colour, pinned rather than read from the user's setting: a specimen that
        // muted itself here would illustrate the reader's configuration instead of the rule.
        view.colorsTell = .howItsGoing
        // A specimen has no previous value to ease away from, so colours resolve straight to target.
        view.colorAnimator = nil

        // Force-unwrapped: `.vibrantDark` is a system-defined name that cannot be absent, and an
        // optional-chained call would silently skip the render and leave a blank image untraceable.
        let appearance = NSAppearance(named: .vibrantDark)!
        var image = NSImage()
        appearance.performAsCurrentDrawingAppearance { image = view.snapshotImage() }
        return image
    }

    // MARK: Dropdown bars

    /// One popup bar, drawn at `width` with no chrome around it.
    ///
    /// **Width is a parameter here**, unlike in `DropdownBarStylePreviewRenderer` where it is a
    /// constant: this page draws a wide anatomy bar above narrow reading-rule bars, and the
    /// difference in length is part of what distinguishes the two kinds of row.
    ///
    /// Whether a row may show blue rides on the `layout` the caller passes
    /// (``BarLayout/blueAllowed``) — the legend's specimens build theirs through
    /// `PacingModel.barLayout`, so a blue rung stays blue here for free.
    static func dropdownBarImage(_ layout: BarLayout, style: BarStyle, width: CGFloat,
                                 subdivisions: Int = 0,
                                 showsRuler: Bool = false,
                                 appearance: NSAppearance? = nil) -> NSImage {
        let view = PopupBarView(frame: .zero)
        view.bar = layout
        view.subdivisions = subdivisions
        view.barStyle = style
        // A step brighter than the popup's own track, and only here (#261): `monochromeGrey` reads
        // right on a vibrant card, but all but vanishes on a flat Settings form with no surrounding
        // rows to say where the bar is. A **quarter** of the way toward quaternary, not the whole way
        // — plain `tertiaryLabelColor` overshot and competed with the coloured ribbon on top.
        //
        // A **dynamic** colour, not a blend computed here: `blended` resolves against whatever
        // appearance is current at the call site, which runs before `performAsCurrentDrawing` below —
        // computing it inside the provider is what makes the tone flip with the theme.
        // Dialled down for the same flat-form reason: at full strength the marker's halo blooms, and
        // this page has a callout pointing *at* the marker.
        view.markerGlowScale = 0.4
        // Same reason, a **strength** scale rather than radius: the strip has no callout and is the
        // widest coloured thing on the page, so fading (not shrinking) reads as the same glow, quieter.
        view.stripGlowScale = 0.35
        // Teeth at shipped size — a legend that redraws the thing it explains at a size the app never
        // uses teaches the wrong picture; the leader pointing at them does the job extra pixels would.
        view.trackTint = NSColor(name: nil) { appearance in
            var mixed: NSColor = .tertiaryLabelColor
            appearance.performAsCurrentDrawingAppearance {
                mixed = NSColor.tertiaryLabelColor
                    .blended(withFraction: 0.25, of: .quaternaryLabelColor) ?? .tertiaryLabelColor
            }
            return mixed
        }
        // **The ruler is on for the anatomy bars**, unlike every other specimen in the app: ADR-0098
        // puts the teeth behind ⌥ in the live dropdown and the style tiles keep them off entirely, but
        // this page exists to *name the parts*, and a diagram captioned "ticks" beside a bar with no
        // ticks explains nothing. Off by default so reading-rule bars stay uncluttered.
        view.optionHeld = showsRuler

        // **Tall enough for the ruler.** `viewHeight` stops at the track's foot (#388), so a canvas
        // that height would clip the teeth to 2 of their 5 pt when the ruler is always on here.
        let rulerDepth: CGFloat = showsRuler ? PopupBarView.rulerDepth : 0
        let size = NSSize(width: width, height: PopupBarView.viewHeight + rulerDepth)
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        // Baked under the **current** theme's vibrant appearance, not a pinned one: the dropdown is a
        // card that flips with the system. Passed explicitly since this view can be hosted under a
        // forced appearance, where `NSApp`'s would be wrong — and assigning `NSApp.appearance`
        // directly doesn't take effect until the run loop turns.
        (appearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
            view.render(in: NSRect(origin: .zero, size: size))
        }
        image.unlockFocus()
        // The specimen carries real pacing colour a template mask would strip.
        image.isTemplate = false
        return image
    }

    // MARK: Pacing swatches

    /// Computed rather than listed, through the **same two functions the live bars call** — a
    /// hand-written list of hexes would be a sixth palette to keep in step with the other five.
    static func tierColor(_ layout: BarLayout) -> NSColor {
        layout.pacing == .ahead
            ? PopupBarView.aheadColor(usage: layout.usageFraction, time: layout.timeFraction,
                                      remainingSeconds: layout.remainingSeconds)
            : PopupBarView.behindColor(layout)
    }

    // MARK: Glyphs

    /// One of the widget's own glyphs, at the size and weight the widget draws it. Symbol *names*
    /// come from ``LegendGlyphs``, which the draw sites read too, so this cannot advertise a glyph
    /// the widget no longer uses.
    ///
    /// **Returned as a template**, with no colour baked in — the caller tints it with
    /// `.foregroundStyle`, which SwiftUI re-resolves on every theme flip. A non-template image would
    /// freeze the colour at bake time.
    static func glyphImage(_ name: String, pointSize: CGFloat = 12) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        symbol.isTemplate = true
        return symbol
    }
}
