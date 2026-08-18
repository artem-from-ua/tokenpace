#!/usr/bin/env swift

// Check which popup detail lines survive the split-row fit gate.
//
// `PopupViewController.detailHalvesFit` lives in the AppKit executable target, which SwiftPM cannot
// reach from `TokenPaceKitTests`, so this mirrors it and pins the decisions the design depends on:
//
//   - every token row keeps its reset, even in the widest ⌥ form
//   - the credits line drops its reset under ⌥ — including at ordinary amounts, not just huge ones
//   - nothing is dropped at rest
//
// The widths cannot be hardcoded: they depend on the system font size and on locale/currency
// formatting (`€10.77`, `10,77 kr`, `12.00 UAH`), so the strings are measured the same way AppKit
// measures them when laying the row out.
//
// Run: swift scripts/check-detail-line-fit.swift

import AppKit

// MARK: - Mirror of PopupViewController.Metrics

let popupWidth: CGFloat = 390
let cardInset: CGFloat = 14
let hPadding: CGFloat = 16
let contentWidth = popupWidth - 2 * cardInset - 2 * hPadding   // 330 pt
let minSplitGap: CGFloat = 12
let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

/// Mirror of `PopupViewController.detailHalvesFit(left:right:font:)`.
func fits(_ left: String, _ right: String) -> Bool {
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    let l = (left as NSString).size(withAttributes: attrs).width
    let r = (right as NSString).size(withAttributes: attrs).width
    return l + minSplitGap + r <= contentWidth
}

func width(_ s: String) -> CGFloat {
    (s as NSString).size(withAttributes: [.font: font]).width
}

// MARK: - The cases the design commits to

struct Case {
    let name: String
    let left: String
    let right: String
    /// Whether the reset must survive.
    let keepsReset: Bool
}

let cases: [Case] = [
    // Token rows: the reset must never be dropped — these are the popup's primary rows and their
    // left half is a short percentage.
    Case(name: "token 5h, rest", left: "20%", right: "2h at 02:50", keepsReset: true),
    Case(name: "token 5h, ⌥", left: "20% used", right: "resets in 2h at 02:50", keepsReset: true),
    Case(name: "token 7d, ⌥", left: "100% used", right: "resets in 7d next Monday", keepsReset: true),
    Case(name: "token 7d far, ⌥", left: "88% used", right: "resets in 5d on Wednesday", keepsReset: true),

    // Credits at rest: the compact forms always fit.
    Case(name: "credits, rest", left: "€10.8 of €15", right: "5d on Friday", keepsReset: true),
    Case(name: "credits wide, rest", left: "€1.23K of €2K", right: "5d on Friday", keepsReset: true),

    // Credits under ⌥: both halves grow at once. Against the old 252 pt column all three of these
    // lost their reset; at 330 (#396) they keep it, which is what the wider popup was for. The gate
    // itself stays — see the two cases below it.
    Case(name: "credits, ⌥", left: "spent €10.77 of €15.00", right: "resets in 5d on Friday", keepsReset: true),
    Case(name: "credits zero, ⌥", left: "spent €0.00 of €15.00", right: "resets in 5d on Friday", keepsReset: true),
    Case(name: "credits wide, ⌥", left: "spent €1,234.56 of €2,000.00", right: "resets in 5d on Friday", keepsReset: true),

    // The gate's remaining job: a four-figure cap paired with the longest reset phrase. The reset is
    // DROPPED rather than truncated — the amounts are what the user opened the popup for, and the
    // reset is repeated in the menu bar anyway.
    Case(name: "credits max, ⌥", left: "spent $5,000.00 of $5,000.00", right: "resets in 20d next Wednesday", keepsReset: false),
    Case(name: "credits max, rest", left: "$5,000.00 of $5,000.00", right: "20d next Wednesday", keepsReset: true),
]

// MARK: - Run

print("contentWidth \(contentWidth) pt · minSplitGap \(minSplitGap) pt · font \(font.pointSize) pt\n")

var failures = 0
for c in cases {
    let got = fits(c.left, c.right)
    let ok = got == c.keepsReset
    if !ok { failures += 1 }
    let total = width(c.left) + minSplitGap + width(c.right)
    let name = c.name.padding(toLength: 20, withPad: " ", startingAt: 0)
    let verdict = got ? "reset shown " : "reset hidden"
    print(String(format: "%@ %@  %@  %6.1f pt", ok ? "ok  " : "FAIL", name, verdict, total))
}

if failures == 0 {
    print("\nAll \(cases.count) detail lines gate as intended.")
} else {
    print("\n\(failures) of \(cases.count) gated unexpectedly.")
    exit(1)
}
