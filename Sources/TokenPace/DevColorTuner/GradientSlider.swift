import AppKit

/// A horizontal slider whose track is filled with a colour gradient showing what the edited colour
/// becomes as the knob moves across this one channel (the dev colour tuner, #185). The gradient is
/// supplied by the owner and rebuilt whenever any *other* channel changes, so each channel's ribbon
/// always reflects the current values of the rest. The knob itself is filled with the colour at the
/// current position, so it reads as a sample of what that value produces.
@MainActor
final class GradientSlider: NSSlider {

    /// Colour stops painted left→right behind the knob. Set by the tuner on every sync.
    var gradientColors: [NSColor] = [.black, .white] {
        didSet { needsDisplay = true }
    }

    /// The colour the knob is filled with — the colour at the slider's current position. Set by the
    /// tuner on every sync (it already computes the ribbon, so it passes the matching value here).
    var knobColor: NSColor = .white {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        sliderType = .linear
        isContinuous = true
        cell = GradientSliderCell()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 22)
    }

    fileprivate var stops: [NSColor] { gradientColors }
    fileprivate var knobFill: NSColor { knobColor }
}

/// Draws the gradient ribbon as the slider's bar and a colour-filled circular knob on top.
private final class GradientSliderCell: NSSliderCell {

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        guard let slider = controlView as? GradientSlider else {
            super.drawBar(inside: rect, flipped: flipped)
            return
        }
        let track = NSRect(x: rect.minX, y: rect.midY - 4, width: rect.width, height: 8)
        let path = NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4)

        let stops = slider.stops
        let colors = stops.count >= 2 ? stops : [stops.first ?? .black, stops.first ?? .white]
        let locations = (0..<colors.count).map { CGFloat($0) / CGFloat(colors.count - 1) }
        let gradient = NSGradient(colors: colors, atLocations: locations, colorSpace: .sRGB)

        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()
        gradient?.draw(in: track, angle: 0)
        NSGraphicsContext.current?.restoreGraphicsState()

        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func drawKnob(_ knobRect: NSRect) {
        guard let slider = controlView as? GradientSlider else {
            super.drawKnob(knobRect)
            return
        }
        // A circular knob filled with the current-position colour, with a white ring + subtle border so
        // it stays visible over any ribbon colour (including near-white / near-background values).
        let d = min(knobRect.width, knobRect.height) - 2
        let r = NSRect(x: knobRect.midX - d / 2, y: knobRect.midY - d / 2, width: d, height: d)
        let ring = NSBezierPath(ovalIn: r)
        NSColor.white.setFill(); ring.fill()

        let inner = r.insetBy(dx: 2, dy: 2)
        let fill = NSBezierPath(ovalIn: inner)
        (slider.knobFill.usingColorSpace(.sRGB) ?? slider.knobFill).setFill()
        fill.fill()
        NSColor.separatorColor.setStroke()
        fill.lineWidth = 0.5
        fill.stroke()
    }
}
