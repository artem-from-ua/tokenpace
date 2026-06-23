import Foundation

// MARK: - LaunchAtLogin

/// Pure, AppKit-free decision core for the launch-at-login feature (#14).
///
/// `SMAppService` is a system singleton that cannot be injected or mocked, so the code that *calls*
/// `register()`/`unregister()`/`status` must live in the `cc-timer` glue target
/// (`LaunchAtLoginController`). What *can* be tested — and reused in Phase 2 — is the semantic
/// status mirror plus the handful of decisions made against it. Keeping those here follows the same
/// pure-core / thin-shell split as `UsageHealth` and `AdaptiveCadence` (ADR-0010, ADR-0011).
///
/// The enum deliberately does **not** import `ServiceManagement`: it is a localisation- and
/// platform-free value type, so `CCTimerKit` stays dependency-light and the predicates are unit
/// testable without a live login-item registration.
public enum LaunchAtLogin {

    /// Semantic mirror of `SMAppService.Status`, decoupled from `ServiceManagement` so decisions and
    /// (future) UI can switch over it without linking the system framework.
    public enum Status: Equatable, Sendable {
        /// The login item is registered and enabled — the app will launch at login (`.enabled`).
        case registered
        /// Not yet registered — the candidate for opt-out auto-registration (`.notRegistered`).
        case notRegistered
        /// Registered but the user disabled it in System Settings → Login Items; needs manual
        /// approval there (`.requiresApproval`).
        case requiresApproval
        /// The service could not be found — typically a bare `swift run` binary with no valid app
        /// bundle, or a registration that is gone (`.notFound`).
        case notFound
    }

    /// Opt-out policy: auto-register at first launch **only** when the item is not registered yet.
    /// `requiresApproval`/`registered`/`notFound` are left untouched — the user or the system has
    /// already decided, and re-registering would either be a no-op or override an explicit choice.
    public static func shouldRegisterOnFirstLaunch(_ status: Status) -> Bool {
        status == .notRegistered
    }

    /// The checkbox state to show in the Settings… window: on **only** when the item is actually
    /// registered. `requiresApproval` reads as off, because launch-at-login is not in effect until
    /// the user re-enables it in System Settings.
    public static func toggleState(for status: Status) -> Bool {
        status == .registered
    }

    /// Whether the app should send the user to System Settings → Login Items: true **only** for
    /// `requiresApproval`, where the toggle cannot take effect without a manual approval there.
    public static func needsSystemSettings(_ status: Status) -> Bool {
        status == .requiresApproval
    }

    /// Whether launch-at-login can be controlled at all in the current run context. `.notFound`
    /// means the OS has no registerable login item for this code identity — a bare `swift run`
    /// binary (no app bundle) or an ad-hoc-signed bundle that `SMAppService` rejects. In that case
    /// the toggle is meaningless: the UI disables it and explains that a properly installed build is
    /// needed (ADR-0012 §"best-effort на unsigned").
    public static func isAvailable(_ status: Status) -> Bool {
        status != .notFound
    }
}
