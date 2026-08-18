#!/usr/bin/env swift

// Check that the badge's CAPSULE ends where every other row's text ends.
//
// The popup pins each detail row's trailing half flush right, so the capsule lands on the column edge
// by default and the badge's text sits its padding-width inside — which is what padding on a filled
// shape should look like. The earlier version of this check demanded the opposite (badge TEXT in the
// column, capsule overhanging); that was rejected on sight: the filled shape is the widest thing on the
// row, and its edge poking past the text above reads as a layout error, not a deliberate bleed.
//
// Two earlier attempts failed here, which is why this script measures RENDERED PIXELS rather than
// frames or advances:
//
//   - `alignmentRectInsets` on the badge — the documented API for exactly this — does nothing:
//     `NSStackView` lays its arranged views out by frame and ignores the alignment rect.
//   - sub-point reasoning about glyph advances and side bearings chased 0.2–0.4 pt effects while the
//     real error was 6 pt. Rasterisation swallows the former entirely.
//
// So the row applies NO shift: every 2 pt of it pushes the capsule 4 px past the column (measured).
//
// Run: swift scripts/check-badge-column.swift

import AppKit

let contentWidth: CGFloat = 252                       // PopupViewController.Metrics.contentWidth
let textFont = NSFont.systemFont(ofSize: 13)          // Metrics.textSize
let pillFont = NSFont.systemFont(ofSize: 11, weight: .medium)   // textSize − 2, medium
let hInset: CGFloat = 0                               // PillView.hInset (on top of the cell's own)
let cellOwnInset: CGFloat = 4.5                       // PillView.cellOwnInset — measured
let vInset: CGFloat = 2                               // PillView.vInset
let scale: CGFloat = 2

/// Mirror of `PillCell` — pads by narrowing the rect the text lays out in.
final class Cell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: rect.insetBy(dx: hInset, dy: vInset))
    }
}

/// Mirror of `PillView`. Configure the cell fully *before* assigning it: assigning `cell` replaces the
/// backing store, so a string set beforehand never arrives and the field measures as empty.
final class Pill: NSTextField {
    convenience init(text: String) {
        self.init(frame: .zero)
        let cell = Cell(textCell: text)
        cell.isEditable = false
        cell.isSelectable = false
        cell.isBezeled = false
        cell.drawsBackground = false
        cell.alignment = .center
        cell.font = pillFont
        cell.textColor = .white
        cell.lineBreakMode = .byClipping
        self.cell = cell
        translatesAutoresizingMaskIntoConstraints = false
    }
    /// From `cell.cellSize`, not `super.intrinsicContentSize` — the latter already reflects the
    /// narrowed drawing rect, so adding the insets to it counts them twice.
    override var intrinsicContentSize: NSSize {
        var size = cell?.cellSize ?? super.intrinsicContentSize
        size.width += 2 * hInset
        size.height += 2 * vInset
        return size
    }
    override func draw(_ rect: NSRect) {
        NSColor(white: 0.35, alpha: 1).setFill()
        let r = bounds.height * 0.35
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        super.draw(rect)
    }
}

/// Build one split row the way `addSplitRow` does and return the x of its rightmost *visible* pixel:
/// the capsule's edge for a badge, the last glyph for a plain label. Both are what meets the column.
func rightmostTextPixel(badge: Bool, corrected: Bool, text: String) -> Int {
    let left = NSTextField(labelWithString: "88% used")
    left.font = textFont
    left.textColor = .white

    let right: NSView
    if badge {
        right = Pill(text: text)
    } else {
        let l = NSTextField(labelWithString: text); l.font = textFont; l.textColor = .white; right = l
    }

    let row = NSStackView(views: [left, right])
    row.orientation = .horizontal
    row.distribution = .equalSpacing
    row.translatesAutoresizingMaskIntoConstraints = false
    row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
    if corrected, right is Pill {
        row.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    let host = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth + 40, height: 40))
    host.addSubview(row)
    NSLayoutConstraint.activate([
        row.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 20),
        row.centerYAnchor.constraint(equalTo: host.centerYAnchor),
    ])
    host.layoutSubtreeIfNeeded()

    let px = Int(host.frame.width * scale), py = Int(host.frame.height * scale)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: py, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = host.frame.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.black.setFill()
    NSRect(origin: .zero, size: host.frame.size).fill()
    host.displayIgnoringOpacity(host.bounds, in: NSGraphicsContext.current!)
    NSGraphicsContext.restoreGraphicsState()

    // A badge's rightmost ink is its capsule (mid-grey); a plain label's is its text (near-white).
    let threshold = badge ? 0.25 : 0.85
    for col in stride(from: px - 1, through: 0, by: -1) {
        for row in 0..<py where (rep.colorAt(x: col, y: row)?.brightnessComponent ?? 0) > threshold {
            return col
        }
    }
    return -1
}

// The strings the badge can hold, in both ⌥ states.
let strings = [
    "5d", "5d on Friday", "7d next Monday", "20h at 03:00",
    "resets in 5d", "resets in 5d on Friday", "resets in 7d next Monday", "resets in 20h at 03:00",
]

/// A glyph's last stem never lands exactly on the column edge — a few px is the font's side bearing.
let tolerance = 8

print("rightmost text pixel per row (higher = further right), column \(Int(contentWidth)) pt\n")
var worst = 0
for s in strings {
    let plain = rightmostTextPixel(badge: false, corrected: false, text: s)
    let raw = rightmostTextPixel(badge: true, corrected: false, text: s)
    let fixed = rightmostTextPixel(badge: true, corrected: true, text: s)
    worst = max(worst, abs(fixed - plain))
    print(String(format: "  %-26@ plain=%3d  badge=%3d (%+d)  corrected=%3d (%+d)",
                 s as NSString, plain, raw, raw - plain, fixed, fixed - plain))
}

print("\nworst |corrected − plain| = \(worst) px (tolerance \(tolerance))")
if worst > tolerance {
    print("FAIL: the badge's capsule does not end at the column.")
    exit(1)
}
print("OK: the badge's capsule ends at the column, like every other row's text.")
