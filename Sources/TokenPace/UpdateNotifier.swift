import AppKit
import TokenPaceKit
import UserNotifications

// MARK: - UpdateNotifier

/// Posts the macOS user notification that a newer TokenPace release is available (#37), and owns the
/// one-time authorization request. The **first** use of `UserNotifications` in the app.
///
/// The banner is a **bonus** channel, not the primary one: the always-available signals are the
/// menu item and the Configure line (both work in any build). `UNUserNotificationCenter` only
/// functions in a code-signed, installed `.app` — a bare `swift run` binary has no bundle identifier
/// and its authorization request errors out. So every entry point here is gated on
/// ``LaunchAtLoginController/isAppBundle`` (the same real-`.app` discriminator launch-at-login uses)
/// and tolerates a denied/failed request without affecting the rest of the feature (ADR-0025).
///
/// The delegate (``UpdateNotificationDelegate``) is set once at launch so a click opens the releases
/// page and the banner is presented even though TokenPace is an accessory (`LSUIElement`) app that is
/// never "frontmost" in the usual sense.
@MainActor
enum UpdateNotifier {

    /// Retains the delegate for the process lifetime (`UNUserNotificationCenter.delegate` is weak).
    private static let delegate = UpdateNotificationDelegate()

    /// Identifiers for the notification's category and its single custom action. `nonisolated` so the
    /// off-actor `postNonisolated` and the delegate can read them.
    ///
    /// Only **one** custom action (`Update`) is declared. macOS folds *multiple* custom actions into a
    /// single "Options" dropdown; declaring just one shows it as its own button, and the system pairs
    /// it with its built-in **Close** button — so the alert reads as two side-by-side buttons
    /// (`Update` / `Close`), the layout Reminders-style notifications use.
    nonisolated static let categoryID = "tokenpace.update"
    nonisolated static let updateActionID = "tokenpace.update.open"

    /// Install the notification-center delegate **and** register the action category. Call once, early
    /// in `applicationDidFinishLaunching`, **before** any notification could be delivered. No-op outside
    /// a real `.app` bundle.
    static func installDelegate() {
        guard LaunchAtLoginController.isAppBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate

        // A single custom action, "Update" (`.foreground` — brings focus as it opens the release page).
        // The system supplies the paired "Close" button itself; declaring a second custom action here
        // would instead collapse both into an "Options" dropdown.
        let update = UNNotificationAction(
            identifier: updateActionID, title: "Update", options: [.foreground])
        let category = UNNotificationCategory(
            identifier: categoryID, actions: [update], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    /// Request authorization once (alert + sound). Safe to call repeatedly — the system only prompts
    /// the user the first time; afterwards it resolves against the stored decision. Gated to a real
    /// `.app` (an unsigned/`swift run` build would only log an error). Called when automatic checks
    /// are on at launch and when the user turns the toggle on.
    ///
    /// The `@MainActor` guard is here; the actual `requestAuthorization` call is dispatched to a
    /// `nonisolated` helper. This is deliberate and load-bearing: `UNUserNotificationCenter` fires its
    /// completion handler on its **own (non-main) queue**, and a closure created inside a `@MainActor`
    /// method inherits main-actor isolation — so Swift 6 inserts an executor check at the closure's
    /// entry that trips `dispatch_assert_queue` → `SIGTRAP` when it runs off the main thread. Creating
    /// the closure inside a `nonisolated` function makes it carry no actor, so it is safe on any queue.
    static func requestAuthorizationIfNeeded() {
        guard LaunchAtLoginController.isAppBundle else { return }
        requestAuthorizationNonisolated()
    }

    /// The off-actor half of `requestAuthorizationIfNeeded` — its completion closure must not be
    /// main-actor-isolated (see that method's doc). `os.Logger` is `Sendable`, so logging here is safe.
    private nonisolated static func requestAuthorizationNonisolated() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                AppLogger.lifecycle.error(
                    "update: notification auth failed: \(error.localizedDescription, privacy: .public)")
            } else {
                AppLogger.lifecycle.notice("update: notification auth granted=\(granted, privacy: .public)")
            }
        }
    }

    /// Post "A new version of TokenPace is available" for `release`. The releases URL rides in
    /// `userInfo` so the delegate can open it on click. Using the tag as the request identifier
    /// de-dupes a re-post of the same version. No-op (logs) outside a real `.app`; if authorization
    /// was denied the system silently drops it — the menu item / Configure line still carry the signal.
    static func post(release: GitHubRelease) {
        guard LaunchAtLoginController.isAppBundle else {
            AppLogger.lifecycle.notice("update: skip notification (not an .app bundle)")
            return
        }
        postNonisolated(tagName: release.tagName, htmlURL: release.htmlURL)
    }

    /// The off-actor half of `post` — as with authorization, `UNUserNotificationCenter.add`'s
    /// completion closure must not carry main-actor isolation (see `requestAuthorizationIfNeeded`).
    private nonisolated static func postNonisolated(tagName: String, htmlURL: String) {
        let content = UNMutableNotificationContent()
        content.title = "TokenPace update available"
        content.body = "\(tagName) is ready to download."
        // No sound — a version check is low-urgency; a silent banner is enough.
        content.userInfo = ["htmlURL": htmlURL]
        // Attach the "Update"/"Close" action buttons registered in `installDelegate`.
        content.categoryIdentifier = categoryID

        let request = UNNotificationRequest(
            identifier: "tokenpace.update.\(tagName)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                AppLogger.lifecycle.error(
                    "update: notification post failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - UpdateNotificationDelegate

/// Handles notification presentation and button actions for ``UpdateNotifier``.
///
/// - `willPresent`: an accessory (`LSUIElement`) app is never conventionally frontmost, so without
///   this the banner would be suppressed while the app is running — we explicitly ask for the banner
///   to be shown (no sound: a version check is low-urgency).
/// - `didReceive`: the "Update" button (or the default body click) opens the release page carried in
///   `userInfo`; the "Close" button (or a dismiss) does nothing.
private final class UpdateNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Only the explicit "Update" button opens the release page. A body click
        // (`UNNotificationDefaultActionIdentifier`), "Close", or a dismiss do nothing.
        if response.actionIdentifier == UpdateNotifier.updateActionID {
            if let urlString = response.notification.request.content.userInfo["htmlURL"] as? String,
               let url = URL(string: urlString) {
                AppLogger.lifecycle.notice("update: notification action opened releases page")
                NSWorkspace.shared.open(url)
            }
        }
        completionHandler()
    }
}
