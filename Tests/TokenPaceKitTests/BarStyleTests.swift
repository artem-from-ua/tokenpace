import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - BarStyle (#224)

@Suite("BarStyle")
struct BarStyleTests {

    /// Three styles ship; the raw values are persisted in UserDefaults. They were renamed in #307
    /// alongside the UI names — see `decodesLegacyRawValues` for the pre-#307 raws.
    @Test func casesAndRawValues() {
        #expect(BarStyle.allCases == [.progress, .mixed, .pressure])
        #expect(BarStyle.progress.rawValue == "progress")
        #expect(BarStyle.mixed.rawValue == "mixed")
        #expect(BarStyle.pressure.rawValue == "pressure")
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

    /// Per-surface scale helpers (#307): a surface draws the renormalised Pressure ribbon exactly
    /// when it draws no time marker. The two are one decision — a marker cannot live on the
    /// `[now .. reset]` track, where it would sit at zero forever — so the invariant is pinned here
    /// rather than left for each renderer to re-derive from a negated flag.
    @Test func perSurfacePressureScaleIsTheInverseOfTheMarker() {
        for style in BarStyle.allCases {
            #expect(style.menuBarUsesPressureScale == !style.menuBarShowsTimeMarker, "\(style)")
            #expect(style.popupUsesPressureScale == !style.popupShowsTimeMarker, "\(style)")
        }
        // Spelled out per case, so a future edit to either flag has to face both names.
        #expect(BarStyle.pressure.menuBarUsesPressureScale)
        #expect(BarStyle.pressure.popupUsesPressureScale)
        #expect(BarStyle.mixed.menuBarUsesPressureScale)    // Pressure in the compact menu bar…
        #expect(!BarStyle.mixed.popupUsesPressureScale)     // …Progress in the roomier dropdown
        #expect(!BarStyle.progress.menuBarUsesPressureScale)
        #expect(!BarStyle.progress.popupUsesPressureScale)
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
