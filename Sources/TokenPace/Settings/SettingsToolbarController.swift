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
final class SettingsToolbarController: NSObject, NSToolbarItemValidation {

    private enum Metrics {

        /// Baseline lift for the title, in points, for the one pixel of vertical alignment left over
        /// once the glyph box matched the system's in width (measured: rows 41–62 against 40–61).
        ///
        /// Applied as a `.baselineOffset` attribute rather than a stack inset: the toolbar centres the
        /// item vertically in the bar, so neither `edgeInsets` nor a half-point on the spacer moved
        /// the label at all — both were measured and left the glyphs on the same rows.
        static let titleLift: CGFloat = 0.5
    }

    private enum ItemID {
        static let back = NSToolbarItem.Identifier("TokenPaceSettingsBack")
        static let forward = NSToolbarItem.Identifier("TokenPaceSettingsForward")
        static let title = NSToolbarItem.Identifier("TokenPaceSettingsPaneTitle")
    }

    /// Invoked when ‹ is clicked. Wired by the window controller into the model's `goBack()`.
    var onBack: (() -> Void)?
    /// Invoked when › is clicked.
    var onForward: (() -> Void)?

    /// The two navigation items, kept so `update(...)` can flip their enablement. The toolbar owns
    /// the buttons inside them.
    private var backItem: NSToolbarItem?
    private var forwardItem: NSToolbarItem?

    /// What the history currently allows. The toolbar asks for this on every window update through
    /// `validateToolbarItem(_:)` — see there for why the state has to live here rather than on the
    /// items.
    private var canGoBack = false
    private var canGoForward = false
    private let titleLabel = NSTextField(labelWithString: "")

    /// The hosting window, for reading its key state when tinting the chevrons. Weak — the window
    /// owns the controller chain, not the other way round.
    private weak var window: NSWindow?

    override init() {
        super.init()
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
    }

