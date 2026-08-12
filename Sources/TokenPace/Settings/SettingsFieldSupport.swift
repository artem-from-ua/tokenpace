import SwiftUI
import TokenPaceKit

// MARK: - Settings field support (#168, ADR-0042)

/// Cross-pane SwiftUI helpers shared by the Settings panes.

extension SuppressDays {
    /// The user-facing menu title for the "Suppress on weekends" picker. Kept in the shell (a view
    /// concern) so the kit's raw values stay stable for persistence.
    var displayName: String {
        switch self {
        case .never:  return "Never"
        case .friSat: return "Friday–Saturday"
        case .satSun: return "Saturday–Sunday"
        }
    }
}

extension SettingsModel {
    /// A `Binding<Date>` over a minute-of-day model field, for a `DatePicker(.hourMinute)`. Reads via
    /// `MinuteOfDay.date(from:)` and writes both window minutes back through `setNotifyWindow` so the
    /// persist-then-nothing ordering and the live duration label stay correct.
    func notifyStartBinding(anchor: Date) -> Binding<Date> {
        Binding(
            get: { MinuteOfDay.date(from: self.notifyStartMinute, anchor: anchor) },
            set: { self.setNotifyWindow(start: MinuteOfDay.minute(from: $0), end: self.notifyEndMinute) })
    }

    func notifyEndBinding(anchor: Date) -> Binding<Date> {
        Binding(
            get: { MinuteOfDay.date(from: self.notifyEndMinute, anchor: anchor) },
            set: { self.setNotifyWindow(start: self.notifyStartMinute, end: MinuteOfDay.minute(from: $0)) })
    }
}

/// A secondary-styled hint line under a control. When `warning` is set, it is prefixed with a
/// warning-triangle SF Symbol (the dev-build "Unavailable in development builds." treatment, #156).
struct SettingsHint: View {
    let text: String
    var warning: Bool = false

    var body: some View {
        if !text.isEmpty {
            Label {
                // `.init(text)` forces the LocalizedStringKey initializer, so inline markdown
                // (`**bold**` / `*italic*`) in a hint renders; plain hints are unaffected.
                Text(.init(text))
            } icon: {
                if warning {
                    Image(systemName: "exclamationmark.triangle")
                }
            }
            .labelStyle(HintLabelStyle(showIcon: warning))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A section header — the plain title, plus an optional hint line directly beneath it. Because it
/// lives in the `header:` slot it renders **outside** the grouped card, so a caveat that covers the
/// whole section reads as part of the heading rather than as one more row among the controls.
///
/// `hint` is `nil` for the ordinary case, which then renders exactly like a plain `Section("Title")`.
struct SectionHeaderWithHint: View {
    let title: String
    /// The caveat shown under the title. Always a ⚠️ line — a neutral note belongs on the control it
    /// describes, not in the heading.
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            if let hint {
                // Cancel the header's inherited uppercase/tracking styling so the hint matches the
                // in-card hints; `.textCase(nil)` has to sit on the text itself, not the VStack.
                SettingsHint(text: hint, warning: true)
                    .textCase(nil)
            }
        }
    }
}

/// The ⚠️ line shown under any section whose data is canned by a `TOKENPACE_STUB` scenario.
///
/// Shared rather than duplicated so the wording stays identical wherever it appears. It used to be a
/// `static let` on `ExtraFeaturesPane`, which meant every other pane reached into that one for it —
/// a coupling that only got more awkward as panes moved (#333). It belongs to no pane.
enum SettingsStubHint {
    static let text = "Stubbed in this development build."
}

// MARK: - SettingsNavigationRow (#333, ADR-0082)

/// A row inside a `Form` that opens a child page — the drill-in affordance System Settings uses on
/// its own parent pages (Network's "Wi-Fi ›", "Firewall ›").
///
/// Anatomy, read off a live System Settings window rather than from memory: a tinted capsule with a
/// white glyph, the page's name, and a small grey chevron at the trailing edge. The **whole row** is
/// the hit target, not just the chevron.
///
/// Modelled on **General**'s rows ("Інформація ›", "Сховище ›"), not Network's. Network draws a
/// bigger chip and a second line because those rows report live state ("Connected"); a row that only
/// leads somewhere carries the name alone, and its chip is correspondingly smaller. Ours lead
/// somewhere — so a subtitle would be filler dressed as information.
///
/// Built from a plain `Button` with `.buttonStyle(.plain)` rather than a `NavigationLink`: the
/// window's navigation state is ours (`SettingsModel`'s route plus the AppKit toolbar's ‹ ›), and a
/// `NavigationLink` would need a `NavigationStack` whose back button cannot land in our toolbar —
/// `NavigationSplitView` inside an `NSHostingController` does not register its columns with the
/// toolbar bridge, so SwiftUI `.navigation` items surface above the *sidebar* instead (ADR-0077 §3,
/// the same wall #156 and #314 hit). The row therefore only reports the tap; the model decides.
struct SettingsNavigationRow: View {
    let page: SettingsChildPage
    /// Invoked on click — the pane hands this straight to `SettingsModel.drill(into:)`.
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.chipTextGap) {
                chip
                Text(page.title)
                Spacer(minLength: Metrics.chipTextGap)
                Image(systemName: "chevron.right")
                    // `.tertiary` is the weight System Settings gives this chevron: present enough to
                    // read as "there is more here", never competing with the row's own text.
                    .foregroundStyle(.tertiary)
                    .font(.system(size: Metrics.chevron, weight: .semibold))
            }
            // Without this the hit target is only the drawn content, leaving the gap between the
            // subtitle and the chevron dead — but the whole row is what looks clickable.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The chip: a flat black or white rounded rect with the glyph in the opposite tone. Not
    /// `SidebarChip` — that one carries the sidebar's measured gradient and its inactive-window
    /// dimming, neither of which applies to a chip that depicts a surface rather than naming a pane.
    private var chip: some View {
        Image(systemName: page.symbol)
            .font(.system(size: Metrics.symbol, weight: .regular))
            .foregroundStyle(page.fill.glyph)
            .frame(width: Metrics.chip, height: Metrics.chip)
            .background(page.fill.capsule, in: shape)
            // Only the white chip gets one; `nil` draws nothing at all.
            .overlay { page.fill.border.map { shape.stroke($0, lineWidth: 1) } }
    }

    /// The chip's outline, shared by its fill and its (optional) border so the two cannot drift.
    /// 5 pt continuous — the same corner the sidebar chips use (System Settings' own).
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 5, style: .continuous) }

    private enum Metrics {
        /// Capsule and glyph sizes for a chip in a `Form` row, measured off System Settings →
        /// **General**, whose rows are the shape ours copy (a name plus a chevron, no status line).
        /// Its chips render ~20 pt, distinctly smaller than the ~27 pt Network uses for its
        /// status-carrying rows — the size tracks how much the row has to say, not the window.
        ///
        /// These do **not** track the system "Sidebar icon size" bucket: that setting governs source
        /// lists, and a form row does not resize with it (checked against System Settings — its rows
        /// keep their chip size while the sidebar's icons change).
        static let chip: CGFloat = 20
        static let symbol: CGFloat = 12
        /// Gap between the chip and the title.
        static let chipTextGap: CGFloat = 10
        static let chevron: CGFloat = 11
    }
}

/// Shows the icon only when present, so a plain hint has no leading gap.
private struct HintLabelStyle: LabelStyle {
    let showIcon: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if showIcon { configuration.icon }
            configuration.title
        }
    }
}
