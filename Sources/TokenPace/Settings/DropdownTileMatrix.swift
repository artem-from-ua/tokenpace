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

    /// One candidate tile geometry.
    struct Candidate {
        let barWidth: CGFloat
        let gap: CGFloat
        let tileWidth: CGFloat
        let tileHeight: CGFloat

        var label: String {
            "bar \(Int(barWidth)) · gap \(Int(gap)) · tile \(Int(tileWidth))×\(Int(tileHeight))"
        }
    }

    /// The candidates, spanning the decision the maintainer has to make.
    ///
    /// The floor is not free: two bars at `PopupBarView.viewHeight` (20 pt) plus a gap already occupy
    /// 40 + gap, so a 64 pt tile leaves ~12 pt for the gap and both margins together. Anything below
    /// that stops being tight and starts clipping the marker's glow.
    static let candidates: [Candidate] = [
        // The menu-bar tile's own width, for reference — how cramped 80 pt actually is with two popup bars.
        Candidate(barWidth: 64, gap: 8, tileWidth: 80, tileHeight: 64),
        // Wider than the menu-bar specimen, as asked, on the same 64 pt height.
        Candidate(barWidth: 76, gap: 10, tileWidth: 92, tileHeight: 64),
        Candidate(barWidth: 88, gap: 12, tileWidth: 104, tileHeight: 64),
        // Same widths, one notch taller — is 64 genuinely enough, or does the pair need air?
        Candidate(barWidth: 88, gap: 16, tileWidth: 104, tileHeight: 72),
        Candidate(barWidth: 100, gap: 12, tileWidth: 116, tileHeight: 64),
        Candidate(barWidth: 100, gap: 16, tileWidth: 116, tileHeight: 72),
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

    private static func barViews(for style: BarStyle, optionHeld: Bool) -> [(view: PopupBarView, subdivisions: Int)] {
        let now = Date(timeIntervalSinceReferenceDate: 0)

        let fiveHour = PopupBarView(frame: .zero)
        fiveHour.bar = PacingModel.barLayout(
            utilization: Specimen.fiveHourUtilization,
            resetsAt: now.addingTimeInterval(Specimen.fiveHourRemaining),
            now: now, window: .fiveHour, blueAllowed: false)
        fiveHour.subdivisions = 5
        fiveHour.isBaseLimit = true
        fiveHour.barStyle = style
        fiveHour.optionHeld = optionHeld
        fiveHour.colorAnimator = nil

        let sevenDay = PopupBarView(frame: .zero)
        sevenDay.bar = PacingModel.barLayout(
            utilization: Specimen.sevenDayUtilization,
            resetsAt: now.addingTimeInterval(Specimen.sevenDayRemaining),
            now: now, window: .sevenDay)
        sevenDay.subdivisions = 7
        sevenDay.isBaseLimit = true
        sevenDay.barStyle = style
        sevenDay.optionHeld = optionHeld
        sevenDay.colorAnimator = nil

        return [(fiveHour, 5), (sevenDay, 7)]
    }

    // MARK: Tile

    /// One tile: the dropdown card colour, both bars, at `candidate`'s geometry.
    static func tileImage(style: BarStyle, candidate: Candidate, appearance: NSAppearance,
                          optionHeld: Bool) -> NSImage {
        let size = NSSize(width: candidate.tileWidth, height: candidate.tileHeight)
        let image = NSImage(size: size)
        let views = barViews(for: style, optionHeld: optionHeld)

        image.lockFocusFlipped(true)
        appearance.performAsCurrentDrawingAppearance {
            // The tile's plate is the dropdown card's own colour — the surface these bars actually sit
            // on — rather than the menu-bar tile's black. Follows the theme by construction.
            let plate = NSRect(origin: .zero, size: size)
            NSColor.popupMenuMatchedBackground.setFill()
            NSBezierPath(roundedRect: plate, xRadius: 6, yRadius: 6).fill()
            // The unselected tile's hairline, as `BarStylePicker.Tile.idleBorder` draws it — inset by half
            // its width so the stroke lands inside the plate rather than straddling its edge.
            NSColor.separatorColor.setStroke()
            let border = NSBezierPath(roundedRect: plate.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            border.lineWidth = 1
            border.stroke()

            let barHeight = PopupBarView.viewHeight
            let totalHeight = barHeight * 2 + candidate.gap
            let top = (candidate.tileHeight - totalHeight) / 2
            let left = (candidate.tileWidth - candidate.barWidth) / 2

            for (index, entry) in views.enumerated() {
                let y = top + CGFloat(index) * (barHeight + candidate.gap)
                let origin = NSPoint(x: left, y: y)
                NSGraphicsContext.saveGraphicsState()
                let transform = NSAffineTransform()
                transform.translateX(by: origin.x, yBy: origin.y)
                transform.concat()
                entry.view.render(in: NSRect(x: 0, y: 0, width: candidate.barWidth, height: barHeight))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    // MARK: Sheet

    /// Render every candidate × every style, in one theme, as a labelled sheet.
    static func sheet(appearance: NSAppearance, optionHeld: Bool) -> NSImage {
        let styles: [(BarStyle, String)] = [(.pressure, "Pressure"), (.gauge, "Gauge"), (.progress, "Progress")]
        let margin: CGFloat = 24
        let rowGap: CGFloat = 30
        let colGap: CGFloat = 20
        let labelHeight: CGFloat = 18
        let headerHeight: CGFloat = 26

        let widest = candidates.map(\.tileWidth).max() ?? 100
        let sheetWidth = margin * 2 + (widest + colGap) * CGFloat(styles.count) - colGap
        let rowHeights = candidates.map { $0.tileHeight + labelHeight + rowGap }
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
                    let tile = tileImage(style: style.0, candidate: candidate, appearance: appearance,
                                         optionHeld: optionHeld)
                    tile.draw(at: NSPoint(x: x, y: tileY), from: .zero, operation: .sourceOver, fraction: 1)
                }
                y += candidate.tileHeight + labelHeight + rowGap
            }
        }
        image.unlockFocus()
        return image
    }

    /// A single contact sheet with **both themes side by side** — the form the maintainer actually
    /// judges from, since a tile has to work in light and dark and flipping between two files hides
    /// exactly the differences that matter.
    static func combinedSheet(optionHeld: Bool) -> NSImage? {
        guard let dark = NSAppearance(named: .darkAqua), let light = NSAppearance(named: .aqua) else {
            return nil
        }
        let left = sheet(appearance: dark, optionHeld: optionHeld)
        let right = sheet(appearance: light, optionHeld: optionHeld)
        let size = NSSize(width: left.size.width + right.size.width, height: max(left.size.height, right.size.height))
        let image = NSImage(size: size)
        // NOT `lockFocusFlipped` here. Each sheet is already a finished bitmap drawn top-left-down; a
        // flipped context flips it a second time on composite, which mirrored the whole sheet
        // vertically (headers at the bottom, the 5h bar under the 7d one). The flip belongs to the
        // *drawing* of a sheet, not to pasting two of them side by side.
        image.lockFocus()
        left.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        right.draw(at: NSPoint(x: left.size.width, y: 0), from: .zero, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        return image
    }

    /// Write both themes' sheets next to `path` and return the files written.
    static func write(to path: String) -> [String] {
        var written: [String] = []
        for (optionHeld, tag) in [(false, "plain"), (true, "ruler")] {
            guard let image = combinedSheet(optionHeld: optionHeld),
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
