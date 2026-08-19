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

/// How a Settings row that appears and disappears with another control's value should move.
///
/// Every pane used to suppress this outright (`.animation(nil, value:)`), on the grounds that an
/// insertion animation made the neighbouring rows flicker as the card changed height. That traded one
/// problem for another: a row **blinking** in or out gives no clue where it came from, so the change
/// reads as the window glitching rather than as a consequence of the click just made.
///
/// A short slide from the top edge plus a fade answers both. The row visibly folds out of the block it
/// belongs to, so the eye follows it instead of hunting for what changed; and the 0.2 s is short enough
/// that the height change reads as one motion rather than as a bounce.
///
/// `easeInOut` rather than a spring: the card is resizing, and an overshoot would push the sections
/// below it past their resting place and back.
enum SettingsRowReveal {
    /// The animation to attach to the **container** (the `Form` or `Section`), keyed on the value that
    /// gates the row. Scoping it to that value matters — a bare `.animation(_:)` would also animate every
    /// segmented-control change on the page, so picking a different segment would slide its own control.
    static let animation: Animation = .easeInOut(duration: 0.2)

    /// The transition to attach to the **row**. `.top` rather than the default fade-in-place: the gated
    /// row always sits under the control that gates it, so folding out of the top edge points back at the
    /// thing that was just clicked.
    ///
    /// Computed rather than stored: `AnyTransition` is not `Sendable`, so a `static let` of it is a
    /// concurrency error. Rebuilding the value per use costs nothing here.
    static var transition: AnyTransition { .move(edge: .top).combined(with: .opacity) }
}

