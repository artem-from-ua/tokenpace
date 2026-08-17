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
/// The key enums below are listed in pane order within each surface group — decoding ignores order, but
/// keeping the lists visually identical to the emitter makes a mismatch obvious. **When you add an
/// Appearance option**, add it here *and* in the emitting list, both at the position matching its
/// control in its pane — never appended at the end. `AppearanceConfigExportTests` asserts the exact
/// emitted sequence, group order included.
extension AppearancePresetValues: Codable {

    /// The two surface groups the dump nests its keys under (#381). Grouping mirrors the two child pages
    /// of Settings → Appearance, so a dump can be read against the panes without a key-by-key lookup.
    enum GroupKeys: String, CodingKey {
        case menuBar
        case dropdown
    }

    /// The keys inside the `menuBar` group, in **pane order**. Trailing comments give the control's
    /// on-screen label — each key is that label, so the mapping needs no lookup.
    enum MenuBarKeys: String, CodingKey {
        case style                  // "Style"
        case colorsTell             // "Colors tell me"
        case hideTop5hBar           // "Hide the top 5h bar"
        case showServiceStatusDot   // "Show service status dot"
    }

    /// The keys inside the `dropdown` group, in **pane order**.
    enum DropdownKeys: String, CodingKey {
        case style                  // "Style"
        case showPerModelLimits     // "Show per-model and per-service limits"
        case showExtraUsage         // "Show *Extra usage*"
    }

    /// The **flat** keys of every dump written before #381, read-only. Not emitted; they exist so a
    /// config exported by an older build still imports.
    ///
    /// Three vintages are covered, each with its own mapping:
    ///
    /// - **pre-#381**: the seven flat keys. Values go through each enum's `legacyRawValues`, so a raw
    ///   like `aboveZero` resolves explicitly rather than falling through to a default.
    /// - **pre-#329**: a single `barStyle` key stood in for the per-surface pair; split through
    ///   `BarStyle.legacySurfaceStyles(for:)`.
    /// - **pre-ADR-0086**: the boolean `hideCalmSevenDayBar`, mapped through
    ///   `TopBarHiding.migrated(fromLegacyHide:)` — the same call the `UserDefaults` migration makes, so
    ///   importing an old dump and upgrading in place agree.
    ///
    /// Keys retired outright (`farBehindInterval`, `showTicks`, `pauseHidesBars`, `showExtraUsage`,
    /// `awaitingInputInMenuBar`) need no case at all: `Codable` ignores unknown JSON keys.
    enum LegacyFlatKeys: String, CodingKey {
        case menuBarStyle
        case calmColorMode
        case calmBarHiding
        case showServiceStatusDot
        case dropdownStyle
        case modelLimitsVisibility
        case extraUsageVisibility
        case barStyle
        case hideCalmSevenDayBar
    }

    /// Written out (rather than left to the compiler) only so the key list appears in pane order in
    /// one more place. It does **not** control the output order — nothing in `Codable` can; the
    /// export's order comes from `AppearanceConfigExport.json(values:preset:appVersion:)`.
    public func encode(to encoder: Encoder) throws {
        var root = encoder.container(keyedBy: GroupKeys.self)

        var mb = root.nestedContainer(keyedBy: MenuBarKeys.self, forKey: .menuBar)
        try mb.encode(menuBarStyle, forKey: .style)
        try mb.encode(colorsTell, forKey: .colorsTell)
        try mb.encode(hideTop5hBar, forKey: .hideTop5hBar)
        try mb.encode(showServiceStatusDot, forKey: .showServiceStatusDot)

        var dd = root.nestedContainer(keyedBy: DropdownKeys.self, forKey: .dropdown)
        try dd.encode(dropdownStyle, forKey: .style)
        try dd.encode(modelLimitsVisibility, forKey: .showPerModelLimits)
        try dd.encode(extraUsageVisibility, forKey: .showExtraUsage)
    }

