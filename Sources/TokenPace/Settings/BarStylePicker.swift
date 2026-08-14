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
/// Deliberately **not** generic, unlike ``SegmentedControl``. That one is shared by five different
/// enums and must stay value-agnostic; this one owns a picture per `BarStyle` case, and making it
/// generic would push the pictures out to the call site — splitting one responsibility across two
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

    /// Tile geometry. The picture is shown at its **natural** size inside a roomier tile rather than
    /// scaled up: the whole point of the preview is "this is what lands in my menu bar", and a
    /// doubled widget answers a question nobody asked. Upscaling a 5 pt bar would also blur the very
    /// slimness `StatusItemView.Metrics.barHeight` is chosen for.
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
        /// The click layer's colour and strength. A mid grey, not a semantic colour: `labelColor` and
        /// friends flip with the theme, and in dark mode a near-white layer reads as the tile lighting
        /// up rather than greying. Black would only deepen a plate that is already black — the tile has
        /// nowhere darker to go, which is why dimming it looks like the whole thing dropping out.
        ///
        /// Kept faint, and lifted just off pure black so the plate turns a touch grey while the mouse
        /// is down without the preview's pacing colours visibly shifting under it.
        static let pressGrey = Color(white: 0.55)
        static let pressTint: CGFloat = 0.14
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
        .accessibilityLabel("Bar style")
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
                    // The pictures are window-mode screen captures, so their transparent margins carry
                    // a black drop shadow at alpha ≤ 24. Over black that shadow is invisible; over any
                    // light surface it would show as a grey halo around every preview.
                    RoundedRectangle(cornerRadius: Tile.cornerRadius, style: .continuous)
                        .fill(Color.black)

                    if let image = Self.images[style] {
                        Image(nsImage: image)
                    }
                }
                .frame(width: Tile.width, height: Tile.height)
                // The click feedback: one grey layer over the whole tile, for exactly as long as the
                // mouse is down. It covers plate and picture together — that is the point, since the
                // capture is opaque (`hasAlpha: no`) and only 54×33 pt of the 80×48 pt tile, so any
                // layer that reaches one but not the other splits the tile into two blacks.
                //
                // Nothing persists after mouse-up: selection is said by the ring, and a picture shown
                // as a specimen of what lands in the menu bar must not keep a colour cast the widget
                // never draws.
                .overlay(
                    RoundedRectangle(cornerRadius: Tile.cornerRadius, style: .continuous)
                        .fill(Tile.pressGrey)
                        .opacity(pressed == style ? Tile.pressTint : 0))
                .overlay(
                    RoundedRectangle(cornerRadius: Tile.cornerRadius, style: .continuous)
                        .strokeBorder(isActive ? Color.accentColor
                                               : Color(nsColor: .separatorColor),
                                      lineWidth: borderWidth))

                Text(title)
                    .font(.callout)
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

    // MARK: Pictures

    /// Preview picture per style, loaded once.
    ///
    /// `Bundle.module` hits the disk on every lookup and `body` re-runs often, so the images are
    /// resolved a single time here instead.
    ///
    /// **This is the seam.** Today a style's picture is a PNG shipped in the target's resource
    /// bundle; it is expected to become a live render of the real widget later, at which point only
    /// this property changes — neither the layout nor the selection logic is touched.
    ///
    /// Because the pictures are frozen, they silently go stale if the widget's geometry or palette
    /// moves. They depend on `StatusItemView.Metrics.barWidth` / `.barHeight` / `.barGap` and on the
    /// pacing colours; change any of those and these files need re-capturing.
    private static let images: [BarStyle: NSImage] = {
        guard let bundle = resourceBundle else { return [:] }
        var loaded: [BarStyle: NSImage] = [:]
        for style in BarStyle.allCases {
            loaded[style] = bundle.image(forResource: resourceName(for: style))
        }
        return loaded
    }()

    /// The target's SwiftPM resource bundle — deliberately **not** `Bundle.module`.
    ///
    /// SwiftPM's generated accessor looks for the bundle next to `Bundle.main.bundleURL` and calls
    /// `fatalError` when it is absent. Inside a real `.app` that URL *is* the app bundle, so it
    /// probes `/Applications/TokenPace_TokenPace.bundle` — while the resources correctly live in
    /// `Contents/Resources/`. The generated fallback is an absolute path into the developer's
    /// `.build` directory, which no installed copy has. Both miss, and the app dies the first time
    /// this pane is opened — the crash behind the `.app`-only trap that `swift run` never shows.
    ///
    /// So the lookup is done here: `Contents/Resources/` first (how a shipped `.app` is laid out),
    /// then beside the executable (how `swift run` lays it out). A miss returns `nil` and the tiles
    /// render without pictures — a decorative preview must never take the app down.
    private static let resourceBundle: Bundle? = {
        let name = "TokenPace_TokenPace.bundle"
        let candidates = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
        ]
        for base in candidates.compactMap({ $0 }) {
            if let bundle = Bundle(url: base.appendingPathComponent(name)) { return bundle }
        }
        // Resources may also be flattened straight into the app's own bundle.
        return Bundle.main
    }()

    /// Resource base name per style. A `switch` without `default` so a fourth `BarStyle` case fails
    /// to compile until it is given a picture — the only guard available, as the app target has no
    /// test target to assert against.
    private static func resourceName(for style: BarStyle) -> String {
        switch style {
        case .pressure: return "bar-style-pressure"
        case .gauge:    return "bar-style-gauge"
        case .progress: return "bar-style-progress"
        }
    }
}

// MARK: - PressReportingButtonStyle

/// A button style that draws its label unchanged and merely **reports** whether it is being pressed.
///
/// `.plain` — the obvious choice for a picture-shaped button — dims the entire label on press. That is
/// wrong here twice over: the label includes the caption, which should not move with the click, and the
/// dimming multiplies against an opaque screen capture differently than against the plate around it, so
/// a held-down tile came apart into two blacks with a seam between them.
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
