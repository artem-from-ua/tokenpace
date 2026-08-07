import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Fixtures

/// The canonical key order: the top-to-bottom order of the controls in Settings → Appearance
/// (`AppearancePane.swift`). Duplicated here on purpose — a test that derived the expected order from
/// `CodingKeys` would pass no matter how the keys were re-ordered, which is exactly the drift this
/// suite exists to catch. When an Appearance option is added, update the pane, the encoder, and this
/// list together.
private let paneOrderedKeys = [
    "barStyle",                   // "Bar style"
    "farBehindInterval",          // "Far behind pace interval"
    "calmColorMode",              // "Calm non-critical colors"
    "awaitingInputInMenuBar",     // "Show awaiting-input icon in the menu bar"
    "pauseHidesBars",             // "Pause icon hides bars"
    "showExtraUsage",             // "Show extra-usage credits icon"
    "hideCalmSevenDayBar",        // "Show 7-day bar when calm"
    "resetCountdownModeMenuBar",  // "Show reset countdown"
    "showServiceStatusDot",       // "Show service status dot on issues"
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
    hideCalmSevenDayBar: true,
    pauseHidesBars: true,
    showExtraUsage: false,
    showServiceStatusDot: false,
    awaitingInputInMenuBar: false,
    modelLimitsVisibility: .optionOnly,
    extraUsageVisibility: .always,
    resetCountdownModeMenuBar: .never,
    barStyle: .mixed,
    showTicks: false,
    farBehindInterval: .short)

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
        #expect(appearanceKeysInOrder(export(customValues, preset: nil)).count == 12)
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
        #expect(json.contains("\"barStyle\" : \"mixed\""))
        #expect(json.contains("\"calmColorMode\" : \"off\""))
        #expect(json.contains("\"farBehindInterval\" : \"short\""))
        #expect(json.contains("\"resetCountdownModeMenuBar\" : \"never\""))
    }

    /// `hideCalmSevenDayBar` is exported in the stored *hide* sense, not the pane's inverted
    /// "Show 7-day bar when calm" — otherwise the dump would contradict `PersistedConfig`.
    @Test func sevenDayFlagKeepsTheStoredHideSense() {
        let hidden = AppearancePreset.chill.values   // hideCalmSevenDayBar == true
        #expect(export(hidden, preset: .chill).contains("\"hideCalmSevenDayBar\" : true"))
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

    /// Decoding ignores key order (JSON objects are unordered), so a dump someone re-formatted or
    /// re-ordered by hand still reads back correctly.
    @Test func decodingIsOrderIndependent() throws {
        let json = """
        { "showTicks" : true, "barStyle" : "simple", "calmColorMode" : "off",
          "farBehindInterval" : "long", "hideCalmSevenDayBar" : false,
          "pauseHidesBars" : false, "showExtraUsage" : true,
          "showServiceStatusDot" : true, "awaitingInputInMenuBar" : true,
          "modelLimitsVisibility" : "always", "extraUsageVisibility" : "optionOnly",
          "resetCountdownModeMenuBar" : "always" }
        """
        let decoded = try JSONDecoder().decode(
            AppearancePresetValues.self, from: Data(json.utf8))
        #expect(decoded.barStyle == .pressure)
        #expect(decoded.farBehindInterval == .long)
        #expect(decoded.resetCountdownModeMenuBar == .always)
        #expect(decoded.modelLimitsVisibility == .always)
        #expect(decoded.extraUsageVisibility == .optionOnly)
        #expect(decoded.showTicks)
    }
}
