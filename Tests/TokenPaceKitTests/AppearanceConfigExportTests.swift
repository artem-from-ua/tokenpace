import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Fixtures

/// The canonical key order, **grouped by surface** since #381: the two groups in the order of the two
/// child pages, and inside each the top-to-bottom order of that page's controls
/// (`AppearancePanes.swift`).
///
/// Duplicated here on purpose — a test that derived the expected order from the `CodingKeys` enums would
/// pass no matter how the keys were re-ordered, which is exactly the drift this suite exists to catch.
/// When an Appearance option is added, update the pane, the encoder, and this list together.
private let paneOrderedGroups: [(group: String, keys: [String])] = [
    ("menuBar", [
        "style",                  // "Style"
        "colorsTell",             // "Colors tell me"
        "hideTop5hBar",           // "Hide the top 5h bar"
        "showServiceStatusDot",   // "Show service status dot"
    ]),
    ("dropdown", [
        "style",                  // "Style"
        "showPerModelLimits",     // "Show per-model & per-service limits"
        "showExtraUsage",         // "Show *Extra usage*"
    ]),
]

/// The flattened expectation — `group.key` for every key, in emission order.
private let paneOrderedKeys = paneOrderedGroups.flatMap { g in g.keys.map { "\(g.group).\($0)" } }

/// The keys of the `appearance` object **in the order they appear in the JSON text**, qualified by their
/// group (`"menuBar.style"`). Works on the raw string rather than `JSONSerialization`, because parsing
/// into a dictionary would discard the very ordering under test.
///
/// Tracks brace depth rather than scanning for the first `}` (#381): with the keys nested one level
/// deeper, "first closing brace" is the end of the **first group**, so the old scan would have silently
/// returned half the dump and let the order assertions pass on incomplete data.
private func appearanceKeysInOrder(_ json: String) -> [String] {
    guard let start = json.range(of: "\"appearance\"") else { return [] }
    var depth = 0
    var group: String?
    var result: [String] = []

    for line in json[start.upperBound...].split(separator: "\n") {
        let opens = line.filter { $0 == "{" }.count
        let closes = line.filter { $0 == "}" }.count

        if let key = quotedKey(in: line) {
            // A line that opens a brace names a group; anything else at depth 1 names a value.
            if opens > 0 {
                group = key
            } else if let group {
                result.append("\(group).\(key)")
            } else {
                result.append(key)   // ungrouped key — the shape this test would flag
            }
        }

        depth += opens - closes
        if closes > 0, opens == 0, depth <= 1 { group = nil }
        if depth <= 0 && !result.isEmpty { break }   // left the `appearance` object
    }
    return result
}

/// The first `"…"`-quoted token on a line, or `nil` — the key half of a pretty-printed
/// `"key" : value` line.
private func quotedKey(in line: Substring) -> String? {
    guard let first = line.firstIndex(of: "\""),
          let second = line[line.index(after: first)...].firstIndex(of: "\"") else { return nil }
    return String(line[line.index(after: first)..<second])
}