    /// The toolbar's own validation hook: it asks on every window update, which is what makes the
    /// answer stick where a direct `isEnabled` write does not.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        // Validation is also where the bezel has to be re-applied: answering here makes the toolbar
        // rebuild the button, and a rebuilt one comes back `isBordered = false` — which is how the
        // hover backing disappeared once validation started driving the enablement. Scheduled rather
        // than done inline, because the button does not exist yet at the moment we answer.
        DispatchQueue.main.async { [weak self] in self?.enableChevronHoverBacking() }
        switch item.itemIdentifier {
        case ItemID.back: return canGoBack
        case ItemID.forward: return canGoForward
        default: return true
        }
    }

    /// Turn on the hover backing for the buttons the toolbar generated for ‹ ›.
    ///
    /// An `NSToolbarItem` with an image builds its own `NSToolbarButton`, but that button ships
    /// `isBordered = false` at 15×20 — a bare glyph — so nothing highlights under the pointer. Asking
    /// it for a bezel shown only while the mouse is inside gives the rounded backing System Settings
    /// has, and the button resizes itself to 40×40, which is exactly what the Accessibility dump
    /// reads off System Settings' own back/forward buttons.
    ///
    /// Has to happen after the toolbar has built its views, and again whenever it rebuilds them —
    /// `NSToolbarItem.view` stays nil for generated buttons, so the button is reached by walking the
    /// titlebar's view tree.
    func enableChevronHoverBacking() {
        guard let themeFrame = window?.contentView?.superview else { return }
        // Ordered left to right, so the first button is ‹ and the second ›, and each can be matched
        // to the item whose enablement it should mirror.
        var buttons: [NSButton] = []
        func collect(_ view: NSView) {
            if let button = view as? NSButton,
               String(describing: type(of: view)).contains("NSToolbarButton") {
                buttons.append(button)
            }
            view.subviews.forEach(collect)
        }
        collect(themeFrame)
        buttons.sort { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }

        for (button, item) in zip(buttons, [backItem, forwardItem]) {
            // The item's enablement is re-applied to its button directly. Setting it on the
            // `NSToolbarItem` alone does not stick: the toolbar rebuilds its buttons, and a rebuilt
            // one comes back enabled — logged as `isEnabled` flipping from false to true between two
            // passes — which is why a greyed-out arrow rendered at full strength and still lit up
            // under the pointer.
            let enabled = item?.isEnabled ?? true
            // Guarded: this runs on every validation pass, and re-assigning the same values makes
            // AppKit repaint the button, which shows up as a flicker under the pointer.
            guard button.isEnabled != enabled || !button.isBordered else { continue }
            button.isEnabled = enabled
            // **Both** buttons are bordered, enabled or not: a bezel changes the button's metrics
            // (measured — 15×20 without it against 40×40 with it), so bordering only the active one
            // left the two chevrons visibly different sizes. `showsBorderOnlyWhileMouseInside` keeps
            // the bezel invisible until hovered, and AppKit does not draw a hover bezel on a
            // disabled button, so the plate still appears on the active arrow only.
            button.isBordered = true
            button.showsBorderOnlyWhileMouseInside = true
            button.bezelStyle = .toolbar
        }
    }

    /// Reflect the current pane and what the history buttons can reach.
    func update(title: String, canGoBack: Bool, canGoForward: Bool) {
        // Every write is guarded, because this runs on **any** model change, not just a navigation
        // one: `observeToolbarState` re-arms `withObservationTracking` on each fire, so toggling an
        // unrelated setting lands here too. Re-assigning the same title or enablement makes AppKit
        // rebuild the item, which cancels the hover highlight mid-render — the flicker under the
        // pointer (#312).
        if titleLabel.stringValue != title {
            titleLabel.attributedStringValue = NSAttributedString(
                string: title,
                attributes: [.font: titleLabel.font as Any,
                             .foregroundColor: titleLabel.textColor as Any,
                             .baselineOffset: Metrics.titleLift])
        }
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        // Writing `isEnabled` on the items does not hold: the toolbar validates its visible items on
        // every window update and a standard item answers by asking its target, so anything set by
        // hand is overwritten moments later (measured — both chevrons settled at `isEnabled = true`
        // however often it was re-applied, which is why a greyed-out arrow rendered at full strength
        // and still lit up under the pointer). `validateToolbarItem(_:)` is where that answer comes
        // from, so the state lives here and the toolbar reads it.
        window?.toolbar?.validateVisibleItems()
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
        [.sidebarTrackingSeparator, ItemID.back, ItemID.forward, ItemID.title]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case ItemID.back, ItemID.forward:
            // No `view`: an `NSToolbarItem` given only an image and an action builds its **own**
            // button, and the toolbar then draws it as a system toolbar button — including the
            // rounded hover highlight, at the system's size, with the system's timing. Supplying a
            // custom view is what opted us out of all of that and forced every plate metric, fill
            // colour and tracking area to be reproduced by hand (and the hand-drawn plate ended up
            // invisible: `.quaternarySystemFill` renders 240 over the bar's 247).
            //
            // `isNavigational` is what these two are: AppKit reserves it for back/forward pairs and
            // positions them accordingly.
            let item = NSToolbarItem(itemIdentifier: identifier)
            let isBack = identifier == ItemID.back
            let symbol = NSImage(
                systemSymbolName: isBack ? "chevron.backward" : "chevron.forward",
                accessibilityDescription: isBack ? "Back" : "Forward")
            // Template, so AppKit tints the glyph itself — that is what makes a disabled arrow read
            // as greyed out. Without it the symbol carries its own colour and both arrows render
            // identically whatever `isEnabled` says (verified: the items and their buttons had the
            // right enablement while the glyphs looked the same).
            symbol?.isTemplate = true
            item.image = symbol
            item.label = isBack ? "Back" : "Forward"
            item.paletteLabel = item.label
            item.isNavigational = true
            // The bezel tracks the button's width less 6 pt (measured: a 40 pt button bezels at 34,
            // a 44 pt one at 38), and the toolbar sizes the button from the item. 39 lands the plate
            // on the 33 pt System Settings draws — ours came out 28 wide before this.
            // No `minSize`/`maxSize`: left alone the toolbar builds a 40×40 button and spaces the
            // pair 36.0 pt apart, which is the system's own figure (measured 36.5 off System
            // Settings). Forcing a width was what pushed them to 43 — and trimming one item to
            // compensate only made its plate smaller than the other's, since the plate is sized
            // from the item.
            item.target = self
            item.action = isBack ? #selector(goBack) : #selector(goForward)
            if isBack { backItem = item } else { forwardItem = item }
            return item
        case ItemID.title:
            // The label is the item's view directly. It used to be wrapped in a stack whose
            // `edgeInsets` supplied a leading gap, which existed to clear a hand-positioned chevron
            // pair; the toolbar spaces its own items now.
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = titleLabel
            return item
        default:
            return nil
        }
    }
}
