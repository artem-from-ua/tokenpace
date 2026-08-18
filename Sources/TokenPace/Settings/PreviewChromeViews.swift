import AppKit

/// Chrome for rendering the popup **outside** a real `NSMenu`: the Settings window's "Dropdown live
/// preview" (ADR-0083).
///
/// These types once served two previews — the dev colour tuner had its own "Popup Preview" window —
/// and lived under the tuner's folder for that reason. ADR-0106 removed the tuner, leaving the
/// Settings preview as the only consumer; the file moved here with it, unchanged.
///
/// Both metrics below were fought for once already: they describe the surface being imitated, not the
/// window doing the imitating, so they belong in one place even with a single caller.
@MainActor
enum PreviewChrome {

    /// The corner radius of a **menu-bar pop-up** on the running macOS version, so a borderless preview
    /// reads as the real popup rather than a plain window. The menu window class (`_NSMenuWindow`) is
    /// private with no public metric, so this is keyed off the OS version — matched visually against a
    /// real TokenPace menu: macOS 15 Sequoia menus use ~10 pt; macOS 26 Tahoe rounds them more (~14 pt).
    static func menuPopupCornerRadius() -> CGFloat {
        if #available(macOS 26.0, *) { return 14 }
        return 10   // macOS 11–15
    }

    /// Whether the app is currently rendering dark — drives the **Vibrant** appearance a preview
    /// window must force.
    ///
    /// Not cosmetic: a real menu window is `NSAppearanceNameVibrantDark`, and system label colours
    /// resolve differently under vibrancy — the popup's translucent grey track resolves to an opaque
    /// `#323232` in VibrantDark versus a light `white@0.17` in DarkAqua. Without the force, a
    /// preview's neutrals read noticeably lighter than the live menu, which is the one thing a
    /// preview must never do.
    static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// The Vibrant appearance matching the current theme, for a preview window's `appearance`.
    static var vibrantAppearance: NSAppearance? {
        NSAppearance(named: isDark ? .vibrantDark : .vibrantLight)
    }

    /// A backing view carrying the system's **menu** material, rounded to the popup's radius.
    ///
    /// The real dropdown is translucent: `CardBackdropView` fills at partial alpha precisely so the
    /// `NSMenu` material beneath lends the plate its tone, and the popup's edges pick up what is behind
    /// the window. A flat fill has nothing underneath, so the card reads as one dead slab and the edges
    /// lose that depth — visible immediately when the preview sits next to a live dropdown.
    ///
    /// `.menu` is the material the popup is actually drawn over, and `.behindWindow` is what lets the
    /// desktop through — the same combination the system menu window uses.
    ///
    /// A flat fill matched to the live menu (sRGB `#212121` in dark) is the right answer only where the
    /// job is to *measure* a colour rather than resemble the surface (#202) — a vibrancy view renders
    /// lighter than the live menu. Here the job is resemblance, so the material wins.
    static func makeMenuMaterialBackdrop() -> MenuMaterialBackdrop {
        let view = MenuMaterialBackdrop()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        // `maskImage`, not `layer.cornerRadius`: an NSVisualEffectView composites its material outside
        // the normal layer path, so a corner radius with `masksToBounds` leaves the material square and
        // only clips the subviews — square corners with a rounded frame drawn inside them. The mask is
        // the documented way to round one, and it is what gives the window the real popup's silhouette.
        view.maskImage = roundedMask(radius: menuPopupCornerRadius())
        return view
    }

    /// A resizable, nine-part rounded-rectangle mask for `NSVisualEffectView.maskImage`.
    ///
    /// Cap insets keep the corners crisp at any size: only the middle strips stretch, so the radius does
    /// not distort as the preview grows with its content.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// The preview card's backing: the system **menu** material while the window is active, an opaque fill
/// once it is not.
///
/// The active look is the whole point of the preview and is left untouched — plain `.menu` material
/// with `.behindWindow` blending, the same recipe the live dropdown's own surface uses.
///
/// The inactive look exists because translucency is how macOS signals *"this surface is live"*. A
/// preview that keeps showing the desktop through itself while nobody is using it competes with the
/// window that does have focus, and the wallpaper shifting behind it is pure noise. Switching the
/// material off and falling back to a flat tone is what system surfaces of this kind do.
///
/// The inactive tone is ``NSColor/previewInactiveBackground`` — see there for why each theme resolves
/// the way it does.
@MainActor
final class MenuMaterialBackdrop: NSVisualEffectView {

    /// Whether the owning window is active. Drives the material ⇄ flat swap.
    var isWindowActive = true {
        didSet {
            guard isWindowActive != oldValue else { return }
            applyState()
        }
    }

    /// The opaque fill shown while the window is inactive, as a **sibling below** the material rather
    /// than a colour on the effect view's own layer.
    ///
    /// Painting `layer.backgroundColor` on an `NSVisualEffectView` costs it its blur: the view renders
    /// its material through that layer, so taking the layer over for a plain fill leaves a flat tint
    /// with no blur behind it — translucency without vibrancy, which is exactly the wrong half.
    private lazy var inactiveFill: ThemedFillView = {
        let fill = ThemedFillView()
        fill.fillColor = .previewInactiveBackground
        fill.translatesAutoresizingMaskIntoConstraints = false
        fill.isHidden = true
        addSubview(fill, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            fill.topAnchor.constraint(equalTo: topAnchor),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor),
            fill.leadingAnchor.constraint(equalTo: leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        return fill
    }()

    private func applyState() {
        // Active: the untouched `.menu` / `.behindWindow` material — the look that matches the live
        // dropdown, left exactly as it was.
        //
        // Inactive: `.inactive` stops the material sampling, and the opaque sibling below shows through
        // in its place. Nothing about the active path changes.
        state = isWindowActive ? .active : .inactive
        inactiveFill.isHidden = isWindowActive
    }
}

extension NSColor {

