import SwiftUI
import TokenPaceKit

// MARK: - BarStylePicker

/// Picks a ``BarStyle`` by **showing** each option rather than naming it, the way System Settings →
/// Appearance picks light/dark: a row of preview pictures, a caption under each, and an accent ring
/// around the chosen one.
///
/// The difference between the three styles is purely visual — where the strip starts, whether a time
/// marker rides on it, which zero it measures from — so three words never conveyed it. Prose was
/// tried and deliberately removed (#341): three paragraphs describing the styles cost more vertical
/// space than they bought. A picture is what that gap wanted.
///
/// Each tile is drawn at runtime by the widget's own code (``BarStylePreviewRenderer``), so a preview
/// cannot drift away from the bar it advertises. It shipped as three captured PNGs first (ADR-0093 §1
/// named that an interim step and left this seam for exactly this change).
///
/// Deliberately **not** generic, unlike ``SegmentedControl``. That one is shared by five different
/// enums and must stay value-agnostic; this one owns a rendered specimen per `BarStyle` case, and
/// making it generic would push that out to the call site — splitting one responsibility across two
/// files for no gain. One consumer, one concrete type.
struct BarStylePicker: View {
    /// The currently selected style — drawn with the accent ring and a heavier caption.
    let active: BarStyle
    /// Called when the user picks a style. The caller persists it (see `SettingsModel`).
    let onSelect: (BarStyle) -> Void

    /// Which tile the pointer is over, if any. Drives a slightly stronger border on hover, matching
    /// the small lift the system picker gives its thumbnails.
    @State private var hovered: BarStyle?

    /// Which tile the mouse is currently held down on, if any. Purely transient: it is set on mouse-
    /// down and cleared on mouse-up, so the grey press layer it drives leaves nothing behind.
    @State private var pressed: BarStyle?

    /// Tile geometry. The specimen is shown at its **natural** size inside a roomier tile rather than
    /// scaled up: the whole point of the preview is "this is what lands in my menu bar", and a
    /// doubled widget answers a question nobody asked. Upscaling a 5 pt bar would also blur the very
    /// slimness `StatusItemView.Metrics.barHeight` is chosen for — and the render already arrives at
    /// a 2× backing, so there is no sharpness to gain by stretching it.
    private enum Tile {
        static let width: CGFloat = 80
        static let height: CGFloat = 48
        static let spacing: CGFloat = 12
        static let cornerRadius: CGFloat = 6
        /// Ring width of the selected tile. Drawn with `strokeBorder` (inside the shape) so selecting
        /// a tile does not change its footprint — with `stroke` the ring straddles the edge and the
        /// whole row would jump on every click.
        static let activeBorder: CGFloat = 3
        static let idleBorder: CGFloat = 1
        static let hoverBorder: CGFloat = 1.5
        /// The grey a pressed tile's black is raised to. Composited with `.lighten`, which keeps
        /// whichever is brighter per channel, so it acts as a **floor**: the black plate comes up to
        /// this grey, while the specimen's greens, yellows and oranges are already brighter and pass
        /// through untouched. This only works because the plate under the render is opaque — see the
        /// plate's own note in `tile(for:title:)`.
        ///
        /// A plain translucent layer cannot do this. Alpha lifts every pixel in proportion, so the
        /// black — the part meant to change — barely moves while the bright bars visibly wash out:
        /// exactly backwards. Hence a blend rather than an opacity.
        ///
        /// Tuned by eye down a ladder of rejected takes — 0.34, 0.26, 0.20, 0.16 — each of which
        /// turned the plate into a grey tile rather than a black one acknowledging a click. The press
        /// should be felt, not announced.
        ///
        /// The last step down came with the live render (#373). The specimen is smaller than the
        /// captures it replaced (38×22 pt against 54×33), so proportionally more of the tile is bare
        /// plate — and the same grey therefore covers more area and reads louder than it did when it
        /// was chosen, even though the value had not changed.
        static let pressGrey = Color(white: 0.12)
    }

    var body: some View {
        HStack(spacing: Tile.spacing) {
            // Iterate the shared segment list rather than a second list of names: the order is a
            // deliberate gradient (see `AppearanceBarStyle`), and the dropdown row still renders from
            // the same array. Two lists would drift.
            ForEach(AppearanceBarStyle.segments) { segment in
                tile(for: segment.value, title: segment.title)
            }
        }
        .accessibilityElement(children: .contain)
        // Matches the visible row label verbatim — VoiceOver naming the group differently from what the
        // eye reads is a mismatch, not extra context.
        .accessibilityLabel("Style")
    }

