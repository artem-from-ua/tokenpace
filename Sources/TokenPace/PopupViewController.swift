import AppKit
import TokenPaceKit

/// The single point size for **every** piece of text in the dropdown menu — the popup's own labels
/// (`PopupViewController`) and the native menu items below it ("Settings…"/"Troubleshoot…", "Quit…"
/// in `App.swift`, pinned to this via `attributedTitle`). One shared constant instead of two
/// independently-tuned values, so the two can never visually drift apart again (see git history:
/// `NSFont.menuFont(ofSize: 0)` and an empirically-picked 16 pt both mismatched the native items —
/// there is no reliable way to *read* AppKit's real menu-item size, so instead both sides are forced
/// to *write* the same one). `NSFont.systemFontSize` (13 pt) is the documented default UI text size.
let dropdownTextSize: CGFloat = NSFont.systemFontSize

// MARK: - PopupBarView

/// A pacing bar drawn inside the popup, in the **same** three-zone style as the menu-bar widget:
/// used (grey) → pacing gap (green/red) → future (teal), with a time-indicator dot. The geometry
/// is a `BarLayout` from `PacingModel`; the colours are the fixed statusline palette (ADR-0005),
/// kept in sync with `StatusItemView` by mirroring the same sRGB values.
final class PopupBarView: NSView {