    /// Fill behind the preview card once its window goes inactive and the vibrancy switches off.
    ///
    /// **Dark → `underPageBackgroundColor`, which resolves to exactly `#282828`** — the tone asked for,
    /// and reaching it through the semantic colour rather than a literal means it tracks any future
    /// system revision instead of drifting from it.
    ///
    /// **Light → `windowBackgroundColor` (`#ECECEC`).** `underPageBackgroundColor` is *not* the light
    /// counterpart despite being the same API: it resolves to `#969696` at 90 % alpha there — a mid grey
    /// meant for the area behind paged content, far too dark for a card. Both values measured by
    /// resolving the colours under each appearance, not assumed.
    ///
    /// Deliberately a step darker than the live menu's own dark tone (sRGB `#212121`), which the *active*
    /// surface matches: an inactive window reading slightly lighter than the live menu is what separates
    /// "settled" from "switched off".
    static let previewInactiveBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .underPageBackgroundColor
            : .windowBackgroundColor
    }
}

/// A layer-backed fill that re-resolves its colour on every theme change. A raw `layer.backgroundColor`
/// set once freezes the CGColor at whatever appearance was current, so the preview window's background
/// stayed light under the dark system theme (#185). Drawing via `updateLayer` lets AppKit re-run it when
/// the effective appearance flips (same technique as the popup's `CardBackdropView`/`PillView`).
@MainActor
final class ThemedFillView: NSView {
    var fillColor: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }

    override var wantsUpdateLayer: Bool { true }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() {
        layer?.backgroundColor = fillColor.cgColor   // re-resolves in the current appearance
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = cornerRadius > 0
    }
}

/// The preview window's heading: a centred title sitting directly on the card, with no backing strip,
/// and an optional second line under it.
///
/// It used to draw a subtly darker plaque behind the text, imitating a window title bar. That reads as
/// *chrome* — a second window inside the window — where the preview should read as the dropdown itself
/// with a label above it. The text alone says the same thing and keeps the card one continuous surface.
///
/// The subtitle is opt-in (`nil` by default), so the dev tuner's heading is unchanged: it has one
/// preview and no modifier to discover. The Settings preview uses it to say that ⌥ shows a second
/// composition — a thing the window can *do* that is invisible until someone happens to hold the key.
@MainActor
final class TitlePlaqueView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    /// The second line, or `nil` for a heading that has none.
    private let subtitleLabel: NSTextField?

    /// Whether the window this heading belongs to is the active one.
    ///
    /// A real title bar dims its title when its window loses focus, and the Settings window's own
    /// toolbar title does exactly that — but only because AppKit dims standard toolbar items for free.
    /// This is a plain label in a borderless window, so it gets none of that and would stay at full
    /// strength beside a dimmed one, reading as the more prominent of the two. Setting it explicitly
    /// keeps the pair in step.
    var isWindowActive = true {
        didSet {
            guard isWindowActive != oldValue else { return }
            applyTitleColour()
        }
    }

    init(title: String, subtitle: String? = nil) {
        subtitleLabel = subtitle.map { text in
            let label = NSTextField(labelWithString: text)
            // A step down from the title, the way a window's proxy subtitle sits under its name: the
            // line is a hint about a key, and reading as loudly as the heading would make the preview
            // look like it had two titles. Only *one* step, though — `smallSystemFontSize` (11) put it
            // at the weight of a footnote, and the ⌥ glyph in particular needs a little more body to
            // be recognisable as a key rather than as punctuation.
            label.font = .systemFont(ofSize: Metrics.subtitleSize)
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            return label
        }
        super.init(frame: .zero)
        titleLabel.stringValue = title
        titleLabel.font = NSFont.titleBarFont(ofSize: NSFont.systemFontSize)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        guard let subtitleLabel else {
            NSLayoutConstraint.activate([
                titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            applyTitleColour()
            return
        }
        addSubview(subtitleLabel)
        // With two lines the pair is pinned top-to-bottom rather than centred: the view's height is
        // its content's (see `intrinsicContentSize`), so centring each line separately would leave
        // them overlapping in a box only as tall as one of them.
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            subtitleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Metrics.lineGap),
            subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyTitleColour()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private enum Metrics {
        /// Title to subtitle. Tight enough that the two read as one heading block rather than as a
        /// heading and a stray line of text above the card.
        static let lineGap: CGFloat = 2
        /// The subtitle's point size: one step under the system size (13) rather than the two steps
        /// `smallSystemFontSize` (11) would take it down.
        static let subtitleSize: CGFloat = 12
    }

    /// Both colours re-resolve per appearance on their own. The inactive state uses
    /// `tertiaryLabelColor` rather than `secondary`: this heading sits on the menu material, which is
    /// darker than a normal window background, so the secondary tier still read as near-white against
    /// it — it needs to drop a step further to match the dimmed toolbar title beside it.
    private func applyTitleColour() {
        titleLabel.textColor = isWindowActive ? .labelColor : .tertiaryLabelColor
        // One tier below the title in both states, so the hierarchy between the two lines survives the
        // window losing focus instead of collapsing into one flat grey.
        subtitleLabel?.textColor = isWindowActive ? .secondaryLabelColor : .quaternaryLabelColor
    }

    /// Hugs the labels. With the backing strip gone there is nothing to give the heading a height of its
    /// own, and a fixed one would add invisible slack that makes the surrounding margins uneven.
    override var intrinsicContentSize: NSSize {
        var height = titleLabel.intrinsicContentSize.height
        if let subtitleLabel {
            height += Metrics.lineGap + subtitleLabel.intrinsicContentSize.height
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }
}
