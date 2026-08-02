import Foundation

// MARK: - CalmColorMode (#224)

/// How much of the **non-critical** pacing palette the menu-bar widget mutes to a neutral white — a
/// single three-way choice that replaces the old `calmMenuBarColors` + `workHarderColors` pair (#105,
/// ADR-0061). The name describes **which colours are muted**: the strong warnings (orange/red) always
/// stay coloured; this only governs the calm side.
///
/// - ``off`` — nothing is muted; every state keeps its colour (the loud look).
/// - ``yellowGreen`` — the calm greens/yellows mute to white, but the far-behind **blue** stays
///   coloured (a nudge that there's headroom). Equivalent to the old "calm on + work harder on".
/// - ``yellowGreenBlue`` — the calm greens/yellows **and** the far-behind blue all mute. Equivalent to
///   the old "calm on + work harder off" (the quietest look).
///
/// The render layer (`StatusItemView`) reads the two derived flags ``mutesCalm`` and ``mutesBlue``
/// rather than the raw case, so `calmedGapColor`'s existing logic is unchanged — it just sources the
/// two booleans from here instead of from two separate persisted keys.
///
/// Stored raw-string in `UserDefaults` with a forward-compatible decode (an unknown raw falls back to
/// ``yellowGreenBlue``, the shipped calm default), mirroring `BarStyle` / `ResetCountdownMode`.
public enum CalmColorMode: String, Sendable, Equatable, Codable, CaseIterable {
    /// Nothing muted — every state keeps its colour.
    case off = "off"
    /// Greens/yellows muted; far-behind blue stays coloured.
    case yellowGreen = "yellowGreen"
    /// Greens/yellows and far-behind blue all muted (the quietest).
    case yellowGreenBlue = "yellowGreenBlue"

    /// Whether the calm greens/yellows are muted to white. True for both muting modes.
    public var mutesCalm: Bool { self != .off }

    /// Whether the far-behind **blue** is muted too. Only ``yellowGreenBlue`` mutes it; ``yellowGreen``
    /// keeps blue coloured (the old "work harder" behaviour is `mutesBlue == false`).
    public var mutesBlue: Bool { self == .yellowGreenBlue }

    /// Forward-compatible decode: an unrecognised raw string falls back to ``yellowGreenBlue`` (the
    /// shipped calm default) instead of throwing. Mirrors `BarStyle` / `ResetCountdownMode`.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CalmColorMode(rawValue: raw) ?? .yellowGreenBlue
    }
}
