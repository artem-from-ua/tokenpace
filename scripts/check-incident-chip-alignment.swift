#!/usr/bin/env swift

// Check where the incident row's `age · stage` chip lands, and that it is flush right either way.
//
// `PopupViewController.incidentText` lives in the AppKit executable target, which SwiftPM cannot
// reach from `TokenPaceKitTests`, so this mirrors it and pins the two outcomes the design depends on:
//
//   - a description whose last line has room keeps the chip on that line, flush right (the tab stop)
//   - a description that fills its last line pushes the chip to a line of its own — still flush
//     right, not flush left (#351)
//
// The decision cannot be hardcoded: it depends on the system font size and on how the description
// happens to wrap at the incident text width, so both are measured the way AppKit measures them.
//
// Run: swift scripts/check-incident-chip-alignment.swift

import AppKit

// MARK: - Mirror of PopupViewController.Metrics

let popupWidth: CGFloat = 312
let cardInset: CGFloat = 8
let hPadding: CGFloat = 14
let contentWidth = popupWidth - 2 * cardInset - 2 * hPadding   // 268 pt
let statusDotDiameter: CGFloat = 8
let statusDotGap: CGFloat = 8
let incidentTextWidth = contentWidth - statusDotDiameter - statusDotGap
let maxIncidentDescriptionLines = 3
let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

// MARK: - Mirror of PopupViewController.chipFitsAfterDescription

func chipFitsAfterDescription(name: String, chip: String) -> Bool {
    let storage = NSTextStorage(string: name, attributes: [.font: font])
    let layoutManager = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: incidentTextWidth, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    container.lineBreakMode = .byWordWrapping
    layoutManager.addTextContainer(container)
    storage.addLayoutManager(layoutManager)
    layoutManager.ensureLayout(for: container)

    var lineCount = 0
    var lastLineWidth: CGFloat = 0
    var index = 0
    while index < layoutManager.numberOfGlyphs {
        var lineRange = NSRange()
        let rect = layoutManager.lineFragmentUsedRect(forGlyphAt: index, effectiveRange: &lineRange)
        lineCount += 1
        lastLineWidth = rect.maxX
        index = NSMaxRange(lineRange)
    }
    guard lineCount <= maxIncidentDescriptionLines else { return false }

    let gap: CGFloat = 12
    let chipWidth = (chip as NSString).size(withAttributes: [.font: font]).width
    return lastLineWidth + gap + chipWidth <= incidentTextWidth
}

// MARK: - Mirror of PopupViewController.incidentText

func incidentText(name: String, chip: String) -> NSMutableAttributedString {
    let separator = chipFitsAfterDescription(name: name, chip: chip) ? "\t" : "\n"
    let text = NSMutableAttributedString(string: name + separator + chip, attributes: [.font: font])

    let paragraph = NSMutableParagraphStyle()
    paragraph.tabStops = [NSTextTab(textAlignment: .right, location: incidentTextWidth)]
    paragraph.lineBreakMode = .byWordWrapping
    text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))

    if separator == "\n" {
        let chipParagraph = NSMutableParagraphStyle()
        chipParagraph.alignment = .right
        chipParagraph.lineBreakMode = .byWordWrapping
        let newlineIndex = (name as NSString).length
        text.addAttribute(
            .paragraphStyle, value: chipParagraph,
            range: NSRange(location: newlineIndex, length: text.length - newlineIndex))
    }
    return text
}

// MARK: - Measurement

/// Lays the row out and reports, for the chip's first glyph, which line it sits on and where that
/// line's text ends — the number that tells flush-right from flush-left.
func measure(name: String, chip: String) -> (lines: Int, chipLine: Int, chipLineEnd: CGFloat, ownLine: Bool) {
    let text = incidentText(name: name, chip: chip)
    // Whether the chip got its own line is the separator's answer, not the line number's: a chip
    // sharing a two-line description's last line is also "on line 2 of 2".
    let ownLine = text.string.contains("\n")
    let storage = NSTextStorage(attributedString: text)
    let layoutManager = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: incidentTextWidth, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    container.lineBreakMode = .byWordWrapping
    layoutManager.addTextContainer(container)
    storage.addLayoutManager(layoutManager)
    layoutManager.ensureLayout(for: container)

    let chipCharIndex = text.length - (chip as NSString).length
    let chipGlyph = layoutManager.glyphIndexForCharacter(at: chipCharIndex)

    var lines = 0
    var chipLine = 0
    var chipLineEnd: CGFloat = 0
    var index = 0
    while index < layoutManager.numberOfGlyphs {
        var lineRange = NSRange()
        let rect = layoutManager.lineFragmentUsedRect(forGlyphAt: index, effectiveRange: &lineRange)
        lines += 1
        if NSLocationInRange(chipGlyph, lineRange) {
            chipLine = lines
            chipLineEnd = rect.maxX
        }
        index = NSMaxRange(lineRange)
    }
    return (lines, chipLine, chipLineEnd, ownLine)
}

// MARK: - Cases

/// Real names from the `incident-two` stub plus the one from #351, each with the chip the row shows
/// and where that chip belongs. Sharing is the preferred outcome — the chip only takes a line of its
/// own when the description's last line has no room for it.
let cases: [(name: String, chip: String, expectOwnLine: Bool)] = [
    ("Increased latency", "5m · monitoring", false),
    ("Degraded performance of multiple models", "2h7m · identified", false),
    ("Elevated errors for Claude Mythos 5, Claude Fable 5, and Claude Sonnet 5",
     "13m · investigating", true),
    // Single-line name, chip still homeless: the name ends ~185 pt in, leaving 67 pt where the chip
    // needs 113. The clearest case, and the one a line-count heuristic would get wrong — one line of
    // description does not mean the chip fits on it.
    ("Elevated error rates on the API", "6m · investigating", true),
    ("Elevated errors for Claude Fable 5, Claude Sonnet 5, Claude Haiku 4.5, and other models",
     "12m · investigating", false),
]

print("incident text width: \(incidentTextWidth) pt\n")
var failures = 0
for c in cases {
    let m = measure(name: c.name, chip: c.chip)
    // Flush right means the chip's line ends at the trailing edge. A point of slack covers rounding
    // in the layout's used rect.
    let flushRight = m.chipLineEnd >= incidentTextWidth - 1
    let placedRight = m.ownLine == c.expectOwnLine
    let ok = flushRight && placedRight
    if !ok { failures += 1 }
    var notes: [String] = []
    if !flushRight { notes.append("not flush right") }
    if !placedRight { notes.append(m.ownLine ? "took its own line unnecessarily" : "should be on its own line") }
    print("\(ok ? "ok  " : "FAIL") [\(m.ownLine ? "own line" : "shared  ")] lines=\(m.lines) " +
          "chip on line \(m.chipLine), ends at \(String(format: "%.1f", m.chipLineEnd)) pt" +
          (notes.isEmpty ? "" : "  ← \(notes.joined(separator: ", "))") +
          "\n     \(c.name)")
}
print(failures == 0
    ? "\nAll chips flush right and on the expected line."
    : "\n\(failures) case(s) wrong.")
exit(failures == 0 ? 0 : 1)
