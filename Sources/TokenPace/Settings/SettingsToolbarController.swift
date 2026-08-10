import AppKit

// MARK: - SettingsToolbarController (#156 §2)

/// Owns the Settings window's toolbar: the ‹ › history buttons and the current pane's name, laid out
/// the way System Settings lays out its own.
///
/// ### Why the toolbar, and not a row in the detail column
///
/// The earlier attempt drew this header as the first view inside the SwiftUI detail column. That put
/// three independent sources of vertical spacing in series — the empty safe area the toolbar reserves
/// at the top of the column, the header row's own padding, and the `Form`'s top inset — so tuning any
/// one of them moved the other two, and the header could be pushed past the first card or collapsed
/// out of sight entirely.
///
/// Dumping the real System Settings window over the Accessibility API settled the shape:
///
/// ```
/// AXWindow (639,34  857x890) "VPN"
/// ├── AXGroup [AXHostingView]        ← all content, one hosting view
/// │   └── AXSplitGroup
/// │       ├── AXGroup   (639,34 275x890)   sidebar, from the window's top edge
/// │       ├── AXSplitter(914,86   1x838)   divider, starting 52 pt lower
/// │       └── AXGroup   (915,34 581x890)   detail column, also from the top edge
/// ├── AXToolbar (639,34 857x52)      ← a sibling of the content, not its parent
/// │   └── AXGroup → AXButton "Назад" (921,40 40x40)
/// │                AXMenuButton "Уперед" (961,40 40x40)
/// ├── AXButton [AXClose/AXZoom/AXMinimize] (657/677/697, 52)
/// └── AXStaticText (999,34 480x52)   ← the pane name, its own element in the bar
/// ```
///
/// So the arrows and the title live *in the toolbar*, the traffic lights are direct children of the
/// window, and they merely share a horizontal band — there is no common container. Putting our own
/// arrows and title in the toolbar removes the empty strip (it now has contents) and with it every
/// compensating offset.
///
/// Positions below come from that dump, expressed relative to the window's left edge: the window
/// starts at x=639, the back button at x=921, so the arrows sit 282 pt in — just past the 276 pt
/// column divider. The bar itself is 52 pt tall.
@MainActor
final class SettingsToolbarController: NSObject {

