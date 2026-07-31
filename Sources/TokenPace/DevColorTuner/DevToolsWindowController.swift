import AppKit
import TokenPaceKit

/// The dev-only "Development tools" window (#185): a live colour tuner. Pick a named UI colour role
/// from the list, adjust it with the embedded picker in the right pane, and the menu-bar icon and the
/// popup-preview window repaint immediately via ``ColorStore``'s `onChange`.
///
/// The picker is inline (no floating `NSColorPanel`). It shows the channels grouped as RGB, HSB, and
/// perceptual (LAB **L\*** lightness / LCH **C** chroma), each with a live gradient ribbon
/// (``GradientSlider``) over its slider and an editable 16-bit field (0–65535). A "Lock hue + saturation"
/// switch pins the colour identity so only tone changes. Editable RGB (0–255) and HEX read-outs sit
/// below, plus WCAG contrast against light/dark menu bars and the popup background. Editing any channel
/// updates every other representation and repaints the UI live.
///
/// Gated the same way as its menu item: only reachable when the `devToolsEnabled` defaults key is set and ⌥ Option is
/// held to reveal the entry. Overrides are ephemeral — nothing is persisted; quitting restores defaults.
///
/// Modelled on ``TroubleshootWindowController``: programmatic AppKit + Auto Layout, `.floating` level,
/// `isReleasedWhenClosed = false` so re-opening reuses the instance.
@MainActor
final class DevToolsWindowController: NSWindowController {

    private enum Metrics {
        static let startSize = NSSize(width: 820, height: 780)
        static let minSize = NSSize(width: 760, height: 680)
        static let padding: CGFloat = 16
        static let listWidth: CGFloat = 260
    }

    private enum Sort: Int { case byGroup = 0, alphabetical = 1 }
    private static let bit16 = 65535.0
    /// Nominal ranges of the perceptual channels (mapped onto the shared 0–65535 slider/field scale).
    private static let lStarMax = 100.0    // LAB L* 0–100
    private static let chromaMax = 132.0   // LCH chroma 0–~132 (sRGB gamut)

    /// The channels shown together, in draw order. R/G/B are sRGB components; H/S/B are HSB; L*/C are
    /// perceptual (LAB lightness / LCH chroma). Colour roles here are always opaque (alpha 1).
    private enum Channel: Int, CaseIterable {
        case r, g, b, h, s, brightness, lStar, chroma
        var caption: String {
            switch self {
            case .r: return "R"; case .g: return "G"; case .b: return "B"
            case .h: return "H"; case .s: return "S"; case .brightness: return "B "
            case .lStar: return "L*"; case .chroma: return "C"
            }
        }
        var isHSB: Bool { self == .h || self == .s || self == .brightness }
        var isPerceptual: Bool { self == .lStar || self == .chroma }
        var isRGB: Bool { self == .r || self == .g || self == .b }
    }

    private var sort: Sort = .byGroup
    private var rows: [ColorRole?] = []
    private var selectedRole: ColorRole?
    /// Guard against feedback loops while programmatically syncing controls to a colour.
    private var isSyncing = false

    /// The working colour is held as HSBA (not RGB) so that hue and saturation **survive** a brightness
    /// of 0 — otherwise dragging brightness to black would discard hue/sat (black has none) and the
    /// colour couldn't be recovered. RGB shown in the read-outs/store is derived from this. Each of H, S,
    /// B, A is an independent slider: brightness moves brightness only, saturation stays put.
    private var workH: CGFloat = 0, workS: CGFloat = 0, workB: CGFloat = 0

    /// When on, every edit pins hue and saturation to `lockedH`/`lockedS`, so only brightness/lightness
    /// changes — for tuning tone while keeping the colour identity. Captured when the lock is switched on.
    private var lockHueSat = false
    private var lockedH: CGFloat = 0, lockedS: CGFloat = 0

    // Live stub selector (#187) — a dropdown at the top of the left column that swaps the data source
    // without a restart. The pick is reported to the app via `onStubChange`; `summary` of the current
    // pick is shown in `stubSummaryLabel` below the popup.
    private let stubTitleLabel = NSTextField(labelWithString: "Preview data source (stub)")
    private let stubPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let stubSummaryLabel = NSTextField(wrappingLabelWithString: "")
    /// Menu order — every scenario, so `indexOfSelectedItem` maps back to a `StubScenario`.
    private let stubScenarios = StubScenario.allCases
    /// Reported when the dropdown selection changes, so the app rebuilds the polling engine (#187).
    var onStubChange: ((StubScenario) -> Void)?

    private let tableView = NSTableView()
    private let sortControl = NSSegmentedControl(labels: ["By group", "A–Z"],
                                                 trackingMode: .selectOne, target: nil, action: nil)

