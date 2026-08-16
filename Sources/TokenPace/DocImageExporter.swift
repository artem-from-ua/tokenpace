import AppKit
import TokenPaceKit

/// Renders the bar-style illustrations for `docs/reference/bar-styles.md` — **through the real
/// widget**, not through a redrawing of it.
///
/// The guide needs pictures of the three styles, and hand-authored SVGs were the obvious first
/// attempt. They were wrong in ways only a side-by-side reveals: the corner radii, the zero tick's
/// weight against the track, how the colours resolve on a vibrant surface. Reproducing
/// `StatusItemView`'s drawing by eye is exactly the "render from a description of the state rather
/// than from the state" mistake `docs/reference/ui-state-truth.md` warns about — the illustrations
/// end up arguing for geometry the app does not have.
///
/// So this draws `StatusItemView` itself, the same way `BarStylePreviewRenderer` does for the
/// Settings tiles: same `snapshotImage()`, same forced `.vibrantDark` appearance (the menu bar is a
/// vibrant surface, and system colours resolve differently there). What lands in `docs/assets/` is
/// then a photograph of the widget rather than a drawing of one.
///
/// Dev-only, triggered by an environment variable and never reached in a shipped run:
///
/// ```sh
/// TOKENPACE_EXPORT_DOC_IMAGES=docs/assets/bar-styles swift run TokenPace
/// ```
///
/// It writes the PNGs and terminates before any polling, menu-bar item or window exists.
@MainActor
enum DocImageExporter {

    /// The env var that both enables the export and names the output directory.
    static let environmentKey = "TOKENPACE_EXPORT_DOC_IMAGES"

    /// One illustration: a file name, the frame to draw, and which style to draw it in.
    ///
    /// `utilization` and `remaining` go through `PacingModel.barLayout`, so severity, the near-reset
    /// overrides and the blue gate are all *computed* — a scene cannot claim a colour the model would
    /// not produce for those numbers.
    private struct Scene {
        let name: String
        let style: BarStyle
        let utilization: Double
        let remaining: TimeInterval
        let window: LimitWindow
        /// Whether the far-behind blue is available; mirrors `PacingModel.weeklyHasHeadroom`.
        var blueAllowed: Bool = true
    }

    /// Five hours and seven days, in seconds — the two window lengths the scenes are stated against.
    private static let fiveHour: TimeInterval = 5 * 3600
    private static let sevenDay: TimeInterval = 7 * 24 * 3600

    /// `t` is expressed as "fraction of the window still to run", which is what `barLayout` takes.
    private static func remaining(ofWindow window: TimeInterval, elapsed: Double) -> TimeInterval {
        window * (1 - elapsed)
    }

    private static var scenes: [Scene] {
        [
            // --- Pressure: the ribbon only grows when spending is ahead of pace.
            .init(name: "pressure-calm", style: .pressure, utilization: 20,
                  remaining: remaining(ofWindow: fiveHour, elapsed: 0.30), window: .fiveHour),
            .init(name: "pressure-mild-lead", style: .pressure, utilization: 38,
                  remaining: remaining(ofWindow: sevenDay, elapsed: 0.30), window: .sevenDay),
            .init(name: "pressure-ahead", style: .pressure, utilization: 97,
                  remaining: remaining(ofWindow: fiveHour, elapsed: 0.93), window: .fiveHour),
            .init(name: "pressure-exhausted", style: .pressure, utilization: 100,
                  remaining: remaining(ofWindow: fiveHour, elapsed: 0.70), window: .fiveHour),

            // --- Gauge: zero in the middle, so the underspend side is drawn too.
            .init(name: "gauge-on-pace", style: .gauge, utilization: 55,
                  remaining: remaining(ofWindow: fiveHour, elapsed: 0.55), window: .fiveHour),
            // 50 % elapsed at 30 % spent. A smaller surplus floors to the centred pill and would be
            // indistinguishable from the on-pace frame above — the illustration has to clear
            // `minStripWidth` to illustrate anything.
            .init(name: "gauge-calm", style: .gauge, utilization: 30,
                  remaining: remaining(ofWindow: fiveHour, elapsed: 0.50), window: .fiveHour),
            // 80 % elapsed at 30 % spent. Both properties this frame is meant to show need checking
            // against the model rather than assumed: the left half saturates at `u <= 2t − 1`, and
            // the far-behind blue needs a surplus past `behindThreshold` — 0.40 for a five-hour
            // window. The obvious-looking t=90/u=70 satisfies the first and fails the second (a
            // 0.20 surplus is still green), which is exactly the kind of thing a hand-drawn mockup
            // gets wrong.
            .init(name: "gauge-deep-surplus", style: .gauge, utilization: 30,
                  remaining: remaining(ofWindow: fiveHour, elapsed: 0.80), window: .fiveHour),
            .init(name: "gauge-ahead", style: .gauge, utilization: 97,
                  remaining: remaining(ofWindow: fiveHour, elapsed: 0.93), window: .fiveHour),

            // --- Progress: the marker, and the gap between time and usage.
            .init(name: "progress-mid", style: .progress, utilization: 70,
                  remaining: remaining(ofWindow: fiveHour, elapsed: 0.50), window: .fiveHour),
            .init(name: "progress-behind", style: .progress, utilization: 40,
                  remaining: remaining(ofWindow: fiveHour, elapsed: 0.60), window: .fiveHour),
        ]
    }

