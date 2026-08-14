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
/// `static let` on a single pane, which meant every other pane reached into that one for it — a
/// coupling that only got more awkward as panes moved (#333, #341). It belongs to no pane.
enum SettingsStubHint {
    static let text = "Stubbed in this development build."
}

// MARK: - SettingsNavigationRow (#341, ADR-0084)

/// A row inside a `Form` that opens a child page — the drill-in affordance System Settings uses on
/// its own parent pages.
///
/// Anatomy, read off a live System Settings window rather than from memory: the page's name, an
/// optional second line reporting its state, and a small grey chevron at the trailing edge. The
/// **whole row** is the hit target, not just the chevron.
///
/// Modelled on **Network** / **Internet Accounts**, not General. General's rows ("Storage ›") only
/// lead somewhere, so they carry a name and nothing else; ours *report* — "Usage API · 3 services
/// monitored" answers the question the page exists to answer, and reading it should not require
/// opening the page.
///
/// The leading ``badge`` is optional and stays that way. It carries a **generic glyph on the
/// provider's brand colour**, never the provider's logo — Internet Accounts' rows are the model here,
/// and a redrawn wordmark would be the legally awkward candidate the badge exists to avoid. A row
/// with nothing to identify beyond its own name passes `nil` and keeps the text flush left.
///
/// Built from a plain `Button` with `.buttonStyle(.plain)` rather than a `NavigationLink`: the
/// window's navigation state is ours (`SettingsModel`'s route plus the AppKit toolbar's ‹ ›), and a
/// `NavigationLink` would need a `NavigationStack` whose back button cannot land in our toolbar —
/// `NavigationSplitView` inside an `NSHostingController` does not register its columns with the
/// toolbar bridge, so SwiftUI `.navigation` items surface above the *sidebar* instead (ADR-0077 §3,
/// the same wall #156 and #314 hit). The row therefore only reports the tap; the model decides.
struct SettingsNavigationRow: View {
    let title: String
    /// The state line under the title. `nil` draws a single-line row.
    let subtitle: String?
    /// The tinted glyph chip at the leading edge. `nil` draws the row with its text flush left.
    var badge: SettingsRowBadge? = nil
    /// Invoked on click — the pane hands this straight to `SettingsModel.drill(into:)`.
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.chipTextGap) {
                if let badge { SettingsRowBadgeView(badge: badge) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: Metrics.subtitle))
                            .foregroundStyle(.secondary)
                    }
                }
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

    private enum Metrics {
        /// Gap between the text block and the chevron.
        static let chipTextGap: CGFloat = 10
        static let chevron: CGFloat = 11
        /// The state line, one step down from the row's own text — System Settings' proportion.
        static let subtitle: CGFloat = 11
    }
}

// MARK: - SettingsRowBadge

/// The tinted glyph chip a ``SettingsNavigationRow`` can carry at its leading edge.
///
/// Unlike `SettingsSection.tint`'s `CapsuleTint`, whose two endpoints are both Digital Color Meter
/// readings off a real System Settings pane, a brand gives us exactly one colour. The second endpoint
/// is therefore **derived, not measured** — ``lightened(by:)`` mixes the brand toward white — and it
/// is kept honest by taking the mix fraction from the measured pairs rather than from taste.
///
/// Modelling each measured `light` as `dark + t·(255 − dark)` per channel gives t = 0.188 for UI
/// presets, 0.191 for Notifications, 0.503 for About and 0.616 for General; the mean is **0.375**,
/// which is what ``brand(_:symbol:)`` applies. The spread across those four is wide because the
/// system's capsules are hand-picked artwork rather than one formula (the `CapsuleTint` doc says as
/// much), so any single fraction is a stand-in for a measurement we cannot take on a colour System
/// Settings never drew.
struct SettingsRowBadge: Equatable {
    /// The chip gradient's bottom-right endpoint — the brand colour itself, unmodified.
    let dark: Color
    /// Its top-left endpoint: the brand mixed toward white. Derived, never metered — see the type doc.
    let light: Color
    /// The SF Symbol drawn on it, always a generic one (see ``SettingsNavigationRow``'s doc on why a
    /// provider logo is not an option).
    let symbol: String