    // Detail pane.
    private let titleLabel = NSTextField(labelWithString: "")
    private let usageLabel = NSTextField(wrappingLabelWithString: "")
    private let distortionLabel = NSTextField(wrappingLabelWithString: "")
    private let swatch = NSView()

    /// One row per channel: caption | gradient slider | 16-bit field.
    @MainActor
    private struct ChannelRow {
        let caption = NSTextField(labelWithString: "")
        let slider = GradientSlider()
        let field = NSTextField()
    }
    private var channelRows: [Channel: ChannelRow] = [:]

    // Live read-outs (selectable so the value can be copied directly).
    private let rgbField = NSTextField(labelWithString: "")
    private let hexField = NSTextField(labelWithString: "")

    /// "Lock hue + saturation" — pins H/S so only tone changes.
    private let lockButton = NSButton(checkboxWithTitle: "Lock hue + saturation", target: nil, action: nil)

    /// WCAG contrast read-outs of the current colour against three reference backdrops.
    private let contrastLightLabel = NSTextField(labelWithString: "")
    private let contrastDarkLabel = NSTextField(labelWithString: "")
    private let contrastPopupLabel = NSTextField(labelWithString: "")

    private let copyRGBButton = NSButton(title: "Copy RGB", target: nil, action: nil)
    private let copyHexButton = NSButton(title: "Copy HEX", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    private let resetAllButton = NSButton(title: "Reset all", target: nil, action: nil)
    private var editorControls: [NSControl] = []

    /// A live preview of the menu-bar dropdown, shown in a separate always-on-top window that opens with
    /// the tuner and closes with it. Renders the same `PopupViewController` view the real popup uses —
    /// in an ordinary window, not the modal `NSMenu`. Fed the same `PopupLayout` via ``updatePreview(_:)``.
    private let previewVC = PopupViewController()
    private var previewWindow: NSWindow?
    /// The mock update-notification dots in the preview window, re-tinted on every colour edit.
    private var previewUpdateDots: [(NSImageView, ColorRole)] = []

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Metrics.startSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "TokenPace — Development tools"
        window.contentMinSize = Metrics.minSize
        window.isReleasedWhenClosed = false
        window.level = .floating   // always-on-top so colour picking never loses the window (ADR-0012 §6)
        self.init(window: window)
        window.delegate = self
        buildContent()
        rebuildRows()
        selectFirstRole()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if !(window?.isVisible ?? false) {
            window?.setContentSize(Metrics.startSize)
            window?.center()
        }
        tableView.reloadData()
        refreshDetail()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        showPreviewWindow()
    }

    // MARK: - Preview window