    private enum Metrics {
        /// Extra leading space before the back chevron.
        ///
        /// **Not** the AX figure (the system's button sits 282 pt from the window's left edge): a
        /// toolbar attached to a `NavigationSplitView` already indents its first item past the
        /// sidebar, so this is only the remainder on top of that. Tuned against the render — 282
        /// stacked on the built-in offset and pushed the arrows to the middle of the pane.
        static let arrowsInset: CGFloat = 14
        /// Chevron spacing, as the stack applies it: the gap is `arrowPitch − glyph width`, and the
        /// glyphs then render 36.5 pt apart centre-to-centre (73 px @2x, measured off the header).
        ///
        /// The AX dump reads 40 (961 − 921) — those frames are the buttons' hit areas, not the glyphs.
        /// The constant used to read 31.5 and was applied as
        /// `spacing = 31.5 − intrinsicContentSize.width`, where that width was the button's
        /// **unconfigured** symbol (10 pt) rather than the 13 pt it draws; the number that reached
        /// the layout was 21.5, so 31.5 never described anything on screen. Subtracting the real
        /// glyph width needs this to be 34.5 to land on the same render — verified by measuring the
        /// glyphs before and after (both at x 616.5 and 689.5 @2x).
        static let arrowPitch: CGFloat = 14.5
        /// Sub-point nudge applied inside the chevron stack, for the last pixel of alignment that
        /// `arrowsInset` cannot reach — see the note where it is applied.
        static let arrowsNudge: CGFloat = 0.5
        /// Leading shift for the chevron row, cancelling the offset a plate-sized button introduces:
        /// its leading edge starts further left than the old bezel's, which moved the glyphs 10.5 pt
        /// right of their measured columns (x 616.5 and 689.5 @2x). Negative pulls left.
        static let arrowsPlatePull: CGFloat = -10.0
        /// Vertical nudge for the chevrons, applied through `ChevronButton.alignmentRectInsets`.
        ///
        /// Uncompensated the glyphs sat 2 px (@2x) below the system's — rows 38–65 against 36–64 —
        /// and the ordinary levers do nothing here: the toolbar centres its item in the bar, so a
        /// stack `edgeInsets` and a taller frame were both measured and were both no-ops. Only the
        /// alignment rect moves them, and only from the bottom edge (a top inset was no-op too).
        static let arrowsLift: CGFloat = -2
        /// The hover backing, measured off System Settings': 33×28 pt. Asked for as the button's
        /// `intrinsicContentSize` — which states the **alignment rect**, and the system's bezel fills
        /// exactly that (verified: a 33×28 intrinsic yields a 33×28 alignment rect inside a 35×31
        /// frame). Left to itself a `.toolbar` button sizes its bezel to 22.5×20, visibly smaller than
        /// the system's.
        static let chevronPlateSize = NSSize(width: 33, height: 28)
        /// Corner radius of that plate, measured off System Settings' (#312).
        static let chevronPlateCornerRadius: CGFloat = 5
        /// Rendered size of a chevron glyph under `chevronMetrics`, measured: 17×29 px @2x. Not read
        /// off the button, which reports three different answers depending on when it is asked —
        /// `NSImage(systemSymbolName:)` gives the unconfigured symbol (10×14), and the button gives
        /// 10×9 before `applyChevronTint` attaches the configuration and 12.5×9 after.
        static let chevronGlyphSize = NSSize(width: 13, height: 18)
        /// Gap from the forward chevron to the pane title. Lands the title on x=176 against the
        /// system's 177; 10 pt overshoots to 178 and there is nothing in between, so the closer of the
        /// two is used (AX reads 38 here — again a hit area, not the glyph).
        static let titleGap: CGFloat = 9.5
        /// Baseline lift for the title, in points, for the one pixel of vertical alignment left over
        /// once the glyph box matched the system's in width (measured: rows 41–62 against 40–61).
        ///
        /// Applied as a `.baselineOffset` attribute rather than a stack inset: the toolbar centres the
        /// item vertically in the bar, so neither `edgeInsets` nor a half-point on the spacer moved
        /// the label at all — both were measured and left the glyphs on the same rows.
        static let titleLift: CGFloat = 0.5
        /// Toolbar height, which is also what lifts the traffic lights onto the System Settings
        /// position — the reason the (previously empty) toolbar was added at all.
        static let barHeight: CGFloat = 52
        /// Inset AppKit already applies before a toolbar's first item; subtracted from the leading
        /// spacer so the chevrons land on `arrowsInset` rather than that much further right.
        ///
        /// 22.5 rather than 12 since the chevrons became plates: a plate is wider than the bezel it
        /// replaced and its leading edge starts further left, which pushed the whole row 10.5 pt
        /// right. Taking that out of the spacer is what puts the glyphs back on their measured
        /// columns (x 616.5 and 689.5 @2x) without touching the plate's size.
        static let firstItemInset: CGFloat = 12
    }

    private enum ItemID {
        /// An empty spacer as wide as the sidebar, so the items that follow start at the detail
        /// column rather than over the traffic lights.
        static let leadingPad = NSToolbarItem.Identifier("TokenPaceSettingsLeadingPad")
        static let navigation = NSToolbarItem.Identifier("TokenPaceSettingsNavigation")
        static let title = NSToolbarItem.Identifier("TokenPaceSettingsPaneTitle")
    }

    /// Invoked when ‹ is clicked. Wired by the window controller into the model's `goBack()`.
    var onBack: (() -> Void)?
    /// Invoked when › is clicked.
    var onForward: (() -> Void)?

    /// A toolbar chevron: the glyph, plus the rounded backing System Settings shows under it while the
    /// pointer is inside.
    ///
    /// `alignmentRectInsets` does two jobs here, and the second is what makes the backing possible.
    ///
    /// The toolbar centres its item vertically in the bar, and the glyphs rendered 2 px (@2x) below
    /// the system's; neither a stack `edgeInsets` nor a taller frame moved them (both measured, both
    /// no-ops), so `arrowsLift` claims a bottom inset — a shorter alignment rect at the foot lifts
    /// what is drawn.
    ///
    /// The backing then needs the button to be `chevronPlateSize` (33×28) rather than glyph-sized
    /// (13×18), because a parent clips whatever a view draws past its bounds. Growing the frame is
    /// what broke this four times: the header's spacer is `arrowsInset − firstItemInset` wide and
    /// already clamps at zero, so nothing downstream can cancel the shift. The way through is that
    /// **Auto Layout positions the alignment rect, not the frame** — so the button claims insets
    /// equal to the overhang on every side, leaving an alignment rect the size of the glyph. The
    /// layout keeps placing a 13×18 box exactly where it always did, while the frame around it is big
    /// enough to draw a 33×28 plate.
    /// A toolbar chevron, with the rounded backing System Settings shows under it on hover.
    ///
    /// Drawn by hand rather than with `showsBorderOnlyWhileMouseInside`, which looks like the right
    /// system mechanism and was measured twice as the wrong fit: the `.toolbar` bezel is a **fixed
    /// 20 pt tall** regardless of the button's size (raising the button to 34 pt only pads around
    /// it) against the system's 28, no other bezel style reaches 28 either — `badge`/`inline` stop
    /// at 24 and change the shape — and AppKit fades its bezel in on a timer, where System Settings'
    /// backing appears the instant the pointer arrives.
    ///
    /// So the plate's size, corner radius and fill are stated here, from the measurements in #312:
    /// 33×28 pt, ~5 pt corner, `.quaternarySystemFill`.
    private final class ChevronButton: NSButton {

