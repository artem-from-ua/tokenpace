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

// MARK: - Conditional rows (#381)

/// How a Settings row that appears and disappears with another control's value should move: a short
/// slide from the top edge plus a fade, so the row visibly folds out of the block it belongs to
/// instead of blinking in/out. `easeInOut` rather than a spring — an overshoot would push the
/// sections below past their resting place and back.
enum SettingsRowReveal {
    /// Keyed on the value that gates the row — a bare `.animation(_:)` would also animate every
    /// segmented-control change on the page.
    static let animation: Animation = .easeInOut(duration: 0.2)

    /// Computed rather than stored: `AnyTransition` is not `Sendable`, so a `static let` is a
    /// concurrency error.
    static var transition: AnyTransition { .move(edge: .top).combined(with: .opacity) }
}

/// A row title that dims when its row is disabled (#381). SwiftUI dims a control's **own** label
/// automatically, but most rows here put the title in a sibling `Text` (`.labelsHidden()` switches,
/// hand-built `HStack` rows), which SwiftUI has no way to associate with the control beside it — so
/// it stays at full strength over a greyed control without this.
struct SettingsDisabledLabel: View {
    let title: String
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String) { self.title = title }

    var body: some View {
        // `Text(.init(_:))` forces the `LocalizedStringKey` initializer, so inline markdown renders
        // (`Switching to *Extra usage*`, ADR-0113) instead of printing the asterisks verbatim.
        Text(.init(title))
            .foregroundStyle(isEnabled
                             ? AnyShapeStyle(.primary)
                             : AnyShapeStyle(Color(nsColor: .disabledControlTextColor)))
    }
}

/// A secondary-styled hint line under a control. When `warning` is set, it is prefixed with a
/// warning-triangle SF Symbol (the dev-build "Unavailable in development builds." treatment, #156).
struct SettingsHint: View {
    let text: String
    var warning: Bool = false

    /// Whether the enclosing row is interactive (#381). **Which hints belong inside the disabled
    /// scope is a call-site decision**: a hint **describing** the control ("Notifies you when the
    /// limit resets") dims with it; a hint **explaining unavailability** ("Unavailable in development
    /// builds.") must stay full strength — it's the recovery instruction, dimming it is backwards.
    /// `GeneralPane`'s launch-at-login row and `AboutPane`'s auto-install row are worked examples.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        if !text.isEmpty {
            Label {
                Text(.init(text))
            } icon: {
                if warning {
                    Image(systemName: "exclamationmark.triangle")
                }
            }
            .labelStyle(HintLabelStyle(showIcon: warning))
            .font(.callout)
            // Disabled drops it a further step to AppKit's own `disabledControlTextColor`, so the
            // whole row reads as one inactive block.
            .foregroundStyle(isEnabled
                             ? AnyShapeStyle(.secondary)
                             : AnyShapeStyle(Color(nsColor: .disabledControlTextColor)))
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A section header — the plain title, plus an optional hint line directly beneath it. Lives in the
/// `header:` slot so it renders **outside** the grouped card, reading as part of the heading rather
/// than as one more row.
struct SectionHeaderWithHint: View {
    let title: String
    /// Always a ⚠️ line — a neutral note belongs on the control it describes, not in the heading.
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            if let hint {
                // Cancel the header's inherited uppercase/tracking styling; `.textCase(nil)` must sit
                // on the text itself, not the VStack.
                SettingsHint(text: hint, warning: true)
                    .textCase(nil)
            }
        }
    }
}

/// The ⚠️ line shown under any section whose data is canned by a `TOKENPACE_STUB` scenario. Shared
/// so the wording stays identical everywhere; belongs to no single pane.
enum SettingsStubHint {
    static let text = "Stubbed in this development build."
}

// MARK: - SettingsNavigationRow (#341, ADR-0084)

