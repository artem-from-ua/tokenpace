import SwiftUI
import TokenPaceKit

// MARK: - BarStylePicker

/// Picks a ``BarStyle`` by **showing** each option rather than naming it, the way System Settings →
/// Appearance picks light/dark: a row of preview pictures, a caption under each, and an accent ring
/// around the chosen one. Prose describing the styles was tried and removed (#341) — the difference
/// is purely visual.
///
/// Each tile is drawn at runtime by the widget's own code (``BarStylePreviewRenderer``), so a preview
/// cannot drift away from the bar it advertises.
///
/// Deliberately **not** generic, unlike ``SegmentedControl``: that one is value-agnostic across five
/// enums, while this one owns a rendered specimen per `BarStyle` case — making it generic would push
/// that out to the call site for no gain.
struct BarStylePicker: View {

    /// Which widget a tile is a specimen **of**. The two surfaces draw the same three styles but are
    /// not the same picture (ADR-0097): the menu-bar specimen bakes under a fixed `.vibrantDark` on a
    /// black plate (the menu bar is dark under a light theme too); the dropdown specimen bakes under
    /// the *current* appearance, since that surface flips with the system.
    enum Surface {
        case menuBar
        case dropdown

        /// The tile's plate. Black for the menu bar in both themes (load-bearing for the press blend
        /// — see `tile(for:title:)`). For the dropdown, the **card's** opaque fill
        /// (`cardPlateFillOpaque`), not the menu plate the card floats on — the bars sit on the card,
        /// so that's what a specimen of them sits on too.
        var plate: Color {
            switch self {
            case .menuBar:  Color.black
            case .dropdown: Color(nsColor: .cardPlateFillOpaque)
            }
        }

        /// Whether the plate is opaque enough for the `.lighten` press overlay to act as a floor
        /// rather than a wash. Black qualifies; the card colour is mid grey/near-white, where
        /// lightening reads as a flash instead of a press.
        var usesLightenPress: Bool { self == .menuBar }
    }

    /// Which widget these tiles preview.
    let surface: Surface
    /// The currently selected style — drawn with the accent ring and a heavier caption.
    let active: BarStyle
    /// Called when the user picks a style. The caller persists it (see `SettingsModel`).
    let onSelect: (BarStyle) -> Void

    /// Drives a slightly stronger border on hover, matching the small lift the system picker gives
    /// its thumbnails.
    @State private var hovered: BarStyle?

    /// Purely transient: set on mouse-down, cleared on mouse-up, so the grey press layer leaves
    /// nothing behind.
    @State private var pressed: BarStyle?

    /// Read **only** to make this view depend on the theme. The specimens are baked non-template
    /// `NSImage`s that don't re-resolve their semantic colors on their own — without this the
    /// dropdown tile (whose palette flips with the system, ADR-0097) would keep whichever theme's
    /// neutrals it was first drawn under. The menu-bar tile is immune (pinned `.vibrantDark`).
    @Environment(\.colorScheme) private var colorScheme

    /// The specimen is shown at its **natural** size inside a roomier tile, not scaled up: the point
    /// of the preview is "this is what lands in my menu bar", and upscaling a 5 pt bar would blur the
    /// slimness `StatusItemView.Metrics.barHeight` is chosen for.
    private enum Tile {
        static let width: CGFloat = 80
        static let height: CGFloat = 48
        static let spacing: CGFloat = 12
        static let cornerRadius: CGFloat = 6
        /// Drawn with `strokeBorder` (inside the shape) so selecting a tile does not change its
        /// footprint — with `stroke` the ring straddles the edge and the row jumps on every click.
        static let activeBorder: CGFloat = 3
        static let idleBorder: CGFloat = 1
        static let hoverBorder: CGFloat = 1.5
        /// The grey a pressed tile's black is raised to, composited with `.lighten` (keeps whichever
        /// channel is brighter) so it acts as a **floor**: the black plate rises to this grey while
        /// the specimen's bright bars pass through untouched. A plain translucent layer can't do this
        /// — alpha would lift every pixel in proportion, washing out the bright bars instead. Only
        /// works because the plate under the render is opaque (see `tile(for:title:)`). Tuned by eye.
        static let pressGrey = Color(white: 0.12)

        /// The dropdown tile's press layer: a neutral scrim at low alpha, composited normally.
        /// `pressGrey`'s `.lighten` trick needs a black plate to floor on; this surface's plate is mid
        /// grey/near-white, so the same layer would flash or vanish depending on theme.
        static let pressScrim = Color(white: 0, opacity: 0.14)
    }