/// A row title that dims when its row is disabled (#381).
///
/// SwiftUI dims a control's **own** label automatically, but most rows here put the title in a sibling
/// `Text` — either because the control carries `.labelsHidden()` (the notification switches) or because
/// the row is a hand-built `HStack` (the Appearance segmented rows). SwiftUI has no way to know such a
/// `Text` belongs to the control beside it, so it stays at full strength over a greyed control and the
/// row reads as half-live.
///
/// Uses AppKit's `disabledControlTextColor` — the colour the platform ships for exactly this ("Text on
/// disabled controls", `NSColor.h`) — so a disabled row here matches every system-drawn one and follows
/// the theme without a second rule.
struct SettingsDisabledLabel: View {
    let title: String
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String) { self.title = title }

    var body: some View {
        // `Text(.init(_:))` forces the `LocalizedStringKey` initializer, which renders inline
        // markdown — the same idiom `SettingsHint` uses. A row label may name another surface's
        // element in italics (`Switching to *Extra usage*`, ADR-0113), and the plain `Text(String)`
        // initializer would print the asterisks verbatim. Labels without markup render identically.
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

    /// Whether the enclosing row is interactive (#381).
    ///
    /// Handled here rather than at each call site so a hint follows its row without every pane having to
    /// remember — but **which hints belong inside the disabled scope is a call-site decision**, and the
    /// distinction is not cosmetic:
    ///
    /// - a hint that **describes** what the control does ("Notifies you when the limit resets") is part
    ///   of the control, and dims with it — at full strength it makes a disabled row read as half-live;
    /// - a hint that **explains why the control is unavailable** ("Unavailable in development builds.",
    ///   "Notifications are turned off for TokenPace — enable them in System Settings") must stay at full
    ///   strength. It is the one line the user still needs, and dimming the recovery instructions along
    ///   with the thing they recover is backwards.
    ///
    /// So put a describing hint inside the `.disabled(…)` scope and leave an explaining one outside it.
    /// `GeneralPane`'s launch-at-login row and `AboutPane`'s auto-install row are the worked examples.
    @Environment(\.isEnabled) private var isEnabled

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
            // Already secondary when live; disabled drops it a further step to AppKit's own
            // `disabledControlTextColor` ("Text on disabled controls", `NSColor.h`), so the whole row —
            // title, control and explanation — reads as one inactive block.
            .foregroundStyle(isEnabled
                             ? AnyShapeStyle(.secondary)
                             : AnyShapeStyle(Color(nsColor: .disabledControlTextColor)))
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

/// A navigator row's press behaviour: the **whole block** takes the click and lights up, the way
/// System Settings' own drill-in rows do.
///
/// `.plain` gave neither. Its hit target is the drawn content, so a click in the row's margins fell
/// through, and it draws no pressed state at all — the row that looked like one target behaved like a
/// piece of text with some dead space around it.
///
/// **The negative insets are the point.** A grouped `Form` lays each row inside its own padding, and a
/// background added inside that padding paints a stripe narrower than the row, with a gap on either
/// side that still swallows clicks. Expanding by the same insets pushes both the fill and the hit area
/// back out to the card's edges, which is where the row's boundary actually is.
private struct NavigationRowButtonStyle: ButtonStyle {

    /// The form's own row padding, which this reaches back across.
    ///
    /// Measured off a grouped `Form` on macOS 15 rather than derived: SwiftUI exposes no metric for it.
    /// If a future macOS changes the padding these numbers follow it — the failure is visible (a fill
    /// that stops short of the card edge, or bleeds past it), which is the kind worth having.
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

    /// Claude's row: Anthropic's terracotta (`#d97757`, confirmed against `anthropics/skills`'
    /// `brand-guidelines/SKILL.md` — ADR-0021), carrying the cloud that used to sit on the Providers
    /// section itself before it became a puzzle piece. The colour comes from the same `ColorRole`
    /// the popup's "Claude Code" header uses, so the two brand marks cannot drift apart.
    ///
    /// Gradient ends up `#D97757` at the bottom-right, `#E7AA96` at the top-left — the second one
    /// derived, so check it with the meter rather than trusting it.
    @MainActor
    static var claude: SettingsRowBadge {
        brand(ColorRole.claudeBrand.defaultColor, symbol: "cloud.fill")
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
        glyph
            .foregroundStyle(badge.glyph)
            .frame(width: Metrics.chip, height: Metrics.chip)
            .background(fill, in: Self.shape)
            // Only the white chip asks for one, for the same reason its sidebar twin does: it is the
            // single badge lighter than the row behind it, so without a hairline its edge is not there.
            .overlay { if badge.needsBorder { Self.shape.stroke(Metrics.border, lineWidth: 1) } }
    }

    /// The chip outline, shared by the fill and the optional border so the two cannot drift.
    private static let shape = RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)

    /// The symbol, drawn whole — or, for a badge that asks for it, only the middle band of it
    /// (`SymbolTrim`, the same renderer the sidebar chip uses).
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

/// Renders an SF Symbol with its outer strokes cut away, keeping only the middle band.
///
/// Shared by the sidebar chip and the navigator-row badge: the band is a property of the *glyph*
/// (`distribute.vertical`'s rounded rectangle between two full-width rules), so it has to survive a
/// page moving between the two surfaces. Both callers ask for the same slice at their own size.
enum SymbolTrim {

    /// The slice of the symbol's height that is kept — the band between the two rules, generous
    /// enough to clear the rectangle's rounded corners at any size. Measured on the rendered glyph at
    /// 64 pt (91×68 px): rules at y 5–9 and 59–63, rectangle at y 23–45, with clean gaps between.
    /// Expressed as fractions of the glyph box rather than pixels so it holds at every chip size.
    static let band: ClosedRange<CGFloat> = 0.28...0.72

    /// Render `name` at `size` and keep only ``band`` of its height.
    ///
    /// The trim happens on the rendered `NSImage`, not through SwiftUI transforms: the band is cut out
    /// and the result handed over as a plain image, so it lays out as exactly what it is. The
    /// `.scaleEffect` + `.mask` spelling looks equivalent and is not — the scale moves the glyph's
    /// centre relative to the mask, so the surviving strip is not the one that was measured. The image
    /// is left as a template so the caller's own `foregroundStyle` still tints it.
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