    private func tile(for style: BarStyle, title: String) -> some View {
        let isActive = style == active
        let borderWidth = isActive ? Tile.activeBorder
                                   : (hovered == style ? Tile.hoverBorder : Tile.idleBorder)

        // A real Button, never `.onTapGesture` — a raw gesture is swallowed by window activation, so
        // the first click on a non-key Settings window would do nothing (the bug that shaped
        // `SegmentedControl`). A large clickable picture invites the gesture spelling; resist it.
        return Button {
            onSelect(style)
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    // Black in BOTH themes, on purpose — not an oversight, and not a semantic colour.
                    //
                    // Two reasons, and the second one is structural:
                    //
                    // 1. It is the truth about the subject. The menu bar is dark under a light theme
                    //    too, and the specimen is baked for a dark vibrant surface to match
                    //    (`BarStylePreviewRenderer`), so a light plate would show it against a backing
                    //    it never has.
                    // 2. **The press layer below depends on it.** `.lighten` compares against what is
                    //    underneath, and the render carries an alpha channel; over a transparent pixel
                    //    the blend would post `pressGrey` straight out and flood the tile. This opaque
                    //    plate flattens the render first, which is what keeps the press a floor on the
                    //    black rather than a wash over everything. Removing it does not simplify the
                    //    tile — it breaks the click feedback.
                    RoundedRectangle(cornerRadius: Tile.cornerRadius, style: .continuous)
                        .fill(Color.black)

                    // Drawn live by the real widget code rather than loaded from a screenshot (#371),
                    // so the tiles cannot fall out of step with the bar they advertise. No
                    // `.resizable()`: the image carries its natural size in points and a 2× backing,
                    // which is exactly how it should land here.
                    Image(nsImage: BarStylePreviewRenderer.image(for: style))
                }
                .frame(width: Tile.width, height: Tile.height)
                // The click feedback: one grey layer over the whole tile, for exactly as long as the
                // mouse is down. It covers plate and specimen together — that is the point, since the
                // widget occupies only its own few dozen points of the 80×48 pt tile, so any layer
                // that reaches one but not the other splits the tile into two blacks.
                //
                // Nothing persists after mouse-up: selection is said by the ring, and a specimen of
                // what lands in the menu bar must not keep a colour cast the widget never draws.
                .overlay(
                    RoundedRectangle(cornerRadius: Tile.cornerRadius, style: .continuous)
                        .fill(Tile.pressGrey)
                        .blendMode(.lighten)
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
                    // A step down from the pane's body text, but not the caption size: `.caption`
                    // read as visibly tiny here and `.callout` as heavier than the pictures it
                    // labels. The caption names what the picture already shows, so it should sit
                    // just below the row's own label rather than match it.
                    .font(.subheadline)
                    .fontWeight(isActive ? .semibold : .regular)
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    // Fixed width so the heavier selected caption cannot widen its column — without
                    // it the row shifts a little on every click.
                    .frame(width: Tile.width)
            }
            .contentShape(Rectangle())
        }
        // Not `.plain`: that style dims the whole label — picture, caption and all — and its dimming
        // multiplies against the opaque capture differently than against the plate around it, so a
        // held-down tile visibly split into two blacks. This one dims nothing and only reports the
        // press, which the label above paints as a single grey layer over the tile.
        .buttonStyle(PressReportingButtonStyle(isPressed: $pressed, value: style))
        .onHover { inside in
            if inside { hovered = style } else if hovered == style { hovered = nil }
        }
        // The caption naming the style lives in a sibling view, so the button needs its own name.
        //
        // Measured caveat: in the live AX tree these tiles still report `missing value` for `name` —
        // but so do the five `SegmentedControl` buttons already on this pane, so it is how
        // `.buttonStyle(.plain)` exposes itself here rather than anything specific to this control.
        // The label is kept because it is the correct declaration and costs nothing; making plain
        // buttons expose names is a pane-wide fix, not this control's to make.
        .accessibilityLabel(Text(title))
        // `.isSelected` is what makes VoiceOver announce the current choice; without it all three
        // tiles read identically and the state is simply absent.
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

}

// MARK: - PressReportingButtonStyle

/// A button style that draws its label unchanged and merely **reports** whether it is being pressed.
///
/// `.plain` — the obvious choice for a picture-shaped button — dims the entire label on press. That is
/// wrong here twice over: the label includes the caption, which should not move with the click, and the
/// dimming multiplies against the specimen differently than against the plate around it, so a held-down
/// tile came apart into two blacks with a seam between them.
///
/// Reporting instead of drawing lets the caller put one flat layer over the tile alone, where it covers
/// picture and plate identically. `isPressed` is bound out rather than handed to a closure so the press
/// can drive ordinary view state; it is written on both edges, so mouse-up always clears it.
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
