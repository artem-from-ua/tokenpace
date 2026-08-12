#!/usr/bin/env swift

// Check that a badged reset's TEXT lines up with a plain reset's text in the same column.
//
// The popup pins each detail row's trailing half flush right. For a plain label that puts the last
// glyph on the column edge; for a `PillView` badge it puts the *capsule* there, so without a
// correction the badge's text sits `PillView.hInset` further left — 13 px measured on Retina. The
// popup routinely shows both anatomies at once (the blocking row is badged, the others are not), and
// under ⌥ the badge grows, so the misalignment is visible and moves.
//
// Two earlier attempts failed here, which is why this script measures RENDERED PIXELS rather than
// frames or advances:
//
//   - `alignmentRectInsets` on the badge — the documented API for exactly this — does nothing:
//     `NSStackView` lays its arranged views out by frame and ignores the alignment rect.
//   - sub-point reasoning about glyph advances and side bearings chased 0.2–0.4 pt effects while the
//     real error was 6 pt. Rasterisation swallows the former entirely.
//
// The fix is a negative trailing `edgeInsets` on the row when its right half is a `PillView`, of the
// badge's FULL internal inset, so its text ends where a plain reset's text ends. A half-inset was tried
// and rejected against a screenshot of the real popup: the text still sat visibly short of the column.
// The capsule then bleeds 6 pt past the column, which is fine — `hPadding` leaves 16 pt before the
// card's own edge, and a filled badge is supposed to overhang.
//
// Run: swift scripts/check-badge-column.swift

import AppKit

let contentWidth: CGFloat = 268                       // PopupViewController.Metrics.contentWidth
let textFont = NSFont.systemFont(ofSize: 13)          // Metrics.textSize
let pillFont = NSFont.systemFont(ofSize: 11, weight: .medium)   // textSize − 2, medium
let hInset: CGFloat = 6                               // PillView.hInset
let vInset: CGFloat = 2                               // PillView.vInset
let scale: CGFloat = 2

/// Mirror of `PillView`'s geometry and drawing.
final class Pill: NSView {
    var text = ""
    var glyph: NSSize { (text as NSString).size(withAttributes: [.font: pillFont]) }
    var box: CGFloat { (glyph.width * scale).rounded(.up) / scale }
    override var intrinsicContentSize: NSSize {
        NSSize(width: box + 2 * hInset,
               height: ((glyph.height + 2 * vInset) * scale).rounded(.up) / scale)
    }
    override func draw(_ rect: NSRect) {
        NSColor(white: 0.35, alpha: 1).setFill()
        let r = bounds.height * 0.35
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        (text as NSString).draw(
            at: NSPoint(x: (bounds.width - glyph.width) / 2, y: (bounds.height - glyph.height) / 2),
            withAttributes: [.font: pillFont, .foregroundColor: NSColor.white])
    }
}

/// Build one split row the way `addSplitRow` does and return the x of its rightmost text pixel.
/// The capsule is mid-grey and the background black, so a near-white pixel can only be a glyph.
func rightmostTextPixel(badge: Bool, corrected: Bool, text: String) -> Int {
    let left = NSTextField(labelWithString: "88% used")
    left.font = textFont
    left.textColor = .white

    let right: NSView
    if badge {
        let p = Pill(); p.text = text; right = p
    } else {
        let l = NSTextField(labelWithString: text); l.font = textFont; l.textColor = .white; right = l
    }

    let row = NSStackView(views: [left, right])
    row.orientation = .horizontal
    row.distribution = .equalSpacing
    row.translatesAutoresizingMaskIntoConstraints = false
    row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
    if corrected, right is Pill {
        row.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: -hInset)
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

    for col in stride(from: px - 1, through: 0, by: -1) {
        for row in 0..<py where (rep.colorAt(x: col, y: row)?.brightnessComponent ?? 0) > 0.85 {
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

/// A glyph's last stem never lands exactly on the column edge — a pixel or two is the font's side
/// bearing, not the layout. Anything beyond that is the uncorrected 13 px error.
let tolerance = 3

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
    print("FAIL: a badged reset's text does not share the column with a plain one.")
    exit(1)
}
print("OK: badged and plain resets land in the same column.")
