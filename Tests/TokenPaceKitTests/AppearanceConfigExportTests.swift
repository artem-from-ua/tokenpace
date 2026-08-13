import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Fixtures

/// The canonical key order: the top-to-bottom order of the controls in Settings → Appearance
/// (`UIPanes.swift`). Duplicated here on purpose — a test that derived the expected order from
/// `CodingKeys` would pass no matter how the keys were re-ordered, which is exactly the drift this
/// suite exists to catch. When an Appearance option is added, update the pane, the encoder, and this
/// list together.
private let paneOrderedKeys = [
    "menuBarStyle",               // Menu Bar Widget → "Bar style"
    "calmColorMode",              // "Calm non-critical colors"
    "calmBarHiding",              // "Hide 5h (top) bar"
    "resetCountdownModeMenuBar",  // "Show reset countdown"
    "showServiceStatusDot",       // "Show service status dot on issues"
    "dropdownStyle",              // Dropdown Widget → "Bar style"
    "modelLimitsVisibility",      // "Show model & service limits"
    "extraUsageVisibility",       // "Show extra usage"
    "showTicks",                  // "Show ticks on bars"
]

/// The keys of the `appearance` object **in the order they appear in the JSON text**. Works on the raw
/// string rather than `JSONSerialization`, because parsing into a dictionary would discard the very
/// ordering under test.
private func appearanceKeysInOrder(_ json: String) -> [String] {
    guard let start = json.range(of: "\"appearance\"") else { return [] }
    let tail = json[start.upperBound...]
    guard let open = tail.firstIndex(of: "{"),
          let close = tail[open...].firstIndex(of: "}") else { return [] }
    let body = tail[tail.index(after: open)..<close]

    return body.split(separator: "\n").compactMap { line in
        // Each pretty-printed line looks like:  "barStyle" : "mixed",
        guard let first = line.firstIndex(of: "\""),
              let second = line[line.index(after: first)...].firstIndex(of: "\"") else { return nil }
        return String(line[line.index(after: first)..<second])
    }
}

/// A value set that deliberately matches **no** preset, so `preset` exports as "custom".
private let customValues = AppearancePresetValues(
    calmColorMode: .off,
    // `.never` with calm colours off would be Control freak, so the rest of the set pulls it away from
    // every preset — a deliberately preset-less combination.
    calmBarHiding: .never,
    showServiceStatusDot: false,
    modelLimitsVisibility: .optionOnly,
    extraUsageVisibility: .always,
    resetCountdownModeMenuBar: .never,
    // Deliberately mismatched surfaces — the pair no preset can express (#329), and the shape the
    // retired `"mixed"` value used to name.
    menuBarStyle: .pressure,
    dropdownStyle: .progress,
    showTicks: false)

private func export(_ values: AppearancePresetValues, preset: AppearancePreset?) -> String {
    AppearanceConfigExport.json(values: values, preset: preset, appVersion: "9.9.9")
}

// MARK: - Key order (the rule this feature turns on)

@Suite("AppearanceConfigExport key order")
struct AppearanceConfigExportOrderTests {

    /// The guard for #257's core rule: keys are emitted in **pane order**, so a pasted dump reads
    /// line-by-line against Settings → Appearance. Fails if someone appends a new key at the end
    /// instead of its matching position, or re-enables `.sortedKeys` on the encoder.
    @Test func keysFollowThePaneOrder() {
        let keys = appearanceKeysInOrder(export(AppearancePreset.chill.values, preset: .chill))
        #expect(keys == paneOrderedKeys)
    }

    /// Pane order is *not* alphabetical — asserted explicitly so the previous test can't be "fixed"
    /// by sorting the expectation and calling it done.
    @Test func paneOrderIsNotAlphabetical() {
        #expect(paneOrderedKeys != paneOrderedKeys.sorted())
    }

    /// The order holds regardless of which config is exported (it comes from the encoder, not the data).
    @Test func orderIsIndependentOfValues() {
        for preset in AppearancePreset.allCases {
            #expect(appearanceKeysInOrder(export(preset.values, preset: preset)) == paneOrderedKeys)
        }
        #expect(appearanceKeysInOrder(export(customValues, preset: nil)) == paneOrderedKeys)
    }

    /// Every Appearance value reaches the dump — catches a property added to `AppearancePresetValues`
    /// whose `encode` call was forgotten, which would otherwise drop it silently.
    @Test func everyValueIsExported() {
        #expect(appearanceKeysInOrder(export(customValues, preset: nil)).count == 9)
    }
}

// MARK: - Payload

@Suite("AppearanceConfigExport payload")
struct AppearanceConfigExportPayloadTests {

    /// A named preset exports under its raw value — the same string `PersistedConfig` stores.
    @Test func namedPresetIsExportedByRawValue() {
        for preset in AppearancePreset.allCases {
            #expect(export(preset.values, preset: preset).contains("\"preset\" : \"\(preset.rawValue)\""))
        }
    }

