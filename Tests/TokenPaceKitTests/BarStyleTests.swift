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
        #expect(!BarStyle.mixed.menuBarShowsTimeMarker)   // pace-only in the menu bar
        #expect(BarStyle.mixed.popupShowsTimeMarker)      // pace & time in the dropdown
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