    /// The mix fraction toward white, averaged over the four measured sidebar capsules (see the type
    /// doc for the per-pane numbers).
    static let lightenFraction: CGFloat = 0.375

    /// A badge built from a single brand colour, lightening it for the gradient's far end.
    static func brand(_ color: NSColor, symbol: String) -> SettingsRowBadge {
        SettingsRowBadge(
            dark: Color(nsColor: color),
            light: Color(nsColor: color.lightened(by: lightenFraction)),
            symbol: symbol)
    }

    /// Claude's row: Anthropic's terracotta (`#d97757`, confirmed against `anthropics/skills`'
    /// `brand-guidelines/SKILL.md` — ADR-0021), carrying the cloud that used to sit on the Providers
    /// section itself before it became a puzzle piece. The colour comes from the same `ColorRole`
    /// the popup's "Claude Code" header uses, so the two brand marks cannot drift apart.
    ///
    /// Gradient ends up `#D97757` at the bottom-right, `#E7AA96` at the top-left — the second one
    /// derived, so check it with the meter rather than trusting it.
    @MainActor
    static var claude: SettingsRowBadge {
        brand(ColorStore.shared.color(.claudeBrand), symbol: "cloud.fill")
    }
}

private extension NSColor {

    /// This colour mixed toward white by `fraction`, in sRGB — the same space the measured capsule
    /// endpoints were read in, so the derived endpoint sits on the same scale as they do.
    func lightened(by fraction: CGFloat) -> NSColor {
        guard let srgb = usingColorSpace(.sRGB) else { return self }
        func mix(_ c: CGFloat) -> CGFloat { c + fraction * (1 - c) }
        return NSColor(srgbRed: mix(srgb.redComponent),
                       green: mix(srgb.greenComponent),
                       blue: mix(srgb.blueComponent),
                       alpha: srgb.alphaComponent)
    }
}

/// Draws a ``SettingsRowBadge``: a white glyph on a tinted rounded rect, sized for a `Form` row
/// rather than for the sidebar.
///
/// Sized off **Internet Accounts**, the pane this row is modelled on: there the account badge is
/// noticeably larger than a sidebar chip, spanning both the account name and its state line rather
/// than sitting beside the title alone. Ours does the same at 26 pt — the sidebar chip's size, which
/// on a two-line row reads as the row's icon rather than as a bullet in front of its text.
///
/// Keeps the sidebar chip's 5 pt continuous corner radius, and its gradient axis, so the two read as
/// the same family of object. The glyph is a touch smaller in proportion than the sidebar's (16 pt in
/// 26, against 17 in 26): a cloud fills its box more than a gear does, and matching the sidebar ratio
/// left it crowding the corners.
private struct SettingsRowBadgeView: View {
    let badge: SettingsRowBadge
    /// Same reasoning as the sidebar chip: a flat tint takes no part in vibrancy, so it would stay at
    /// full strength in an inactive window while every label around it dims. Halving the fill keeps
    /// the row's parts dimming together.
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        Image(systemName: badge.symbol)
            .font(.system(size: Metrics.symbol, weight: .regular))
            .foregroundStyle(.white)
            .frame(width: Metrics.chip, height: Metrics.chip)
            .background(fill, in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
    }

    /// Light at the top-left, brand at the bottom-right, on the sidebar capsule's own axis — tilted
    /// off vertical but shallower than the corner-to-corner diagonal.
    private var fill: AnyShapeStyle {
        let gradient = LinearGradient(
            colors: [badge.light, badge.dark],
            startPoint: Metrics.gradientLightPoint,
            endPoint: Metrics.gradientDarkPoint)
        return appearsActive
            ? AnyShapeStyle(gradient)
            : AnyShapeStyle(gradient.opacity(Metrics.inactiveAlpha))
    }

    private enum Metrics {
        static let chip: CGFloat = 26
        static let symbol: CGFloat = 16
        /// The sidebar chip's radius, unchanged — see the type doc.
        static let corner: CGFloat = 5
        static let inactiveAlpha: Double = 0.5
        /// The sidebar capsule's gradient axis, unchanged (`SidebarChip.Metrics`).
        static let gradientLightPoint = UnitPoint(x: 0.25, y: 0)
        static let gradientDarkPoint = UnitPoint(x: 0.75, y: 1)
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