    private func showPreviewWindow() {
        if previewWindow == nil {
            // The preview is a plain window, not an NSMenu, so its popup backdrop must match the menu's
            // on-screen colour itself (dark #212121) rather than the lighter `windowBackgroundColor` fill.
            previewVC.matchesMenuBackground = true
            previewVC.loadView()
            // Borderless: attached as a child of the tuner, it has no title bar / close button — it can't
            // be closed on its own and always travels with the tuner. Its own "Popup Preview" heading is
            // drawn inside the content instead.
            let win = NSWindow(
                contentRect: NSRect(origin: .zero, size: NSSize(width: 340, height: 320)),
                styleMask: [.borderless],
                backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.level = .floating
            win.hasShadow = true
            // Transparent window so the rounded content corners show (an opaque window frame would sit
            // behind them as square corners). The rounded, filled container provides the visible surface.
            win.isOpaque = false
            win.backgroundColor = .clear
            win.contentView = buildPreviewContent()
            previewWindow = win
        }
        if let main = window, let preview = previewWindow {
            // Position at the tuner's top-right, then attach as a child so it follows the tuner when the
            // tuner is dragged (top edges aligned). Re-align after any content resize via `positionPreview`.
            positionPreview()
            if preview.parent == nil { main.addChildWindow(preview, ordered: .above) }
        }
        previewWindow?.orderFront(nil)
    }

    /// Park the preview at the tuner window's top-right, top edges aligned.
    private func positionPreview() {
        guard let main = window, let preview = previewWindow else { return }
        let f = main.frame
        preview.setFrameOrigin(NSPoint(x: f.maxX + 12, y: f.maxY - preview.frame.height))
    }

    /// Preview content = the live popup view, a divider, and two mock update-notification rows (#185
    /// request): a blue dot "new update available" and a red dot "auto-update failed" — mirroring the
    /// real menu update item so those colours (popupServiceBlue / popupWarningRed) are visible for tuning.
    private func buildPreviewContent() -> NSView {
        previewVC.view.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let updateRow = makeUpdateRow(dot: .popupServiceBlue, text: "New update available")
        let failRow = makeUpdateRow(dot: .popupWarningRed, text: "Automatic update failed")

        // The update rows carry their own left inset; the popup view spans the full width flush to the
        // edges (it draws its own backdrop), so there is no pale margin beside it. The whole content view
        // shares the popup's window-background colour so the popup card and the footer strip read as one.
        let footer = NSStackView(views: [divider, updateRow, failRow])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 8
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 12, right: 14)
        footer.translatesAutoresizingMaskIntoConstraints = false

        // Title-bar plaque across the top (the window is borderless — no real title bar). Both the plaque
        // and the container background are theme-adaptive (layer-backed, re-resolved in updateLayer), so
        // the preview follows light ↔ dark instead of freezing at the launch appearance.
        let plaque = TitlePlaqueView(title: "Popup Preview")
        plaque.translatesAutoresizingMaskIntoConstraints = false
        let plaqueDivider = NSBox()
        plaqueDivider.boxType = .separator
        plaqueDivider.translatesAutoresizingMaskIntoConstraints = false

        let container = ThemedFillView()
        // Match the real NSMenu popup's on-screen colour (dark #212121), not the lighter fill a plain
        // `windowBackgroundColor` renders here. Light already matches, so the dynamic colour only
        // overrides dark. The hosted popup view uses the same colour via `matchesMenuBackground`.
        container.fillColor = .popupMenuMatchedBackground
        container.borderColor = .popupMenuBorder   // hairline edge, like a real system menu window
        container.cornerRadius = Self.menuPopupCornerRadius(for: window)
        container.addSubview(plaque)
        container.addSubview(plaqueDivider)
        container.addSubview(previewVC.view)
        container.addSubview(footer)
        NSLayoutConstraint.activate([
            plaque.topAnchor.constraint(equalTo: container.topAnchor),
            plaque.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            plaque.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            plaqueDivider.topAnchor.constraint(equalTo: plaque.bottomAnchor),
            plaqueDivider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            plaqueDivider.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            previewVC.view.topAnchor.constraint(equalTo: plaqueDivider.bottomAnchor, constant: 6),
            previewVC.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            previewVC.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            footer.topAnchor.constraint(equalTo: previewVC.view.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            divider.widthAnchor.constraint(equalTo: footer.widthAnchor, constant: -28),
        ])
        return container
    }

    /// One update-notification row: a coloured `circle.fill` dot (tinted from a `ColorRole` so it tracks
    /// tuning) + label — the same look the real menu update item uses.
    private func makeUpdateRow(dot role: ColorRole, text: String) -> NSView {
        let dot = NSImageView()
        dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
        dot.contentTintColor = ColorStore.shared.color(role)
        dot.tag = role.rawValue == ColorRole.popupServiceBlue.rawValue ? 1 : 2
        dot.identifier = .init(role == .popupServiceBlue ? "updateDot" : "failDot")
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        let row = NSStackView(views: [dot, label])
        row.orientation = .horizontal
        row.spacing = 6
        previewUpdateDots.append((dot, role))
        return row
    }

    /// Feed the preview the same `PopupLayout` the real popup gets; called from `AppDelegate` on every
    /// re-render (which fires on each colour edit), so the preview repaints live. Also re-tints the mock
    /// update dots so their `ColorRole`s track edits. No-op if not open.
    func updatePreview(_ layout: PopupLayout) {
        guard let preview = previewWindow, preview.isVisible else { return }
        previewVC.layout = layout
        for (dot, role) in previewUpdateDots { dot.contentTintColor = ColorStore.shared.color(role) }
        // The container is Auto Layout; size the window to its fitting size (popup width + footer height).
        if let container = preview.contentView {
            preview.setContentSize(container.fittingSize)
        }
        preview.layoutIfNeeded()
        positionPreview()   // keep the top edge aligned to the tuner after a height change
    }

    // MARK: - Layout

    private func buildContent() {
        guard let window else { return }
        let content = NSView()

        stubTitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        stubTitleLabel.textColor = .secondaryLabelColor
        stubTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        stubPopUp.target = self
        stubPopUp.action = #selector(stubScenarioChanged)
        stubPopUp.translatesAutoresizingMaskIntoConstraints = false
        stubPopUp.removeAllItems()
        for scenario in stubScenarios {
            stubPopUp.addItem(withTitle: scenario.displayName)
            stubPopUp.lastItem?.representedObject = scenario
        }

        stubSummaryLabel.font = .preferredFont(forTextStyle: .caption1)
        stubSummaryLabel.textColor = .secondaryLabelColor
        stubSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        stubSummaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        sortControl.selectedSegment = sort.rawValue
        sortControl.target = self
        sortControl.action = #selector(sortChanged)
        sortControl.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("role"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 22
        tableView.dataSource = self
        tableView.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let detail = buildDetailPane()
        detail.translatesAutoresizingMaskIntoConstraints = false

        resetAllButton.bezelStyle = .rounded
        resetAllButton.target = self
        resetAllButton.action = #selector(resetAll)
        resetAllButton.translatesAutoresizingMaskIntoConstraints = false

        for view in [stubTitleLabel, stubPopUp, stubSummaryLabel, sortControl, scroll, detail, resetAllButton] {
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            stubTitleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: Metrics.padding),
            stubTitleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Metrics.padding),
            stubTitleLabel.widthAnchor.constraint(equalToConstant: Metrics.listWidth),

            stubPopUp.topAnchor.constraint(equalTo: stubTitleLabel.bottomAnchor, constant: 4),
            stubPopUp.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Metrics.padding),
            stubPopUp.widthAnchor.constraint(equalToConstant: Metrics.listWidth),

            stubSummaryLabel.topAnchor.constraint(equalTo: stubPopUp.bottomAnchor, constant: 4),
            stubSummaryLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Metrics.padding),
            stubSummaryLabel.widthAnchor.constraint(equalToConstant: Metrics.listWidth),