/// A row inside a `Form` that opens a child page — the drill-in affordance System Settings uses.
/// Modelled on **Network** / **Internet Accounts**, not General: these rows *report* state
/// ("Usage API · 3 services monitored"), not just a name to tap through.
///
/// The leading ``badge`` carries a **generic glyph on the provider's brand color**, never the
/// provider's logo (Internet Accounts is the model; a redrawn wordmark is legally awkward). `nil`
/// keeps the text flush left.
///
/// Built from a plain `Button`, not a `NavigationLink`: a `NavigationSplitView` inside an
/// `NSHostingController` doesn't register its columns with the toolbar bridge, so `.navigation`
/// items would surface above the sidebar instead of in our AppKit toolbar's ‹ › (ADR-0077 §3, same
/// wall #156/#314 hit). The row only reports the tap; the model decides.
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
                    // `.tertiary` is the weight System Settings gives this chevron.
                    .foregroundStyle(.tertiary)
                    .font(.system(size: Metrics.chevron, weight: .semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(NavigationRowButtonStyle())
    }

    private enum Metrics {
        /// Gap between the text block and the chevron.
        static let chipTextGap: CGFloat = 10
        static let chevron: CGFloat = 11
        /// The state line, one step down from the row's own text — System Settings' proportion.
        static let subtitle: CGFloat = 11
    }
}

// MARK: - NavigationRowButtonStyle

/// A navigator row's press behaviour: the **whole block** takes the click and lights up. `.plain`'s
/// hit target is only the drawn content, so a click in the row's margins falls through and it draws
/// no pressed state.
///
/// **The negative insets are the point.** A grouped `Form` lays each row inside its own padding, so a
/// background added inside it paints a stripe narrower than the row with a dead gap on either side.
/// Expanding by the same insets pushes both the fill and the hit area back out to the card's edges.
private struct NavigationRowButtonStyle: ButtonStyle {

    /// Measured off a grouped `Form` on macOS 15 — SwiftUI exposes no metric for it. If a future
    /// macOS changes the padding, the failure is visible (fill short of or past the card edge).
    private enum Inset {
        static let horizontal: CGFloat = 10
        static let vertical: CGFloat = 6
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Inset.horizontal)
            .padding(.vertical, Inset.vertical)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.09 : 0)))
            // After the background, so the shape covers the padding above and not just the label.
            .contentShape(Rectangle())
            .padding(.horizontal, -Inset.horizontal)
            .padding(.vertical, -Inset.vertical)
    }
}

// MARK: - SettingsRowBadge

/// The tinted glyph chip a ``SettingsNavigationRow`` can carry at its leading edge.
///
/// Unlike `SettingsSection.tint`'s `CapsuleTint`, whose two endpoints are both measured off a real
/// System Settings pane, a brand gives us exactly one color — the second endpoint is therefore
/// **derived, not measured** via ``lightened(by:)``, using a mix fraction averaged from the measured
/// pairs (t = 0.188/0.191/0.503/0.616 across four panes, mean **0.375**) rather than from taste.
struct SettingsRowBadge: Equatable {
    /// The chip gradient's bottom-right endpoint — for a brand badge, the brand colour itself.
    let dark: Color
    /// Its top-left endpoint. Derived for a brand badge (see the type doc), measured for one built
    /// from a ``CapsuleTint``.
    let light: Color
    /// The SF Symbol drawn on it, always a generic one (see ``SettingsNavigationRow``'s doc on why a
    /// provider logo is not an option).
    let symbol: String
    /// The glyph's colour on an active window — white on every brand badge, black on the one white
    /// chip, which would otherwise draw white on white.
    var glyph: Color = .white
    /// Whether the chip needs a hairline to read against the form row behind it. Only the white one
    /// does; every other badge is darker than the material under it.
    var needsBorder: Bool = false
    /// Whether only the middle band of ``symbol`` is drawn — see ``SettingsChildPage/trimsOuterRules``.
    var trimsOuterRules: Bool = false

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

    /// A badge whose gradient is a ``CapsuleTint`` rather than a brand colour — the sidebar's own
    /// currency, so a page that used to be a sidebar row keeps the exact chip it wore there when it
    /// becomes a navigator row instead. Nothing is derived here: both endpoints come from the tint.
    static func tinted(_ tint: CapsuleTint, symbol: String, trimsOuterRules: Bool = false) -> SettingsRowBadge {
        SettingsRowBadge(
            dark: tint.dark,
            light: tint.light,
            symbol: symbol,
            glyph: tint.glyph,
            needsBorder: tint.needsBorder,
            trimsOuterRules: trimsOuterRules)
    }

