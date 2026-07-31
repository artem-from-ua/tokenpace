import Foundation
import TokenPaceKit

// MARK: - ProdEnvFlag

/// The shared resolver for the handful of `TOKENPACE_*` presence-flags that must be honoured even in a
/// **login/GUI launch** — where launchd starts the `.app` binary directly (`SMAppService`, Finder, Dock,
/// Launchpad) with **no shell in between**, so a plain `export TOKENPACE_FOO=1` in `~/.zshrc` never
/// reaches `ProcessInfo.processInfo.environment`.
///
/// Each flag is resolved the same way (previously duplicated ad-hoc for `TOKENPACE_GH_AUTH`):
///
/// 1. **`ProcessInfo` first** — set when the app is launched from a terminal, or via `launchctl setenv`.
///    This is synchronous and always consulted, on every read, so a terminal/`launchctl` launch is
///    honoured immediately with zero startup cost.
/// 2. **Login-shell fallback** via ``ShellEnvironment`` (`zsh -l -i -c`, sources `~/.zprofile` + full
///    `~/.zshrc`). This is a **subprocess** (sub-second typically, capped at 5 s), so it must never run
///    on a hot path or block launch. It is therefore run **once, off-main, at startup** by ``warmUp()``
///    and its result cached; synchronous reads before warm-up completes see only the `ProcessInfo` value.
///
/// ### Usage contract
///
/// - Call ``warmUp(then:)`` exactly once, early in `applicationDidFinishLaunching`. The optional
///   completion runs on the main actor after the shell probe finishes, so the app can re-render or
///   rebuild anything gated on a flag (e.g. the dev-tools menu item, an override-driven repaint).
/// - Read a flag anywhere with ``isEnabled(_:)`` — safe on any thread, non-blocking. On the draw hot
///   path it is a dictionary lookup plus an env read; before warm-up it simply reflects `ProcessInfo`.
///
/// Adding a future prod-visible flag is one line in ``all`` — no new resolver, no new plumbing.
enum ProdEnvFlag: String, CaseIterable {
    /// Enables the `gh`-subprocess update path for the still-private repo (#37, ADR-0025).
    case ghAuth = "TOKENPACE_GH_AUTH"
    /// Unlocks the ⌥-revealed "Development tools…" menu item and the live colour tuner (#185).
    case devTools = "TOKENPACE_DEVTOOLS"

    /// Every flag warmed up at startup. New prod-visible flags are added here — nothing else changes.
    static var all: [ProdEnvFlag] { allCases }

    // MARK: Cache

    /// Login-shell probe results, keyed by flag. `nil` for a flag means "not yet warmed up"; a present
    /// `false` means the probe ran and the var was unset there too. Guarded by `lock` — read from any
    /// thread (draw path, poll), written once by ``warmUp(then:)``.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var shellResults: [ProdEnvFlag: Bool] = [:]

    // MARK: Reads

    /// True when the flag is present (non-empty) in `ProcessInfo`, or — once warm-up has run — in the
    /// login shell's rc files. Non-blocking and thread-safe. Before ``warmUp(then:)`` completes this
    /// reflects only `ProcessInfo`, so a login-launched app briefly reads `false` until the probe lands.
    static func isEnabled(_ flag: ProdEnvFlag) -> Bool {
        if let value = ProcessInfo.processInfo.environment[flag.rawValue], !value.isEmpty {
            return true
        }
        return lock.withLock { shellResults[flag] ?? false }
    }

    // MARK: Warm-up

    /// Probe the login shell for every flag once, off the main thread, then invoke `completion` on the
    /// main actor. Only flags absent from `ProcessInfo` are probed (the sync path already covers those,
    /// and each probe is a subprocess). Idempotent enough for a single startup call; not meant to be
    /// re-run.
    static func warmUp(then completion: @escaping @MainActor () -> Void = {}) {
        // Which flags still need the shell fallback — the ones ProcessInfo didn't already resolve.
        let pending = all.filter { ProcessInfo.processInfo.environment[$0.rawValue].map(\.isEmpty) ?? true }
        guard !pending.isEmpty else {
            Task { @MainActor in completion() }
            return
        }
        Task.detached(priority: .utility) {
            var resolved: [ProdEnvFlag: Bool] = [:]
            for flag in pending {
                let found = (ShellEnvironment.value(for: flag.rawValue).map { !$0.isEmpty }) ?? false
                resolved[flag] = found
                if found {
                    AppLogger.lifecycle.notice(
                        "env: \(flag.rawValue, privacy: .public) found in login shell env")
                }
            }
            lock.withLock {
                for (flag, found) in resolved { shellResults[flag] = found }
            }
            await MainActor.run { completion() }
        }
    }
}
