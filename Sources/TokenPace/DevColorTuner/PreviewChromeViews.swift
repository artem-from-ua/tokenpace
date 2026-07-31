import AppKit

/// A layer-backed fill that re-resolves its colour on every theme change. A raw `layer.backgroundColor`
/// set once freezes the CGColor at whatever appearance was current, so the preview window's background
/// stayed light under the dark system theme (#185). Drawing via `updateLayer` lets AppKit re-run it when
/// the effective appearance flips (same technique as the popup's `SolidBackdropView`).
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