    var bar: BarLayout? {
        didSet {
            guard bar != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Number of equal sub-intervals the tick ruler splits this window into (`LimitRow.subdivisions`:
    /// 5 for the 5-hour bar, 7 for the 7-day/per-model bars). Draws `subdivisions - 1` interior
    /// ticks; `0` (the default) draws none (issue #38).
    var subdivisions: Int = 0 {
        didSet {
            guard subdivisions != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Whether this is the **idle** 5-hour bar (#100, ADR-0027): a solid-blue knobless track (no pacing
    /// zones, no time-indicator dot) for a 5h window with no active session. The under-bar tick ruler
    /// still draws (`subdivisions`), keeping the row's anatomy in family with the active bars.
    var idle: Bool = false {
        didSet {
            guard idle != oldValue else { return }
            needsDisplay = true
        }
    }

    private enum Metrics {
        /// Height of the pacing bar itself (the coloured zones + indicator dot).
        static let barHeight: CGFloat = 6
        static let corner: CGFloat = 2
        /// Diameter of the time-indicator dot — 2× the bar height so it reads clearly as the primary
        /// time marker over the pacing zones.
        static let indicatorDiameter: CGFloat = 12
        static let indicatorStroke: CGFloat = 1
        // Tick ruler, drawn *below* the bar like an axis (issue #38, "under-bar ruler" style).
        static let tickLength: CGFloat = 3
        static let tickGap: CGFloat = 2
        static let tickWidth: CGFloat = 1
        /// Total view height: tall enough for the bar + under-bar tick ruler **and** for the dot,
        /// which is centred on the bar and so overhangs it by `indicatorDiameter/2 − barHeight/2`
        /// on top; without that headroom a larger dot would be clipped by the view's frame.
        static let height: CGFloat = max(
            barHeight + tickGap + tickLength,
            indicatorDiameter + tickGap + tickLength)
    }

    /// The fixed view height (bar + under-bar tick ruler), exposed so `PopupViewController` can pin
    /// the hosted bar's height constraint to the same value the view draws into.
    static var viewHeight: CGFloat { Metrics.height }

    // Statusline 256-colour palette (ADR-0005), appearance-aware in the popup: on a dark theme the
    // bars keep the exact menu-bar colours; on a light theme the dark zones (used grey, future
    // teal) and the indicator ring are lightened so they read on a light panel. The pacing-gap green
    // is darkened on light to read against the pale panel; the red stays identical in both themes.
    //
    // NSColor(name:dynamicProvider:) resolves per-appearance and AppKit re-draws on theme change
    // automatically (PopupBarView draws in its real appearance — no manual observation needed).
    private enum Palette {
        /// Pacing gap colours. Green (on pace) is the **system** colour, matching the Claude
        /// service-status dots. The ahead-of-pace grade — amber (< 15 pts ahead) → orange (≥ 15) → red
        /// (exhausted) — uses **custom** sRGB, pulled apart so the steps read clearly distinct: a golden
        /// **amber** (not a pale yellow — a pure light yellow washed out against the light-grey bar, so
        /// the mildest step is a darker golden tone instead), an orange nudged toward red, and a pure
        /// saturated red (no blue tint unlike `systemRed`).
        static let gapGreen = NSColor.systemGreen
        /// The **idle** 5-hour bar's solid fill (#100, ADR-0027): the 5h window has no active session, so
        /// the bar is a knobless solid track meaning "ready to start, full quota available" — a neutral
        /// blue, not a pacing colour (green is reserved for an active window's pacing status). Built on
        /// `NSColor.systemBlue` (the appearance-aware pair to `gapGreen`'s `systemGreen`), but **lightened
        /// on the light theme** (mixed ~22 % toward white) so it does not read as heavy against the pale
        /// panel; on dark it stays the full `systemBlue`, which already reads bright there. The blend is
        /// computed **inside** the provider, in the target appearance, so `systemBlue` resolves to its
        /// real per-theme RGB before mixing (a `static let … .blended(...)` would bake in whatever
        /// appearance was current at first access — the same trap `dimmedLabelColor` documents).
        static let idleBlue = NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua { return .systemBlue }
            var lightened: NSColor = .systemBlue
            appearance.performAsCurrentDrawingAppearance {
                lightened = NSColor.systemBlue.blended(withFraction: 0.22, of: .white) ?? .systemBlue
            }
            return lightened
        }
        static let gapRed = NSColor(srgbRed: 225/255, green: 45/255, blue: 35/255, alpha: 1)
        static let gapYellow = NSColor(srgbRed: 230/255, green: 180/255, blue: 25/255, alpha: 1)
        static let gapOrange = NSColor(srgbRed: 248/255, green: 118/255, blue: 15/255, alpha: 1)

        /// Indicator-dot ring: a soft separation between the dot and the bar beneath it. On **light** a
        /// near-white translucent ring (the earlier `windowBackgroundColor·0.4` read too dark against the
        /// light-grey bar); on **dark** the panel background at reduced opacity, which already reads as a
        /// soft dark ring there.
        static let indicatorStroke = dynamic(
            dark: NSColor.windowBackgroundColor.withAlphaComponent(0.4),
            light: NSColor(white: 1, alpha: 0.65)
        )

        /// Tick-ruler marks below the bar: a muted neutral **solid** grey (opaque, not translucent) so
        /// it renders the same regardless of what's behind — a translucent tick composited against the
        /// opaque backdrop read far too dark on dark. Weaker than the indicator dot.
        static let tick = dynamic(dark: gray(120), light: gray(150))

        /// The monochrome base-zone grey (the bar's `used` + future/unused zones): a **solid** light grey
        /// on light, a darker solid grey on dark, so the bar's base recedes while the pacing gap and dot
        /// stay the clear foreground — and it never depends on alpha compositing against the backdrop.
        static let monochromeGrey = dynamic(dark: gray(78), light: gray(210))

        private static func gray(_ v: CGFloat) -> NSColor {
            NSColor(srgbRed: v/255, green: v/255, blue: v/255, alpha: 1)
        }

        /// Resolves to `dark` under a dark appearance, `light` otherwise; AppKit swaps on theme change.
        private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
            NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
        }
    }

    /// The solid grey both bar base zones (`used` + future/unused tail) render in — a monochrome,
    /// low-contrast bar where only the pacing gap + dot carry colour. Exposed so ``StatusItemView``
    /// draws the menu-bar bars identically.
    static let monochromeGrey = Palette.monochromeGrey

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Metrics.height) }

    override func draw(_ dirtyRect: NSRect) {
        // The bar sits below a top margin equal to the dot's overhang — the dot is centred on the
        // bar, so a dot taller than the bar sticks out by `(diameter − barHeight)/2` on each side;
        // the margin keeps that top overhang inside the view (the tick ruler fills the strip below).
        let overhang = max(0, (Metrics.indicatorDiameter - Metrics.barHeight) / 2)
        let rect = NSRect(
            x: bounds.minX, y: bounds.minY + overhang, width: bounds.width, height: Metrics.barHeight)
        let w = rect.width

        // Idle 5h bar (#100, ADR-0027): a solid blue track + the under-bar tick ruler, but no pacing
        // zones and no time-indicator dot ("no active session, full quota available"). Rendered before
        // the pacing path so the (inert, zeroed) `bar` layout is never consulted.
        if idle {
            let idlePath = NSBezierPath(roundedRect: rect, xRadius: Metrics.corner, yRadius: Metrics.corner)
            Palette.idleBlue.setFill()
            idlePath.fill()
            drawTicks(in: rect, width: w)
            return
        }

        guard let l = bar else { return }

        let path = NSBezierPath(roundedRect: rect, xRadius: Metrics.corner, yRadius: Metrics.corner)

        // Whole-bar rounded background = the monochrome future/unused base (others paint over it).
        Self.monochromeGrey.setFill()
        path.fill()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        fillZone(from: 0, to: l.usageFraction, in: rect, width: w, color: Self.monochromeGrey)
        let gapColor = l.pacing == .ahead
            ? Self.aheadColor(usage: l.usageFraction, time: l.timeFraction)
            : Palette.gapGreen
        fillZone(from: l.gapStart, to: l.gapEnd, in: rect, width: w, color: gapColor)
        NSGraphicsContext.restoreGraphicsState()

        // Tick ruler: `subdivisions - 1` interior marks at k/subdivisions, drawn below the bar and
        // *under* the indicator dot in z-order (so the dot always reads as the primary marker).
        drawTicks(in: rect, width: w)

        // Time-indicator dot at timeFraction, coloured by the raw usage-vs-time relationship.
        let cx = rect.minX + CGFloat(l.timeFraction) * w
        let cy = rect.midY
        let d = Metrics.indicatorDiameter
        let dot = NSBezierPath(ovalIn: NSRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d))
        indicatorColor(usage: l.usageFraction, time: l.timeFraction).setFill()
        dot.fill()
        Palette.indicatorStroke.setStroke()
        dot.lineWidth = Metrics.indicatorStroke
        dot.stroke()
    }

    /// Draw the under-bar tick ruler: vertical teeth at each interior window boundary
    /// (`k / subdivisions` for `k` in `1 ..< subdivisions`), pixel-snapped on x. No-op when
    /// `subdivisions < 2` (nothing to subdivide).
    private func drawTicks(in barRect: NSRect, width: CGFloat) {
        guard subdivisions >= 2 else { return }
        let top = barRect.maxY + Metrics.tickGap           // flipped: just below the bar
        let bottom = top + Metrics.tickLength
        Palette.tick.setFill()
        for k in 1 ..< subdivisions {
            let f = CGFloat(k) / CGFloat(subdivisions)
            // Pixel-snap a 1.5px-wide tooth so it stays crisp at @1x and @2x.
            let cx = (barRect.minX + f * width).rounded()
            NSRect(x: cx - Metrics.tickWidth / 2, y: top, width: Metrics.tickWidth, height: bottom - top).fill()
        }
    }

    private func indicatorColor(usage: Double, time: Double) -> NSColor {
        // The dot uses the exact pacing-bar colours so it reads as the same colour as the gap zone it
        // sits over, not a separate shade. A tie (usage == time) is still on pace → green.
        usage > time ? Self.aheadColor(usage: usage, time: time) : Palette.gapGreen
    }

    /// The gap/dot colour when **ahead of pace** (`usage > time`), graded by how far ahead — the same
    /// system colours the Claude status dots use:
    /// - limit exhausted (`usage >= 1`) → red (the worst; also where the bar is full)
    /// - ahead by < 15 percentage points → yellow (mild)
    /// - ahead by ≥ 15 points → orange (worse)
    /// `usage`/`time` are fractions in [0, 1], so the 15% threshold is `0.15`.
    static func aheadColor(usage: Double, time: Double) -> NSColor {
        if usage >= 1 { return Palette.gapRed }
        return (usage - time) < 0.15 ? Palette.gapYellow : Palette.gapOrange
    }

    private func fillZone(from: Double, to: Double, in rect: NSRect, width: CGFloat, color: NSColor) {
        let x0 = rect.minX + CGFloat(from) * width
        let x1 = rect.minX + CGFloat(to) * width
        guard x1 > x0 else { return }
        color.setFill()
        NSRect(x: x0, y: rect.minY, width: x1 - x0, height: rect.height).fill()
    }
}

// MARK: - SolidBackdropView

/// A plain opaque fill for the popup's solid backdrop. Layer-backed and drawn via `updateLayer`, so
/// AppKit re-runs it on theme change and the `windowBackgroundColor` CGColor re-resolves (a raw
/// `layer.backgroundColor` set once would not track light/dark).
final class SolidBackdropView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        // The system panel background, resolved in this view's own appearance so it tracks light/dark
        // and matches the surrounding menu chrome.
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
}

