import AppKit

/// The dev-only "Development tools" window (#185): a live colour tuner. Pick a named UI colour role
/// from the list, adjust it with the **embedded** picker in the right pane — RGB / HSB sliders plus
/// editable 16-bit fields (0–65535 per channel) — and the menu-bar icon and popup repaint immediately
/// via ``ColorStore``'s `onChange`.
///
/// The picker is inline (no floating `NSColorPanel`): AppKit ships no single "wheel + sliders + fields"
/// view, so the pane composes a swatch, an RGB/HSB mode toggle, three channel sliders, an alpha slider,
/// and 16-bit numeric fields, all kept in two-way sync.
///
/// Gated the same way as its menu item: only reachable when `TOKENPACE_DEVTOOLS` is set and ⌥ Option is
/// held to reveal the entry. Overrides are ephemeral — nothing is persisted; quitting restores defaults.
///
/// Modelled on ``TroubleshootWindowController``: programmatic AppKit + Auto Layout, normal window level,
/// `isReleasedWhenClosed = false` so re-opening reuses the instance.
@MainActor
final class DevToolsWindowController: NSWindowController {

    private enum Metrics {
        static let startSize = NSSize(width: 760, height: 560)
        static let minSize = NSSize(width: 700, height: 480)
        static let padding: CGFloat = 16
        static let listWidth: CGFloat = 260
    }

    private enum Sort: Int { case byGroup = 0, alphabetical = 1 }
    /// Channel model the sliders/fields edit. 16-bit range 0–65535 per the issue.
    private enum Channels: Int { case rgb = 0, hsb = 1 }

    private static let bit16 = 65535.0

    private var sort: Sort = .byGroup
    /// Flattened table rows; `nil` entries are group headers.
    private var rows: [ColorRole?] = []
    private var selectedRole: ColorRole?
    private var channels: Channels = .rgb
    /// Guard against feedback loops while programmatically syncing sliders/fields to a colour.
    private var isSyncing = false

    private let tableView = NSTableView()
    private let sortControl = NSSegmentedControl(labels: ["By group", "A–Z"],
                                                 trackingMode: .selectOne, target: nil, action: nil)

    // Detail pane.
    private let titleLabel = NSTextField(labelWithString: "")
    private let usageLabel = NSTextField(wrappingLabelWithString: "")
    private let distortionLabel = NSTextField(wrappingLabelWithString: "")
    private let swatch = NSView()
    private let modeControl = NSSegmentedControl(labels: ["RGB", "HSB"],
                                                 trackingMode: .selectOne, target: nil, action: nil)

    /// Three colour channels + alpha, each a labelled slider paired with a 16-bit numeric field.
    @MainActor
    private struct ChannelControl {
        let caption = NSTextField(labelWithString: "")
        let slider = NSSlider()
        let field = NSTextField()
    }
    private let ch = [ChannelControl(), ChannelControl(), ChannelControl()]
    private let alpha = ChannelControl()

    private let copyButton = NSButton(title: "Copy sRGB", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    private let resetAllButton = NSButton(title: "Reset all", target: nil, action: nil)
    private var editorControls: [NSControl] = []

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Metrics.startSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "TokenPace — Development tools"
        window.contentMinSize = Metrics.minSize
        window.isReleasedWhenClosed = false
        self.init(window: window)
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
    }

    // MARK: - Layout

