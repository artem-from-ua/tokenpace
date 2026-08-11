import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - BarStyle (#224)

@Suite("BarStyle")
struct BarStyleTests {

    /// Three styles ship; the raw values are persisted in UserDefaults. Two were renamed in #307
    /// alongside the UI names — see `decodesLegacyRawValues` for the pre-#307 raws. `gauge` is new in
    /// #326 and has no legacy raw, so it is absent from that table by construction. The fourth case,
    /// `mixed`, was never a style at all but a *pair* of them; #329 gave each surface its own key and
    /// retired it (see `legacySurfaceStylesSplitsTheOldKey`).
    @Test func casesAndRawValues() {
        #expect(BarStyle.allCases == [.progress, .pressure, .gauge])
        #expect(BarStyle.progress.rawValue == "progress")
        #expect(BarStyle.pressure.rawValue == "pressure")
        #expect(BarStyle.gauge.rawValue == "gauge")
    }

    /// The scale of every case, spelled out — the table the renderers branch on. Since #329 a style
    /// carries one scale rather than a per-surface pair: which surface it applies to is the caller's
    /// business, not the enum's.
    @Test func scales() {
        #expect(BarStyle.progress.scale == .window)
        #expect(BarStyle.pressure.scale == .remaining)
        #expect(BarStyle.gauge.scale == .centred)
    }

    /// A time marker is meaningful on the **window** scale and nowhere else — on either renormalised
    /// track it would sit at a fixed spot forever. Until Gauge that implication was an equivalence and
    /// one bit told the two scales apart; a third marker-less scale breaks the reverse direction, so
    /// what is pinned here is the surviving one-way rule, with the scale itself as the source.
    @Test func theTimeMarkerIsExactlyTheWindowScale() {
        for style in BarStyle.allCases {
            #expect(style.showsTimeMarker == (style.scale == .window), "\(style)")
        }
    }

    /// Gauge is the only case on the centred scale, and it carries no marker — the pair of facts that
    /// makes its centre tick load-bearing rather than decorative (#326).
    @Test func onlyGaugeIsCentredAndItIsMarkerLess() {
        for style in BarStyle.allCases where style != .gauge {
            #expect(style.scale != .centred, "\(style)")
        }
        #expect(!BarStyle.gauge.showsTimeMarker)
    }

    /// A known raw value round-trips through `Codable`.
    @Test func decodesKnownRawValue() throws {
        let data = Data(#""pressure""#.utf8)
        let style = try JSONDecoder().decode(BarStyle.self, from: data)
        #expect(style == .pressure)
    }

    /// Forward-compatible decode: an unrecognised raw string (a newer build's value) falls back to
    /// `.progress` — the shipped behaviour — instead of throwing, so an older build never trips.
    @Test func decodesUnknownRawValueToProgress() throws {
        let data = Data(#""ribbon-3d""#.utf8)
        let style = try JSONDecoder().decode(BarStyle.self, from: data)
        #expect(style == .progress)
    }

    /// The pre-#307 raws decode to the cases that replaced them, **not** to the unknown-value
    /// fallback. This is what keeps an appearance config exported by an older build importable: without
    /// it `"simple"` (Pace) would land on `.progress` — silently turning a marker-less bar into a
    /// marked one, the exact loss the rename had to avoid.
    @Test func decodesLegacyRawValues() throws {
        let cases: [(String, BarStyle)] = [
            ("pacing", .progress),   // was "Pace & Time"
            ("simple", .pressure),   // was "Pace"
        ]
        for (raw, expected) in cases {
            let style = try JSONDecoder().decode(BarStyle.self, from: Data("\"\(raw)\"".utf8))
            #expect(style == expected, "\(raw)")
        }
    }

    /// `"mixed"` decodes here to the unknown-value fallback, **not** to a style — deliberately. This
    /// container holds one surface's style, and `"mixed"` named two different ones; splitting it needs
    /// the level that knows which key is which surface. That is `legacySurfaceStyles(for:)`, exercised
    /// below, and `AppearanceConfigExportTests` covers the import path end to end.
    @Test func mixedIsNotASingleSurfaceStyle() throws {
        #expect(BarStyle(rawValue: "mixed") == nil)
        #expect(BarStyle.legacyRawValues["mixed"] == nil)
        let style = try JSONDecoder().decode(BarStyle.self, from: Data(#""mixed""#.utf8))
        #expect(style == .progress)   // the unknown-raw fallback, not a mapping
    }

    /// The legacy table covers exactly the two renamed cases. Pins the table against a future edit
    /// that adds a stale entry.
    @Test func legacyTableCoversOnlyTheRenamedCases() {
        #expect(BarStyle.legacyRawValues == ["pacing": .progress, "simple": .pressure])
        // Every legacy raw maps to a case whose *current* raw differs — otherwise the entry is dead.
        for (raw, style) in BarStyle.legacyRawValues {
            #expect(style.rawValue != raw, "\(raw)")
        }
    }

    /// Splitting a pre-#329 stored value across the two surfaces (#329). `"mixed"` is the case that
    /// forced a pair-returning helper: it is the one legacy value whose surfaces disagree, so mapping
    /// it to a single style would have to silently change how one of them looks. Everything else maps
    /// to itself on both surfaces, renames included.
    @Test func legacySurfaceStylesSplitsTheOldKey() {
        let cases: [(String, BarStyle, BarStyle)] = [
            ("mixed", .pressure, .progress),      // Pressure menu bar + Progress dropdown, as drawn
            ("pacing", .progress, .progress),     // pre-#307 rename, then doubled
            ("simple", .pressure, .pressure),
            ("progress", .progress, .progress),   // current raws split too — the key itself is gone
            ("pressure", .pressure, .pressure),
            ("gauge", .gauge, .gauge),
        ]
        for (raw, menuBar, dropdown) in cases {
            let split = BarStyle.legacySurfaceStyles(for: raw)
            #expect(split?.menuBar == menuBar, "\(raw)")
            #expect(split?.dropdown == dropdown, "\(raw)")
        }
    }

    /// An unplaceable raw returns `nil` rather than guessing, so the caller can leave the setting
    /// alone and let the preset default apply — the same "never silently invent a choice" rule the
    /// migration relies on.
    @Test func legacySurfaceStylesRejectsUnknownRaw() {
        #expect(BarStyle.legacySurfaceStyles(for: "ribbon-3d") == nil)
        #expect(BarStyle.legacySurfaceStyles(for: "") == nil)
    }
}
