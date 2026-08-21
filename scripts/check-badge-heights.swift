#!/usr/bin/env swift

// Check that every badge in the popup is the same height, whatever it carries.
//
// There are three kinds: the blocking-reset badge (a reset line), the credits marker's resting form (a
// currency glyph) and its ⌥ form (the word "active"). They sit in different rows but the popup shows
// them together, so a height that varies with the content makes the section look assembled by accident.
//
// It did. Before `PillView.sharedHeight`, each badge sized itself to its own content and they came out
// 18.0, 17.5–20.5 and 14.0 pt — and the currency one changed height with the *currency*, because SF
// Symbol boxes disagree (12×12 for `eurosign`, 12×15 for `coloncurrencysign`). A row would shift shape
// when the account's billing currency changed.
//
// The fix: width still comes from the content, height always from `sharedHeight`, measured once off the
// reset badge (the tallest anatomy, so nothing has to grow past it).
//
// This also pins the claim in ADR-0068's postscript — that centring a currency glyph *is* solvable by
// calculation, against that ADR's original "isn't solved by calculation". Measuring the glyph's ink
// rather than its box is what makes it work, and a text attachment gets it for free: the text system
// positions the symbol from the font's cap height, with no per-currency constant.
//
// Run: swift scripts/check-badge-heights.swift

import AppKit

let dropdownTextSize = NSFont.systemFontSize    // PopupViewController.dropdownTextSize
let hInset: CGFloat = 0                         // PillView.hInset
let vInset: CGFloat = 2                         // PillView.vInset

/// Mirror of `PillCell`.
final class PillCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: rect.insetBy(dx: hInset, dy: vInset))
    }
}

/// Mirror of `PillView` — including the shared-height rule under test.
final class PillView: NSTextField {
    var isHeightProbe = false
    private static var cachedSharedHeight: CGFloat?

    static var sharedHeight: CGFloat {
        if let cached = cachedSharedHeight { return cached }
        let probe = make(NSAttributedString(string: "0"), font: pillFont)
        probe.isHeightProbe = true
        let height = probe.intrinsicContentSize.height
        cachedSharedHeight = height
        return height
    }

    static func make(_ content: NSAttributedString, font: NSFont) -> PillView {
        let view = PillView(frame: .zero)
        let cell = PillCell(textCell: "")
        cell.isEditable = false
        cell.isSelectable = false
        cell.isBezeled = false
        cell.drawsBackground = false
        cell.font = font
        cell.textColor = .controlBackgroundColor
        cell.lineBreakMode = .byClipping
        view.cell = cell

        let styled = NSMutableAttributedString(attributedString: content)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byClipping
        styled.addAttributes(
            [.font: font, .foregroundColor: NSColor.controlBackgroundColor, .paragraphStyle: paragraph],
            range: NSRange(location: 0, length: styled.length))
        view.attributedStringValue = styled
        return view
    }

    override var intrinsicContentSize: NSSize {
        var size = cell?.cellSize ?? super.intrinsicContentSize
        size.width += 2 * hInset
        size.height += 2 * vInset
        if !isHeightProbe { size.height = Self.sharedHeight }
        return size
    }
}

/// Mirror of `PillView.init(symbol:…)` — the SF Symbol as a text attachment on the font's cap height.
func symbolContent(_ name: String, font: NSFont) -> NSAttributedString? {
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .bold)) else { return nil }
    let attachment = NSTextAttachment()
    attachment.image = image
    attachment.bounds = CGRect(x: 0, y: (font.capHeight - image.size.height) / 2,
                               width: image.size.width, height: image.size.height)
    return NSAttributedString(attachment: attachment)
}

/// `PopupViewController.pillFont` — one face for every badge: the reset line, the currency glyph and
/// the ⌥ word. They share a popup, so a size difference between them reads as a mistake.
let pillFont = NSFont.systemFont(ofSize: dropdownTextSize - 2, weight: .medium)

/// Every currency the badge can show — mirror of `StatusItemView.creditsSymbolName(for:)`.
let currencies = [
    "eurosign", "dollarsign", "sterlingsign", "yensign", "indianrupeesign", "coloncurrencysign",
]

var rows: [(String, NSSize)] = []

for text in ["5d", "resets in 5d on Monday", "resets in 20h at 03:00"] {
    rows.append(("reset · \(text)",
                 PillView.make(NSAttributedString(string: text), font: pillFont).intrinsicContentSize))
}
for name in currencies {
    guard let content = symbolContent(name, font: pillFont) else {
        print("  \(name): symbol missing — check the name against SF Symbols")
        exit(1)
    }
    rows.append(("currency · \(name)", PillView.make(content, font: pillFont).intrinsicContentSize))
}
rows.append(("⌥ word · active",
             PillView.make(NSAttributedString(string: "active"), font: pillFont).intrinsicContentSize))

print("badge sizes (pt)\n")
for (label, size) in rows {
    print(String(format: "  %-30@ %5.1f × %5.1f", label as NSString, size.width, size.height))
}

let heights = Set(rows.map { $0.1.height })
print("\ndistinct heights: \(heights.sorted().map { String(format: "%.1f", $0) }.joined(separator: ", "))")

if heights.count != 1 {
    print("FAIL: badges do not share a height — a row will change shape with its content.")
    exit(1)
}
print("OK: all \(rows.count) badges are \(String(format: "%.1f", heights.first ?? 0)) pt tall.")
