import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - BarStyle (#224)

@Suite("BarStyle")
struct BarStyleTests {

    /// Three styles ship; the raw values are stable identifiers persisted in UserDefaults.
    @Test func casesAndRawValues() {
        #expect(BarStyle.allCases == [.pacing, .mixed, .simple])
        #expect(BarStyle.pacing.rawValue == "pacing")
        #expect(BarStyle.mixed.rawValue == "mixed")
        #expect(BarStyle.simple.rawValue == "simple")
    }

    /// Per-surface marker helpers: `.pacing` marks both, `.simple` marks neither, `.mixed` marks only
    /// the dropdown (pace-only menu bar).
    @Test func perSurfaceMarkers() {
        #expect(BarStyle.pacing.menuBarShowsTimeMarker)
        #expect(BarStyle.pacing.popupShowsTimeMarker)
        #expect(!BarStyle.simple.menuBarShowsTimeMarker)
        #expect(!BarStyle.simple.popupShowsTimeMarker)
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
        #expect(BarStyle.simple.menuBarUsesPressureScale)
        #expect(BarStyle.simple.popupUsesPressureScale)
        #expect(BarStyle.mixed.menuBarUsesPressureScale)    // Pressure in the compact menu bar…
        #expect(!BarStyle.mixed.popupUsesPressureScale)     // …Progress in the roomier dropdown
        #expect(!BarStyle.pacing.menuBarUsesPressureScale)
        #expect(!BarStyle.pacing.popupUsesPressureScale)
    }

    /// A known raw value round-trips through `Codable`.
    @Test func decodesKnownRawValue() throws {
        let data = Data(#""simple""#.utf8)
        let style = try JSONDecoder().decode(BarStyle.self, from: data)
        #expect(style == .simple)
    }

    /// Forward-compatible decode: an unrecognised raw string (a newer build's value) falls back to
    /// `.pacing` — the shipped behaviour — instead of throwing, so an older build never trips.
    @Test func decodesUnknownRawValueToPacing() throws {
        let data = Data(#""ribbon-3d""#.utf8)
        let style = try JSONDecoder().decode(BarStyle.self, from: data)
        #expect(style == .pacing)
    }
}
