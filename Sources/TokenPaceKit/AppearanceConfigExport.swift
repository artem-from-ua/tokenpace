import Foundation

// MARK: - AppearancePresetValues + Codable (#257)

/// JSON coding for the Appearance value set — the **reading** half of the clipboard export
/// (``AppearanceConfigExport``): it lets a dump round-trip back into a value set.
///
/// The **writing** half does not go through this conformance. `Codable` cannot control key order
/// (the keyed container is backed by an unordered dictionary, so the order varies between runs), and
/// the export's whole point is that keys follow the **top-to-bottom order of the controls in
/// Settings → Appearance** so a pasted dump reads line-by-line against the pane. `AppearanceConfigExport.json(values:preset:appVersion:)`
/// therefore writes the text directly; see the note there.
///
/// The `CodingKeys` below are still listed in pane order — decoding ignores order, but keeping the
/// two lists visually identical makes a mismatch obvious. **When you add an Appearance option**, add
/// it here *and* in the emitting list, both at the position matching its control in the pane — never
/// appended at the end. `AppearanceConfigExportTests` asserts the exact emitted sequence.
extension AppearancePresetValues: Codable {

    /// The export keys, in **pane order**. The trailing comments give the control's on-screen label,
    /// so the mapping can be checked against the pane without opening it.
    enum CodingKeys: String, CodingKey {
        case menuBarStyle               // Menu Bar Widget → "Bar style"
        case calmColorMode              // "Calm non-critical colors"
        case awaitingInputInMenuBar     // "Show awaiting-input icon in the menu bar"
        case pauseHidesBars             // "Pause icon hides bars"
        case showExtraUsage             // "Show extra-usage credits icon"
        case hideCalmSevenDayBar        // "Show 7-day bar when calm" (stored inverted, as a *hide* flag)
        case resetCountdownModeMenuBar  // "Show reset countdown"
        case showServiceStatusDot       // "Show service status dot on issues"
        case dropdownStyle              // Dropdown Widget → "Bar style"
        case modelLimitsVisibility      // "Show model & service limits"
        case extraUsageVisibility       // "Show extra usage"
        case showTicks                  // "Show ticks on bars"

        /// The pre-#329 single "Bar style" key, read-only. Not emitted — it exists so a config
        /// exported by an older build still imports, splitting into the two per-surface keys via
        /// `BarStyle.legacySurfaceStyles(for:)`.
        case barStyle

        // A retired `farBehindInterval` key needs no case at all: `Codable` ignores unknown JSON keys,
        // so a config exported before the far-behind width was fixed still imports cleanly.
    }

    /// Written out (rather than left to the compiler) only so the key list appears in pane order in
    /// one more place. It does **not** control the output order — nothing in `Codable` can; the
    /// export's order comes from `AppearanceConfigExport.json(values:preset:appVersion:)`.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(menuBarStyle, forKey: .menuBarStyle)
        try c.encode(calmColorMode, forKey: .calmColorMode)
        try c.encode(awaitingInputInMenuBar, forKey: .awaitingInputInMenuBar)
        try c.encode(pauseHidesBars, forKey: .pauseHidesBars)
        try c.encode(showExtraUsage, forKey: .showExtraUsage)
        try c.encode(hideCalmSevenDayBar, forKey: .hideCalmSevenDayBar)
        try c.encode(resetCountdownModeMenuBar, forKey: .resetCountdownModeMenuBar)
        try c.encode(showServiceStatusDot, forKey: .showServiceStatusDot)
        try c.encode(dropdownStyle, forKey: .dropdownStyle)
        try c.encode(modelLimitsVisibility, forKey: .modelLimitsVisibility)
        try c.encode(extraUsageVisibility, forKey: .extraUsageVisibility)
        try c.encode(showTicks, forKey: .showTicks)
    }

    /// Decoding is order-independent (JSON objects are unordered by definition), so this only has to
    /// mirror the key names. Present so a dump round-trips back into a value set — the guarantee that
    /// the export really describes the config.
    ///
    /// The one place it does more than mirror: a config exported **before #329** carries a single
    /// `barStyle` key instead of the per-surface pair. It is split here — the level that knows which
    /// key belongs to which surface — through `BarStyle.legacySurfaceStyles(for:)`, the same call the
    /// `UserDefaults` migration makes, so importing an old dump and upgrading in place agree. A
    /// `"mixed"` dump therefore lands as Pressure + Progress, exactly what that build drew.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        let legacy = try c.decodeIfPresent(String.self, forKey: .barStyle)
            .flatMap(BarStyle.legacySurfaceStyles(for:))
        let menuBarStyle = try c.decodeIfPresent(BarStyle.self, forKey: .menuBarStyle)
            ?? legacy?.menuBar ?? AppearancePreset.defaultValues.menuBarStyle
        let dropdownStyle = try c.decodeIfPresent(BarStyle.self, forKey: .dropdownStyle)
            ?? legacy?.dropdown ?? AppearancePreset.defaultValues.dropdownStyle

        self.init(
            calmColorMode: try c.decode(CalmColorMode.self, forKey: .calmColorMode),
            hideCalmSevenDayBar: try c.decode(Bool.self, forKey: .hideCalmSevenDayBar),
            pauseHidesBars: try c.decode(Bool.self, forKey: .pauseHidesBars),
            showExtraUsage: try c.decode(Bool.self, forKey: .showExtraUsage),
            showServiceStatusDot: try c.decode(Bool.self, forKey: .showServiceStatusDot),
            awaitingInputInMenuBar: try c.decode(Bool.self, forKey: .awaitingInputInMenuBar),
            modelLimitsVisibility: try c.decode(PopupSectionVisibility.self, forKey: .modelLimitsVisibility),
            extraUsageVisibility: try c.decode(PopupSectionVisibility.self, forKey: .extraUsageVisibility),
            resetCountdownModeMenuBar: try c.decode(ResetCountdownMode.self, forKey: .resetCountdownModeMenuBar),
            menuBarStyle: menuBarStyle,
            dropdownStyle: dropdownStyle,
            showTicks: try c.decode(Bool.self, forKey: .showTicks))
    }
}

