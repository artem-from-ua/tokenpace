import AppKit
import TokenPaceKit

// MARK: - DropdownTileMatrix

/// Dev-only size explorer for the dropdown `Bar style` preview tiles (#374).
///
/// The tile geometry cannot be settled on paper: the live popup bar is 252 pt wide with a 14 pt marker
/// over a 6 pt track, and the tile has to carry **two** of those bars at their real thickness. Which bar
/// width, which vertical gap and which tile height make that read is a judgement about a picture, so
/// this renders the candidates side by side and lets the maintainer pick one.
///
/// Not shipped: gated behind `TOKENPACE_TILE_MATRIX=<path>`, which renders the sheet and exits. Delete
/// this file once the size is chosen and written into the real control.
@MainActor
enum DropdownTileMatrix {

    /// One candidate: how long the bar is inside the fixed tile.
    struct Candidate {
        let barWidth: CGFloat
        var label: String { "bar \(Int(barWidth)) pt" }
    }

    /// The tile box is **fixed at the menu-bar tile's own 80×48** (`BarStylePicker.Tile`), so the two
    /// Settings rows stay a matched pair. The tile is therefore not a free variable — what is left to
    /// choose is how long the bar inside it should be, which is what the candidates vary.
    ///
    /// 48 pt holds two 20 pt bars only because the spacing is solved symmetrically: `(48 − 40)/3 ≈ 2.7`
    /// above, between and below.
    static let tileWidth: CGFloat = 80
    static let tileHeight: CGFloat = 48

    static let candidates: [Candidate] = [
        Candidate(barWidth: 56),
        Candidate(barWidth: 62),
        Candidate(barWidth: 68),
        Candidate(barWidth: 72),
    ]

    // MARK: Specimen

    /// The same `climbing` first-poll frame the menu-bar tiles bake, so both surfaces explain the three
    /// styles with one dataset (`BarStylePreviewRenderer.Specimen`).
    private enum Specimen {
        static let fiveHourUtilization = 20.0
        static let fiveHourRemaining: TimeInterval = 2 * 3600
        static let sevenDayUtilization = 55.0
        static let sevenDayRemaining: TimeInterval = 5 * 24 * 3600
    }

    private static func barViews(for style: BarStyle) -> [(view: PopupBarView, subdivisions: Int)] {
        let now = Date(timeIntervalSinceReferenceDate: 0)

        let fiveHour = PopupBarView(frame: .zero)
        fiveHour.bar = PacingModel.barLayout(
            utilization: Specimen.fiveHourUtilization,
            resetsAt: now.addingTimeInterval(Specimen.fiveHourRemaining),
            now: now, window: .fiveHour, blueAllowed: false)
        fiveHour.subdivisions = 5
        fiveHour.isBaseLimit = true
        fiveHour.barStyle = style
        // `optionHeld` stays at its `false` default, deliberately: ⌥ must not reach the specimen. In the
        // live dropdown the modifier reveals the explanatory ruler *while held*, so a tile baked with it
        // on would advertise a state the row does not sit in. The mark that identifies Pressure from
        // Gauge is the zero struck through the track, which `drawZeroTick` draws unconditionally — so
        // nothing distinguishing is lost by leaving the modifier out.
        fiveHour.colorAnimator = nil

        let sevenDay = PopupBarView(frame: .zero)
        sevenDay.bar = PacingModel.barLayout(
            utilization: Specimen.sevenDayUtilization,
            resetsAt: now.addingTimeInterval(Specimen.sevenDayRemaining),
            now: now, window: .sevenDay)
        sevenDay.subdivisions = 7
        sevenDay.isBaseLimit = true
        sevenDay.barStyle = style
        sevenDay.colorAnimator = nil

        return [(fiveHour, 5), (sevenDay, 7)]
    }

    // MARK: Tile