    /// Decoding is order-independent (JSON objects are unordered by definition), so this only has to
    /// mirror the key names. Present so a dump round-trips back into a value set — the guarantee that
    /// the export really describes the config.
    ///
    /// The two places it does more than mirror, both for configs exported by older builds:
    ///
    /// - **Before #329** a single `barStyle` key stood in for the per-surface pair. It is split here —
    ///   the level that knows which key belongs to which surface — through
    ///   `BarStyle.legacySurfaceStyles(for:)`, the same call the `UserDefaults` migration makes, so
    ///   importing an old dump and upgrading in place agree. A `"mixed"` dump therefore lands as
    ///   Pressure + Progress, exactly what that build drew.
    /// - **Before ADR-0086** the calm-bar choice was the boolean `hideCalmSevenDayBar`. It maps onto the
    ///   enum through `TopBarHiding.migrated(fromLegacyHide:)` — again the same call the `UserDefaults`
    ///   migration makes. A dump with neither key falls back to `.fiveHour`: any build old enough to
    ///   omit both was drawing one bar while calm, which is what that case still means.
    ///
    /// Keys retired by ADR-0090 (`pauseHidesBars`, `showExtraUsage`, `awaitingInputInMenuBar`) need no
    /// case at all — `Codable` ignores unknown JSON keys, so a dump written by an older build still
    /// imports, exactly as the retired `farBehindInterval` key does.
    public init(from decoder: Decoder) throws {
        let flat = try decoder.container(keyedBy: LegacyFlatKeys.self)
        let groups = try decoder.container(keyedBy: GroupKeys.self)
        let mb = try? groups.nestedContainer(keyedBy: MenuBarKeys.self, forKey: .menuBar)
        let dd = try? groups.nestedContainer(keyedBy: DropdownKeys.self, forKey: .dropdown)

        let defaults = AppearancePreset.defaultValues

        // Pre-#329: one `barStyle` for both surfaces. Split at the level that knows which key belongs
        // to which surface, so a `"mixed"` dump lands as Pressure + Progress — exactly what that build
        // drew.
        let legacyPair = try flat.decodeIfPresent(String.self, forKey: .barStyle)
            .flatMap(BarStyle.legacySurfaceStyles(for:))

        let menuBarStyle = try mb?.decodeIfPresent(BarStyle.self, forKey: .style)
            ?? flat.decodeIfPresent(BarStyle.self, forKey: .menuBarStyle)
            ?? legacyPair?.menuBar ?? defaults.menuBarStyle
        let dropdownStyle = try dd?.decodeIfPresent(BarStyle.self, forKey: .style)
            ?? flat.decodeIfPresent(BarStyle.self, forKey: .dropdownStyle)
            ?? legacyPair?.dropdown ?? defaults.dropdownStyle

        // Pre-ADR-0086: the boolean `hideCalmSevenDayBar`. Mapped through the same function the
        // `UserDefaults` migration calls, so an import and an in-place upgrade cannot disagree.
        let legacyHide = try flat.decodeIfPresent(Bool.self, forKey: .hideCalmSevenDayBar)
        let hideTop5hBar = try mb?.decodeIfPresent(TopBarHiding.self, forKey: .hideTop5hBar)
            ?? flat.decodeIfPresent(TopBarHiding.self, forKey: .calmBarHiding)
            ?? legacyHide.map(TopBarHiding.migrated(fromLegacyHide:))
            ?? defaults.hideTop5hBar

        // Every remaining value: nested key first, then the pre-#381 flat key, then the preset default.
        // The enums' own `init(from:)` resolve retired raws through their `legacyRawValues`, so a flat
        // dump carrying `yellowGreen` / `aboveZero` / `optionOnly` decodes to the renamed case rather
        // than to a default — a silent default here is how a stored choice gets lost.
        self.init(
            colorsTell: try mb?.decodeIfPresent(ColorAdvice.self, forKey: .colorsTell)
                ?? flat.decodeIfPresent(ColorAdvice.self, forKey: .calmColorMode)
                ?? defaults.colorsTell,
            hideTop5hBar: hideTop5hBar,
            showServiceStatusDot: try mb?.decodeIfPresent(Bool.self, forKey: .showServiceStatusDot)
                ?? flat.decodeIfPresent(Bool.self, forKey: .showServiceStatusDot)
                ?? defaults.showServiceStatusDot,
            modelLimitsVisibility: try dd?.decodeIfPresent(
                PopupSectionVisibility.self, forKey: .showPerModelLimits)
                ?? flat.decodeIfPresent(PopupSectionVisibility.self, forKey: .modelLimitsVisibility)
                ?? defaults.modelLimitsVisibility,
            extraUsageVisibility: try dd?.decodeIfPresent(
                PopupSectionVisibility.self, forKey: .showExtraUsage)
                ?? flat.decodeIfPresent(PopupSectionVisibility.self, forKey: .extraUsageVisibility)
                ?? defaults.extraUsageVisibility,
            menuBarStyle: menuBarStyle,
            dropdownStyle: dropdownStyle)
    }
}

// MARK: - AppearanceConfigExport (#257)

/// Serializes the live **Appearance** config to pretty-printed JSON for the clipboard — the payload
/// behind the copy button in Settings → Appearance (#257).
///
/// The Appearance surface is combinatorial (`BarStyle` × `ColorAdvice` × `FarBehindInterval` × the
/// toggles), so "it looks wrong on my machine" is more often a config difference than a bug. This
/// makes answering "what does your setup look like?" one click instead of a screenshot tour.
///
/// Deliberately **Appearance-only**, unlike the full `PersistedConfig` dump proposed in #256: these
/// seven keys are pure presentation — no filesystem paths, no account names, no working hours —
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

    /// Build the clipboard JSON: the app version and active preset as metadata, and the seven
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
        // Pane order, grouped by surface — keep in sync with the `CodingKeys` enums above,
        // `AppearancePanes.swift`, and `AppearanceConfigExportTests`. Insert a new option at its
        // on-screen position inside its own group; never append to the end of the dump.
        let menuBar: [(String, String)] = [
            ("style", jsonString(v.menuBarStyle.rawValue)),
            ("colorsTell", jsonString(v.colorsTell.rawValue)),
            ("hideTop5hBar", jsonString(v.hideTop5hBar.rawValue)),
            ("showServiceStatusDot", jsonBool(v.showServiceStatusDot)),
        ]
        let dropdown: [(String, String)] = [
            ("style", jsonString(v.dropdownStyle.rawValue)),
            ("showPerModelLimits", jsonString(v.modelLimitsVisibility.rawValue)),
            ("showExtraUsage", jsonString(v.extraUsageVisibility.rawValue)),
        ]

        // Two-space indent and `" : "` around the colon match `JSONSerialization.prettyPrinted`, so
        // this dump looks like the one the Troubleshoot window shows.
        func group(_ name: String, _ pairs: [(String, String)]) -> String {
            let body = pairs
                .map { "      \"\($0.0)\" : \($0.1)" }
                .joined(separator: ",\n")
            return "    \"\(name)\" : {\n\(body)\n    }"
        }

        let body = [group("menuBar", menuBar), group("dropdown", dropdown)]
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
