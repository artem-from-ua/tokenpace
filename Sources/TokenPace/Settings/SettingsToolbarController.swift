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
        if backItem?.isEnabled != canGoBack { backItem?.isEnabled = canGoBack }
        if forwardItem?.isEnabled != canGoForward { forwardItem?.isEnabled = canGoForward }
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
            item.image = NSImage(
                systemSymbolName: isBack ? "chevron.backward" : "chevron.forward",
                accessibilityDescription: isBack ? "Back" : "Forward")
            item.label = isBack ? "Back" : "Forward"
            item.paletteLabel = item.label
            item.isNavigational = true
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
