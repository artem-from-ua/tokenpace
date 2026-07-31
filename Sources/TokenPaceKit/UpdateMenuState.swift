import Foundation

// MARK: - UpdateMenuState

/// The single popup menu item that carries every non-critical update signal (#130) — a pure state
/// machine, no clock, no I/O, unit-tested with literals (ADR-0009). Replaces the noisy triple channel
/// of ADR-0025/0033 (system banner + blue-dot menu item + Settings "Download" line) with **one**
/// dropdown item whose colour and text depend on context. There are no macOS notifications; the goal
/// is to interrupt and clutter as little as possible until the App Store build lands (where updates
/// are the store's job).
///
/// The item's click target is always the releases page — the state only changes the **dot colour**
/// and **wording**. Keeping the semantics here (an ``Item`` case) and the human strings + colours in
/// the view mirrors ``ServiceStatus`` (its `word`/`dotColor` live in `PopupViewController`): the kit
/// says *what* the item means, the view decides how it reads (ADR-0009/0013).
public enum UpdateMenuState {

    /// What the single update menu item should show, in priority order. `hidden` means no item (and no
    /// separator) at all. The four `shown` cases map 1:1 to the priority table in #130; the view turns
    /// each into a dot colour + label.
    public enum Item: Sendable, Equatable {
        /// No newer version is known **and** no unseen "what's new" is pending — nothing to surface.
        case hidden
        /// A newer version exists but the automatic install of *this* tag already failed
        /// (`lastFailedInstallVersion == latest`), so it will not be retried — red, "update failed".
        case updateFailed
        /// A newer version exists and automatic install is **off** — blue, "New version available".
        case updateAvailable
        /// A newer version exists, automatic install is **on**, but the install is **deferred**
        /// (battery / metered network / low disk) — blue, "Update pending".
        case updatePending
        /// The installed build **is** the newest, and its successful auto-update has not been seen yet
        /// (`pendingWhatsNewVersion` set) — blue, "What's new".
        case whatsNew
    }

    /// Decide which single item (if any) the update menu should show.
    ///
    /// The four visible cases are strictly prioritized, and **any** version newer than the installed
    /// build (cases 1–3) *pre-empts* "what's new" (case 4): "what's new" appears only when the
    /// installed build is already the newest. So a user who never clicked "what's new" before a newer
    /// release shipped simply sees "New version available", not both.
    ///
    /// While an auto-install is actively in flight (auto on, newer, not deferred, not yet failed) the
    /// item is **hidden** — the download/verify/replace happens silently, and the item only reappears
    /// as `whatsNew` after the relaunch, or as `updateFailed` if it failed.
    ///
    /// - Parameters:
    ///   - installedVersion: The running build's version (`TokenPaceKit.version`).
    ///   - latestKnownVersion: The newest release tag the last check surfaced, or `nil` if none is
    ///     known / the build is current.
    ///   - autoInstallEnabled: `PersistedConfig.installUpdatesAutomatically`.
    ///   - installDeferred: Whether the auto-install of the newer release is currently deferred by an
    ///     environment gate (battery / metered / disk) — from `UpdateInstallDecision.defer…`. Only
    ///     meaningful when `autoInstallEnabled` and a newer version exists.
    ///   - lastFailedInstallVersion: The tag whose auto-install already failed and won't be retried
    ///     (`PersistedConfig.lastFailedInstallVersion`), or `nil`.
    ///   - pendingWhatsNewVersion: The tag of a successful auto-update not yet acknowledged by the user
    ///     (`PersistedConfig.pendingWhatsNewVersion`), or `nil`.
    public static func evaluate(
        installedVersion: String,
        latestKnownVersion: String?,
        autoInstallEnabled: Bool,
        installDeferred: Bool,
        lastFailedInstallVersion: String?,
        pendingWhatsNewVersion: String?
    ) -> Item {
        // Is there a release strictly newer than what is installed? Cases 1–3 all require this, and it
        // is what pre-empts "what's new" (4). A `nil`/unparsable/older tag is "no newer version".
        let hasNewer = latestKnownVersion.map {
            UpdateComparison.isNewer(tag: $0, than: installedVersion)
        } ?? false

        if hasNewer {
            let latest = latestKnownVersion!   // non-nil whenever hasNewer is true
            // 1. Auto-install of *this* tag failed — red, and it won't retry (a newer tag would).
            if let failed = lastFailedInstallVersion, sameVersion(failed, latest) {
                return .updateFailed
            }
            // 2. Automatic install off — a plain "available" signal (the user installs manually).
            guard autoInstallEnabled else { return .updateAvailable }
            // 3. Auto on but deferred by an environment gate — "pending".
            if installDeferred { return .updatePending }
            // Auto on, not deferred, not failed → the install is (or will be) running silently. No item
            // while it is in flight; it reappears as `whatsNew` after relaunch, or `updateFailed`.
            return .hidden
        }

        // 4. Installed build is the newest. Surface "what's new" once, until the user opens it (which
        //    clears the pending marker) or a newer release pre-empts it (handled by `hasNewer` above).
        if pendingWhatsNewVersion != nil { return .whatsNew }

        return .hidden
    }

    /// Whether two version tags denote the same release, compared on their parsed `MAJOR.MINOR.PATCH`
    /// so a `v`-prefixed tag and a bare one line up (`"v0.35.0"` == `"0.35.0"`). Falls back to a raw
    /// string compare when either side does not parse — an unparsable pair is only "same" if identical.
    public static func sameVersion(_ a: String, _ b: String) -> Bool {
        if let va = SemanticVersion(a), let vb = SemanticVersion(b) { return va == vb }
        return a == b
    }
}