    var body: some View {
        HStack(spacing: Tile.spacing) {
            // Iterate the shared segment list rather than a second list of names, or the two drift.
            ForEach(AppearanceBarStyle.segments) { segment in
                tile(for: segment.value, title: segment.title)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Style")
    }

    private func tile(for style: BarStyle, title: String) -> some View {
        let isActive = style == active
        let borderWidth = isActive ? Tile.activeBorder
                                   : (hovered == style ? Tile.hoverBorder : Tile.idleBorder)

        // A real Button, never `.onTapGesture`: a raw gesture is swallowed by window activation, so
        // the first click on a non-key Settings window would do nothing.
        return Button {
            onSelect(style)
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    // Black in BOTH themes: (1) it's the truth about the subject — the menu bar is
                    // dark under a light theme too, matching the specimen's dark vibrant bake; (2) the
                    // press layer below depends on it — `.lighten` over a transparent pixel would post
                    // `pressGrey` straight out and flood the tile, so this opaque plate flattens the
                    // render first. For the dropdown, the popup card's own colour instead — that
                    // surface flips with the theme, so a black plate would show the specimen against a
                    // backing it never has.
                    RoundedRectangle(cornerRadius: Tile.cornerRadius, style: .continuous)
                        .fill(surface.plate)

                    // Drawn live by the real widget code rather than loaded from a screenshot (#371),
                    // so the tiles cannot fall out of step with the bar they advertise.
                    switch surface {
                    case .menuBar:
                        Image(nsImage: BarStylePreviewRenderer.image(for: style))
                    case .dropdown:
                        // Baked under the **vibrant** appearance of the current theme: the live bars
                        // draw inside an `NSMenu`, a vibrant surface where the palette resolves
                        // differently (opaque track, different green) than under a plain appearance.
                        // Passed explicitly rather than read from `NSApp`, since this view can be
                        // hosted under a forced appearance.
                        Image(nsImage: DropdownBarStylePreviewRenderer.image(
                            for: style,
                            size: NSSize(width: Tile.width, height: Tile.height),
                            appearance: NSAppearance(
                                named: colorScheme == .dark ? .vibrantDark : .vibrantLight)))
                    }
                }
                .frame(width: Tile.width, height: Tile.height)
                // One grey layer over the whole tile, covering plate and specimen together — a layer
                // reaching one but not the other would split the tile into two blacks. Nothing
                // persists after mouse-up: selection is said by the ring.
                .overlay(
                    RoundedRectangle(cornerRadius: Tile.cornerRadius, style: .continuous)
                        .fill(surface.usesLightenPress ? Tile.pressGrey : Tile.pressScrim)
                        .blendMode(surface.usesLightenPress ? .lighten : .normal)
                        .opacity(pressed == style ? 1 : 0))
                // `.lighten` compares against the layer below, so the tile has to be its own
                // compositing group — without this the blend would reach the pane behind it too.
                .compositingGroup()
                .overlay(
                    RoundedRectangle(cornerRadius: Tile.cornerRadius, style: .continuous)
                        .strokeBorder(isActive ? Color.accentColor
                                               : Color(nsColor: .separatorColor),
                                      lineWidth: borderWidth))

                Text(title)
                    // `.caption` read as visibly tiny here, `.callout` as heavier than the picture.
                    .font(.subheadline)
                    .fontWeight(isActive ? .semibold : .regular)
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    // Fixed width so the heavier selected caption cannot widen its column.
                    .frame(width: Tile.width)
            }
            .contentShape(Rectangle())
        }
        // Not `.plain`: that dims the whole label — picture, caption and all — and its dimming
        // multiplies against the opaque capture differently than against the plate around it, so a
        // held-down tile visibly split into two blacks.
        .buttonStyle(PressReportingButtonStyle(isPressed: $pressed, value: style))
        .onHover { inside in
            if inside { hovered = style } else if hovered == style { hovered = nil }
        }
        // The caption naming the style lives in a sibling view, so the button needs its own name.
        // In the live AX tree these tiles report `missing value` for `name` anyway — so do the five
        // `SegmentedControl` buttons on this pane, so it is how a plain SwiftUI button exposes
        // itself, not a defect here. The label stays: it is the correct declaration, and making
        // plain buttons expose names is a pane-wide fix.
        .accessibilityLabel(Text(title))
        // `.isSelected` is what makes VoiceOver announce the current choice; without it all three
        // tiles read identically and the state is simply absent.
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

}

// MARK: - PressReportingButtonStyle

/// A button style that draws its label unchanged and merely **reports** whether it is being pressed.
/// `.plain` — the obvious choice for a picture-shaped button — dims the entire label on press,
/// including the caption, and the dimming multiplies against the specimen differently than against
/// the plate around it, so a held-down tile came apart into two blacks with a seam between them.
struct PressReportingButtonStyle<Value: Equatable>: ButtonStyle {
    /// Set to `value` while this button is held down, and cleared back to `nil` on release.
    @Binding var isPressed: Value?
    /// Identifies this button among its siblings — the row shares one `isPressed` binding.
    let value: Value

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, nowPressed in
                if nowPressed {
                    isPressed = value
                } else if isPressed == value {
                    isPressed = nil
                }
            }
    }
}
