import Foundation

// MARK: - WindowFrameBox

/// A rectangle in macOS screen coordinates (origin **bottom-left**, y grows upward), in plain
/// `Double` so the validator stays framework-free: `TokenPaceKit` has no CoreGraphics or AppKit
/// dependency (ADR-0009), and Phase 2 (iOS/watchOS) should not inherit one. The shell converts
/// to/from `CGRect`/`NSRect` at the boundary.
public struct WindowFrameBox: Sendable, Equatable {

    /// A width/height pair — the size half of a frame, used for the "open at this size, centred"
    /// answer where a position does not exist yet.
    public struct Size: Sendable, Equatable {
        public let width: Double
        public let height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var size: Size { Size(width: width, height: height) }

    /// Every component is a real, finite number. A `UserDefaults` value can come back as `NaN`/`Inf`
    /// after a corrupted write, and arithmetic on those silently poisons every comparison below.
    var isFinite: Bool { x.isFinite && y.isFinite && width.isFinite && height.isFinite }

    /// The overlapping rectangle with `other`, or `nil` when they do not overlap. Touching edges
    /// count as **no** overlap: a zero-area sliver is not something the user can see or grab.
    func intersection(_ other: WindowFrameBox) -> WindowFrameBox? {
        let left = max(x, other.x)
        let right = min(maxX, other.maxX)
        let bottom = max(y, other.y)
        let top = min(maxY, other.maxY)
        guard right > left, top > bottom else { return nil }
        return WindowFrameBox(x: left, y: bottom, width: right - left, height: top - bottom)
    }
}

// MARK: - WindowFrameValidator

/// Decides whether a **restored** window frame is still usable under the *current* screen layout
/// (ADR-0069).
///
/// This is the guard whose absence made ADR-0035 drop `setFrameAutosaveName` altogether: a saved
/// frame outlives the display layout it was valid for (a monitor was unplugged, the resolution or
/// scale changed), and AppKit does **not** re-validate a restored frame against the current layout —
/// it only constrains frames the *user* drags. Persisting geometry is therefore only acceptable
/// together with this check, which the shell runs before applying anything.
///
/// Pure and framework-free, so "is this saved geometry still sane?" is unit-tested against synthetic
/// screen layouts — no `NSWindow`, and no second monitor to plug in (ADR-0009, ADR-0023).
public enum WindowFrameValidator {

    /// What the caller should do with the stored frame.
    public enum Decision: Sendable, Equatable {
        /// The frame is usable — apply it verbatim (it is already clamped and shifted to fit).
        case restore(WindowFrameBox)
        /// No usable stored frame — open at this size and centre it.
        case centreDefault(WindowFrameBox.Size)
    }

    /// How much of the window's **title-bar strip** must stay on screen for the frame to count as
    /// reachable: the user has to be able to grab it and drag the window back. AppKit enforces
    /// something similar while dragging, but not for a frame set programmatically, so it is stated
    /// explicitly here.
    static let minimumVisibleWidth: Double = 120
    static let minimumVisibleHeight: Double = 44