    /// One tile — the dropdown card colour plus both bars — drawn at `origin` in the **current**
    /// (flipped) context, which is what the caller's sheet already is.
    static func drawTile(style: BarStyle, candidate: Candidate, at origin: NSPoint,
                         appearance: NSAppearance) {
        let views = barViews(for: style)

        appearance.performAsCurrentDrawingAppearance {
            // The tile's plate is the dropdown card's own colour — the surface these bars actually sit
            // on — rather than the menu-bar tile's black. Follows the theme by construction.
            let plate = NSRect(x: origin.x, y: origin.y, width: tileWidth, height: tileHeight)
            NSColor.popupMenuMatchedBackground.setFill()
            NSBezierPath(roundedRect: plate, xRadius: 6, yRadius: 6).fill()
            // The unselected tile's hairline, as `BarStylePicker.Tile.idleBorder` draws it — inset by half
            // its width so the stroke lands inside the plate rather than straddling its edge.
            NSColor.separatorColor.setStroke()
            let border = NSBezierPath(roundedRect: plate.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            border.lineWidth = 1
            border.stroke()

            // **Symmetric vertical rhythm**: the space between the two bars equals the space above the
            // first and below the second — one value used three times, rather than a gap tuned
            // separately from the margins. `(tileHeight − 2·barHeight)/3` is that value, and solving for
            // it is what centres the pair *and* spaces it evenly; centring alone leaves the outer
            // margins at whatever happens to be left over.
            let barHeight = PopupBarView.viewHeight
            let spacing = (tileHeight - barHeight * 2) / 3
            let left = origin.x + (tileWidth - candidate.barWidth) / 2

            for (index, entry) in views.enumerated() {
                let y = origin.y + spacing * CGFloat(index + 1) + barHeight * CGFloat(index)
                entry.view.render(in: NSRect(x: left, y: y, width: candidate.barWidth, height: barHeight))
            }
        }
    }

    // MARK: Sheet

    /// Render every candidate × every style, in one theme, as a labelled sheet.
    static func sheet(appearance: NSAppearance) -> NSImage {
        let styles: [(BarStyle, String)] = [(.pressure, "Pressure"), (.gauge, "Gauge"), (.progress, "Progress")]
        let margin: CGFloat = 24
        let rowGap: CGFloat = 30
        let colGap: CGFloat = 20
        let labelHeight: CGFloat = 18
        let headerHeight: CGFloat = 26

        let widest = tileWidth
        let sheetWidth = margin * 2 + (widest + colGap) * CGFloat(styles.count) - colGap
        let rowHeights = candidates.map { _ in tileHeight + labelHeight + rowGap }
        let sheetHeight = margin * 2 + headerHeight + rowHeights.reduce(0, +)

        let image = NSImage(size: NSSize(width: sheetWidth, height: sheetHeight))
        image.lockFocusFlipped(true)
        appearance.performAsCurrentDrawingAppearance {
            // The sheet's own backdrop is `controlBackgroundColor`, NOT `windowBackgroundColor`: in the
            // light theme the tile's plate (`popupMenuMatchedBackground`) falls through to exactly
            // `windowBackgroundColor`, so a matching sheet made every light tile invisible — its edges
            // vanished into the paper and the geometry could not be judged at all. This is a property of
            // the contact sheet, not of the tile; in the real pane the tile sits on the Settings pane's
            // own material, which differs from the card colour.
            NSColor.controlBackgroundColor.setFill()
            NSRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight).fill()

            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let ink: NSColor = isDark ? .white : .black
            let header: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: ink,
            ]
            let caption: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: ink.withAlphaComponent(0.6),
            ]

            for (column, style) in styles.enumerated() {
                let x = margin + CGFloat(column) * (widest + colGap)
                (style.1 as NSString).draw(at: NSPoint(x: x, y: margin), withAttributes: header)
            }

            var y = margin + headerHeight
            for candidate in candidates {
                (candidate.label as NSString).draw(at: NSPoint(x: margin, y: y), withAttributes: caption)
                let tileY = y + labelHeight
                for (column, style) in styles.enumerated() {
                    let x = margin + CGFloat(column) * (widest + colGap)
                    // Drawn straight into the sheet, NOT via an intermediate `NSImage`. Compositing a
                    // flipped image into a flipped context flips it a second time, which mirrored each
                    // tile vertically — the 7-day bar rendered above the 5-hour one, so the pacing
                    // colours read as swapped even though a probe showed both bars carrying the right
                    // `pacing` at the right y. Drawing in place has no second coordinate system to
                    // disagree with.
                    drawTile(style: style.0, candidate: candidate,
                             at: NSPoint(x: x, y: tileY), appearance: appearance)
                }
                y += tileHeight + labelHeight + rowGap
            }
        }
        image.unlockFocus()
        return image
    }

    /// A single contact sheet with **both themes side by side** — the form the maintainer actually
    /// judges from, since a tile has to work in light and dark and flipping between two files hides
    /// exactly the differences that matter.
    static func combinedSheet() -> NSImage? {
        guard let dark = NSAppearance(named: .darkAqua), let light = NSAppearance(named: .aqua) else {
            return nil
        }
        let left = sheet(appearance: dark)
        let right = sheet(appearance: light)
        let size = NSSize(width: left.size.width + right.size.width, height: max(left.size.height, right.size.height))
        let image = NSImage(size: size)
        // Unflipped, because each sheet is a finished bitmap rather than live drawing: `NSImage.draw`
        // pastes it upright here, whereas a flipped context would re-read it bottom-up and mirror the
        // whole page. (Inside `sheet` the opposite holds — there the tiles are drawn live, so the
        // context must stay flipped; see `drawTile`.)
        image.lockFocus()
        left.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        right.draw(at: NSPoint(x: left.size.width, y: 0), from: .zero, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        return image
    }

    /// Write the contact sheet to `path` and return the files written.
    static func write(to path: String) -> [String] {
        var written: [String] = []
        for tag in ["sheet"] {
            guard let image = combinedSheet(),
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else { continue }
            // Pin the pixel size to the point size. `lockFocusFlipped` renders at the main screen's
            // backing scale, so on a Retina Mac the bitmap comes back 2× and the file is four times the
            // bytes for a picture judged at 1×.
            rep.size = image.size
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let file = "\(path)-\(tag).png"
            try? png.write(to: URL(fileURLWithPath: file))
            written.append(file)
        }
        return written
    }
}
