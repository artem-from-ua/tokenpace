import AppKit
import Foundation
import UserNotifications
import TokenPaceKit

// MARK: - IncidentNotificationDelegate

/// Routes taps on incident banners (#279): the body opens that incident's page, the `Unfollow`
/// button stops following the episode without opening anything.
///
/// **Actor isolation is the whole difficulty here.** `UNUserNotificationCenter` invokes its delegate
/// on a private background queue, and `@MainActor`-isolated code run there trips a
/// `dispatch_assert_queue` fatal error (SIGTRAP) — the trap already documented in
/// ``BackToWorkNotifier``'s header. So this type is **not** `@MainActor`: the handler runs wherever
/// UN calls it, touches only thread-safe API (`UserDefaults`, `NSWorkspace`), and hops to the main
/// actor solely to ask the app to re-render.
///
/// `UserDefaults` is read and written directly rather than through `PersistedConfig`, which is
/// `@MainActor`-isolated — reaching it from this queue is precisely the crash above. The key and the
/// encoding are shared with it, so the two stay in step.
final class IncidentNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    /// Called on the **main actor** after the subscription changed from a banner action, so the popup
    /// reflects it the next time it opens.
    private let onUnfollowed: @MainActor () -> Void

    init(onUnfollowed: @escaping @MainActor () -> Void) {
        self.onUnfollowed = onUnfollowed
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Present banners even when TokenPace is frontmost. It is an `LSUIElement` agent with no windows
    /// of its own, so "the app is active" never means the user is looking at this information.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let incidentID = userInfo[BackToWorkNotifier.incidentIDKey] as? String

        switch response.actionIdentifier {
        case BackToWorkNotifier.unfollowActionIdentifier:
            unfollow()
        case UNNotificationDefaultActionIdentifier:
            // Open the incident's own page when the banner names one; the episode-ended banners do
            // not, and then a tap simply dismisses rather than opening an unrelated page.
            if let incidentID, let url = URL(string: "https://status.claude.com/incidents/\(incidentID)") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
        completionHandler()
    }

    // MARK: - Unfollow (off the main actor)

    /// Clear the persisted subscription from UN's own queue.
    ///
    /// Writes the same key/encoding as `PersistedConfig.episodeSubscription`, which cannot be called
    /// from here (it is `@MainActor`). `UserDefaults` is thread-safe, so the write itself is fine; the
    /// re-render hops to the main actor.
    private func unfollow() {
        if let data = try? JSONEncoder().encode(EpisodeSubscription.none) {
            UserDefaults.standard.set(data, forKey: Self.subscriptionKey)
        }
        AppLogger.lifecycle.info("incident: unfollowed from a banner action")
        Task { @MainActor [onUnfollowed] in onUnfollowed() }
    }

    /// Must match `PersistedConfig.Key.episodeSubscription` — that enum is private to its file, and
    /// this queue cannot reach `PersistedConfig` anyway.
    private static let subscriptionKey = "episodeSubscription"
}
