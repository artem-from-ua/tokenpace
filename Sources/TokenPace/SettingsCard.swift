import AppKit

// MARK: - SettingsColors

/// Dynamic colours matching System Settings' grouped-inset list, measured from the live app (#156,
/// ADR-0040). macOS AppKit has no semantic colour or material that reproduces the grouped-background
/// pair with its light↔dark flip (the card is slightly DARKER than the pane in light, slightly LIGHTER
/// in dark) — the UIKit `systemGroupedBackground` family simply doesn't exist here, and the closest
/// material (`.contentBackground`) renders pure white in light. So these are fixed dynamic greys that
/// resolve to the measured values: pane 246/40, card 242/43 (light/dark).
@MainActor
enum SettingsColors {
    static let paneBackground = grouped(light: 246, dark: 40)
    static let groupedCardFill = grouped(light: 242, dark: 43)

    private static func grouped(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let v = CGFloat(isDark ? dark : light) / 255
            return NSColor(srgbRed: v, green: v, blue: v, alpha: 1)
        }
    }
}

// MARK: - FlippedView

/// A top-left-origin container. `NSScrollView`'s document view is bottom-origin by default, which
/// pins short content to the *bottom* of a tall pane; flipping the document makes it start at the top,
/// the way a settings pane should read (#131).
@MainActor
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Grouped-inset card primitives (#131)

/// A single grouped-inset "card" — the rounded, filled container that holds a run of settings rows,
/// matching the panels inside modern macOS System Settings (Ventura+). It replaces the old flat
/// `NSStackView` + bold-header + `NSBox`-separator sections (ADR-0012) with the native card look.
///
/// **Fill is a system material, not a hand-picked colour (#156, ADR-0040).** System Settings renders
/// its cards as a translucent `NSVisualEffectView` material over the pane, which is why the card reads
/// as a subtle *offset* from the pane background (slightly darker in light, lighter in dark) rather
/// than a flat white — the earlier `controlBackgroundColor` fill (pure white in light) was the inverse
/// of that. So the card *is* an `NSVisualEffectView` with `.contentBackground` material; the pane
/// behind it uses `.windowBackground`. Both are appearance- and desktop-aware for free.
///
/// The rounded corners are a layer mask on the effect view (`cornerRadius` + `masksToBounds`);
/// geometry is appearance-agnostic and set once. Dividers are inset hairlines between rows.
@MainActor
final class SettingsCard: NSView {

    enum Metrics {
        // Measured from System Settings' grouped card (Retina ÷2): the card corner is ~4 pt, not the
        // ~10 pt of a typical rounded panel — System Settings' cards are only gently rounded (#156).
        static let cornerRadius: CGFloat = 4
        /// Inset of the hairline divider from BOTH card edges — measured 10 pt each side in System
        /// Settings (the divider starts ~at the text margin and stops symmetrically on the right, #156).
        static let dividerInset: CGFloat = 10
    }

    private let rowStack = NSStackView()

    init() {
        super.init(frame: .zero)
        // The card fill is `windowBackgroundColor`, on a pane painted with the lighter
        // `textBackgroundColor` (set on the pane's scroll/document, see `pane(...)`). In System Settings
        // the grouped card sits a step OFF the pane — slightly DARKER in light, slightly LIGHTER in dark
        // — which is exactly the windowBackground-on-textBackground relationship (light: ~246 card on
        // 255 pane; dark: the flip). The earlier `.contentBackground` material rendered pure white,
        // making the card lighter than the pane — the inverse of System Settings (#156). CGColor is
        // static, so the fill is re-resolved in `updateLayer()` for light/dark.
        wantsLayer = true
        layer?.cornerRadius = Metrics.cornerRadius
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 0
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.topAnchor.constraint(equalTo: topAnchor),
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Card fill: a dynamic colour matching System Settings' grouped-inset card exactly — 242 in
        // light, 43 in dark. macOS AppKit has NO semantic colour (nor material) that produces this with
        // the light/dark flip (System Settings draws it via a `.behindWindow` material whose value
        // drifts with the desktop; `.contentBackground` renders pure white in light — the earlier bug).
        // A fixed dynamic colour is the robust way to pin the measured values (#156, ADR-0040).
        layer?.backgroundColor = SettingsColors.groupedCardFill.cgColor
        // A subtle hairline border around the card, like System Settings' grouped cards.
        layer?.borderWidth = 1 / (window?.backingScaleFactor ?? 2)
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    /// Add a row to the card. Rows are separated by an inset hairline, except before the first one — or
    /// when `divider: false`, which attaches the row to the one above with no separator (used for a
    /// sub-note that belongs to the row above it, e.g. the dev-build hint under "Back to work").
    /// Each row stretches to the card's full width so trailing controls sit on the right edge.
    func addRow(_ row: NSView, divider: Bool = true) {
        if divider, !rowStack.arrangedSubviews.isEmpty {
            let line = DividerView(inset: Metrics.dividerInset)
            rowStack.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        rowStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
    }

    /// Hide/show a row *and* the hairline that precedes it, so a hidden row collapses out of layout
    /// without leaving an orphan divider (the update-available row, #37, is hidden as a unit this way).
    /// Pass the row view previously added via `addRow`.
    func setRow(_ row: NSView, hidden: Bool) {
        row.isHidden = hidden
        // The divider that precedes this row sits immediately before it in the stack.
        let views = rowStack.arrangedSubviews
        guard let idx = views.firstIndex(of: row), idx > 0 else { return }
        (views[idx - 1] as? DividerView)?.isHidden = hidden
    }
}

// MARK: - DividerView

/// A retina-correct inset hairline between card rows. Height is `1/backingScaleFactor` (0.5 pt on a
/// retina display), re-read on a backing change; the colour is re-resolved in `updateLayer()` for
/// dark/light (same `CGColor`-is-static reason as ``SettingsCard``).
@MainActor
final class DividerView: NSView {

    private let inset: CGFloat
    private var heightConstraint: NSLayoutConstraint!
    /// The hairline itself is a dedicated sublayer inset from both edges — the view's own layer stays
    /// clear. (Painting the view layer directly + resizing it in `layout()` fought Auto Layout and the
    /// line spanned the full width; a sublayer insets reliably, #156.)
    private let lineLayer = CALayer()

    init(inset: CGFloat) {
        self.inset = inset
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(lineLayer)
        translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(equalToConstant: 1)
        heightConstraint.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        heightConstraint.constant = 1 / max(scale, 1)
    }

    override func layout() {
        super.layout()
        // Inset the hairline from BOTH edges — it starts where the row text starts on the left and stops
        // short of the right edge, like System Settings, rather than spanning the full card width (#156).
        lineLayer.frame = CGRect(x: inset, y: 0, width: max(0, bounds.width - inset * 2), height: bounds.height)
        // Re-resolve the colour here too (CGColor is static; `layout` runs on appearance changes).
        lineLayer.backgroundColor = NSColor.separatorColor.cgColor
    }
}

// MARK: - SettingsRow

/// Builders for the card's row types. A row is a horizontal band with content on the leading edge and
/// an optional trailing control (a switch, a button, a link). Multi-line hints live *under* the
/// primary label in a leading vertical stack, in `secondaryLabelColor` — the switch has no subtitle of
/// its own, so all explanatory text is a plain label here (a deliberate consequence of moving from
/// checkbox-with-title to a trailing `NSSwitch`, #131).
@MainActor
enum SettingsRow {

    enum Metrics {
        // Measured from System Settings (Retina ÷2): a single-line row is 37 pt tall with the text
        // vertically centred; card-edge → label = 11 pt. A 13 pt system font in a 37 pt row leaves ~12 pt
        // above/below, so `verticalInset` is 12 (13 + 2×12 = 37). `minHeight` pins the single-line height
        // exactly; multi-line rows (title + hint) grow from the content (#156).
        static let horizontalInset: CGFloat = 11
        static let verticalInset: CGFloat = 12
        static let minHeight: CGFloat = 37
    }

    /// A row wrapping arbitrary leading content and an optional trailing control, padded and pinned to
    /// the card width. The trailing control (if any) hugs the right edge; the leading content takes the
    /// remaining width.
    static func container(leading: NSView, trailing: NSView? = nil) -> NSView {
        // The row's height comes from its content plus a symmetric vertical inset — NOT a stretched
        // fixed-height view with the text centred by hand (which left the text visually top-heavy). The
        // leading and trailing views are laid out by a horizontal NSStackView aligned to the FIRST
        // baseline, so text and controls line up the way AppKit lines up a labelled control, with equal
        // space above and below (#156). A minimum height keeps very short rows from looking cramped.
        let hStack = NSStackView()
        hStack.orientation = .horizontal
        hStack.alignment = .firstBaseline
        hStack.spacing = 12
        hStack.translatesAutoresizingMaskIntoConstraints = false
        hStack.edgeInsets = NSEdgeInsets(
            top: Metrics.verticalInset, left: Metrics.horizontalInset,
            bottom: Metrics.verticalInset, right: Metrics.horizontalInset)

        leading.translatesAutoresizingMaskIntoConstraints = false
        hStack.addArrangedSubview(leading)

        if let trailing {
            trailing.translatesAutoresizingMaskIntoConstraints = false
            trailing.setContentHuggingPriority(.required, for: .horizontal)
            trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
            // A flexible spacer pushes the trailing control to the right edge; the leading view takes the
            // rest and its wrapping hint reflows to that width.
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            hStack.addArrangedSubview(spacer)
            hStack.addArrangedSubview(trailing)
        }

        // The stack fully defines the row: its edgeInsets give equal top/bottom padding, so the row's
        // height is exactly content + 2×inset with no hand-centred stretching (which had left the text
        // top-heavy with no bottom space). A minimum height is enforced by requiring the CONTENT to be at
        // least `minHeight − 2×inset` tall, so short rows aren't cramped but the padding stays symmetric.
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(hStack)
        let minContent = Metrics.minHeight - Metrics.verticalInset * 2
        NSLayoutConstraint.activate([
            hStack.topAnchor.constraint(equalTo: row.topAnchor),
            hStack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            hStack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            hStack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            leading.heightAnchor.constraint(greaterThanOrEqualToConstant: minContent),
        ])
        return row
    }

    /// The leading label (+ optional hint) column used by most rows. Returns the stack plus the hint
    /// label so callers that need to collapse the hint on empty (launch-at-login, #69) can reach it.
    static func labelColumn(_ title: String, hint: String? = nil)
        -> (view: NSView, hintLabel: NSTextField?) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .labelColor

        let stack = NSStackView(views: [label])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2

        var hintLabel: NSTextField?
        if let hint {
            let hl = wrappingHint(hint)
            hintLabel = hl
            stack.addArrangedSubview(hl)
        }
        return (stack, hintLabel)
    }

    /// A wrapping secondary-colour hint label. It wraps to the width the row's leading column actually
    /// gets (the card width minus the trailing control), rather than a fixed column width — so it
    /// reflows as the window/card width changes (#156). The row (`container`) pins the leading column's
    /// trailing edge, which gives this label its wrapping width; a low horizontal hugging priority lets
    /// it stretch to fill that width.
    static func wrappingHint(_ text: String) -> NSTextField {
        let hl = NSTextField(wrappingLabelWithString: text)
        hl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hl.textColor = .secondaryLabelColor
        hl.translatesAutoresizingMaskIntoConstraints = false
        hl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return hl
    }

    /// A trailing `NSSwitch` wired to `target`/`action` — the checkbox replacement (#131). Uses the
    /// `.mini` control size, which matches the switches in System Settings' grouped rows exactly
    /// (26×15 pt measured; System Settings sets its SwiftUI toggles to `.mini` too) — `.regular` (38×22)
    /// and even `.small` (32×18) are visibly too big (#156).
    static func makeSwitch(target: AnyObject?, action: Selector) -> NSSwitch {
        let sw = NSSwitch()
        sw.controlSize = .mini
        sw.target = target
        sw.action = action
        return sw
    }

    /// A small rounded push button (Choose…, Archive Now, Check Now).
    static func makeButton(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        return b
    }

    /// An inline link button (`.linkColor`, borderless) — the repo link and the Download link.
    static func makeLink(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.isBordered = false
        b.bezelStyle = .inline
        b.contentTintColor = .linkColor
        b.font = .systemFont(ofSize: NSFont.systemFontSize)   // body size, matching the row's label
        return b
    }

    /// Wrap a bezelless control (e.g. an `NSDatePicker` with its own drawing turned off) in a rounded
    /// bezel box, so a time stepper reads like System Settings' rounded time field (#156). AppKit can't
    /// round an `NSDatePicker`'s own bezel, so the rounded rect is drawn by the host view here.
    static func roundedFieldBox(wrapping control: NSView) -> NSView {
        let box = RoundedFieldBox()
        box.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(control)
        // Centre the control vertically in the box (equal visual space top and bottom). Pinning both
        // top and bottom with equal insets looked bottom-heavy because the picker's glyphs don't sit
        // centred in its own bounds; centring on Y + a fixed box height fixes the asymmetry (#156).
        // Insets tuned to match System Settings' time field (measured): the stepper pill hugs the right
        // bezel edge (trailing −1) and the digits have a small left pad (leading 4); height +2 → ~22pt,
        // System Settings' field height (#156).
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 4),
            control.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
            // The picker's glyphs sit slightly above its bounds centre, so nudge the control down a hair
            // to look vertically centred inside the box (equal space above/below the digits).
            control.centerYAnchor.constraint(equalTo: box.centerYAnchor, constant: 1.5),
            box.heightAnchor.constraint(equalTo: control.heightAnchor, constant: 2),
        ])
        return box
    }
}

// MARK: - RoundedFieldBox

/// A rounded-rect bezel drawn by hand, to host a bezelless control (the time-stepper `NSDatePicker`,
/// which can't round its own bezel) so it reads like System Settings' rounded time field (#156). The
/// fill/border are semantic colours re-resolved in `updateLayer()` for light/dark.
@MainActor
final class RoundedFieldBox: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = 5
        layer.borderWidth = 1
        layer.borderColor = NSColor.separatorColor.cgColor
        // Fill matches the card, not `textBackgroundColor` — in dark mode the latter is near-black and
        // read darker than the card; System Settings' time field is the same tone as its card (#156).
        layer.backgroundColor = SettingsColors.groupedCardFill.cgColor
    }
}

