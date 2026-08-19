import Foundation

// MARK: - ColorAdvice (#224, renamed in #381)

/// Which pacing states the menu-bar widget keeps **coloured**, and which mute to a neutral white — the
/// single three-way choice behind Settings → Appearance › Menu bar → **"Colors tell me"**.
///
/// Named for the **advice the colour carries**, not for the colours it mutes. The retired
/// `CalmColorMode` (and its `off` / `yellowGreen` / `yellowGreenBlue` cases) described the mechanism —
/// which hues fade — while the reader is choosing what they want to be told:
///
/// - ``slowDown`` — only "you are spending faster than the window allows" stays coloured (orange).
/// - ``slowDownOrSpeedUp`` — that, **plus** "you have spare capacity" (the far-behind blue).
/// - ``howItsGoing`` — nothing mutes; every state keeps its colour.
///
/// The strong warnings are never governed by this choice: orange always stays coloured, and an
/// exhausted window is never drawn as a bar at all (ADR-0091), so red does not arise here.
///
/// ## Scope: pacing bars only
///
/// Since #381 this governs **only** the two pacing bars — still true after #410, which changed the
/// service dot's `degraded` tone to yellow but not who decides it (the dot reads no setting at all).
/// The service-status dot, the credits glyph and
/// the idle "ready to start" pill answer different questions and no longer read it — see
/// `StatusItemView.statusDotTarget` / `creditsIconColor` and the idle branch of `draw(_:)`. That is
/// what makes the row safe to hide under Pressure, where the whole calm side draws as zero and there
/// is nothing left for a colour to say.
///
/// The render layer reads the two derived flags ``mutesCalm`` and ``mutesBlue`` rather than the case
/// itself, so `calmedGapColor`'s logic is unchanged by the rename.
///
/// Stored raw-string in `UserDefaults` under `menuBar.colorsTell`, with a forward-compatible decode:
/// the pre-#381 raws (`off` / `yellowGreen` / `yellowGreenBlue`) resolve through
/// ``legacyRawValues`` rather than falling through to the default, because a silent fallback is how a
/// user's choice gets lost.
public enum ColorAdvice: String, Sendable, Equatable, Codable, CaseIterable {
    /// Only the "spending too fast" orange stays coloured; greens, yellows **and** the far-behind blue
    /// all mute to white. The quietest look (`.chill`).
    case slowDown = "slowDown"
    /// Orange **and** the far-behind blue stay coloured — the blue is the "there is spare capacity"
    /// advice, and it survives here because under Balance/Progress its length saturates: past the middle
    /// of a window a big surplus and a small one draw the same full half, so colour is the only thing
    /// left that distinguishes them. **Default** (`.workHarder`).
    case slowDownOrSpeedUp = "slowDownOrSpeedUp"
    /// Nothing mutes — every state keeps its colour (the loud look, `.controlFreak`).
    case howItsGoing = "howItsGoing"

    /// Whether the calm greens/yellows mute to white. True for both muting modes.
    public var mutesCalm: Bool { self != .howItsGoing }

    /// Whether the far-behind **blue** mutes too. Only ``slowDown`` mutes it; ``slowDownOrSpeedUp``
    /// keeps it coloured, which is the whole difference between those two cases.
    public var mutesBlue: Bool { self == .slowDown }

    /// The pre-#381 raw values, mapped one-to-one onto the current cases. Consulted by ``init(from:)``
    /// **before** the default fallback: resolving a known-old raw through the default would silently
    /// downgrade a stored choice, which is the failure mode a rename must not have.
    ///
    /// Lives here rather than in `PersistedConfig` so it is unit-testable from `TokenPaceKitTests` and
    /// shared by both readers of an old value — the `UserDefaults` migration and
    /// `AppearancePresetValues`' decode of an exported config. Same split `BarStyle.legacyRawValues`
    /// uses.
    public static let legacyRawValues: [String: ColorAdvice] = [
        "yellowGreenBlue": .slowDown,          // greens/yellows *and* blue muted → quietest
        "yellowGreen": .slowDownOrSpeedUp,     // blue stayed coloured
        "off": .howItsGoing,                   // nothing muted
    ]

    /// Forward-compatible decode. A pre-#381 raw resolves through ``legacyRawValues``; anything else
    /// unrecognised falls back to ``slowDown``, the quietest mode — matching the shipped calm default
    /// (`yellowGreenBlue`) that a config written by an unknown build most likely meant.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ColorAdvice(rawValue: raw) ?? ColorAdvice.legacyRawValues[raw] ?? .slowDown
    }
}
