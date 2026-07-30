import Foundation
import UserNotifications
import TokenPaceKit

// MARK: - BackToWorkNotifier

/// Thin `UserNotifications` glue for the local notifications — the "Back to work!" banner (#160) and
/// the "Now using Extra Usage Credit" banner — the side-effecting half of features whose pure decisions
/// live in `WorkAvailability` / `ExtraUsageOnset` + `NotificationSchedule` (`TokenPaceKit`).
/// `UNUserNotificationCenter.current()` is a system singleton, not injectable, so this stays in the
/// executable target and is verified manually (ADR-0009/0023). Both notifications share one
/// authorization grant (`[.alert, .sound]`) — the first feature the user enables requests it.
///
/// The edge detection (blocked→unblocked) and the quiet-hours evaluation happen in the caller
/// (`AppDelegate`) using the pure Kit types; this type only *requests authorization* and *posts*, so
/// the impure surface stays as small as possible.
///
/// **Actor isolation.** This enum is deliberately **not** `@MainActor`: `UNUserNotificationCenter`
/// invokes its completion handlers on a private background queue, and a `@MainActor`-isolated closure
/// run there trips a `dispatch_assert_queue` fatal error (SIGTRAP). So the `UNUserNotificationCenter`
/// calls and their handlers run wherever UN calls them (the center is thread-safe), and we hop to the
/// main actor **only** to invoke the caller's `completion`, which touches `@MainActor` UI state.
///
/// Local notifications need **no** entitlement and **no** Info.plist key — only a valid bundle
/// identifier, which the shipped `.app` has (`com.artem-n.tokenpace`). A bare `swift run` binary has
/// no real bundle, so `UNUserNotificationCenter` cannot authorize there; every call degrades
/// gracefully (never crashes) and the Settings hint tells the user the feature needs the installed app
/// (mirrors launch-at-login / auto-install, which are also `.app`-only).
enum BackToWorkNotifier {

    /// The reported authorization status for the app, for the Settings hint. `.dev` is the synthetic
    /// state for a non-bundle `swift run` build where authorization is impossible.
    enum AuthState: Sendable {
        case dev
        case authorized
        case denied
        case notDetermined
    }

    private static var center: UNUserNotificationCenter { .current() }

    /// Whether local notifications can work at all in this build. False on a bare `swift run` binary.
    /// `LaunchAtLoginController.isAppBundle` only reads `Bundle.main`, which is safe off the main actor.
    static var isSupported: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    /// Ask for alert+sound authorization if it has not been decided yet. Called lazily the first time
    /// the user enables the feature (never at launch — this is an opt-in feature and we must not prompt
    /// users who never turn it on). No-op on a dev build. The `completion` is always invoked on the
    /// **main actor** so callers can update UI state directly.
    static func requestAuthorizationIfNeeded(completion: @escaping @MainActor (AuthState) -> Void) {
        guard isSupported else {
            AppLogger.lifecycle.info("back-to-work: authorization dev (no bundle)")
            Task { @MainActor in completion(.dev) }
            return
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                AppLogger.lifecycle.error("back-to-work: authorization error \(error.localizedDescription, privacy: .public)")
            }
            AppLogger.lifecycle.info("back-to-work: authorization \(granted ? "granted" : "denied", privacy: .public)")
            Task { @MainActor in completion(granted ? .authorized : .denied) }
        }
    }

    /// Query the current authorization state for the Settings hint. Returns `.dev` immediately on a
    /// non-bundle build. `completion` is invoked on the **main actor**.
    static func currentAuthState(completion: @escaping @MainActor (AuthState) -> Void) {
        guard isSupported else {
            Task { @MainActor in completion(.dev) }
            return
        }
        center.getNotificationSettings { settings in
            let state: AuthState
            switch settings.authorizationStatus {
            case .authorized, .provisional: state = .authorized
            case .denied:                   state = .denied
            case .notDetermined:            state = .notDetermined
            @unknown default:               state = .notDetermined
            }
            Task { @MainActor in completion(state) }
        }
    }

    /// Post the "Back to work!" banner immediately. The caller has already confirmed the
    /// blocked→unblocked edge and passed the quiet-hours gate; this only checks authorization and
    /// delivers. No-op (logged) on a dev build or when not authorized. All work runs on UN's own
    /// queue — nothing here touches `@MainActor` state.
    static func postBackToWork() {
        post(kind: "back-to-work", idPrefix: "backToWork",
             title: "Back to work!",
             body: "Your Claude usage limit has reset — you're good to go.")
    }

    /// Post the "Now using Extra Usage Credit" banner immediately. The caller has already confirmed the
    /// not-spending→spending edge and passed the quiet-hours gate; this only checks authorization and
    /// delivers. The `body` (which carries the spent amount and, if set, the limit) is built by the pure
    /// `ExtraUsageOnset.bannerBody(for:)`. No-op (logged) on a dev build or when not authorized.
    static func postExtraUsage(body: String) {
        post(kind: "extra-usage", idPrefix: "extraUsage",
             title: "Now using Extra Usage Credit", body: body)
    }

    /// Shared authorization-gated post. Runs entirely on UN's own queue (nothing here touches
    /// `@MainActor` state); a fresh identifier per call so successive edges each surface their own banner.
    private static func post(kind: String, idPrefix: String, title: String, body: String) {
        guard isSupported else { return }
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else {
                AppLogger.lifecycle.info("\(kind, privacy: .public): not authorized, skipping")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "\(idPrefix)-\(UUID().uuidString)",
                content: content,
                trigger: nil   // deliver now
            )
            center.add(request) { error in
                if let error {
                    AppLogger.lifecycle.error("\(kind, privacy: .public): post failed \(error.localizedDescription, privacy: .public)")
                } else {
                    AppLogger.lifecycle.info("\(kind, privacy: .public): edge detected, posting notification")
                }
            }
        }
    }
}