// MARK: - StatusLineLabel

/// A status line whose status **word** is a clickable link to the Claude status page (issue #31).
///
/// `NSTextField`'s built-in `.link` handling needs first-responder/field-editor plumbing that does
/// not work reliably for a label inside an `NSMenu`-hosted view, so the click is handled here: a
/// `mouseDown` whose point falls within ``linkRange`` opens ``linkURL`` via `NSWorkspace`. A
/// tracking area shows the pointing-hand cursor over that range so it reads as a link.
final class StatusLineLabel: NSTextField {

    /// Character range of the linked status word within the attributed string.
    var linkRange: NSRange?
    /// The URL the linked word opens.
    var linkURL: URL?

    override func mouseDown(with event: NSEvent) {
        guard let url = linkURL, hitTestLink(event) else {
            super.mouseDown(with: event)
            return
        }
        NSWorkspace.shared.open(url)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        // Pointing-hand cursor over the whole label — but only when there is a link (operational
        // rows carry no link, so they keep the default arrow). The label is sized to its content
        // and the linked word sits at its trailing edge, so a label-wide hand is a fine
        // approximation and avoids per-glyph rect math.
        guard linkURL != nil else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// Whether `event`'s location falls on the linked word. Uses a `TextKit` layout pass over the
    /// attributed string to map the click point to a character index, then tests membership in
    /// ``linkRange``.
    private func hitTestLink(_ event: NSEvent) -> Bool {
        guard let linkRange, let attributed = attributedStringValue.mutableCopy() as? NSMutableAttributedString else {
            return false
        }
        let point = convert(event.locationInWindow, from: nil)

        let textStorage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: bounds.size)
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        let index = layoutManager.characterIndex(
            for: point, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        return NSLocationInRange(index, linkRange)
    }
}

// MARK: - PopupViewController

/// The click-to-open detail popup's content — the thin AppKit shell of issue #11, styled after
/// native macOS menu-bar widgets (battery, etc.): a bold title, two service lines, then one
/// section per limit (separator + bold heading + detail line + pacing bar).
///
/// It owns **no** business logic: it takes a `PopupLayout` (computed in `TokenPaceKit`) and renders
/// it. The model carries raw numbers / semantic enums and the shared `ResetClock` time strings;
/// **every human-readable sentence is assembled here**, in `static` formatters, so a future
/// localisation (Phase 2) touches only this file (ADR-0009).
final class PopupViewController: NSViewController {

