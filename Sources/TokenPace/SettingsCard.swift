import AppKit

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
/// AppKit has no built-in rounded grouped container that matches Sequoia, so the card is a
/// layer-backed `NSView` drawn by hand: `controlBackgroundColor` fill on the window's
/// `windowBackgroundColor`, a ~10 pt corner radius, and inset hairline dividers between rows.
///
/// **Dark mode:** a `CGColor` is a static colour, not a dynamic `NSColor` — so the layer fill and the
/// divider colours are re-resolved in `updateLayer()` (driven by `wantsUpdateLayer`), which AppKit
/// calls on every appearance change. Geometry (corner radius, `masksToBounds`) is appearance-agnostic
/// and set once.
@MainActor
final class SettingsCard: NSView {

    enum Metrics {
        static let cornerRadius: CGFloat = 10
        /// Leading inset of the hairline divider between rows — aligns roughly under the row label,
        /// the way System Settings insets its dividers. Approximate; tuned by eye.
        static let dividerInset: CGFloat = 14
    }

    private let rowStack = NSStackView()

    init() {
        super.init(frame: .zero)
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
        // Re-resolve the fill for the current appearance — CGColor does not track light/dark on its own.
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    /// Add a row to the card. Rows are separated by an inset hairline, except before the first one.
    /// Each row stretches to the card's full width so trailing controls sit on the right edge.
    func addRow(_ row: NSView) {
        if !rowStack.arrangedSubviews.isEmpty {
            let divider = DividerView(inset: Metrics.dividerInset)
            rowStack.addArrangedSubview(divider)
            divider.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
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

    init(inset: CGFloat) {
        self.inset = inset
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(equalToConstant: 1)
        heightConstraint.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        heightConstraint.constant = 1 / max(scale, 1)
    }

    override func layout() {
        super.layout()
        // Inset the hairline from the leading edge only, like System Settings.
        layer?.frame = CGRect(x: inset, y: 0, width: max(0, bounds.width - inset), height: bounds.height)
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
        static let horizontalInset: CGFloat = 14
        static let verticalInset: CGFloat = 9
        static let minHeight: CGFloat = 38
        /// Fixed width for the leading text column's wrapping hints, so a hint wraps predictably
        /// rather than fighting the trailing control for width.
        static let textColumnWidth: CGFloat = 300
    }

    /// A row wrapping arbitrary leading content and an optional trailing control, padded and pinned to
    /// the card width. The trailing control (if any) hugs the right edge; the leading content takes the
    /// remaining width.
    static func container(leading: NSView, trailing: NSView? = nil) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        leading.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(leading)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.minHeight),
            leading.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Metrics.horizontalInset),
            leading.topAnchor.constraint(equalTo: row.topAnchor, constant: Metrics.verticalInset),
            leading.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -Metrics.verticalInset),
        ])

        if let trailing {
            trailing.translatesAutoresizingMaskIntoConstraints = false
            trailing.setContentHuggingPriority(.required, for: .horizontal)
            trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addSubview(trailing)
            NSLayoutConstraint.activate([
                trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -Metrics.horizontalInset),
                trailing.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                leading.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -12),
            ])
        } else {
            leading.trailingAnchor.constraint(
                lessThanOrEqualTo: row.trailingAnchor, constant: -Metrics.horizontalInset).isActive = true
        }
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

    /// A wrapping secondary-colour hint label at the fixed text-column width.
    static func wrappingHint(_ text: String) -> NSTextField {
        let hl = NSTextField(wrappingLabelWithString: text)
        hl.font = .systemFont(ofSize: 11)
        hl.textColor = .secondaryLabelColor
        hl.translatesAutoresizingMaskIntoConstraints = false
        hl.widthAnchor.constraint(equalToConstant: Metrics.textColumnWidth).isActive = true
        return hl
    }

    /// A trailing `NSSwitch` wired to `target`/`action` — the checkbox replacement (#131).
    static func makeSwitch(target: AnyObject?, action: Selector) -> NSSwitch {
        let sw = NSSwitch()
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
        b.font = .systemFont(ofSize: 12)
        return b
    }
}