    private func buildContent() {
        guard let window else { return }
        let content = NSView()

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

        for view in [sortControl, scroll, detail, resetAllButton] { content.addSubview(view) }

        NSLayoutConstraint.activate([
            sortControl.topAnchor.constraint(equalTo: content.topAnchor, constant: Metrics.padding),
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

        modeControl.selectedSegment = channels.rawValue
        modeControl.target = self
        modeControl.action = #selector(modeChanged)

        // Build the four channel rows (3 colour + alpha). Each: caption | slider | 16-bit field.
        let channelRows: [NSView] = (Array(ch) + [alpha]).enumerated().map { index, control in
            control.caption.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            control.caption.alignment = .right
            control.caption.widthAnchor.constraint(equalToConstant: 24).isActive = true

            control.slider.minValue = 0
            control.slider.maxValue = Self.bit16
            control.slider.target = self
            control.slider.action = #selector(sliderMoved(_:))
            control.slider.tag = index
            control.slider.setContentHuggingPriority(.defaultLow, for: .horizontal)

            control.field.formatter = Self.makeIntFormatter()
            control.field.alignment = .right
            control.field.target = self
            control.field.action = #selector(fieldEdited(_:))
            control.field.tag = index
            control.field.widthAnchor.constraint(equalToConstant: 64).isActive = true

            let row = NSStackView(views: [control.caption, control.slider, control.field])
            row.orientation = .horizontal
            row.spacing = 8
            row.distribution = .fill
            return row
        }

        let sliderStack = NSStackView(views: channelRows)
        sliderStack.orientation = .vertical
        sliderStack.spacing = 8
        sliderStack.alignment = .leading
        // Make each channel row span the full pane width so sliders stretch.
        channelRows.forEach { $0.widthAnchor.constraint(equalTo: sliderStack.widthAnchor).isActive = true }

        for button in [copyButton, resetButton] {
            button.bezelStyle = .rounded
            button.target = self
        }
        copyButton.action = #selector(copySRGB)
        resetButton.action = #selector(resetCurrent)
        let buttonRow = NSStackView(views: [copyButton, resetButton])
        buttonRow.spacing = 8

        editorControls = [modeControl, copyButton, resetButton]
            + (Array(ch) + [alpha]).flatMap { [$0.slider, $0.field] as [NSControl] }

        let stack = NSStackView(views: [
            titleLabel, usageLabel, distortionLabel, swatch, modeControl, sliderStack, buttonRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: distortionLabel)
        stack.setCustomSpacing(16, after: swatch)

        // Full-width children.
        [usageLabel, distortionLabel, swatch, sliderStack].forEach {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
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

    /// Push a colour into the swatch, sliders, and 16-bit fields (without triggering edit callbacks).
    private func syncControls(to color: NSColor) {
        isSyncing = true
        defer { isSyncing = false }
        swatch.layer?.backgroundColor = color.cgColor

        let values: [CGFloat]
        switch channels {
        case .rgb:
            ch[0].caption.stringValue = "R"; ch[1].caption.stringValue = "G"; ch[2].caption.stringValue = "B"
            values = [color.redComponent, color.greenComponent, color.blueComponent]
        case .hsb:
            ch[0].caption.stringValue = "H"; ch[1].caption.stringValue = "S"; ch[2].caption.stringValue = "B"
            values = [color.hueComponent, color.saturationComponent, color.brightnessComponent]
        }
        alpha.caption.stringValue = "A"
        for (i, v) in (values + [color.alphaComponent]).enumerated() {
            let control = i < 3 ? ch[i] : alpha
            let scaled = Double(v) * Self.bit16
            control.slider.doubleValue = scaled
            control.field.integerValue = Int(scaled.rounded())
        }
    }

    /// Read the four controls back into a colour in the current channel model.
    private func colorFromControls() -> NSColor {
        let c = ch.map { CGFloat($0.slider.doubleValue / Self.bit16) }
        let a = CGFloat(alpha.slider.doubleValue / Self.bit16)
        switch channels {
        case .rgb:
            return NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: a)
        case .hsb:
            return NSColor(hue: c[0], saturation: c[1], brightness: c[2], alpha: a)
        }
    }

    private func applyEdit() {
        guard !isSyncing, let role = selectedRole else { return }
        let color = colorFromControls()
        ColorStore.shared.set(color, for: role)   // fires onChange → live repaint
        // Re-sync so the sibling representation (slider ↔ field, or the swatch) stays consistent.
        syncControls(to: resolvedColor(role))
        titleLabel.stringValue = role.displayName + "  ●"
        resetButton.isEnabled = true
        resetAllButton.isEnabled = true
        tableView.reloadData()   // ● marker in the list
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

    @objc private func modeChanged() {
        channels = Channels(rawValue: modeControl.selectedSegment) ?? .rgb
        if let role = selectedRole { syncControls(to: resolvedColor(role)) }
    }

    @objc private func sliderMoved(_ sender: NSSlider) { applyEdit() }

    @objc private func fieldEdited(_ sender: NSTextField) {
        // Mirror the typed value onto the matching slider, then apply.
        let control = sender.tag < 3 ? ch[sender.tag] : alpha
        control.slider.doubleValue = min(Self.bit16, max(0, Double(sender.integerValue)))
        applyEdit()
    }

    @objc private func copySRGB() {
        guard let role = selectedRole else { return }
        let color = resolvedColor(role)
        let r = Int((color.redComponent * 255).rounded())
        let g = Int((color.greenComponent * 255).rounded())
        let b = Int((color.blueComponent * 255).rounded())
        let text = "NSColor(srgbRed: \(r)/255, green: \(g)/255, blue: \(b)/255, alpha: \(String(format: "%.2f", color.alphaComponent)))"
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