    /// Render every scene into `directory`, or return `false` if the env var is unset.
    @discardableResult
    static func exportIfRequested() -> Bool {
        guard let dir = ProcessInfo.processInfo.environment[environmentKey], !dir.isEmpty else {
            return false
        }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        for scene in scenes {
            let image = render(scene)
            let path = url.appendingPathComponent("\(scene.name).png")
            guard write(image, to: path) else {
                FileHandle.standardError.write(Data("failed to write \(path.path)\n".utf8))
                continue
            }
            print("\(scene.name).png  \(Int(image.size.width))×\(Int(image.size.height)) pt")
        }
        print("\n\(scenes.count) images → \(url.path)")
        return true
    }

    // MARK: Drawing

    /// One bar, drawn by the real `StatusItemView` under the menu bar's appearance.
    private static func render(_ scene: Scene) -> NSImage {
        // A fixed instant: only the differences between `now` and `resetsAt` are read, so the frame
        // is deterministic and the PNGs are reproducible byte for byte.
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let bar = BarView(
            layout: PacingModel.barLayout(
                utilization: scene.utilization,
                resetsAt: now.addingTimeInterval(scene.remaining),
                now: now, window: scene.window, blueAllowed: scene.blueAllowed),
            indicator: .neutral, window: scene.window)

        let view = StatusItemView(frame: .zero)
        view.isPreviewSpecimen = true
        // One bar per illustration — `.expanded` takes both rows as optionals, so the second is
        // simply absent. The guide talks about a single bar's shape, and a second row would invite
        // reading the pair instead of the shape.
        view.layout = MenuBarLayout(mode: .expanded(fiveHour: bar, sevenDay: nil))
        view.barStyle = scene.style
        // `.off` keeps every pacing colour at full strength — these are swatches, and calm muting is
        // a separate setting the guide describes in words rather than pictures.
        view.calmColorMode = .off
        view.colorAnimator = nil

        // Same forcing `BarStylePreviewRenderer` documents: the menu bar is a *vibrant dark* surface
        // whatever the app's theme, and system colours resolve differently there. Drawing must happen
        // inside the block, because `snapshotImage()` resolves eagerly.
        var image = NSImage()
        NSAppearance(named: .vibrantDark)!.performAsCurrentDrawingAppearance {
            image = view.snapshotImage()
        }
        return image
    }

    /// Breathing room around the widget, so the bar does not touch the plate's edge.
    private static let plateInset: CGFloat = 4

    /// Write `image` as a PNG at 4× so the bar stays crisp when a docs page scales it down.
    ///
    /// The plate is filled **inside** a `.vibrantDark` block for the same reason the widget is drawn
    /// in one: `popupMenuMatchedBackground` is a dynamic colour, and resolved against whatever
    /// appearance happens to be current it comes out flat black instead of the menu material.
    private static func write(_ image: NSImage, to url: URL) -> Bool {
        let scale: CGFloat = 4
        let canvas = NSSize(width: image.size.width + plateInset * 2,
                            height: image.size.height + plateInset * 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return false }
        rep.size = canvas

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: .vibrantDark)!.performAsCurrentDrawingAppearance {
            // The surface the widget is actually seen against — the project's eyedropper-calibrated
            // menu material (`0x212121` dark), not a colour picked to look right. Without a plate the
            // PNG is a dark bar on transparency, which reads as broken on a light docs page.
            NSColor.popupMenuMatchedBackground.setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: canvas),
                         xRadius: 3, yRadius: 3).fill()
            image.draw(at: NSPoint(x: plateInset, y: plateInset),
                       from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}