    /// The current popup model. Setting it rebuilds the sections. `nil` renders nothing.
    var layout: PopupLayout? {
        didSet {
            guard isViewLoaded, layout != oldValue else { return }
            rebuild()
        }
    }

    /// Whether ⌥ Option is currently held (ADR-0020's modifier-poll timer feeds this live while the
    /// dropdown is open). It reveals the on-demand data age ("2m ago") in the "Claude Code" header;
    /// it does **not** gate the service-status rows, which show only when a component is
    /// non-operational (`rebuild()`'s `showStatusRows`) — two green lines are never worth the space.
    var optionHeld = false {
        didSet {
            guard isViewLoaded, optionHeld != oldValue else { return }
            rebuild()
        }
    }

    private enum Metrics {
        static let width: CGFloat = 280
        static let hPadding: CGFloat = 14
        static let vPadding: CGFloat = 10
        /// Top inset — a touch tighter than `vPadding` so the content sits closer to the top edge
        /// without the extra strip of empty background above the "Claude Code" line, but not cramped.
        static let topPadding: CGFloat = 7
        /// Bottom inset — tighter than `vPadding` so the last bar sits close to the menu's separator
        /// below it (the section already ends there; a full `vPadding` reads as too much air).
        static let bottomPadding: CGFloat = 3
        static let rowSpacing: CGFloat = 3
        static let sectionSpacing: CGFloat = 14
        /// Gap **between limit blocks** (after each section's bar) — a touch tighter than
        /// `sectionSpacing` so the limit list reads as a group without the header's larger breathing room.
        static let limitSpacing: CGFloat = 10
        static let textSize: CGFloat = dropdownTextSize
    }

    private let stack = NSStackView()

    /// The solid opaque backdrop behind the content (below `stack`), so nothing shows through the popup.
    /// Built once by ``rebuildBackdrop()`` on load; it re-resolves its own fill on theme change.
    private var backdropView: NSView?

    /// The bold header of the popup's first section — "Claude" covers the update-cadence line and the
    /// per-component service status rows beneath it (see `rebuild`).
    private static let claudeCodeSectionTitle = "Claude"

    /// The status word shown flush-right on the **idle** 5-hour row (#100, ADR-0027): the 5h window has
    /// no active session, so the row reads "5-hour  ready to start" with a solid-blue bar and no second
    /// line. The localisation seam (ADR-0009) — like the other status phrases, the English word lives
    /// here, not in the kit.
    static let idleStatusText = "ready to start"

    /// Anthropic's official primary accent colour (`#d97757`, a terracotta orange) — confirmed
    /// against `anthropics/skills`' `brand-guidelines/SKILL.md` on GitHub, the same value the local
    /// Claude Code "claude" theme slot resolves to. Used only for the "Claude Code" section header,
    /// so the popup echoes the CLI's own brand mark rather than a generic label colour.
    private static let claudeBrandColor = NSColor(srgbRed: 0xd9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)

    /// `Metrics.textSize`, bold — the "Claude Code" section header and the two native menu items
    /// below it (via `App.swift`'s `attributedTitle`) all resolve to this exact font, so there is no
    /// visual mismatch to chase.
    private static var menuItemFont: NSFont {
        NSFontManager.shared.convert(.systemFont(ofSize: Metrics.textSize), toHaveTrait: .boldFontMask)
    }

    /// Dimmed text colour for supporting numbers/rows ("88% used", "resets in …", "Updated …",
    /// service-status words) — neither `secondaryLabelColor` (too light) nor `tertiaryLabelColor`
    /// (too dark) alone; AppKit has no built-in "in-between" semantic label colour, so this blends the
    /// two. A **dynamic** `NSColor(name:)`: the blend is computed *inside* the provider, in the target
    /// appearance, so it re-resolves per view and adapts to light/dark. A plain `static let ...
    /// .blended(...)` bakes in whatever appearance was current at first access — which made it render
    /// near-black under the dark system theme.
    static let dimmedLabelColor = NSColor(name: nil) { appearance in
        var mixed: NSColor = .secondaryLabelColor
        appearance.performAsCurrentDrawingAppearance {
            mixed = NSColor.tertiaryLabelColor.blended(withFraction: 0.5, of: .secondaryLabelColor)
                ?? .secondaryLabelColor
        }
        return mixed
    }


