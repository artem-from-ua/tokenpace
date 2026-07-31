import AppKit
import Foundation

/// The single source the two `Palette` enums read every colour through, so the dev color tuner (#185)
/// can override any role live and see the menu-bar icon and popup repaint immediately.
///
/// **Gated by the `devToolsEnabled` defaults key.** When it is unset/false, ``devToolsEnabled`` is
/// false and ``color(_:)`` returns the role's shipped ``ColorRole/defaultColor`` unconditionally — the
/// override dictionary is never consulted, so a normal launch pays nothing on the draw hot path and
/// cannot be perturbed. The tuner window and its menu item are gated on the same flag, so overrides can
/// only ever be set when the flag is on. Independent of build type (dev / notarized / release): the
/// gate is the defaults key, not `#if DEBUG` or the bundle kind.
///
/// The flag lives in `UserDefaults` (`PersistedConfig.devToolsEnabled`), so a GUI/login launch
/// (`SMAppService`, Finder, Dock) — which gets no shell environment — reads it just the same as a
/// terminal launch. Enable it on the installed `.app` with
/// `defaults write com.artem-n.tokenpace devToolsEnabled -bool true`.
///
/// Overrides are **ephemeral** — held in memory only, never persisted. Quitting resets everything.
@MainActor
final class ColorStore {

    static let shared = ColorStore()

    /// True when the `devToolsEnabled` defaults key is set to `true` (`PersistedConfig.devToolsEnabled`).
    /// Read straight from `UserDefaults`, so a login/GUI launch honours it exactly like a terminal
    /// launch — no shell probe, no warm-up delay. Non-blocking: safe to read on the draw hot path.
    /// Enable with `defaults write com.artem-n.tokenpace devToolsEnabled -bool true`.
    static var devToolsEnabled: Bool { PersistedConfig.devToolsEnabled }

    private var overrides: [ColorRole: NSColor] = [:]

    /// Invoked after any mutation (set / reset / resetAll) so the owner can repaint both surfaces.
    /// Wired by `AppDelegate` to `reRenderForCurrentTime()`.
    var onChange: (() -> Void)?

    private init() {}

    /// The live colour for a role: the override when dev-tools are on and one is set, else the default.
    /// On the hot draw path when dev-tools are off this is a single Bool check plus the default.
    func color(_ role: ColorRole) -> NSColor {
        guard Self.devToolsEnabled else { return role.defaultColor }
        return overrides[role] ?? role.defaultColor
    }

    /// Whether the role currently carries a (non-default) override.
    func isModified(_ role: ColorRole) -> Bool {
        Self.devToolsEnabled && overrides[role] != nil
    }

    /// Any role currently overridden — drives the "Reset all" enabled state.
    var hasAnyOverride: Bool { Self.devToolsEnabled && !overrides.isEmpty }

    func set(_ color: NSColor, for role: ColorRole) {
        guard Self.devToolsEnabled else { return }
        overrides[role] = color
        onChange?()
    }

    func reset(_ role: ColorRole) {
        guard overrides.removeValue(forKey: role) != nil else { return }
        onChange?()
    }

    func resetAll() {
        guard !overrides.isEmpty else { return }
        overrides.removeAll()
        onChange?()
    }
}