    /// The "Custom" state (the pane's indicator segment) exports as a readable string, not `null`.
    @Test func customStateExportsAsCustom() {
        let json = export(customValues, preset: nil)
        #expect(json.contains("\"preset\" : \"custom\""))
        #expect(!json.contains("null"))
    }

    /// Metadata: the app version rides along so the values can be interpreted against a build.
    @Test func appVersionIsIncluded() {
        #expect(export(customValues, preset: nil).contains("\"appVersion\" : \"9.9.9\""))
    }

    /// Enum values export as their stable raw strings (not ordinals), so a dump stays readable and
    /// survives a case being re-ordered in a later build.
    @Test func enumsExportAsRawStrings() {
        let json = export(customValues, preset: nil)
        #expect(json.contains("\"menuBarStyle\" : \"pressure\""))
        #expect(json.contains("\"dropdownStyle\" : \"progress\""))
        #expect(json.contains("\"calmColorMode\" : \"off\""))
        #expect(json.contains("\"resetCountdownModeMenuBar\" : \"never\""))
        #expect(json.contains("\"calmBarHiding\" : \"never\""))
    }

    /// `calmBarHiding` exports as the raw string naming the **hidden** bar — the same sense
    /// `PersistedConfig` stores, with no inversion left anywhere (ADR-0086 retired the boolean whose
    /// stored form was the opposite of its checkbox).
    @Test func calmBarHidingExportsTheHiddenBar() {
        #expect(export(AppearancePreset.chill.values, preset: .chill)
            .contains("\"calmBarHiding\" : \"fiveHour\""))
        #expect(export(AppearancePreset.controlFreak.values, preset: .controlFreak)
            .contains("\"calmBarHiding\" : \"never\""))
    }

    /// Pretty-printed, so the dump is readable where it's pasted.
    @Test func outputIsPrettyPrinted() {
        #expect(export(customValues, preset: nil).contains("\n"))
    }

    /// Same input → identical output. There is no export timestamp, so two dumps of an unchanged
    /// config diff cleanly against each other.
    @Test func outputIsDeterministic() {
        #expect(export(customValues, preset: nil) == export(customValues, preset: nil))
    }
}

// MARK: - Round-trip

@Suite("AppearancePresetValues Codable round-trip")
struct AppearancePresetValuesCodableTests {

    /// Decoding a dump reproduces the exact value set — the guarantee that the export really describes
    /// the config rather than an approximation of it.
    @Test func roundTripsThroughJSON() throws {
        for values in AppearancePreset.allCases.map(\.values) + [customValues] {
            let data = try JSONEncoder().encode(values)
            #expect(try JSONDecoder().decode(AppearancePresetValues.self, from: data) == values)
        }
    }

    /// The `.aboveZero` visibility crosses the wire as its own raw string. Covered indirectly by the
    /// round-trip above (it is the shipped Extra-usage default), but pinned literally here: the raw is
    /// storage, so a typo in it would silently reset everyone's choice on the next launch.
    @Test func aboveZeroCrossesTheWireAsItsRawString() throws {
        let json = """
        { "showTicks" : true, "menuBarStyle" : "pressure", "dropdownStyle" : "pressure",
          "calmColorMode" : "off", "calmBarHiding" : "never",
          "pauseHidesBars" : false, "showExtraUsage" : true,
          "showServiceStatusDot" : true, "awaitingInputInMenuBar" : true,
          "modelLimitsVisibility" : "aboveZero", "extraUsageVisibility" : "aboveZero",
          "resetCountdownModeMenuBar" : "always" }
        """
        let decoded = try JSONDecoder().decode(AppearancePresetValues.self, from: Data(json.utf8))
        #expect(decoded.modelLimitsVisibility == .aboveZero)
        #expect(decoded.extraUsageVisibility == .aboveZero)
    }

    /// Decoding ignores key order (JSON objects are unordered), so a dump someone re-formatted or
    /// re-ordered by hand still reads back correctly.
    @Test func decodingIsOrderIndependent() throws {
        let json = """
        { "showTicks" : true, "dropdownStyle" : "gauge", "calmColorMode" : "off",
          "menuBarStyle" : "simple", "farBehindInterval" : "long", "hideCalmSevenDayBar" : false,
          "pauseHidesBars" : false, "showExtraUsage" : true,
          "showServiceStatusDot" : true, "awaitingInputInMenuBar" : true,
          "modelLimitsVisibility" : "always", "extraUsageVisibility" : "optionOnly",
          "resetCountdownModeMenuBar" : "always" }
        """
        let decoded = try JSONDecoder().decode(
            AppearancePresetValues.self, from: Data(json.utf8))
        #expect(decoded.menuBarStyle == .pressure)   // the pre-#307 raw still maps, per surface
        #expect(decoded.dropdownStyle == .gauge)
        #expect(decoded.resetCountdownModeMenuBar == .always)
        #expect(decoded.modelLimitsVisibility == .always)
        #expect(decoded.extraUsageVisibility == .optionOnly)
        #expect(decoded.showTicks)
        // This fixture also predates ADR-0086, so it exercises the legacy boolean: `false` → `.never`.
        #expect(decoded.calmBarHiding == .never)
    }