// MARK: - AppearanceConfigExport (#257)

/// Serializes the live **Appearance** config to pretty-printed JSON for the clipboard — the payload
/// behind the copy button in Settings → Appearance (#257).
///
/// The Appearance surface is combinatorial (`BarStyle` × `CalmColorMode` × `FarBehindInterval` × the
/// toggles), so "it looks wrong on my machine" is more often a config difference than a bug. This
/// makes answering "what does your setup look like?" one click instead of a screenshot tour.
///
/// Deliberately **Appearance-only**, unlike the full `PersistedConfig` dump proposed in #256: these
/// thirteen keys are pure presentation — no filesystem paths, no account names, no working hours —
/// so a dump can be pasted into an issue without reading it first. Widening this to other panes
/// requires a per-key privacy pass first (#256).
///
/// Pure string-building with no I/O or AppKit, so it is unit-testable without a UI; the shell owns
/// only the button and the pasteboard write.
public enum AppearanceConfigExport {

    /// The `preset` value used when the live config matches no named preset — the same "Custom" state
    /// the pane's segmented control shows. A string rather than `null` so the field stays readable and
    /// never disappears from the dump.
    public static let customPresetName = "custom"

    /// Build the clipboard JSON: the app version and active preset as metadata, and the thirteen
    /// Appearance values under `appearance` **in pane order** (see the `Codable` extension above).
    ///
    /// No export timestamp on purpose: it would make two dumps of an unchanged config differ, which
    /// defeats diffing one against another. The app version is what's needed to interpret the values.
    ///
    /// - Parameters:
    ///   - values: the live Appearance config (`PersistedConfig.currentAppearanceValues`, or the
    ///     Settings model's observable mirror of it).
    ///   - preset: the preset the config matches, or `nil` for the Custom state.
    ///   - appVersion: the running marketing version (`TokenPaceKit.version`).
    /// - Returns: pretty-printed JSON with `appearance` keys in pane order.
    ///
    /// ## Why the text is built by hand
    ///
    /// Neither `JSONEncoder` nor `JSONSerialization` can promise key order: both route keyed values
    /// through an unordered dictionary, so the output order is whatever the hash seed produces — it
    /// varies **between runs of the same build**. `.sortedKeys` is the only way to make either of them
    /// deterministic, and that forces the alphabet, which is exactly the order this feature rejects.
    /// A `CodingKeys` list and a hand-written `encode(to:)` do not help for the same reason.
    ///
    /// So the emitting side writes the string directly, one line per key, in pane order. The values
    /// are still escaped through `JSONSerialization` (see ``jsonString(_:)``), and the `Codable`
    /// conformance above remains the *reading* side — a dump round-trips back into a value set.
    public static func json(
        values v: AppearancePresetValues,
        preset: AppearancePreset?,
        appVersion: String
    ) -> String {
        // Pane order — keep in sync with `CodingKeys` above, `AppearancePane.swift`, and
        // `AppearanceConfigExportTests`. Insert a new option at its on-screen position; never append.
        let appearance: [(String, String)] = [
            ("menuBarStyle", jsonString(v.menuBarStyle.rawValue)),
            ("calmColorMode", jsonString(v.calmColorMode.rawValue)),
            ("awaitingInputInMenuBar", jsonBool(v.awaitingInputInMenuBar)),
            ("pauseHidesBars", jsonBool(v.pauseHidesBars)),
            ("showExtraUsage", jsonBool(v.showExtraUsage)),
            ("hideCalmSevenDayBar", jsonBool(v.hideCalmSevenDayBar)),
            ("resetCountdownModeMenuBar", jsonString(v.resetCountdownModeMenuBar.rawValue)),
            ("showServiceStatusDot", jsonBool(v.showServiceStatusDot)),
            ("dropdownStyle", jsonString(v.dropdownStyle.rawValue)),
            ("modelLimitsVisibility", jsonString(v.modelLimitsVisibility.rawValue)),
            ("extraUsageVisibility", jsonString(v.extraUsageVisibility.rawValue)),
            ("showTicks", jsonBool(v.showTicks)),
        ]

        // Two-space indent and `" : "` around the colon match `JSONSerialization.prettyPrinted`, so
        // this dump looks like the one the Troubleshoot window shows.
        let body = appearance
            .map { "    \"\($0.0)\" : \($0.1)" }
            .joined(separator: ",\n")

        return """
        {
          "appVersion" : \(jsonString(appVersion)),
          "preset" : \(jsonString(preset?.rawValue ?? customPresetName)),
          "appearance" : {
        \(body)
          }
        }
        """
    }

    /// A JSON string literal, escaped by `JSONSerialization` rather than by hand — the values here are
    /// enum raw values and a version string, but escaping is not something to hand-roll on a surface
    /// that might later carry free text.
    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return text
    }

    private static func jsonBool(_ value: Bool) -> String { value ? "true" : "false" }
}
