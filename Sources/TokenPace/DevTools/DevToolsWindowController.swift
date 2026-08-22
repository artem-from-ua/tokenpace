import AppKit
import TokenPaceKit

/// The dev-only "Development tools" window: a live stub selector (#187) and a switch for the raw
/// status-payload JSONL log (#279).
///
/// Both instruments answer the same need — driving the app through states that real traffic reaches
/// rarely or never, without a restart. The stub dropdown swaps the data source in place; the log
/// captures what live `status.claude.com` traffic actually sends, so design questions get answered
/// from payloads rather than guesswork.
///
/// Gated the same way as its menu item: only reachable when the `devToolsEnabled` defaults key is set
/// and ⌥ Option is held to reveal the entry (ADR-0053).
///
/// Modelled on ``TroubleshootWindowController``: programmatic AppKit + Auto Layout, `.floating` level,
/// `isReleasedWhenClosed = false` so re-opening reuses the instance.
@MainActor
final class DevToolsWindowController: NSWindowController {

    private enum Metrics {
        static let startSize = NSSize(width: 380, height: 220)
        static let minSize = NSSize(width: 340, height: 200)
        static let padding: CGFloat = 16
        static let listWidth: CGFloat = 260
    }

    // Live stub selector (#187) — a dropdown that swaps the data source without a restart. The pick is
    // reported to the app via `onStubChange`; `summary` of the current pick is shown below it.
    private let stubTitleLabel = NSTextField(labelWithString: "Preview data source (stub)")
    private let stubPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let stubSummaryLabel = NSTextField(wrappingLabelWithString: "")
    /// Menu order — every scenario, so `indexOfSelectedItem` maps back to a `StubScenario`.
    private let stubScenarios = StubScenario.allCases
    /// Reported when the dropdown selection changes, so the app rebuilds the polling engine (#187).
    var onStubChange: ((StubScenario) -> Void)?

    /// Toggles the raw status-payload JSONL (#279, ADR-0071 §10) — the instrument for answering the
    /// ADR's deliberately-open questions from real traffic rather than guesswork.
    private let payloadLogCheckbox = NSButton(
        checkboxWithTitle: "Log status payloads (JSONL)", target: nil, action: nil)
    private let revealPayloadLogButton = NSButton(
        title: "Reveal in Finder", target: nil, action: nil)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Metrics.startSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "TokenPace — Development tools"
        window.contentMinSize = Metrics.minSize
        window.isReleasedWhenClosed = false
        window.level = .floating   // always-on-top so the app stays drivable while this is open (ADR-0012 §6)
        self.init(window: window)
        buildContent()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if !(window?.isVisible ?? false) {
            window?.setContentSize(Metrics.startSize)
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Content

    /// One vertical stack pinned on all four edges. The controls sit in a single column, so a stack
    /// carries the layout with no per-view anchors.
    private func buildContent() {
        guard let window else { return }

        stubTitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        stubTitleLabel.textColor = .secondaryLabelColor

        stubPopUp.target = self
        stubPopUp.action = #selector(stubScenarioChanged)
        stubPopUp.removeAllItems()
        for scenario in stubScenarios {
            // Prefix the ⚡ (real API) / ⏱ (real clock) / ⏭ (steps per poll — use "Refresh now")
            // badges so a live or sequential scenario is flagged at a glance.
            stubPopUp.addItem(withTitle: scenario.badges + scenario.displayName)
            stubPopUp.lastItem?.representedObject = scenario
        }

        stubSummaryLabel.font = .preferredFont(forTextStyle: .caption1)
        stubSummaryLabel.textColor = .secondaryLabelColor
        stubSummaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        payloadLogCheckbox.target = self
        payloadLogCheckbox.action = #selector(payloadLogToggled)
        payloadLogCheckbox.state = PersistedConfig.statusPayloadLogEnabled ? .on : .off
        payloadLogCheckbox.toolTip =
            "Append each materially-changed status.claude.com response to a JSONL file "
            + "(ADR-0071 §10). Live network only; unchanged payloads are not written."

        revealPayloadLogButton.bezelStyle = .rounded
        revealPayloadLogButton.controlSize = .small
        revealPayloadLogButton.target = self
        revealPayloadLogButton.action = #selector(revealPayloadLog)

        // The reveal button is indented under its checkbox and sized to its title; everything else
        // spans the column. `.leading` alignment keeps both shapes on the same left edge.
        let stack = NSStackView(views: [stubTitleLabel, stubPopUp, stubSummaryLabel,
                                        payloadLogCheckbox, revealPayloadLogButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.setCustomSpacing(12, after: stubSummaryLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: Metrics.padding),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Metrics.padding),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor,
                                            constant: -Metrics.padding),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor,
                                          constant: -Metrics.padding),

            stubPopUp.widthAnchor.constraint(equalToConstant: Metrics.listWidth),
            stubTitleLabel.widthAnchor.constraint(equalToConstant: Metrics.listWidth),
            stubSummaryLabel.widthAnchor.constraint(equalToConstant: Metrics.listWidth),
            payloadLogCheckbox.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.listWidth),
        ])
        // Indent the reveal button under the checkbox it belongs to.
        stack.setCustomSpacing(4, after: payloadLogCheckbox)
        revealPayloadLogButton.leadingAnchor.constraint(
            equalTo: stack.leadingAnchor, constant: 18).isActive = true

        window.contentView = content
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

    // MARK: - Status-payload log (#279)

    /// Flip the raw status-payload log (#279). Takes effect on the next status poll — no restart —
    /// because the poll reads the flag each time rather than caching it.
    @objc private func payloadLogToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        PersistedConfig.statusPayloadLogEnabled = enabled
        AppLogger.journal.info("status-payload-log: enabled set \(enabled, privacy: .public)")
    }

    /// Reveal this month's payload log, or the containing folder when nothing has been written yet
    /// (the log only appears once a material change has been captured, so "no file" is the normal
    /// state right after enabling it).
    @objc private func revealPayloadLog() {
        let directory = UsageJournal.defaultDirectory
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        let suffix = UsageJournal.runningFromApplications ? "" : "-dev"
        let file = directory.appendingPathComponent(
            "status-payloads\(suffix)-\(formatter.string(from: Date())).jsonl")

        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(directory)
        }
    }
}