    /// Resolve a stored frame against the screens that exist right now.
    ///
    /// - Parameters:
    ///   - stored: The frame read back from persistence; `nil` on a first launch or an unreadable value.
    ///   - visibleFrames: Every screen's *visible* frame (menu bar and Dock already excluded). Empty
    ///     means "no screens", a real transient state mid display-reconfiguration — treated as
    ///     "cannot validate" rather than guessed at.
    ///   - defaultSize: The size to open at when the stored frame is unusable. Its width is also the
    ///     authoritative window width (this window is width-pinned).
    ///   - minimumSize: The smallest acceptable frame. A stored frame below it is rejected rather
    ///     than grown: a sliver is the symptom of a bad write, not a user preference.
    public static func resolve(
        stored: WindowFrameBox?,
        visibleFrames: [WindowFrameBox],
        defaultSize: WindowFrameBox.Size,
        minimumSize: WindowFrameBox.Size
    ) -> Decision {
        let fallback = Decision.centreDefault(defaultSize)

        guard let stored, stored.isFinite, !visibleFrames.isEmpty else { return fallback }
        guard stored.width >= minimumSize.width, stored.height >= minimumSize.height else {
            return fallback
        }

        // The width is pinned by the window itself, so a stored width is a *derivative* of whatever
        // the constant was when it was written — never a preference. Normalising here means a build
        // that changes the pinned width doesn't restore old windows at the old width.
        let width = defaultSize.width
        let candidate = WindowFrameBox(x: stored.x, y: stored.y, width: width, height: stored.height)

        // The host screen is the one the window mostly sits on — not the first that happens to touch
        // it, which would pick the wrong screen for a window straddling two displays.
        guard let host = hostScreen(for: candidate, among: visibleFrames) else { return fallback }

        // Correct for "today's screen is shorter than the one this was saved on" before judging the
        // frame: clamp the height, keeping the **top** edge where the user left it (a window shrinks
        // downwards on macOS; the title bar is the anchor they track), then pull the top down under
        // the screen's top edge if it still overhangs. Both are mechanical consequences of a smaller
        // screen, not evidence that the window is somewhere unreachable — judging before them would
        // reject the very case this rescues.
        let height = min(candidate.height, host.height)
        let top = min(candidate.maxY, host.maxY)
        let resized = WindowFrameBox(x: candidate.x, y: top - height, width: width, height: height)

        // The verdict is taken on where the window *is* after those corrections, not on where it
        // could be nudged to: slide a frame far enough and anything touching a screen becomes
        // reachable, which would restore windows the user last saw on a monitor that is now gone.
        guard let overlap = resized.intersection(host),
              isTitleBarReachable(frame: resized, overlap: overlap)
        else { return fallback }

        // Accepted — now nudge it fully onto its screen. A window that hung a little off an edge is
        // still where the user put it.
        return .restore(WindowFrameBox(
            x: clamp(resized.x, span: width, within: host.x, host.maxX),
            y: clamp(resized.y, span: height, within: host.y, host.maxY),
            width: width,
            height: height))
    }

    /// The screen with the largest overlap, or `nil` when the frame touches none of them (its screen
    /// is gone — the frame is off-screen entirely and nothing can be recovered from it).
    private static func hostScreen(
        for frame: WindowFrameBox, among screens: [WindowFrameBox]
    ) -> WindowFrameBox? {
        screens
            .compactMap { screen -> (screen: WindowFrameBox, area: Double)? in
                guard let overlap = frame.intersection(screen) else { return nil }
                return (screen, overlap.width * overlap.height)
            }
            .max { $0.area < $1.area }?
            .screen
    }

    /// Whether enough of the title bar — the strip along the window's **top** edge — is on screen to
    /// be grabbed. Checking the overlap's total area is not enough: a window pushed up under the menu
    /// bar can overlap a screen generously while its draggable strip sits entirely off it.
    ///
    /// In practice this rejects on the **horizontal** axis (a window pushed off the side until only a
    /// sliver shows), because the caller has already pulled the top edge down under the screen's:
    /// vertical overhang is always recoverable while the frame still touches a screen. Losing contact
    /// with every screen is caught earlier, by there being no host screen at all.
    private static func isTitleBarReachable(frame: WindowFrameBox, overlap: WindowFrameBox) -> Bool {
        overlap.width >= minimumVisibleWidth
            && overlap.maxY >= frame.maxY - minimumVisibleHeight
    }

    /// Slide a span of `span` starting at `origin` so it sits inside `[lower, upper]`. When the span
    /// is wider than the range (a screen narrower than the pinned window width), it is pinned to
    /// `lower` and allowed to overhang — the window's own min/max size will not let it be narrowed,
    /// and an overhanging right edge beats a broken layout.
    private static func clamp(
        _ origin: Double, span: Double, within lower: Double, _ upper: Double
    ) -> Double {
        guard span <= upper - lower else { return lower }
        return min(max(origin, lower), upper - span)
    }
}