        /// Drawn only while the pointer is inside, with no animation — the system's does not fade.
        private var isHovered = false {
            didSet { if isHovered != oldValue { needsDisplay = true } }
        }

        /// Clicking an arrow can disable it under a stationary pointer — returning to the first pane
        /// greys out ‹ while the cursor is still on it. No mouse event follows, so without repainting
        /// here the plate would linger under an arrow that leads nowhere.
        override var isEnabled: Bool {
            didSet { if isEnabled != oldValue && isHovered { needsDisplay = true } }
        }

        override var intrinsicContentSize: NSSize { Metrics.chevronPlateSize }

        /// The lift is mirrored top and bottom so it moves the glyph without shortening the plate:
        /// with all of it on the bottom the frame measured 33×26 against the system's 33×28, because
        /// the frame is the alignment rect grown by the insets.
        override var alignmentRectInsets: NSEdgeInsets {
            NSEdgeInsets(top: -Metrics.arrowsLift, left: 0,
                         bottom: Metrics.arrowsLift, right: 0)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            // `.inVisibleRect` keeps the area glued to the button as the toolbar lays it out; a fixed
            // `rect:` goes stale after the first pass and the hover stops registering.
            // `.activeAlways`, not `.activeInKeyWindow`: a toolbar item view lives in the titlebar's
            // own view tree, and with the latter the button never received `mouseEntered` even with
            // the app frontmost and the window main (measured).
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self))
        }

        override func mouseEntered(with event: NSEvent) { isHovered = true }
        override func mouseExited(with event: NSEvent) { isHovered = false }

        /// A disabled arrow gets no plate — hovering a greyed-out chevron leaves System Settings' bar
        /// unchanged too.
        override func draw(_ dirtyRect: NSRect) {
            if isHovered && isEnabled {
                NSColor.quaternarySystemFill.setFill()
                NSBezierPath(roundedRect: bounds,
                             xRadius: Metrics.chevronPlateCornerRadius,
                             yRadius: Metrics.chevronPlateCornerRadius).fill()
            }
            super.draw(dirtyRect)
        }
    }

    private let backButton = ChevronButton()
    private let forwardButton = ChevronButton()
    private let titleLabel = NSTextField(labelWithString: "")

    /// The hosting window, for reading its key state when tinting the chevrons. Weak — the window
    /// owns the controller chain, not the other way round.
    private weak var window: NSWindow?

    override init() {
        super.init()
        configureButtons()
        configureTitle()
    }

    /// Build the toolbar and attach it to the window. `.unified` is the style that lands the traffic
    /// lights on the measured System Settings position — `.unifiedCompact` falls 7 pt short.
    func install(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: "TokenPaceSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        // The bar is a fixed header, not a customisable strip of user-chosen tools.
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        self.window = window
        applyChevronTint()
    }

    /// Reflect the current pane and what the history buttons can reach.
    func update(title: String, canGoBack: Bool, canGoForward: Bool) {
        titleLabel.attributedStringValue = NSAttributedString(
            string: title,
            attributes: [.font: titleLabel.font as Any,
                         .foregroundColor: titleLabel.textColor as Any,
                         .baselineOffset: Metrics.titleLift])
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        applyChevronTint()
    }

    /// Tint the chevrons for the window's current key state.
    ///
    /// Applied through the symbol's `paletteColors` rather than `contentTintColor`, which a borderless
    /// toolbar button ignores — with it the glyph rendered at 106 over the bar's 40 background (an
    /// alpha of 0.307, matching no semantic colour) regardless of what was set.
    ///
    /// Re-applied on every key-state change because a symbol configuration holds a **resolved** colour:
    /// nothing repaints it when the window resigns key, which is how the chevrons ended up staying
    /// bright at 164 while the pane title beside them correctly dimmed to 105.
    private func applyChevronTint() {
        let isKey = window?.isKeyWindow ?? false
        for button in [backButton, forwardButton] {
            // Full strength only when the arrow leads somewhere *and* the window is key; every other
            // combination is the muted grey, which is how System Settings draws them (verified on a
            // freshly-opened window, where both arrows are disabled).
            //
            // The key state has to be read explicitly: a symbol's palette colour is resolved once, so
            // nothing re-dims it when the window changes state — `refreshTint()` re-applies it from
            // the window delegate.
            let tint = button.isEnabled && isKey ? Self.enabledChevronGrey : Self.dimmedChevronGrey
            button.symbolConfiguration = Self.chevronMetrics.applying(.init(paletteColors: [tint]))
        }
    }

    /// Chevron greys for the two enabled states, matched to System Settings' rendered pixels.
    ///
    /// An ADR-0040 exception, so here is the derivation. A symbol's palette colour does not reach the
    /// screen unchanged — AppKit applies its own dimming — and, separately, an **alpha** in that
    /// palette is ignored outright (measured: `NSColor(white: 1, alpha: 0.626)` rendered identically
    /// to the semantic colour it replaced). So neither picking a semantic label colour by name nor
    /// dialling its alpha lands on the target; only an opaque grey does.
    ///
    /// Targets, measured off System Settings' own chevrons over the bar's 40 background:
    ///
    /// - **148** when the arrow leads somewhere and the window is key;
    /// - **94** otherwise — a disabled arrow, or a background window. System Settings draws both of
    ///   those the same, verified on a freshly-opened window (no history, so both arrows disabled).
    ///
    /// These render 149 and 90, with the muted glyph covering 554 lit pixels against the system's 557.
    ///
    /// `.quaternaryLabelColor` was tried for the muted case and is far too dark here: it rendered
    /// *below* the 40 background, so the arrows disappeared entirely rather than reading as muted.
    /// (Dark appearance; the light-mode pair is still to be measured.)
    private static let enabledChevronGrey = NSColor(white: 0.58, alpha: 1)
    private static let dimmedChevronGrey = NSColor(white: 0.64, alpha: 1)

    /// Size and weight of the chevron glyphs, kept apart from the colour so `applyChevronTint` can
    /// re-apply the palette without disturbing the geometry.
    ///
    /// Matched pixel-for-pixel against the system's: both render 17×29 px (@2x) with a 6 px stroke.
    /// `.large` scale carries the size — a bare point size overshot (16 pt reached 35 px tall) — and
    /// `.semibold`/`pointSize: 14` were each measured and rejected for thinning or inflating the glyph.
    private static let chevronMetrics = NSImage.SymbolConfiguration(
        pointSize: 13, weight: .medium, scale: .large)

    /// Re-tint after the window's key state changes. Called from `SettingsWindowController`'s
    /// `windowDidBecomeKey`/`windowDidResignKey` — the window has a delegate implementing those, and a
    /// delegate takes the callback *instead of* the matching notification reaching other observers, so
    /// an observer registered here would never fire (measured: the tint stayed at the inactive value).
    func refreshTint() { applyChevronTint() }

    private func configureButtons() {
        for (button, symbol, label, action) in [
            (backButton, "chevron.backward", "Back", #selector(goBack)),
            (forwardButton, "chevron.forward", "Forward", #selector(goForward)),
        ] {
            // Not a template image: a template hands the tint to AppKit, and on a borderless toolbar
            // button AppKit ignores `contentTintColor` and paints its own disabled grey. Measured, the
            // glyph came out at 106 over the bar's 40 background — an alpha of 0.307, which matches no
            // semantic colour at all — where the system's sits at 94 (alpha 0.251). Colouring the
            // symbol directly, via `paletteColors`, is what actually takes effect (see
            // `applyChevronTint`, which re-applies it on every key-state change).
            //
            // Geometry is already exact and must not move: compared pixel-for-pixel against the
            // system's chevron, both are 17×29 px with a 6 px stroke, so only the colour differed.
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            // Bordered, but the bezel only shows under the pointer — the system's own hover backing
            // (#312), and the mechanism ADR-0040 calls for instead of drawing a plate by hand.
            // `isBordered = false` removes the bezel outright, leaving the flag nothing to reveal,
            // which is why the arrows previously had no backing at all.
            // Borderless, with the plate drawn in `ChevronButton.draw`. `showsBorderOnlyWhileMouseInside`
            // was the obvious system mechanism and is the wrong fit here, measured twice: the
            // `.toolbar` bezel is a **fixed 20 pt tall** whatever the button's size (raising the
            // button to 34 pt only pads around it), against the system's 28, and no other bezel style
            // reaches 28 either — `badge`/`inline` top out at 24 and change the shape. AppKit also
            // fades its bezel in on a timer, where System Settings' backing appears instantly.
            button.isBordered = false
            button.bezelStyle = .toolbar
            button.target = self
            button.action = action
            button.setAccessibilityLabel(label)
        }
    }

    private func configureTitle() {
        // Sized against the system's own pane title, compared pixel-for-pixel at the same window size:
        // theirs renders 22 px tall (@2x), `.headline` gave 19 and `systemFontSize` (the *body* size)
        // was further off still. 15 pt semibold lands on 22.
        // Matched against a System Settings window showing the *same word* ("VPN") at the same window
        // size — the only comparison that works here. Earlier attempts measured our all-caps pane name
        // against a system pane with lowercase and descenders ("Обліковий запис Apple"), whose glyph
        // box is not comparable, and that pointed the size the wrong way twice.
        //
        // Final render matches the system's exactly: glyph box x 180–238, y 40–61 (@2x, x relative to
        // the column divider), with 57.9% ink coverage against their 57.9%. `.semibold` is what
        // carries the weight — at `.medium` the stems came out 4–5 px against the system's 5–6.
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        // `labelColor` is the one that dims when the window resigns key, which is what System Settings'
        // title does — a hardcoded white stayed bright on a background window.
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
    }

    @objc private func goBack() { onBack?() }
    @objc private func goForward() { onForward?() }
}

// MARK: - NSToolbarDelegate

extension SettingsToolbarController: NSToolbarDelegate {

    /// Leading order, no `.flexibleSpace` in front: a flexible space here shoves both items into the
    /// right corner (measured), while System Settings keeps them at the left of the detail column.
    /// `ItemID.leadingPad` supplies the sidebar-width offset that puts them there.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.leadingPad, ItemID.navigation, ItemID.title]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case ItemID.leadingPad:
            let item = NSToolbarItem(itemIdentifier: identifier)
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            // Width = distance from the window's left edge to the back chevron, minus the inset the
            // toolbar already applies to its first item.
            spacer.widthAnchor.constraint(
                equalToConstant: Metrics.arrowsInset - Metrics.firstItemInset).isActive = true
            spacer.heightAnchor.constraint(equalToConstant: 1).isActive = true
            item.view = spacer
            return item
        case ItemID.navigation:
            let item = NSToolbarItem(itemIdentifier: identifier)
            let stack = NSStackView(views: [backButton, forwardButton])
            stack.orientation = .horizontal
            // Without this the stack stretches its buttons to fill, which is what widened the plate
            // to 60.5 pt; the chevrons must stay at their intrinsic 33.
            stack.distribution = .fill
            stack.setHuggingPriority(.required, for: .horizontal)
            for button in [backButton, forwardButton] {
                button.setContentHuggingPriority(.required, for: .horizontal)
                button.setContentCompressionResistancePriority(.required, for: .horizontal)
            }
            // A stack's spacing is the gap between alignment rects, and `ChevronButton` keeps those
            // glyph-sized — so the gap is the glyph pitch less one glyph.
            stack.spacing = Metrics.arrowPitch - Metrics.chevronGlyphSize.width
            // The final pixel of horizontal placement comes from here, not from `arrowsInset`: the
            // spacer's width lands the *stack* on a whole pixel, so 14.4 pt and 14.75 pt rendered at
            // 48 and 50 with nothing in between. An inset inside the stack shifts the glyphs within
            // an already-placed frame, which is what reaches the odd pixel.
            stack.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.arrowsNudge, bottom: 0, right: 0)
            // Wrapped in a container so the stack can be pinned with a negative leading constant:
            // the toolbar's leading spacer already clamps at zero (measured — spending 10.5 pt on it
            // moved the row only 2), and a stack `edgeInsets` stretches the item without moving it.
            // A constraint is the one lever that shifts the glyphs back onto their measured columns
            // now that each chevron is a plate.
            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false
            stack.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                               constant: Metrics.arrowsPlatePull),
                stack.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                                constant: Metrics.arrowsPlatePull),
                stack.topAnchor.constraint(equalTo: container.topAnchor),
                stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            item.view = container
            return item
        case ItemID.title:
            let item = NSToolbarItem(itemIdentifier: identifier)
            // Wrapped in a stack with a leading spacer rather than positioned directly: a toolbar
            // item has no leading-inset knob, and without the gap the title butts up against the
            // forward chevron (measured at x=157 against the system's 178).
            let stack = NSStackView(views: [titleLabel])
            stack.orientation = .horizontal
            stack.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.titleGap, bottom: 0, right: 0)
            item.view = stack
            return item
        default:
            return nil
        }
    }
}
