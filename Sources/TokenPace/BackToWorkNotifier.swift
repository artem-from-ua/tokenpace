import Foundation
import UserNotifications
import TokenPaceKit

// MARK: - BackToWorkNotifier

/// Thin `UserNotifications` glue for the "Back to work!" notification (#160) — the side-effecting half
/// of the feature whose pure decisions live in `WorkAvailability` + `NotificationSchedule`
/// (`TokenPaceKit`). `UNUserNotificationCenter.current()` is a system singleton, not injectable, so
/// this stays in the executable target and is verified manually (ADR-0009/0023).
///
/// The edge detection (blocked→unblocked) and the quiet-hours evaluation happen in the caller
/// (`AppDelegate`) using the pure Kit types; this type only *requests authorization* and *posts*, so
/// the impure surface stays as small as possible.
///
/// Local notifications need **no** entitlement and **no** Info.plist key — only a valid bundle
/// identifier, which the shipped `.app` has (`com.artem-n.tokenpace`). A bare `swift run` binary has
/// no real bundle, so `UNUserNotificationCenter` cannot authorize there; every call degrades
/// gracefully (never crashes) and the Settings hint tells the user the feature needs the installed app
/// (mirrors launch-at-login / auto-install, which are also `.app`-only).
@MainActor
enum BackToWorkNotifier {

    /// The reported authorization status for the app, for the Settings hint. `.dev` is the synthetic
    /// state for a non-bundle `swift run` build where authorization is impossible.
    enum AuthState {
        case dev
        case authorized
        case denied
        case notDetermined
    }

    private static var center: UNUserNotificationCenter { .current() }

    /// Whether local notifications can work at all in this build. False on a bare `swift run` binary.
    static var isSupported: Bool { LaunchAtLoginController.isAppBundle }

    /// Ask for alert+sound authorization if it has not been decided yet. Called lazily the first time
    /// the user enables the feature (never at launch — this is an opt-in feature and we must not prompt
    /// users who never turn it on). No-op on a dev build. The `completion` reports the resolved state
    /// so Settings can refresh its hint.
    static func requestAuthorizationIfNeeded(completion: @escaping (AuthState) -> Void) {
        guard isSupported else {
            AppLogger.lifecycle.info("back-to-work: authorization dev (no bundle)")
            completion(.dev)
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

    /// Query the current authorization state (async → main) for the Settings hint. Returns `.dev`
    /// immediately on a non-bundle build.
    static func currentAuthState(completion: @escaping (AuthState) -> Void) {
        guard isSupported else { completion(.dev); return }
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
    /// delivers. No-op (logged) on a dev build or when not authorized.
    static func postBackToWork() {
        guard isSupported else { return }
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else {
                AppLogger.lifecycle.info("back-to-work: not authorized, skipping")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Back to work!"
            content.body = "Your Claude usage limit has reset — you're good to go."
            content.sound = .default
            // Fresh identifier so successive unblock edges each surface their own banner.
            let request = UNNotificationRequest(
                identifier: "backToWork-\(UUID().uuidString)",
                content: content,
                trigger: nil   // deliver now
            )
            center.add(request) { error in
                if let error {
                    AppLogger.lifecycle.error("back-to-work: post failed \(error.localizedDescription, privacy: .public)")
                } else {
                    AppLogger.lifecycle.info("back-to-work: edge detected, posting notification")
                }
            }
        }
    }
}
