import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - BarStyle (#224)

@Suite("BarStyle")
struct BarStyleTests {

    /// Four styles ship; the raw values are persisted in UserDefaults. Three were renamed in #307
    /// alongside the UI names — see `decodesLegacyRawValues` for the pre-#307 raws. `gauge` is new in
    /// #326 and has no legacy raw, so it is absent from that table by construction.
    @Test func casesAndRawValues() {
        #expect(BarStyle.allCases == [.progress, .mixed, .pressure, .gauge])
        #expect(BarStyle.progress.rawValue == "progress")
        #expect(BarStyle.mixed.rawValue == "mixed")
        #expect(BarStyle.pressure.rawValue == "pressure")
        #expect(BarStyle.gauge.rawValue == "gauge")
    }

    /// Per-surface marker helpers: `.progress` marks both, `.pressure` marks neither, `.mixed` marks
    /// only the dropdown (Pressure menu bar).
    @Test func perSurfaceMarkers() {
        #expect(BarStyle.progress.menuBarShowsTimeMarker)
        #expect(BarStyle.progress.popupShowsTimeMarker)
        #expect(!BarStyle.pressure.menuBarShowsTimeMarker)
        #expect(!BarStyle.pressure.popupShowsTimeMarker)
        #expect(!BarStyle.mixed.menuBarShowsTimeMarker)   // Pressure in the menu bar
        #expect(BarStyle.mixed.popupShowsTimeMarker)      // Progress in the dropdown
    }

    /// Per-surface scale helpers (#307, restated for three scales in #326): a time marker is
    /// meaningful on the **window** scale and nowhere else — on either renormalised track it would
    /// sit at a fixed spot forever. Until Gauge that implication was an equivalence and one bit told
    /// the two scales apart; a third marker-less scale breaks the reverse direction, so what is
    /// pinned now is the surviving one-way rule, with the scale itself as the source.
    @Test func theTimeMarkerIsExactlyTheWindowScale() {
        for style in BarStyle.allCases {
            #expect(style.menuBarShowsTimeMarker == (style.menuBarScale == .window), "\(style)")
            #expect(style.popupShowsTimeMarker == (style.popupScale == .window), "\(style)")
        }
    }

    /// The per-surface scale of every case, spelled out — the table the renderers branch on.
    @Test func perSurfaceScales() {
        #expect(BarStyle.progress.menuBarScale == .window)
        #expect(BarStyle.progress.popupScale == .window)
        #expect(BarStyle.mixed.menuBarScale == .remaining)   // Pressure in the compact menu bar…
        #expect(BarStyle.mixed.popupScale == .window)        // …Progress in the roomier dropdown
        #expect(BarStyle.pressure.menuBarScale == .remaining)
        #expect(BarStyle.pressure.popupScale == .remaining)
        #expect(BarStyle.gauge.menuBarScale == .centred)     // the centred scale is both-surfaces
        #expect(BarStyle.gauge.popupScale == .centred)
    }

    /// Gauge is the only case on the centred scale, and it carries no marker on either surface —
    /// the pair of facts that makes its centre tick load-bearing rather than decorative (#326).
    @Test func onlyGaugeIsCentredAndItIsMarkerLess() {
        for style in BarStyle.allCases where style != .gauge {
            #expect(style.menuBarScale != .centred, "\(style)")
            #expect(style.popupScale != .centred, "\(style)")
        }
        #expect(!BarStyle.gauge.menuBarShowsTimeMarker)
        #expect(!BarStyle.gauge.popupShowsTimeMarker)
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
            ("mixed", .mixed),       // unchanged by #307
        ]
        for (raw, expected) in cases {
            let style = try JSONDecoder().decode(BarStyle.self, from: Data("\"\(raw)\"".utf8))
            #expect(style == expected, "\(raw)")
        }
    }

    /// The legacy table covers exactly the two renamed cases — `"mixed"` is absent because it still
    /// decodes through `rawValue`. Pins the table against a future edit that adds a stale entry.
    @Test func legacyTableCoversOnlyTheRenamedCases() {
        #expect(BarStyle.legacyRawValues == ["pacing": .progress, "simple": .pressure])
        // Every legacy raw maps to a case whose *current* raw differs — otherwise the entry is dead.
        for (raw, style) in BarStyle.legacyRawValues {
            #expect(style.rawValue != raw, "\(raw)")
        }
    }
}
