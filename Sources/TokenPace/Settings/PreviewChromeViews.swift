import AppKit

/// Chrome for rendering the popup **outside** a real `NSMenu`: the Settings window's "Dropdown live
/// preview" (ADR-0083).
@MainActor
enum PreviewChrome {

    /// The menu window class (`_NSMenuWindow`) is private with no public metric, so this is keyed off
    /// the OS version — matched visually against a real TokenPace menu: macOS 15 Sequoia uses ~10 pt;
    /// macOS 26 Tahoe rounds more (~14 pt).
    static func menuPopupCornerRadius() -> CGFloat {
        if #available(macOS 26.0, *) { return 14 }
        return 10   // macOS 11–15
    }

    /// Not cosmetic: a real menu window is `NSAppearanceNameVibrantDark`, and system label colours
    /// resolve differently under vibrancy — the popup's translucent grey track resolves to an opaque
    /// `#323232` in VibrantDark versus a light `white@0.17` in DarkAqua. Without the force, a
    /// preview's neutrals read noticeably lighter than the live menu.
    static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static var vibrantAppearance: NSAppearance? {
        NSAppearance(named: isDark ? .vibrantDark : .vibrantLight)
    }

    /// A backing view carrying the system's **menu** material, rounded to the popup's radius. The
    /// real dropdown is translucent — a flat fill has nothing underneath, so the card reads as one
    /// dead slab and loses the edge depth a live dropdown has. `.menu` is the material the popup is
    /// actually drawn over, and `.behindWindow` is what lets the desktop through — the same
    /// combination the system menu window uses.
    static func makeMenuMaterialBackdrop() -> MenuMaterialBackdrop {
        let view = MenuMaterialBackdrop()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        // `maskImage`, not `layer.cornerRadius`: an NSVisualEffectView composites its material outside
        // the normal layer path, so a corner radius with `masksToBounds` leaves the material square
        // and only clips the subviews. The mask is the documented way to round one.
        view.maskImage = roundedMask(radius: menuPopupCornerRadius())
        return view
    }

    /// Cap insets keep the corners crisp at any size: only the middle strips stretch.
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
/// once it is not — translucency is how macOS signals "this surface is live", so a preview that keeps
/// showing the desktop through itself while unfocused competes with the window that has focus.
@MainActor
final class MenuMaterialBackdrop: NSVisualEffectView {

    /// Drives the material ⇄ flat swap.
    var isWindowActive = true {
        didSet {
            guard isWindowActive != oldValue else { return }
            applyState()
        }
    }

    /// A **sibling below** the material rather than a colour on the effect view's own layer: painting
    /// `layer.backgroundColor` on an `NSVisualEffectView` costs it its blur, since the view renders its
    /// material through that layer.
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
        // Inactive: `.inactive` stops the material sampling, and the opaque sibling below shows
        // through in its place.
        state = isWindowActive ? .active : .inactive
        inactiveFill.isHidden = isWindowActive
    }
}

extension NSColor {

    /// **Dark → `underPageBackgroundColor`** (`#282828`), reached through the semantic colour so it
    /// tracks any future system revision. **Light → `windowBackgroundColor`** (`#ECECEC`) —
    /// `underPageBackgroundColor` is *not* the light counterpart despite the same API: it resolves to
    /// `#969696` at 90% alpha there, a mid grey meant for paged content, far too dark for a card.
    static let previewInactiveBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .underPageBackgroundColor
            : .windowBackgroundColor
    }
}

/// A layer-backed fill that re-resolves its colour on every theme change. A raw `layer.backgroundColor`
/// set once freezes the CGColor at whatever appearance was current. Drawing via `updateLayer` lets
/// AppKit re-run it when the effective appearance flips.
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
/// and an optional second line under it. No plaque behind the text — that would read as *chrome*, a
/// second window inside the window, where the preview should read as the dropdown itself with a
/// label above it.
@MainActor
final class TitlePlaqueView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    /// The second line, or `nil` for a heading that has none.
    private let subtitleLabel: NSTextField?

    /// A plain label in a borderless window gets none of AppKit's automatic toolbar-title dimming, so
    /// it would stay full strength beside a dimmed one without this.
    var isWindowActive = true {
        didSet {
            guard isWindowActive != oldValue else { return }
            applyTitleColour()
        }
    }

    init(title: String, subtitle: String? = nil) {
        subtitleLabel = subtitle.map { text in
            let label = NSTextField(labelWithString: text)
            // One step down from the title, not two (`smallSystemFontSize`/11 reads as a footnote,
            // and the ⌥ glyph needs body to read as a key rather than punctuation).
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
        // Pinned top-to-bottom rather than centred: the view's height is its content's (see
        // `intrinsicContentSize`), so centring each line separately would overlap them.
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
        static let lineGap: CGFloat = 2
        /// One step under the system size (13), not the two `smallSystemFontSize` (11) would take.
        static let subtitleSize: CGFloat = 12
    }

    /// Inactive uses `tertiaryLabelColor` rather than `secondary`: this heading sits on the menu
    /// material, darker than a normal window background, so `secondary` still reads near-white there.
    private func applyTitleColour() {
        titleLabel.textColor = isWindowActive ? .labelColor : .tertiaryLabelColor
        // One tier below the title in both states, so the hierarchy survives losing focus.
        subtitleLabel?.textColor = isWindowActive ? .secondaryLabelColor : .quaternaryLabelColor
    }

    /// Hugs the labels. With the backing strip gone, a fixed height would add invisible slack.
    override var intrinsicContentSize: NSSize {
        var height = titleLabel.intrinsicContentSize.height
        if let subtitleLabel {
            height += Metrics.lineGap + subtitleLabel.intrinsicContentSize.height
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }
}
