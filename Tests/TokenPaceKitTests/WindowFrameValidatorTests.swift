import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - WindowFrameValidator (#261, ADR-0069)

/// The Settings window persists its frame, and a saved frame outlives the display layout it was
/// written under. These cover the two halves of that: what must be **rejected** (so the window never
/// reopens somewhere the user cannot reach it — the failure ADR-0035 removed persistence over), and
/// what must be **recovered** (a frame that merely hangs off an edge or is taller than today's screen
/// is still the user's preference and should be clamped, not discarded).
@Suite("WindowFrameValidator")
struct WindowFrameValidatorTests {

    /// A built-in 14" display: visible frame excludes menu bar and Dock, origin at zero.
    private static let builtIn = WindowFrameBox(x: 0, y: 0, width: 1512, height: 944)
    /// An external display placed to the right of the built-in one.
    private static let external = WindowFrameBox(x: 1512, y: 200, width: 2560, height: 1415)
    /// An external display placed to the **left** — macOS gives these a negative origin.
    private static let leftOfBuiltIn = WindowFrameBox(x: -1920, y: 0, width: 1920, height: 1080)

    private static let defaultSize = WindowFrameBox.Size(width: 857, height: 732)
    private static let minimumSize = WindowFrameBox.Size(width: 857, height: 480)

    /// Resolve against the built-in screen unless a different layout is given.
    private static func resolve(
        _ stored: WindowFrameBox?, screens: [WindowFrameBox] = [builtIn]
    ) -> WindowFrameValidator.Decision {
        WindowFrameValidator.resolve(
            stored: stored, visibleFrames: screens,
            defaultSize: defaultSize, minimumSize: minimumSize)
    }

    /// The frame a `.restore` decision carries, or `nil` when it fell back to the centred default.
    private static func restored(_ decision: WindowFrameValidator.Decision) -> WindowFrameBox? {
        guard case .restore(let box) = decision else { return nil }
        return box
    }

    // MARK: Nothing to restore

    @Test func firstLaunchOpensAtDefault() {
        #expect(Self.resolve(nil) == .centreDefault(Self.defaultSize))
    }

    /// `NSScreen.screens` really is empty for a moment while displays are being reconfigured. Guess
    /// nothing then — the default is always on screen.
    @Test func noScreensOpensAtDefault() {
        let frame = WindowFrameBox(x: 100, y: 100, width: 857, height: 732)
        #expect(Self.resolve(frame, screens: []) == .centreDefault(Self.defaultSize))
    }

    // MARK: Recoverable frames

    @Test func fullyVisibleFrameIsRestoredVerbatim() {
        let frame = WindowFrameBox(x: 300, y: 120, width: 857, height: 732)
        #expect(Self.restored(Self.resolve(frame)) == frame)
    }

    /// The pair that proves the display-layout hazard is handled: the same saved frame is restored
    /// while its screen is attached, and rejected once that screen is gone.
    @Test func frameOnSecondScreenIsRestoredWhileThatScreenExists() {
        let frame = WindowFrameBox(x: 1800, y: 400, width: 857, height: 900)
        let decision = Self.resolve(frame, screens: [Self.builtIn, Self.external])
        #expect(Self.restored(decision) == frame)
    }

    @Test func frameOnADetachedScreenFallsBackToDefault() {
        let frame = WindowFrameBox(x: 1800, y: 400, width: 857, height: 900)
        #expect(Self.resolve(frame, screens: [Self.builtIn]) == .centreDefault(Self.defaultSize))
    }

    @Test func frameHangingOffTheRightEdgeIsShiftedBackOn() {
        // 400 pt of the window sits past the screen's right edge.
        let frame = WindowFrameBox(x: 1055, y: 120, width: 857, height: 732)
        let restored = Self.restored(Self.resolve(frame))
        #expect(restored?.maxX == Self.builtIn.maxX)
        #expect(restored?.y == 120)          // the vertical position is untouched
        #expect(restored?.height == 732)
    }

    @Test func frameHangingBelowTheScreenIsShiftedBackOn() {
        let frame = WindowFrameBox(x: 300, y: -200, width: 857, height: 732)
        let restored = Self.restored(Self.resolve(frame))
        #expect(restored?.y == Self.builtIn.y)
        #expect(restored?.height == 732)     // shifted, not shrunk
    }

    @Test func frameTallerThanTheScreenIsClampedToIt() {
        // Saved on the tall external display, reopened on the built-in one alone.
        let frame = WindowFrameBox(x: 200, y: 100, width: 857, height: 1400)
        let restored = Self.restored(Self.resolve(frame))
        #expect(restored?.height == Self.builtIn.height)
        #expect(restored?.y == Self.builtIn.y)
    }

    @Test func hostScreenIsTheOneHoldingMostOfTheWindow() {
        // Straddles the seam, mostly on the external screen — it must be clamped into *that* one.
        let frame = WindowFrameBox(x: 1400, y: 400, width: 857, height: 732)
        let restored = Self.restored(Self.resolve(frame, screens: [Self.builtIn, Self.external]))
        #expect(restored?.x == Self.external.x)
        #expect(restored != nil)
    }

    /// A screen to the left has a negative origin; nothing may assume coordinates start at zero.
    @Test func screenWithNegativeOriginIsHandled() {
        let frame = WindowFrameBox(x: -1500, y: 200, width: 857, height: 732)
        let decision = Self.resolve(frame, screens: [Self.leftOfBuiltIn, Self.builtIn])
        #expect(Self.restored(decision) == frame)
    }

    // MARK: Unreachable frames

    @Test func frameEntirelyOffScreenFallsBackToDefault() {
        let frame = WindowFrameBox(x: 6000, y: 4000, width: 857, height: 732)
        #expect(Self.resolve(frame) == .centreDefault(Self.defaultSize))
    }

    /// Only a thin strip of the window is on screen — not enough to grab and drag back.
    @Test func frameVisibleOnlyAsASliverFallsBackToDefault() {
        let frame = WindowFrameBox(x: 1492, y: 120, width: 857, height: 732)   // 20 pt visible
        #expect(Self.resolve(frame) == .centreDefault(Self.defaultSize))
    }

    /// A window that merely pokes above the top edge is *fitted* (slid down), not discarded — it
    /// still belongs to this screen. What must be rejected is a frame whose title bar is off the
    /// screen it mostly sits on and cannot be fitted back: here only the window's bottom sliver
    /// reaches the screen below it, so pulling it down would teleport it away from where it was.
    @Test func frameOverhangingTheTopIsFittedRatherThanDiscarded() {
        let frame = WindowFrameBox(x: 300, y: 300, width: 857, height: 732)    // maxY = 1032 > 944
        let restored = Self.restored(Self.resolve(frame))
        #expect(restored?.maxY == Self.builtIn.maxY)
        #expect(restored?.height == 732)
    }

    /// While any part of the window still touches the screen, vertical overhang is recoverable —
    /// sliding it down lands it back on the screen it belongs to, however high it sat. Rejection is
    /// driven by losing contact with every screen (above), not by how far up the frame drifted; this
    /// pins that asymmetry so a change to the fitting order cannot quietly start discarding tall
    /// windows.
    @Test func verticalOverhangIsFittedWhileTheFrameStillTouchesTheScreen() {
        for y in [300.0, 900.0] {
            let frame = WindowFrameBox(x: 300, y: y, width: 857, height: 732)
            let restored = Self.restored(Self.resolve(frame))
            #expect(restored?.maxY == Self.builtIn.maxY)
            #expect(restored?.x == 300)
        }
    }

    // MARK: Corrupted values

    @Test func frameShorterThanTheMinimumFallsBackToDefault() {
        let frame = WindowFrameBox(x: 300, y: 120, width: 857, height: 200)
        #expect(Self.resolve(frame) == .centreDefault(Self.defaultSize))
    }

    @Test func frameNarrowerThanTheMinimumFallsBackToDefault() {
        let frame = WindowFrameBox(x: 300, y: 120, width: 400, height: 732)
        #expect(Self.resolve(frame) == .centreDefault(Self.defaultSize))
    }

    /// The zero-sized frame an early `windowDidResize` could write before the window is on screen.
    @Test func zeroSizedFrameFallsBackToDefault() {
        let frame = WindowFrameBox(x: 0, y: 0, width: 0, height: 0)
        #expect(Self.resolve(frame) == .centreDefault(Self.defaultSize))
    }

    @Test func nonFiniteValuesFallBackToDefault() {
        let cases = [
            WindowFrameBox(x: .nan, y: 120, width: 857, height: 732),
            WindowFrameBox(x: 300, y: .infinity, width: 857, height: 732),
            WindowFrameBox(x: 300, y: 120, width: 857, height: .nan),
        ]
        for frame in cases {
            #expect(Self.resolve(frame) == .centreDefault(Self.defaultSize))
        }
    }

    // MARK: Width normalisation

    /// The width is pinned by the window, so a stored width is a leftover of whatever the constant
    /// was when it was written — a build that changes the pin must win over it.
    @Test func storedWidthIsNormalisedToTheDefaultWidth() {
        let frame = WindowFrameBox(x: 300, y: 120, width: 900, height: 732)
        #expect(Self.restored(Self.resolve(frame))?.width == Self.defaultSize.width)
    }
}
