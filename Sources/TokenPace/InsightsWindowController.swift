import AppKit
import SwiftUI
import TokenPaceKit

// MARK: - InsightsWindowController

/// The "Insights" window (ADR-0067) — a **separate** window (styled like Settings) reached from the
/// first item of the popup menu, where usage-journal data will be visualised. For now a placeholder:
/// the menu entry, window chrome, and journal-enabled empty state are all in place, and a downstream
/// ticket only has to drop chart views into `InsightsRootView`. Kept as its own controller, not a
/// Settings pane, because Settings is only for configuring the collector.
@MainActor
final class InsightsWindowController: NSWindowController {

    private enum Metrics {
        /// Matches the Settings window width so the two feel like one family (#156).
        static let contentWidth: CGFloat = 857
        static let contentHeight: CGFloat = 560
    }

    private var hasBeenPositioned = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.contentWidth, height: Metrics.contentHeight),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "TokenPace Insights"
        window.level = .floating               // float above other apps from a menu-bar app (ADR-0012 §6)
        window.isReleasedWhenClosed = false    // keep the controller alive so re-opening reuses it
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.contentMinSize = NSSize(width: Metrics.contentWidth, height: Metrics.contentHeight)
        self.init(window: window)
        let hosting = NSHostingController(rootView: InsightsRootView())
        hosting.sizingOptions = []
        window.contentViewController = hosting
    }

    /// Show or re-focus the window, bringing the app forward and centring on first show of a session.
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.setContentSize(NSSize(width: Metrics.contentWidth, height: Metrics.contentHeight))
        if !hasBeenPositioned {
            hasBeenPositioned = true
            window?.center()
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - InsightsRootView

/// Placeholder content for the Insights window. The usage journal is the data source; charts land in
/// a downstream ticket. Until then this states what the window will show and reflects whether
/// recording is on, so the empty state is honest rather than blank — without that, a user who just
/// enabled recording reads the unchanged screen as a broken feature.
///
/// The Settings pointer names **General**, where the toggle currently lives — a hard-coded path to
/// another pane goes stale silently, so whoever moves it next must grep for this string.
private struct InsightsRootView: View {
    /// A plain read of the collector switch — no live binding needed for a placeholder; the window
    /// is short-lived and re-reads on each open.
    @State private var recording = PersistedConfig.journalEnabled

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text("Usage Insights")
                .font(.title2.weight(.semibold))
            Text("Charts of your usage will appear here.")
                .foregroundStyle(.secondary)
            // Reuses the Settings ⚠️ hint treatment so the two surfaces state a caveat the same way.
            SettingsHint(text: "This window is still a placeholder — the charts arrive in a future version of TokenPace.",
                         warning: true)
            if !recording {
                Text("Turn on **Record usage history** in Settings → General to start collecting data.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .onAppear { recording = PersistedConfig.journalEnabled }
    }
}