    override func loadView() {
        let container = NSView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Metrics.topPadding),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Metrics.hPadding),
            container.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: Metrics.hPadding),
            container.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: Metrics.bottomPadding),
            container.widthAnchor.constraint(equalToConstant: Metrics.width),
        ])
        self.view = container
        rebuildBackdrop()
        rebuild()
    }

    /// (Re)build the popup's solid opaque backdrop, inserting it as the **bottom-most** subview (below
    /// `stack`) pinned to every container edge, so nothing shows through. Called on load and on a dev
    /// theme change (so the fresh `SolidBackdropView` re-resolves `windowBackgroundColor`).
    func rebuildBackdrop() {
        guard isViewLoaded else { return }
        backdropView?.removeFromSuperview()
        backdropView = nil

        let new = SolidBackdropView()   // self-updates its fill on theme change (see updateLayer)
        new.translatesAutoresizingMaskIntoConstraints = false
        // Bottom-most so the stack (and its bars/labels) draw on top of it.
        view.addSubview(new, positioned: .below, relativeTo: stack)
        NSLayoutConstraint.activate([
            new.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            new.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            new.topAnchor.constraint(equalTo: view.topAnchor),
            new.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        backdropView = new
    }

    // MARK: Rendering

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let layout else { return }

        // The "Claude Code" section header (first line): the brand-coloured, bold title (always
        // shown — see `claudeBrandColor`) flush left. Its right half carries the dim data age
        // ("2m ago") **only while ⌥ Option is held** — the age is an on-demand detail.
        //
        // The service status rows (issue #31, #89) show **only when there is a real problem** —
        // `worstProblem != nil`, i.e. at least one monitored component is non-operational. All-
        // operational lines add nothing worth the space, so a healthy status is never shown (⌥ still
        // reveals the data age, but not the status). When a problem is present we show **one row per
        // monitored component**, each with its own status — `API` always, then `Code`, `WEB/Desktop`,
        // and `Cowork` when their services are enabled (the healthy ones for context). Each row is a
        // single component, so there is nothing to expand under ⌥.
        let status = layout.serviceStatus
        let showStatusRows = status?.worstProblem != nil
        let sectionHeader = addSplitLine(
            left: Self.claudeCodeSectionTitle, right: optionHeld ? Self.ageText(layout.lastUpdateAge) : "",
            leftFont: Self.menuItemFont, rightFont: .systemFont(ofSize: Metrics.textSize),
            leftColor: Self.claudeBrandColor, rightColor: Self.dimmedLabelColor)
        stack.setCustomSpacing(Metrics.sectionSpacing, after: sectionHeader)

        if showStatusRows, let status {
            var lastRow: NSView?
            for component in status.checks.flatMap(\.components) {
                lastRow = addServiceStatusRow(label: Self.displayName(component), status: component.status)
            }
            if let lastRow { stack.setCustomSpacing(Metrics.sectionSpacing, after: lastRow) }
        }

        // Error block (when failing): two lines — a bold title led by the ⚠️ symbol, then the
        // detail. Shown immediately on any failure (SPEC), so the problem is read before the limit
        // sections. No trailing rule (see above).
        if let reason = layout.warning {
            addWarningTitle(Self.warningTitle(reason))
            addWrappingLabel(Self.warningDetail(reason), font: .systemFont(ofSize: Metrics.textSize), secondary: true)
        }

        // One section per limit row: "title · status" line + "reset · %" line + bar. No rule
        // between sections — the only interior rule in the popup is the one after the title block;
        // sections below it are told apart by the bold per-row title and the `limitSpacing` gap
        // after each bar, not by a line.
        for (index, row) in layout.rows.enumerated() {
            addTitleStatusLine(title: row.title, status: Self.statusText(row))
            // The idle 5-hour row (#100) has **no** second line at all — no "0%", no reset — so it reads
            // as a compact "5-hour  ready to start" + solid-blue bar. Every other row shows the detail.
            if !row.sessionIdle {
                addDetailLine(used: Self.usedText(row), reset: Self.resetText(row))
            }
            // No inter-section gap after the **last** bar — it sits just above the menu's own separator,
            // so the section gap plus the bottom padding read as too much air. Later bars need the gap.
            addBar(row, isLast: index == layout.rows.count - 1)
        }
    }

    /// The section's first line: title and pacing status, both `labelColor` — the same weight and
    /// colour the dropdown's own "Settings…" text uses. `status` sits flush **right**, lined up with
    /// the detail line and bar below it, instead of trailing right after the title on the left.
    /// Neither half is bold — the section reads from the bar and numbers, not a heavier heading. Both
    /// the window titles (`"5-hour"`/`"7-day"`) and the bare per-model names (`"Opus"`/`"Fable"`) render
    /// whole in `labelColor`.
    @discardableResult
    private func addTitleStatusLine(title: String, status: String) -> NSView {
        let font = NSFont.systemFont(ofSize: Metrics.textSize)
        return addSplitLine(
            left: title, right: status, leftFont: font, rightFont: font,
            leftColor: .labelColor, rightColor: .labelColor)
    }

    @discardableResult
    private func addLabel(_ text: String, font: NSFont, secondary: Bool = false, color: NSColor? = nil) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color ?? (secondary ? Self.dimmedLabelColor : .labelColor)
        stack.addArrangedSubview(label)
        return label
    }

    /// The per-limit detail line: `used` percent flush left, `reset` countdown flush **right** against
    /// the content width — the percent leads the line (under the "% used" reading) while the reset time
    /// lines up with the bar's right edge below it.
    @discardableResult
    private func addDetailLine(used: String, reset: String) -> NSView {
        let font = NSFont.systemFont(ofSize: Metrics.textSize)
        return addSplitLine(
            left: used, right: reset, leftFont: font, rightFont: font,
            leftColor: Self.dimmedLabelColor, rightColor: Self.dimmedLabelColor)
    }

    /// A two-column row spanning the full content width: `left` flush against the leading edge,
    /// `right` flush against the trailing edge — the shared layout behind `addTitleStatusLine` and
    /// `addDetailLine`, both of which right-align their second half to line up with the bar beneath.
    @discardableResult
    private func addSplitLine(
        left: String, right: String, leftFont: NSFont, rightFont: NSFont,
        leftColor: NSColor, rightColor: NSColor
    ) -> NSView {
        let leftLabel = NSTextField(labelWithString: left)
        leftLabel.font = leftFont
        leftLabel.textColor = leftColor
        let rightLabel = NSTextField(labelWithString: right)
        rightLabel.font = rightFont
        rightLabel.textColor = rightColor
        return addSplitRow(leftLabel: leftLabel, rightLabel: rightLabel)
    }

    /// The shared layout behind every split line: a full-content-width horizontal row that pins
    /// `leftLabel` flush leading and `rightLabel` flush trailing. Callers build the two labels —
    /// plain (``addSplitLine``) or attributed (``addTitleStatusLine`` per-model heading) — this only
    /// arranges them.
    @discardableResult
    private func addSplitRow(leftLabel: NSTextField, rightLabel: NSTextField) -> NSView {
        let row = NSStackView(views: [leftLabel, rightLabel])
        row.orientation = .horizontal
        row.distribution = .equalSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Metrics.width - 2 * Metrics.hPadding).isActive = true
        stack.addArrangedSubview(row)
        return row
    }

    /// A label that **wraps** onto multiple lines instead of clipping — for the error detail, whose
    /// text can be the server's own response body (`authHTTP`) and so be arbitrarily long. A plain
    /// `labelWithString:` is single-line and would truncate; `wrappingLabelWithString:` wraps, but
    /// only once pinned to a concrete width — `NSMenu` lays the hosted view out from its frame, not
    /// Auto Layout, so without a width anchor the field grows to its intrinsic single-line width and
    /// never breaks. We pin it to the content width (`width − 2·hPadding`) and set
    /// `preferredMaxLayoutWidth` to match, so it wraps at word boundaries within the popup.
    @discardableResult
    private func addWrappingLabel(_ text: String, font: NSFont, secondary: Bool = false) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = secondary ? Self.dimmedLabelColor : .labelColor
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        let contentWidth = Metrics.width - 2 * Metrics.hPadding
        label.preferredMaxLayoutWidth = contentWidth
        label.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        stack.addArrangedSubview(label)
        return label
    }

    /// The error block's bold first line: a ⚠️ symbol attachment followed by `text`, both in the
    /// system red so the failure reads at a glance. The symbol is the popup counterpart of the
    /// menu-bar glyph (issue #12); using `.systemRed` (not the fixed palette sRGB) lets the popup,
    /// which is appearance-aware, keep contrast on light and dark panels alike.
    @discardableResult
    private func addWarningTitle(_ text: String) -> NSView {
        let font = NSFont.boldSystemFont(ofSize: Metrics.textSize)
        let color = NSColor.systemRed
        let attributed = NSMutableAttributedString()

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        if let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "warning")?
            .withSymbolConfiguration(symbolConfig) {
            let attachment = NSTextAttachment()
            attachment.image = symbol
            attributed.append(NSAttributedString(attachment: attachment))
            attributed.append(NSAttributedString(string: "  "))
        }
        attributed.append(NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: color]))

        let label = NSTextField(labelWithAttributedString: attributed)
        stack.addArrangedSubview(label)
        return label
    }

    private func addBar(_ row: LimitRow, isLast: Bool) {
        let view = PopupBarView()
        view.bar = row.bar
        view.subdivisions = row.subdivisions
        view.idle = row.sessionIdle   // solid-blue knobless track when the 5h window is idle (#100)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: Metrics.width - 2 * Metrics.hPadding).isActive = true
        view.heightAnchor.constraint(equalToConstant: PopupBarView.viewHeight).isActive = true
        stack.addArrangedSubview(view)
        // Between-section gap after every bar except the last (the last sits above the menu separator).
        if !isLast { stack.setCustomSpacing(Metrics.limitSpacing, after: view) }
    }

    // MARK: Service status row (issue #31)

    /// One Claude-service status line: a colour dot for `status`, the component `label`, then the
    /// status **word**. When the component is **not** `operational`, the word is a link to the
    /// status page (there is something to go look at); when it *is* operational, the word is plain
    /// secondary text — no link, since the status page would add nothing. The dot mirrors
    /// `addWarningTitle`'s symbol-attachment technique (`circle.fill` tinted via `paletteColors`);
    /// the link, when present, is handled explicitly by `StatusLineLabel` because `NSTextField`'s
    /// built-in `.link` handling is unreliable inside an `NSMenu`-hosted view.
    @discardableResult
    private func addServiceStatusRow(label: String, status: ServiceStatus) -> NSView {
        let font = NSFont.systemFont(ofSize: Metrics.textSize)
        let attributed = NSMutableAttributedString()

        // Colour dot — same attachment approach as the warning triangle, tinted by status.
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(.init(paletteColors: [Self.dotColor(status)]))
        if let symbol = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: status == .operational ? "operational" : "issue")?
            .withSymbolConfiguration(symbolConfig) {
            let attachment = NSTextAttachment()
            attachment.image = symbol
            attributed.append(NSAttributedString(attachment: attachment))
            attributed.append(NSAttributedString(string: "  "))
        }

        // Prefix the component's display label (e.g. "API: ") in the normal label colour.
        attributed.append(NSAttributedString(string: "\(label): ", attributes: [
            .font: font, .foregroundColor: NSColor.labelColor,
        ]))

        // Status word. Operational → plain dimmed text (no link). Otherwise → underlined link
        // colour, opened on click by StatusLineLabel over the word's range.
        let word = Self.word(status)
        let isLink = status != .operational
        let wordStart = attributed.length
        attributed.append(NSAttributedString(string: word, attributes: isLink
            ? [.font: font, .foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
            : [.font: font, .foregroundColor: Self.dimmedLabelColor]))

        let field = StatusLineLabel(labelWithAttributedString: attributed)
        if isLink {
            field.linkRange = NSRange(location: wordStart, length: (word as NSString).length)
            field.linkURL = StatusHealth.pageURL
        }
        stack.addArrangedSubview(field)
        return field
    }

    /// AppKit colour for one service status — the popup's indicator palette. Appearance-aware
    /// `system*` colours (not the fixed sRGB bar palette) so the dot keeps contrast on light and
    /// dark panels, exactly like the warning triangle's `.systemRed`. Exhaustive, no `default`.
    static func dotColor(_ status: ServiceStatus) -> NSColor {
        switch status {
        case .operational:      return .systemGreen
        case .degraded:         return .systemYellow
        case .partialOutage:    return .systemOrange
        case .majorOutage:      return .systemRed
        case .underMaintenance: return .systemBlue
        case .unknown:          return .systemGray
        }
    }

    /// The human status word shown after the component name. Exhaustive, no `default`, so a new
    /// `ServiceStatus` case breaks the build until consciously worded (like `warningTitle`).
    static func word(_ status: ServiceStatus) -> String {
        switch status {
        case .operational:      return "operational"
        case .degraded:         return "degraded"
        case .partialOutage:    return "partial outage"
        case .majorOutage:      return "major outage"
        case .underMaintenance: return "maintenance"
        case .unknown:          return "unknown"
        }
    }

    /// The popup label for one monitored component (#89) — the localisation seam: the kit carries the
    /// component's matching name (`ResolvedComponent.name`), and the short label the user reads is
    /// assembled here (ADR-0009/0013). Each monitored component gets its own row (`Cowork` is its own
    /// line, not a suffix), so the mapping is per-component. Names are shown bare (no "Claude" prefix)
    /// under the "Claude" section header. An unrecognised name falls back to itself, so a future
    /// component still renders rather than vanishing.
    static func displayName(_ component: ResolvedComponent) -> String {
        switch component.name {
        case StatusHealth.claudeAPIComponentName:    return "API"
        case StatusHealth.claudeCodeComponentName:   return "Code"
        case StatusHealth.claudeWebComponentName:    return "WEB/Desktop"
        case StatusHealth.claudeCoworkComponentName: return "Cowork"
        default:                                     return component.name
        }
    }

    // MARK: - Pure text formatters (the localisation seam)

    /// The per-limit detail line's **left**-aligned half: `"20%"` — the bare utilisation percentage.
    static func usedText(_ row: LimitRow) -> String { percent(row.utilization) }

    /// The per-limit detail line's **right**-aligned half: `"20m at 05:30"` for a near reset,
    /// `"3d on Monday"` for a far 7-day reset, or `"resetting…"` when the model carries no relative
    /// countdown (reset is now/past). The relative countdown is rounded (``ResetClock/relativeRounded``);
    /// exactly one qualifier is appended — " at hh:mm" when the reset is < 24 h away (``resetAbsolute``),
    /// otherwise " on <weekday>" for a 7-day window a day or more out (``resetWeekday``).
    static func resetText(_ row: LimitRow) -> String {
        guard let rel = row.resetRelative else { return "resetting…" }
        var reset = rel
        if let abs = row.resetAbsolute {
            reset += " at \(abs)"
        } else if let weekday = row.resetWeekday {
            reset += " on \(weekday)"
        }
        return reset
    }

    /// The data age shown flush-right in the "Claude Code" header (under the ⌥/problem gate):
    /// `"2m ago"`, or `"just now"` for anything under a full minute — the age never shows seconds
    /// (user preference), so a sub-minute age reads as "just now", not "40s".
    static let justNowThreshold = 60
    static func ageText(_ ageSeconds: TimeInterval) -> String {
        let age = Int(ageSeconds)
        return age < justNowThreshold
            ? "just now"
            : "\(durationMinutes(age)) ago"
    }

    /// Like ``duration`` but **never** emits a seconds component — minutes are the finest unit, so
    /// the data-age text stays second-free even just past the minute boundary.
    private static func durationMinutes(_ seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let m = minutes % 60
            return m == 0 ? "\(hours)h" : "\(hours)h \(m)m"
        }
        let days = hours / 24
        let h = hours % 24
        return h == 0 ? "\(days)d" : "\(days)d \(h)h"
    }

    // MARK: Warning banner (issue #12)

    /// The bold first line of the warning banner — a short title per failure cause. For an HTTP
    /// auth error it embeds the status code; the body text goes on the detail line below.
    static func warningTitle(_ reason: FailureReason) -> String {
        switch reason {
        case .notSignedIn:               return "Missing auth token"
        case .tokenExpired:              return "Auth token expired"
        case let .authHTTP(status, _):   return "Auth error (HTTP \(status))"
        case .timeout, .cannotResolveHost, .network:
            return "Claude API connectivity issue"
        case .serverProblem:             return "Usage API unavailable"
        case .unknown:                   return "Could not fetch usage"
        }
    }

    /// The detail (second) line of the warning banner — the explanation/next step. For an HTTP auth
    /// error this is the server's own response body (sans status code) when present, else a generic
    /// line.
    static func warningDetail(_ reason: FailureReason) -> String {
        switch reason {
        case .notSignedIn:
            return "You need to authenticate in Claude Code console app first"
        case .tokenExpired:
            return "Refreshing via the claude CLI — open Claude Code if this persists"
        case let .authHTTP(_, body):
            return body ?? "Your authorization was rejected — sign in to Claude Code again"
        case .timeout:
            return "Authentication API timeout"
        case .cannotResolveHost:
            return "Unable to resolve API endpoint hostname"
        case let .network(message):
            return message
        case .serverProblem:
            return "The usage API is unavailable right now — retrying automatically"
        case .unknown:
            return "Could not fetch usage data"
        }
    }

    // MARK: Formatter helpers

    private static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// Pacing/severity in words. Severity (critical/warning) wins over the plain pacing direction. When
    /// ahead of pace, the wording grades with the gap colour (see ``PopupBarView/aheadColor``): a large
    /// lead (≥ 15 points, the orange gap) reads "well ahead of pace"; a small one (yellow) stays "ahead
    /// of pace".
    private static func statusText(_ row: LimitRow) -> String {
        // Idle 5-hour row (#100): "ready to start" instead of a pacing phrase — there is no active
        // window to pace. Guarded first so the inert placeholder indicator/pacing are never consulted.
        if row.sessionIdle { return idleStatusText }
        switch row.indicator {
        case .critical: return "limit reached"
        case .warning:  return aheadPhrase(row) + " ⚠"
        case .neutral:  return row.pacing == .ahead ? aheadPhrase(row) : "on pace"
        }
    }

    /// "well ahead of pace" when the token usage leads elapsed time by ≥ 15 points (the orange gap),
    /// else "ahead of pace" (yellow). Same threshold as the gap colour, so word and colour agree.
    private static func aheadPhrase(_ row: LimitRow) -> String {
        (row.bar.usageFraction - row.bar.timeFraction) >= 0.15 ? "well ahead of pace" : "ahead of pace"
    }

}
