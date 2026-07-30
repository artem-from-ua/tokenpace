import AppKit

/// A horizontal slider whose track is filled with a colour gradient showing what the edited colour
/// becomes as the knob moves across this one channel (the dev colour tuner, #185). The gradient is
/// supplied by the owner and rebuilt whenever any *other* channel changes, so each channel's ribbon
/// always reflects the current values of the rest.
@MainActor
final class GradientSlider: NSSlider {

    /// Colour stops painted left→right behind the knob. Set by the tuner on every sync.
    var gradientColors: [NSColor] = [.black, .white] {
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

    /// Bridge the cell's draw call to this view's stops.
    fileprivate var stops: [NSColor] { gradientColors }
}

/// Draws the gradient ribbon as the slider's bar, then lets AppKit draw the standard knob on top.
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

        path.addClip()
        gradient?.draw(in: track, angle: 0)

        // Hairline border so a near-background ribbon still reads as a control.
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
