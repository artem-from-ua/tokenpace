import Foundation

// MARK: - CopyFeedback (#257)

/// Shared presentation rules for the app's **copy-to-clipboard buttons**, so every one of them looks
/// and behaves the same.
///
/// A clipboard write is invisible: nothing on screen changes, and there is no system-level
/// confirmation. Without feedback the only way to tell a click registered is to paste somewhere and
/// look. Each button therefore swaps its glyph to a checkmark for ``duration`` and swaps back.
///
/// The values live in the kit rather than in either UI because the two buttons are built with
/// different toolkits — the Appearance pane's is SwiftUI (`AppearancePane`), the Troubleshoot
/// window's is AppKit (`TroubleshootWindowController`) — and a constant duplicated across that seam
/// is exactly the kind that drifts. One gesture should not feel like two features.
public enum CopyFeedback {

    /// SF Symbol shown at rest: the standard "copy" glyph.
    public static let restingSymbol = "doc.on.doc"

    /// SF Symbol shown immediately after a successful copy.
    public static let confirmedSymbol = "checkmark"

    /// How long ``confirmedSymbol`` stays before reverting to ``restingSymbol``.
    ///
    /// Long enough to register if you glanced away mid-click, short enough that the button is back to
    /// its normal state before you would think to click it again.
    public static let duration: Double = 1.2

    /// Accessibility label for the button at rest. Callers pass what is being copied, since
    /// VoiceOver has no other way to distinguish two copy buttons in the same app.
    public static func restingLabel(_ what: String) -> String { "Copy \(what)" }

    /// Accessibility label while the checkmark is showing.
    public static let confirmedLabel = "Copied"
}
