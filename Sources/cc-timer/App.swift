import AppKit
import CCTimerKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The menu-bar item. Held strongly for the process lifetime — releasing it removes the item.
    private var statusItem: NSStatusItem?

    /// The custom view that renders the menu-bar image. Held so the image can be re-snapshotted when
    /// the menu-bar appearance changes (Dark ↔ Light).
    private var statusView: StatusItemView?

    /// KVO token for the button's `effectiveAppearance`, so the non-template image's semantic
    /// colours (idle glyph / reset label) track the menu-bar theme.
    private var appearanceObservation: NSKeyValueObservation?

    /// The detail popup's content controller (issue #11). Hosted inside a menu item so the popup
    /// gets the native menu-bar look — a rounded panel with **no arrow**, and the status button is
    /// highlighted while it is open (both come free with `NSMenu`, unlike `NSPopover`).
    private let popupVC = PopupViewController()

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Accessory: no Dock icon, no main menu — belt-and-suspenders with LSUIElement
        // so the bare `swift run` binary (which has no Info.plist) is also dockless.
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // MOCK — replaced by live polling in #13. Drives the custom view with a representative
        // snapshot + health so the bars/idle/reset and the #12 error states are visible under
        // `swift run` today. Flip `Self.demoMode` to preview the failure phases.
        let now = Date()
        let snapshot = Self.mockSnapshot(now: now)
        let health = Self.mockHealth(now: now)
        let layout = MenuBarLayout.make(from: snapshot, health: health, now: now)
        let view = StatusItemView(frame: NSRect(origin: .zero, size: NSSize(width: 0, height: 22)))
        view.layout = layout
        self.statusView = view
        self.statusItem = item

        // Hand the button a ready non-template image. (Hosting the custom NSView as a button
        // subview is unreliable — the system button paints over it; see StatusItemView.snapshotImage.)
        refreshStatusImage()

        // The image is non-template, so macOS won't re-tint it when the menu-bar theme flips;
        // re-snapshot in the new appearance ourselves (otherwise the reset label / idle glyph,
        // drawn in labelColor, stay the wrong shade — e.g. dark text on a dark menu bar).
        appearanceObservation = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshStatusImage() }
        }

        // Build the popup content from the same snapshot + health. MOCK — #13 supplies the real
        // health (last success, failure start, reason) and interval (PollingBackoff.interval);
        // until then the service line reads from the mock health's lastSuccess.
        popupVC.loadView()   // realise the view so it can be sized before the menu measures it
        popupVC.layout = PopupLayout.make(
            from: snapshot,
            health: health,
            now: now,
            interval: PollingBackoff.defaultInterval
        )
        // A menu item's hosted view must have a concrete non-zero frame — NSMenu reads `frame`, not
        // Auto Layout, to lay the item out (otherwise: "menu item's height should never be 0").
        popupVC.view.frame = NSRect(origin: .zero, size: popupVC.view.fittingSize)

        // Host the content in a menu item. Attaching the menu to the status item gives the native
        // menu-bar behaviour: clicking opens it (no target/action needed), there is no popover
        // arrow, and the button highlights while open.
        let menu = NSMenu()
        let popupItem = NSMenuItem()
        popupItem.view = popupVC.view
        menu.addItem(popupItem)
        item.menu = menu

        AppLogger.lifecycle.info(
            "cc-timer status item attached (\(CCTimerKit.version, privacy: .public)); live polling arrives in #13"
        )
    }

    // MARK: - Menu-bar image

    /// Re-render the menu-bar image in the button's current appearance and resize the item to fit.
    /// Called at launch and whenever the menu-bar theme changes.
    private func refreshStatusImage() {
        guard let button = statusItem?.button, let view = statusView else { return }
        let image = view.snapshotImage(appearance: button.effectiveAppearance)
        button.image = image
        statusItem?.length = image.size.width
    }

    // MARK: - Mock data (#13 replaces this with a live poll)

    /// Which mock state `swift run` renders. Default `.healthy` keeps the normal bars (issue #11
    /// behaviour); flip to a failure case to preview the issue #12 error states by eye:
    /// - `.failing30m` → ⚠️ **plus** stale bars (the 30–60 min phase) + the popup warning banner.
    /// - `.failing70m` → ⚠️ **alone** (past 60 min) + the popup warning banner.
    private enum DemoMode { case healthy, failing30m, failing70m }
    private static let demoMode: DemoMode = .healthy

    /// A mock ``UsageHealth`` matching ``demoMode`` — healthy, or failing for a duration that lands
    /// in the requested menu-bar phase. `lastSuccess` is set in the past so the popup's "Last
    /// update" line shows the data ageing.
    private static func mockHealth(now: Date) -> UsageHealth {
        switch demoMode {
        case .healthy:
            return .healthy(lastSuccess: now)
        case .failing30m:
            return UsageHealth(
                lastSuccess: now.addingTimeInterval(-35 * 60),
                failingSince: now.addingTimeInterval(-35 * 60),
                reason: .authHTTP(status: 401, body: "Invalid or expired access token"))
        case .failing70m:
            return UsageHealth(
                lastSuccess: now.addingTimeInterval(-70 * 60),
                failingSince: now.addingTimeInterval(-70 * 60),
                reason: .notSignedIn)
        }
    }

    /// A representative `UsageSnapshot` for visual verification, deliberately exercising **both**
    /// pacing colours so the green/red palette can be judged at a glance:
    /// - 5h: 40% used, ~60% of the window elapsed → on pace → **green** gap.
    /// - 7d: 75% used, ~57% of the window elapsed → ahead of pace → **red** gap.
    ///
    /// `seven_day_sonnet` is populated (Opus left absent) so the popup shows one per-model row and
    /// the null-safe handling of the other — matching the common "Sonnet only" settings view.
    private static func mockSnapshot(now: Date) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: UsageWindow(utilization: 40, resetsAt: iso(now.addingTimeInterval(2 * 3600))),
            sevenDay: UsageWindow(utilization: 75, resetsAt: iso(now.addingTimeInterval(3 * 24 * 3600))),
            sevenDaySonnet: UsageWindow(utilization: 2, resetsAt: iso(now.addingTimeInterval(3 * 24 * 3600)))
        )
    }

    /// Format a `Date` as the ISO-8601 string the usage API emits (and `ResetClock.parse` accepts).
    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
