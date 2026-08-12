import AppKit

/// Chrome shared by every window that renders the popup **outside** a real `NSMenu`: the dev colour
/// tuner's "Popup Preview" (#185) and the Settings window's "Dropdown live preview" (ADR-0083).
///
/// The types here are deliberately *not* dev-tools-only despite the folder they sit in — neither
/// knows about `ColorRole`/`ColorStore`, and the Settings preview ships in release builds with no
/// `devToolsEnabled` gate. What binds them is the surface being imitated, not the tool using it.
///
/// Both metrics below were fought for once already; duplicating either would let the two previews
/// drift apart on the next OS bump.
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
}

/// A layer-backed fill that re-resolves its colour on every theme change. A raw `layer.backgroundColor`
/// set once freezes the CGColor at whatever appearance was current, so the preview window's background
/// stayed light under the dark system theme (#185). Drawing via `updateLayer` lets AppKit re-run it when
/// the effective appearance flips (same technique as the popup's `CardBackdropView`/`PillView`).
@MainActor
final class ThemedFillView: NSView {
    var fillColor: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    /// A hairline border around the rounded card, mimicking the thin light edge a real `NSMenu` popup
    /// draws (see ``NSColor/popupMenuBorder``). `nil` = no border. Preview only (#185).
    var borderColor: NSColor? { didSet { needsDisplay = true } }

    override var wantsUpdateLayer: Bool { true }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() {
        layer?.backgroundColor = fillColor.cgColor   // re-resolves in the current appearance
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = cornerRadius > 0
        // The 1 pt hairline is drawn inside masksToBounds, so it stays clipped to the rounded corners.
        layer?.borderWidth = borderColor == nil ? 0 : 1
        layer?.borderColor = borderColor?.cgColor
    }
}

/// The preview window's title-bar plaque: a subtly darker strip across the top with a centred title,
/// mimicking a macOS window title bar. Layer-backed so its fill and the title colour both track the
/// theme (light ↔ dark).
@MainActor
final class TitlePlaqueView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")

    override var wantsUpdateLayer: Bool { true }

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        titleLabel.stringValue = title
        titleLabel.font = NSFont.titleBarFont(ofSize: NSFont.systemFontSize)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 28) }

    override func updateLayer() {
        // A hair darker than the card background — the standard title-bar look — and theme-adaptive.
        // Base off the menu-matched colour (dark #2C2C2C) so the plaque tracks the card, not the lighter
        // raw `windowBackgroundColor`.
        let base = NSColor.popupMenuMatchedBackground
        layer?.backgroundColor = (base.blended(withFraction: 0.04, of: .labelColor) ?? base).cgColor
        titleLabel.textColor = .labelColor   // NSTextField re-resolves labelColor per appearance anyway
    }
}