    /// A dump exported **before ADR-0086** carries the boolean `hideCalmSevenDayBar` instead of
    /// `calmBarHiding`. It maps through `CalmBarHiding.migrated(fromLegacyHide:)` — the same call the
    /// `UserDefaults` migration makes — so importing an old dump and upgrading in place agree.
    @Test func decodesTheLegacyHideCalmSevenDayBoolean() throws {
        func decode(_ legacy: String) throws -> AppearancePresetValues {
            let json = """
            { "showTicks" : true, "menuBarStyle" : "gauge", "dropdownStyle" : "gauge",
              "calmColorMode" : "off", \(legacy),
              "pauseHidesBars" : false, "showExtraUsage" : true,
              "showServiceStatusDot" : true, "awaitingInputInMenuBar" : true,
              "modelLimitsVisibility" : "always", "extraUsageVisibility" : "optionOnly",
              "resetCountdownModeMenuBar" : "always" }
            """
            return try JSONDecoder().decode(AppearancePresetValues.self, from: Data(json.utf8))
        }
        // `true` hid the calm 7-day bar; `false` kept both. The 7-day mode retired with ADR-0090, so
        // `true` lands on `.fiveHour` — still one bar while calm, which is what that user asked for.
        // Note the fixture also carries the three keys ADR-0090 retired: they must be ignored, not throw.
        #expect(try decode("\"hideCalmSevenDayBar\" : true").calmBarHiding == .fiveHour)
        #expect(try decode("\"hideCalmSevenDayBar\" : false").calmBarHiding == .never)
        // The new key wins when both are present — an old key left in a hand-edited dump can't override
        // the current one.
        #expect(try decode("\"calmBarHiding\" : \"fiveHour\", \"hideCalmSevenDayBar\" : true")
            .calmBarHiding == .fiveHour)
        // Neither key (a dump older still) falls back to the same one-bar-while-calm reading.
        #expect(try decode("\"unrelated\" : 1").calmBarHiding == .fiveHour)
    }

    // MARK: Pre-#329 configs — one `barStyle` key for both surfaces

    /// A config exported before #329 carries a single `barStyle`. `"mixed"` named *different* styles
    /// per surface, so it splits into the pair it drew — Pressure in the menu bar, Progress in the
    /// dropdown — rather than collapsing onto one. Same rule the `UserDefaults` migration applies, so
    /// importing an old dump and upgrading in place land in the same place.
    @Test func legacyMixedSplitsAcrossTheTwoSurfaces() throws {
        let decoded = try JSONDecoder().decode(
            AppearancePresetValues.self, from: Data(legacyJSON(barStyle: "mixed").utf8))
        #expect(decoded.menuBarStyle == .pressure)
        #expect(decoded.dropdownStyle == .progress)
    }

    /// Every other legacy raw — including the pre-#307 renames — applies to both surfaces, since one
    /// style is all those values ever meant.
    @Test func otherLegacyStylesApplyToBothSurfaces() throws {
        let cases: [(String, BarStyle)] = [
            ("simple", .pressure),   // pre-#307 "Pace"
            ("pacing", .progress),   // pre-#307 "Pace & Time"
            ("gauge", .gauge),
        ]
        for (raw, expected) in cases {
            let decoded = try JSONDecoder().decode(
                AppearancePresetValues.self, from: Data(legacyJSON(barStyle: raw).utf8))
            #expect(decoded.menuBarStyle == expected, "\(raw)")
            #expect(decoded.dropdownStyle == expected, "\(raw)")
        }
    }

    /// A dump with **no** style key at all (neither the new pair nor the legacy one) decodes to the
    /// preset default rather than throwing — the same "a missing choice is the default choice" rule
    /// the getters follow.
    @Test func aConfigWithNoStyleKeyFallsBackToTheDefault() throws {
        let decoded = try JSONDecoder().decode(
            AppearancePresetValues.self, from: Data(legacyJSON(barStyle: nil).utf8))
        #expect(decoded.menuBarStyle == AppearancePreset.defaultValues.menuBarStyle)
        #expect(decoded.dropdownStyle == AppearancePreset.defaultValues.dropdownStyle)
    }

    /// A pre-#329 dump: every current key except the per-surface styles, plus the single legacy one.
    private func legacyJSON(barStyle: String?) -> String {
        let styleLine = barStyle.map { "\"barStyle\" : \"\($0)\"," } ?? ""
        return """
        { \(styleLine) "showTicks" : true, "calmColorMode" : "off",
          "farBehindInterval" : "long", "hideCalmSevenDayBar" : false,
          "pauseHidesBars" : false, "showExtraUsage" : true,
          "showServiceStatusDot" : true, "awaitingInputInMenuBar" : true,
          "modelLimitsVisibility" : "always", "extraUsageVisibility" : "optionOnly",
          "resetCountdownModeMenuBar" : "always" }
        """
    }
}
