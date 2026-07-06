import Foundation
import TokenPaceKit
import ServiceManagement

// MARK: - LaunchAtLoginController

/// Thin `ServiceManagement` glue for launch-at-login (#14): the side-effecting half of the feature
/// whose pure decisions live in `LaunchAtLogin` (`TokenPaceKit`). `SMAppService.mainApp` is a system
/// singleton — not injectable — so this stays in the executable target and is verified manually,
/// like `PollingShell` (ADR-0011).
///
/// Registration is **best-effort**: `SMAppService` is only fully reliable on a *signed* app bundle.
/// On an unsigned build (a bare `swift run` binary, or an ad-hoc `.app`) `register()` may throw —
/// callers wrap it in `do/catch` and log the result rather than crash, exactly as the ticket and
/// SPEC anticipate.
@MainActor
enum LaunchAtLoginController {
    private static var service: SMAppService { .mainApp }

    /// The current registration state, mapped to the framework-free `LaunchAtLogin.Status` so the
    /// decision predicates and UI never touch `ServiceManagement`. `@unknown default` collapses any
    /// future SDK case to `.notFound` (the conservative "not active" reading).
    static func currentStatus() -> LaunchAtLogin.Status {
        switch service.status {
        case .enabled:          return .registered
        case .notRegistered:    return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .notFound:         return .notFound
        @unknown default:       return .notFound
        }
    }

    /// Whether the running process is a proper `.app` bundle (not a bare `swift run` binary). Used
    /// to gate *opt-out* auto-registration: registering a login item without the user's consent is
    /// only appropriate for the shipped product, not for every `swift run` during development —
    /// which, being ad-hoc-signed, `SMAppService` will happily register at a `.build/…` path and so
    /// pollute the user's Login Items (#69). A `swift run` binary has a `Bundle.main` whose
    /// `bundleIdentifier` is `nil` and whose path is the executable itself, not a `.app`; a real
    /// bundle has a non-nil identifier and a `.app` wrapper. This gates auto-registration only — the
    /// Settings toggle stays clickable on a dev build, letting `register()` adjudicate on demand.
    static var isAppBundle: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Register the main app as a login item. Throws on an unsigned/invalid bundle — best-effort.
    static func enable() throws { try service.register() }

    /// Remove the login-item registration. Throws are surfaced to the caller for logging.
    static func disable() throws { try service.unregister() }

    /// Open System Settings → General → Login Items so the user can approve a `.requiresApproval`
    /// item that cannot be re-enabled programmatically.
    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