    /// The badge for a child page that declares a chip of its own (``SettingsChildPage/tint``), or
    /// `nil` for one that carries none — `Claude`, whose badge is a brand colour instead.
    @MainActor
    static func page(_ page: SettingsChildPage) -> SettingsRowBadge? {
        guard let tint = page.tint, let symbol = page.symbol else { return nil }
        return .tinted(tint, symbol: symbol, trimsOuterRules: page.trimsOuterRules)
    }

    /// Anthropic's terracotta (`#d97757`, ADR-0021), the same `ColorRole` the popup's "Claude Code"
    /// header uses, so the two brand marks cannot drift apart.
    @MainActor
    static var claude: SettingsRowBadge {
        brand(ColorRole.claudeBrand.defaultColor, symbol: "cloud.fill")
    }

    /// GitHub's row (#454): the **same `cloud.fill`** Claude wears, on black — one glyph for every
    /// provider, deliberately. ADR-0094 §4: "color belongs to the brand, shape belongs to the
    /// system"; a per-provider glyph is also the seam where a logo eventually gets proposed, and a
    /// shared category glyph closes that door.
    @MainActor
    static var github: SettingsRowBadge {
        brand(ColorRole.githubBrand.defaultColor, symbol: "cloud.fill")
    }
}

private extension NSColor {

    /// In sRGB — the same space the measured capsule endpoints were read in.
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
/// rather than for the sidebar. Sized off **Internet Accounts** at 26 pt (the sidebar chip's size),
/// which on a two-line row reads as the row's icon. Keeps the sidebar chip's 5 pt corner radius and
/// gradient axis; the glyph is proportionally smaller (16 pt in 26 vs. 17 in 26) since a cloud fills
/// its box more than a gear does.
private struct SettingsRowBadgeView: View {
    let badge: SettingsRowBadge
    /// A flat tint takes no part in vibrancy, so it would stay full strength in an inactive window
    /// while every label around it dims without this.
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        glyph
            .foregroundStyle(badge.glyph)
            .frame(width: Metrics.chip, height: Metrics.chip)
            .background(fill, in: Self.shape)
            // Only the white chip asks for one — it's the single badge lighter than the row behind it.
            .overlay { if badge.needsBorder { Self.shape.stroke(Metrics.border, lineWidth: 1) } }
    }

    private static let shape = RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)

    @ViewBuilder
    private var glyph: some View {
        if badge.trimsOuterRules,
           let trimmed = SymbolTrim.middleBand(badge.symbol, size: Metrics.symbol) {
            Image(nsImage: trimmed)
        } else {
            Image(systemName: badge.symbol).font(.system(size: Metrics.symbol, weight: .regular))
        }
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
        /// Hairline around the white chip — the system separator colour, so it tracks the appearance
        /// the way every other divider in the window does (`SidebarChip.Metrics.chipBorder`).
        static let border = Color(nsColor: .separatorColor)
    }
}

// MARK: - SymbolTrim

/// Renders an SF Symbol with its outer strokes cut away, keeping only the middle band. Shared by the
/// sidebar chip and the navigator-row badge, each asking for the same slice at their own size.
enum SymbolTrim {

    /// The band between the two rules, generous enough to clear the rectangle's rounded corners at
    /// any size. Measured on the rendered glyph at 64 pt: rules at y 5–9 and 59–63, rectangle at
    /// y 23–45. Expressed as fractions of the glyph box so it holds at every chip size.
    static let band: ClosedRange<CGFloat> = 0.28...0.72

    /// Trims on the rendered `NSImage`, not via SwiftUI transforms: `.scaleEffect` + `.mask` looks
    /// equivalent but isn't — the scale moves the glyph's centre relative to the mask, so the
    /// surviving strip is not the one that was measured.
    static func middleBand(_ name: String, size: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        guard let full = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let kept = NSSize(width: full.size.width, height: full.size.height * (band.upperBound - band.lowerBound))
        guard kept.height > 0 else { return nil }
        let out = NSImage(size: kept)
        out.lockFocus()
        // Draw the whole glyph shifted down by the discarded lower band, so the kept slice lands in
        // the canvas and everything outside it falls off the edges.
        full.draw(in: NSRect(x: 0, y: -full.size.height * band.lowerBound,
                             width: full.size.width, height: full.size.height))
        out.unlockFocus()
        out.isTemplate = true
        return out
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