/// A value set that deliberately matches **no** preset, so `preset` exports as "custom".
private let customValues = AppearancePresetValues(
    colorsTell: .howItsGoing,
    // `.never` with nothing muted would be Control freak, so the rest of the set pulls it away from
    // every preset — a deliberately preset-less combination.
    hideTop5hBar: .never,
    showServiceStatusDot: false,
    // `.onceUsed` here rather than Control freak's `.always`, which keeps this set distinct from every
    // preset even though `.howItsGoing` + `.never` match one. (The retired `.optionOnly` used to do that
    // job; #381 removed the case.)
    modelLimitsVisibility: .onceUsed,
    extraUsageVisibility: .always,
    // Deliberately mismatched surfaces — the pair no preset can express (#329), and the shape the
    // retired `"mixed"` value used to name.
    menuBarStyle: .pressure,
    dropdownStyle: .progress)

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
        // Counted against `paneOrderedKeys` rather than a literal: the literal had to be edited by hand
        // every time a key came or went, and a stale one fails here for a reason that has nothing to do
        // with the rule under test.
        #expect(appearanceKeysInOrder(export(customValues, preset: nil)).count == paneOrderedKeys.count)
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
    ///
    /// The two `style` keys are checked with their values rather than by name alone: since #381 both
    /// groups carry a key called `style`, so the pair is what pins each to its own surface.
    @Test func enumsExportAsRawStrings() {
        let json = export(customValues, preset: nil)
        #expect(json.contains("\"style\" : \"pressure\""))     // menuBar
        #expect(json.contains("\"style\" : \"progress\""))      // dropdown
        #expect(json.contains("\"colorsTell\" : \"howItsGoing\""))
        #expect(json.contains("\"hideTop5hBar\" : \"never\""))
    }

    /// `hideTop5hBar` exports as the raw string naming what it does to the bar — the same sense
    /// `PersistedConfig` stores, with no inversion left anywhere (ADR-0086 retired the boolean whose
    /// stored form was the opposite of its checkbox).
    @Test func hideTopBarExportsItsMode() {
        #expect(export(AppearancePreset.chill.values, preset: .chill)
            .contains("\"hideTop5hBar\" : \"untilItNeedsAttention\""))
        #expect(export(AppearancePreset.controlFreak.values, preset: .controlFreak)
            .contains("\"hideTop5hBar\" : \"never\""))
    }

    /// The dump is **nested by surface** (#381): two groups, in child-page order, each holding its own
    /// page's keys. Pinned separately from the key-order test because the grouping is the part a reader
    /// relies on — it is what lets a dump be read against the two panes without a lookup table.
    @Test func appearanceIsGroupedBySurface() {
        let json = export(customValues, preset: nil)
        #expect(json.contains("\"menuBar\" : {"))
        #expect(json.contains("\"dropdown\" : {"))
        guard let menuBar = json.range(of: "\"menuBar\" : {"),
              let dropdown = json.range(of: "\"dropdown\" : {") else { return }
        #expect(menuBar.lowerBound < dropdown.lowerBound)   // menu bar first, as on the sidebar
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
        #expect(decoded.modelLimitsVisibility == .onceUsed)
        #expect(decoded.extraUsageVisibility == .onceUsed)
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
        #expect(decoded.dropdownStyle == .balance)
        #expect(decoded.modelLimitsVisibility == .always)
        #expect(decoded.extraUsageVisibility == .onceUsed)
        // This fixture also predates ADR-0086, so it exercises the legacy boolean: `false` → `.never`.
        #expect(decoded.hideTop5hBar == .never)
    }

    /// A dump exported **before ADR-0086** carries the boolean `hideCalmSevenDayBar` instead of
    /// `calmBarHiding`. It maps through `TopBarHiding.migrated(fromLegacyHide:)` — the same call the
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
        // Note the fixture also carries the keys ADR-0090/ADR-0091 retired — including
        // `resetCountdownModeMenuBar`, whose setting is gone now that a countdown only ever accompanies
        // the bars-less modes — and `showTicks`, retired when the tick ruler stopped being optional.
        // They must be ignored, not throw.
        #expect(try decode("\"hideCalmSevenDayBar\" : true").hideTop5hBar == .untilItNeedsAttention)
        #expect(try decode("\"hideCalmSevenDayBar\" : false").hideTop5hBar == .never)
        // The new key wins when both are present — an old key left in a hand-edited dump can't override
        // the current one.
        #expect(try decode("\"calmBarHiding\" : \"fiveHour\", \"hideCalmSevenDayBar\" : true")
            .hideTop5hBar == .untilItNeedsAttention)
        // Neither key (a dump older still) falls back to the same one-bar-while-calm reading.
        #expect(try decode("\"unrelated\" : 1").hideTop5hBar == .untilItNeedsAttention)
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
            ("gauge", .balance),     // pre-#388 raw
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