            sortControl.topAnchor.constraint(equalTo: stubSummaryLabel.bottomAnchor, constant: 12),
            sortControl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Metrics.padding),
            sortControl.widthAnchor.constraint(equalToConstant: Metrics.listWidth),

            scroll.topAnchor.constraint(equalTo: sortControl.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Metrics.padding),
            scroll.widthAnchor.constraint(equalToConstant: Metrics.listWidth),
            scroll.bottomAnchor.constraint(equalTo: resetAllButton.topAnchor, constant: -8),

            resetAllButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Metrics.padding),
            resetAllButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Metrics.padding),

            detail.topAnchor.constraint(equalTo: content.topAnchor, constant: Metrics.padding),
            detail.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: Metrics.padding),
            detail.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Metrics.padding),
            detail.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -Metrics.padding),
        ])

        window.contentView = content
    }

    private func buildDetailPane() -> NSView {
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.lineBreakMode = .byTruncatingTail

        usageLabel.font = .preferredFont(forTextStyle: .body)
        usageLabel.textColor = .secondaryLabelColor

        distortionLabel.font = .preferredFont(forTextStyle: .callout)
        distortionLabel.textColor = .systemOrange

        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 4
        swatch.layer?.borderWidth = 1
        swatch.layer?.borderColor = NSColor.separatorColor.cgColor
        swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.heightAnchor.constraint(equalToConstant: 40).isActive = true

        // Build one row (caption | gradient slider | 16-bit field) per channel.
        var rowViews: [Channel: NSView] = [:]
        for channel in Channel.allCases {
            let row = ChannelRow()
            channelRows[channel] = row

            row.caption.stringValue = channel.caption
            row.caption.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            row.caption.alignment = .right
            row.caption.widthAnchor.constraint(equalToConstant: 24).isActive = true

            row.slider.minValue = 0
            row.slider.maxValue = Self.bit16
            row.slider.target = self
            row.slider.action = #selector(sliderMoved(_:))
            row.slider.tag = channel.rawValue
            row.slider.setContentHuggingPriority(.defaultLow, for: .horizontal)

            row.field.formatter = Self.makeIntFormatter()
            row.field.alignment = .right
            row.field.target = self
            row.field.action = #selector(fieldEdited(_:))
            row.field.tag = channel.rawValue
            row.field.widthAnchor.constraint(equalToConstant: 60).isActive = true

            let hRow = NSStackView(views: [row.caption, row.slider, row.field])
            hRow.orientation = .horizontal
            hRow.spacing = 8
            rowViews[channel] = hRow
        }

        // Three channel groups: RGB, HSB, and perceptual (L*/C). Partition by the `Channel` flags so the
        // rows never depend on hardcoded indices.
        func group(_ filter: (Channel) -> Bool) -> NSStackView {
            let g = NSStackView(views: Channel.allCases.filter(filter).compactMap { rowViews[$0] })
            g.orientation = .vertical; g.spacing = 6; g.alignment = .leading
            return g
        }
        func sectionHeader(_ text: String) -> NSTextField {
            let h = NSTextField(labelWithString: text)
            h.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            h.textColor = .secondaryLabelColor
            return h
        }
        let rgbGroup = group { $0.isRGB }
        let hsbGroup = group { $0.isHSB }
        let perceptualGroup = group { $0.isPerceptual }
        let rgbHeader = sectionHeader("RGB")
        let hsbHeader = sectionHeader("HSB")
        let perceptualHeader = sectionHeader("Perceptual (LAB L* · LCH C)")

        // Lock hue + saturation.
        lockButton.target = self
        lockButton.action = #selector(lockToggled)

        // Editable RGB and HEX fields: show the live value and accept typed input ("r, g, b" / "#RRGGBB").
        for f in [rgbField, hexField] {
            f.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            f.isSelectable = true
            f.isBezeled = true
            f.isEditable = true
            f.drawsBackground = true
            f.target = self
        }
        rgbField.action = #selector(rgbFieldEdited)
        hexField.action = #selector(hexFieldEdited)
        for button in [copyRGBButton, copyHexButton, resetButton] {
            button.bezelStyle = .rounded
            button.target = self
        }
        copyRGBButton.action = #selector(copyRGB)
        copyHexButton.action = #selector(copyHex)
        resetButton.action = #selector(resetCurrent)

        let rgbReadout = NSStackView(views: [NSTextField(labelWithString: "RGB"), rgbField, copyRGBButton])
        rgbReadout.spacing = 8
        let hexReadout = NSStackView(views: [NSTextField(labelWithString: "HEX"), hexField, copyHexButton])
        hexReadout.spacing = 8

        // WCAG contrast block.
        for l in [contrastLightLabel, contrastDarkLabel, contrastPopupLabel] {
            l.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        }
        let contrastHeader = NSTextField(labelWithString: "WCAG contrast")
        contrastHeader.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        contrastHeader.textColor = .secondaryLabelColor
        let contrastGroup = NSStackView(views: [contrastHeader, contrastLightLabel, contrastDarkLabel, contrastPopupLabel])
        contrastGroup.orientation = .vertical
        contrastGroup.spacing = 3
        contrastGroup.alignment = .leading

        let stack = NSStackView(views: [
            titleLabel, usageLabel, distortionLabel, swatch,
            rgbHeader, rgbGroup, hsbHeader, hsbGroup, perceptualHeader, perceptualGroup, lockButton,
            rgbReadout, hexReadout, contrastGroup, resetButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(14, after: distortionLabel)
        stack.setCustomSpacing(14, after: swatch)
        stack.setCustomSpacing(4, after: rgbHeader)
        stack.setCustomSpacing(12, after: rgbGroup)
        stack.setCustomSpacing(4, after: hsbHeader)
        stack.setCustomSpacing(12, after: hsbGroup)
        stack.setCustomSpacing(4, after: perceptualHeader)
        stack.setCustomSpacing(12, after: perceptualGroup)
        stack.setCustomSpacing(14, after: hexReadout)

        for group in [rgbGroup, hsbGroup, perceptualGroup, rgbReadout, hexReadout, contrastGroup] {
            group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        [usageLabel, distortionLabel, swatch].forEach {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        rowViews.values.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        editorControls = [copyRGBButton, copyHexButton, resetButton, lockButton]
            + Channel.allCases.compactMap { channelRows[$0] }.flatMap { [$0.slider, $0.field] as [NSControl] }
        return stack
    }

    /// The corner radius of a **menu-bar pop-up** on the running macOS version, so the borderless preview
    /// reads as the real popup rather than a plain window. The menu window class (`_NSMenuWindow`) is
    /// private with no public metric, so this is keyed off the OS version — matched visually against a
    /// real TokenPace menu: macOS 15 Sequoia menus use ~10 pt; macOS 26 Tahoe rounds them more (~14 pt).
    private static func menuPopupCornerRadius(for referenceWindow: NSWindow?) -> CGFloat {
        if #available(macOS 26.0, *) { return 14 }
        return 10   // macOS 11–15
    }

    private static func makeIntFormatter() -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 0
        f.maximum = NSNumber(value: bit16)
        f.allowsFloats = false
        return f
    }

    // MARK: - Rows

    private func rebuildRows() {
        switch sort {
        case .alphabetical:
            rows = ColorRole.allCases
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                .map { Optional($0) }
        case .byGroup:
            var out: [ColorRole?] = []
            for group in ColorRole.Group.allCases {
                let inGroup = ColorRole.allCases.filter { $0.group == group }
                guard !inGroup.isEmpty else { continue }
                out.append(nil)
                out.append(contentsOf: inGroup.map { Optional($0) })
            }
            rows = out
        }
        tableView.reloadData()
    }

    private func selectFirstRole() {
        if let idx = rows.firstIndex(where: { $0 != nil }) {
            tableView.selectRowIndexes([idx], byExtendingSelection: false)
        }
    }

    private func groupHeader(at index: Int) -> ColorRole.Group? {
        guard rows[index] == nil else { return nil }
        for row in rows[(index + 1)...] where row != nil { return row!.group }
        return nil
    }

    // MARK: - Detail / sync

    private func refreshDetail() {
        guard let role = selectedRole else {
            titleLabel.stringValue = "Select a colour"
            usageLabel.stringValue = ""
            distortionLabel.isHidden = true
            swatch.layer?.backgroundColor = NSColor.clear.cgColor
            editorControls.forEach { $0.isEnabled = false }
            rgbField.stringValue = ""; hexField.stringValue = ""
            resetAllButton.isEnabled = ColorStore.shared.hasAnyOverride
            return
        }
        let modified = ColorStore.shared.isModified(role)
        titleLabel.stringValue = role.displayName + (modified ? "  ●" : "")
        usageLabel.stringValue = role.usageDescription
        if let distortion = role.distortion {
            distortionLabel.stringValue = "⚠︎ Transformed before drawing: " + distortion
            distortionLabel.isHidden = false
        } else {
            distortionLabel.isHidden = true
        }
        editorControls.forEach { $0.isEnabled = true }
        resetButton.isEnabled = modified
        resetAllButton.isEnabled = ColorStore.shared.hasAnyOverride
        syncControls(to: resolvedColor(role))
    }

    /// The current store colour for a role, resolved in the window's appearance to a concrete sRGB
    /// colour so appearance-aware defaults (systemGreen, providers) show real channel values.
    private func resolvedColor(_ role: ColorRole) -> NSColor {
        var resolved = ColorStore.shared.color(role)
        (window?.effectiveAppearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            resolved = resolved.usingColorSpace(.sRGB) ?? resolved
        }
        return resolved
    }

    /// The current working colour, built from the retained HSBA state.
    private var workingColor: NSColor {
        NSColor(hue: workH, saturation: workS, brightness: workB, alpha: 1)
    }

    /// Load a colour into the retained HSBA state, then refresh every control from that state.
    private func syncControls(to color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        workH = c.hueComponent; workS = c.saturationComponent
        workB = c.brightnessComponent
        refreshControlsFromState()
    }

    /// Push the retained HSB state into the swatch, all sliders + fields, gradient ribbons, the RGB/HEX
    /// read-outs, and the contrast block — without triggering edit callbacks. Driven off H/S/B so hue and
    /// saturation are preserved even at brightness 0 (a black RGB colour has no hue to read back).
    private func refreshControlsFromState() {
        isSyncing = true
        defer { isSyncing = false }
        let c = (workingColor.usingColorSpace(.sRGB) ?? workingColor)

        swatch.layer?.backgroundColor = NSColor(srgbRed: c.redComponent, green: c.greenComponent,
                                                blue: c.blueComponent, alpha: 1).cgColor

        // Each channel's value as a 0–1 fraction of its own range (perceptual channels are normalised).
        let lch = ColorSpaces.lch(of: c)
        let fraction: [Channel: CGFloat] = [
            .r: c.redComponent, .g: c.greenComponent, .b: c.blueComponent,
            .h: workH, .s: workS, .brightness: workB,
            .lStar: lch.l / CGFloat(Self.lStarMax),
            .chroma: min(1, lch.c / CGFloat(Self.chromaMax)),
        ]
        for channel in Channel.allCases {
            guard let row = channelRows[channel], let f = fraction[channel] else { continue }
            let scaled = Double(f) * Self.bit16
            row.slider.doubleValue = scaled
            row.field.integerValue = Int(scaled.rounded())
            row.slider.gradientColors = gradientStops(for: channel)
            row.slider.knobColor = colorAtPosition(channel, t: f)   // knob = colour at current value
            // H/S are disabled while locked (they can't change independently).
            if channel == .h || channel == .s {
                row.slider.isEnabled = !lockHueSat && selectedRole != nil
                row.field.isEnabled = !lockHueSat && selectedRole != nil
            }
        }

        let (r, g, b) = (Int((c.redComponent * 255).rounded()),
                         Int((c.greenComponent * 255).rounded()),
                         Int((c.blueComponent * 255).rounded()))
        rgbField.stringValue = "\(r), \(g), \(b)"
        hexField.stringValue = String(format: "#%02X%02X%02X", r, g, b)
        updateContrastReadouts(for: c)
    }

    /// Refresh the three WCAG contrast read-outs (vs light menu-bar, dark menu-bar, popup background).
    private func updateContrastReadouts(for color: NSColor) {
        let popupBG = (NSColor.windowBackgroundColor.usingColorSpace(.sRGB)) ?? .white
        set(contrastLightLabel, label: "vs light menu-bar", ratio: ColorSpaces.contrastRatio(color, .white))
        set(contrastDarkLabel, label: "vs dark menu-bar", ratio: ColorSpaces.contrastRatio(color, .black))
        set(contrastPopupLabel, label: "vs popup bg", ratio: ColorSpaces.contrastRatio(color, popupBG))
    }

    private func set(_ field: NSTextField, label: String, ratio: CGFloat) {
        let grade: String
        let color: NSColor
        switch ratio {
        case 7...:   grade = "AAA"; color = .systemGreen
        case 4.5...: grade = "AA";  color = .systemGreen
        case 3...:   grade = "AA large"; color = .systemYellow
        default:     grade = "fail"; color = .systemRed
        }
        field.stringValue = String(format: "%@: %.2f:1  %@", label, ratio, grade)
        field.textColor = color
    }

    /// The gradient ribbon for one channel: the colour swept across that channel's full range while the
    /// other channels stay at the retained state. HSB ribbons use the retained H/S/B directly so hue is
    /// shown even when brightness is 0.
    private func gradientStops(for channel: Channel) -> [NSColor] {
        let steps = 8
        return (0...steps).map { colorAtPosition(channel, t: CGFloat($0) / CGFloat(steps)) }
    }

    /// The colour a channel produces at fraction `t` of its range, other channels held at the retained
    /// state — used for both the ribbon stops and the knob fill (so knob and ribbon always agree).
    private func colorAtPosition(_ channel: Channel, t: CGFloat) -> NSColor {
        let base = workingColor.usingColorSpace(.sRGB) ?? workingColor
        let r = base.redComponent, g = base.greenComponent, b = base.blueComponent
        switch channel {
        case .r: return NSColor(srgbRed: t, green: g, blue: b, alpha: 1)
        case .g: return NSColor(srgbRed: r, green: t, blue: b, alpha: 1)
        case .b: return NSColor(srgbRed: r, green: g, blue: t, alpha: 1)
        // Knob/ribbon for H/S use eased minimums so a colour is visible; the brightness ramp is literal.
        case .h: return NSColor(hue: t, saturation: max(workS, 0.5), brightness: max(workB, 0.5), alpha: 1)
        case .s: return NSColor(hue: workH, saturation: t, brightness: max(workB, 0.3), alpha: 1)
        case .brightness: return NSColor(hue: workH, saturation: workS, brightness: t, alpha: 1)
        // Perceptual: sweep L* 0–100 at the current a,b; sweep chroma 0–max at the current l,h.
        case .lStar:
            return ColorSpaces.withLightness(t * CGFloat(Self.lStarMax), of: base)
        case .chroma:
            let lch = ColorSpaces.lch(of: base)
            return ColorSpaces.color(l: lch.l, c: t * CGFloat(Self.chromaMax), h: lch.h)
        }
    }

    /// Update the retained HSB state from the edited channel only. H/S/B move their own component; an
    /// RGB channel and the perceptual channels (L*/C) build a new colour and re-derive H/S/B from it.
    private func updateState(from edited: Channel) {
        func norm(_ ch: Channel) -> CGFloat { CGFloat((channelRows[ch]?.slider.doubleValue ?? 0) / Self.bit16) }
        func adopt(_ color: NSColor) {
            let c = color.usingColorSpace(.sRGB) ?? color
            workH = c.hueComponent; workS = c.saturationComponent; workB = c.brightnessComponent
        }
        switch edited {
        case .h: workH = norm(.h)
        case .s: workS = norm(.s)
        case .brightness: workB = norm(.brightness)
        case .r, .g, .b:
            adopt(NSColor(srgbRed: norm(.r), green: norm(.g), blue: norm(.b), alpha: 1))
        case .lStar:
            adopt(ColorSpaces.withLightness(norm(.lStar) * CGFloat(Self.lStarMax), of: workingColor))
        case .chroma:
            let lch = ColorSpaces.lch(of: workingColor)
            adopt(ColorSpaces.color(l: lch.l, c: norm(.chroma) * CGFloat(Self.chromaMax), h: lch.h))
        }
        // When hue+sat are locked, only tone may change: pin H/S back to the captured values.
        if lockHueSat { workH = lockedH; workS = lockedS }
    }

    private func applyEdit(edited: Channel) {
        guard !isSyncing, let role = selectedRole else { return }
        updateState(from: edited)                 // update only the edited channel in the HSB state
        let color = workingColor                  // build the colour from the retained state
        ColorStore.shared.set(color, for: role)   // fires onChange → live repaint
        refreshControlsFromState()                // reflect the state everywhere (keeps hue at brightness 0)
        titleLabel.stringValue = role.displayName + "  ●"
        resetButton.isEnabled = true
        resetAllButton.isEnabled = true
        tableView.reloadData()
    }

    // MARK: - Actions

    @objc private func sortChanged() {
        sort = Sort(rawValue: sortControl.selectedSegment) ?? .byGroup
        rebuildRows()
        if let role = selectedRole, let idx = rows.firstIndex(where: { $0 == role }) {
            tableView.selectRowIndexes([idx], byExtendingSelection: false)
        } else {
            selectFirstRole()
        }
    }

    // MARK: - Live stub selector (#187)

    /// Preselect the dropdown to the scenario currently driving the app (including one set via
    /// `TOKENPACE_STUB` at launch) and sync the description. Called by the app when the window opens.
    func setCurrentScenario(_ scenario: StubScenario) {
        guard let idx = stubScenarios.firstIndex(of: scenario) else { return }
        stubPopUp.selectItem(at: idx)
        stubSummaryLabel.stringValue = scenario.summary
    }

    @objc private func stubScenarioChanged() {
        guard let scenario = stubPopUp.selectedItem?.representedObject as? StubScenario else { return }
        stubSummaryLabel.stringValue = scenario.summary
        onStubChange?(scenario)
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        guard let channel = Channel(rawValue: sender.tag) else { return }
        applyEdit(edited: channel)
    }

    @objc private func lockToggled(_ sender: NSButton) {
        lockHueSat = sender.state == .on
        if lockHueSat { lockedH = workH; lockedS = workS }   // capture the identity to hold
        refreshControlsFromState()                           // enable/disable H/S rows
    }

    @objc private func fieldEdited(_ sender: NSTextField) {
        guard let channel = Channel(rawValue: sender.tag) else { return }
        channelRows[channel]?.slider.doubleValue = min(Self.bit16, max(0, Double(sender.integerValue)))
        applyEdit(edited: channel)
    }

    @objc private func copyRGB() { copyToPasteboard(rgbField.stringValue) }
    @objc private func copyHex() { copyToPasteboard(hexField.stringValue) }

    /// Parse "r, g, b" (0–255 each; commas/spaces/slashes tolerated) and apply it. Malformed → revert.
    @objc private func rgbFieldEdited(_ sender: NSTextField) {
        let parts = sender.stringValue
            .components(separatedBy: CharacterSet(charactersIn: ", /"))
            .filter { !$0.isEmpty }
            .compactMap { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ (0...255).contains($0) }) else {
            refreshDetail(); return   // reject: restore the shown value
        }
        applyExternalColor(NSColor(srgbRed: CGFloat(parts[0]) / 255, green: CGFloat(parts[1]) / 255,
                                   blue: CGFloat(parts[2]) / 255, alpha: 1))
    }

    /// Parse "#RRGGBB" / "RRGGBB" (also 3-digit shorthand) and apply it. Malformed → revert.
    @objc private func hexFieldEdited(_ sender: NSTextField) {
        var hex = sender.stringValue.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }   // #abc → #aabbcc
        guard hex.count == 6, let v = Int(hex, radix: 16) else { refreshDetail(); return }
        applyExternalColor(NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                                   green: CGFloat((v >> 8) & 0xFF) / 255,
                                   blue: CGFloat(v & 0xFF) / 255, alpha: 1))
    }

    /// Apply a colour that came from the RGB/HEX fields: store it, load it into the HSB state, refresh.
    private func applyExternalColor(_ color: NSColor) {
        guard let role = selectedRole else { return }
        ColorStore.shared.set(color, for: role)
        syncControls(to: color)
        titleLabel.stringValue = role.displayName + "  ●"
        resetButton.isEnabled = true
        resetAllButton.isEnabled = true
        tableView.reloadData()
    }

    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func resetCurrent() {
        guard let role = selectedRole else { return }
        ColorStore.shared.reset(role)
        refreshDetail()
        tableView.reloadData()
    }

    @objc private func resetAll() {
        ColorStore.shared.resetAll()
        refreshDetail()
        tableView.reloadData()
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension DevToolsWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows[row] == nil }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row] != nil }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            c.identifier = id
            return c
        }()

        if let role = rows[row] {
            let modified = ColorStore.shared.isModified(role)
            cell.textField?.stringValue = (modified ? "● " : "") + role.displayName
            cell.textField?.font = .systemFont(ofSize: NSFont.systemFontSize)
            cell.textField?.textColor = modified ? .controlAccentColor : .labelColor
        } else {
            cell.textField?.stringValue = groupHeader(at: row)?.rawValue ?? ""
            cell.textField?.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            cell.textField?.textColor = .secondaryLabelColor
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        selectedRole = (row >= 0 && row < rows.count) ? rows[row] : nil
        refreshDetail()
    }
}

// MARK: - NSWindowDelegate

extension DevToolsWindowController: NSWindowDelegate {
    /// Close the popup-preview window automatically when the tuner window closes (only for the tuner's
    /// own close — the preview has no delegate).
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        previewWindow?.orderOut(nil)
    }
}
