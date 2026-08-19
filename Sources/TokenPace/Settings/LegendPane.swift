import SwiftUI
import TokenPaceKit

// MARK: - LegendPane (#261)

/// Appearance › Legend — the visual language, explained.
///
/// The one page in Settings that **sets nothing**. Everything the widget encodes into very little
/// pixel area — five pacing colours, three bar styles, a handful of glyphs — was until now explained
/// only in `USER-GUIDE.md`, in issue threads and in the maintainer's head. A reader who saw a blue
/// bar or a raised hand had no way, inside the app, to find out what it meant.
///
/// Three rules shaped the content, each of which corrected a real line while it was being drafted:
///
/// 1. **No word from the code.** `surface`, `window`, `gap`, `pacing`, `calm` are this project's
///    vocabulary, not the reader's. They see *Menu bar* and *Dropdown* (as Appearance names them) and
///    think "between resets", not "the window".
/// 2. **A term lives where it was introduced.** `now-marker` is captioned on the diagram before the
///    rules below it use the word. An earlier draft dropped the caption that introduced *gap* and left
///    three rules referring to something no longer named anywhere on screen.
/// 3. **Mute what is not the subject; full ink for what is.** The explanation lines *are* the content
///    here — the bar beside them is the illustration, not the other way round. They are drawn in
///    `.primary`, not the `.secondary` a settings row's subtitle would use.
struct LegendPane: View {

    /// Read purely to force a rebuild when the theme flips.
    ///
    /// The dropdown specimens are non-template `NSImage`s, so their semantic colours are resolved at
    /// bake time and do **not** re-resolve on a theme change. Without this dependency the bars would
    /// stay frozen in whichever theme the page was first opened under — the same reason
    /// `BarStylePicker` reads it. The menu-bar specimens are immune (pinned `.vibrantDark`).
    @Environment(\.colorScheme) private var colorScheme

    /// The vibrant appearance the popup bars are baked under.
    ///
    /// Vibrant rather than plain: the live bars are drawn inside an `NSMenu`, where the palette
    /// resolves differently — measured, the track comes back opaque there instead of translucent, and
    /// the greens differ outright. Passed explicitly rather than read from `NSApp` inside the
    /// renderer, because this view can be hosted under a forced appearance.
    private var barAppearance: NSAppearance? {
        NSAppearance(named: colorScheme == .dark ? .vibrantDark : .vibrantLight)
    }

    var body: some View {
        Form {
            colorSection
            menuBarSection
            markerlessSection
            progressSection
            iconSection
        }
        .formStyle(.grouped)
    }

    // MARK: 1 · Colours

    /// The five tiers, plus the muted white that is not a sixth.
    ///
    /// The subtitle carries this section's real work. It names the **purpose** — pace, not level — and
    /// its second half pre-empts the misreading #254 documented as near-universal: a horizontal bar
    /// beside a percentage reads as a progress bar, and the colour then looks like "how full", which
    /// is the one thing it never means.
    private var colorSection: some View {
        Section(header: heading("What a bar’s colour says",
                                detail: "how fast you’re spending, not how much")) {
            ForEach(Array(LegendCatalog.tiers.enumerated()), id: \.offset) { _, tier in
                legendRow(swatch: { stroke(colour: Color(LegendRenderer.tierColor(tier.layout))) },
                          name: tier.word,
                          detail: Self.tierDetail[tier.word] ?? "")
            }
            legendRow(swatch: { stroke(colour: Color(nsColor: ColorRole.calmWhite.defaultColor),
                                       outlined: true) },
                      name: "no colour",
                      detail: "optionally replaces non-critical colours in the menu bar")
        }
    }

    /// What each tier means, keyed by the status word the dropdown prints for it.
    ///
    /// Kept beside the words rather than in `LegendCatalog`: the kit type carries the *states*, which
    /// are testable, while these are presentation copy that belongs with the view drawing them.
    private static let tierDetail: [String: String] = [
        "far behind pace": "big surplus · spend freely · 5-hour & 7-day bars only",
        "on pace": "all good · keep going",
        "ahead of pace": "a bit fast · nothing to do yet",
        "well ahead of pace": "slow down",
        "limit reached": "blocked until it resets",
    ]

    // MARK: 2 · Menu bar

    /// Two renders of the widget: both bars, then only the seven-day one.
    ///
    /// **One story, not two illustrations.** The seven-day bar is identical in both and the five-hour
    /// bar — the calm one — is what disappears, which is exactly what `TopBarHiding` does in the live
    /// widget. A pair of unrelated states would have left the reader hunting for which of several
    /// differences the section was about.
    ///
    /// **Two equal halves, each centred within its own.** The row splits the width evenly rather than
    /// packing both cases against the leading edge, and nothing divides them: a rule between two
    /// pictures of the same widget would say they are separate subjects, when the whole point is that
    /// one is the other a moment later.
    ///
    /// Centring is what makes the halves comparable despite differing widths — `snapshotImage()` sizes
    /// each render from its own layout, so the one-bar image is genuinely narrower. Left-aligned, that
    /// difference reads as the widget having moved; centred, each specimen sits in the middle of the
    /// space it is being compared in.
    private var menuBarSection: some View {
        Section(header: heading("Menu bar", detail: nil)) {
            HStack(alignment: .top, spacing: 0) {
                menuBarCase(fiveHour: LegendCatalog.menuBarFiveHour,
                            sevenDay: LegendCatalog.menuBarSevenDay,
                            caption: "5-hour on top · 7-day below")
                menuBarCase(fiveHour: nil,
                            sevenDay: LegendCatalog.menuBarSevenDay,
                            caption: "7-day only · 5-hour hidden while calm")
            }
        }
    }

    /// One half of the Menu bar row: the specimen over its caption, both centred, filling half the
    /// width. `maxWidth: .infinity` on each of two siblings is what divides the row evenly.
    private func menuBarCase(fiveHour: BarLayout?, sevenDay: BarLayout?,
                             caption: String) -> some View {
        VStack(alignment: .center, spacing: 7) {
            Image(nsImage: LegendRenderer.menuBarImage(fiveHour: fiveHour, sevenDay: sevenDay))
                // The menu bar is dark under either theme, so the specimen needs a dark plate to sit
                // on — the same argument `BarStylePicker`'s black tile makes.
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.black.opacity(colorScheme == .dark ? 0.35 : 0.8)))
            Text(caption)
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 3 · Balance & Pressure

    /// Both marker-less styles, drawn from **one** state so the reader can see they measure the same
    /// quantity from different zeros (`pressureLength ≡ max(0, balanceOffset)`, ADR-0101).
    ///
    /// Balance first: it shows the whole scale, and Pressure is its right half. Naming the derived one
    /// second is what makes the sentence under them read as a fact rather than a coincidence.
    private var markerlessSection: some View {
        Section(header: heading("Balance & Pressure bar styles",
                                detail: "how far you’ve drifted from steady spending")) {
            anatomy(style: .balance,
                    caption: "zero in the middle · grows both ways", name: "Balance")
            anatomy(style: .pressure,
                    caption: "zero at the left · grows right only", name: "Pressure")
            Text("*Pressure* is *Balance*’s right half")
                .font(.callout)
            ForEach(Array(Self.markerlessRules.enumerated()), id: \.offset) { _, rule in
                ruleRow(style: .balance, layout: rule.layout, text: rule.text)
            }
        }
    }

    /// The reading rules, ordered left-to-right as the ribbon travels: behind, on pace, ahead.
    private static var markerlessRules: [(layout: BarLayout, text: String)] {
        [(LegendCatalog.progressSpecimen, "grows left — behind pace · *Balance* only"),
         (LegendCatalog.onPaceSpecimen, "dot at the zero — on pace"),
         (LegendCatalog.markerlessSpecimen, "grows right — ahead of pace · the wider, the more so")]
    }

    // MARK: 4 · Progress

    /// The one style whose track carries two scales at once.
    private var progressSection: some View {
        Section(header: heading("Progress bar style",
                                detail: "shows where you are between resets")) {
            anatomy(style: .progress, subdivisions: 5,
                    caption: "the limit window edge to edge · two readings: time and usage",
                    name: "Progress")
            ForEach(Array(Self.progressRules.enumerated()), id: \.offset) { _, rule in
                ruleRow(style: .progress, layout: rule.layout, text: rule.text)
            }
        }
    }

    private static var progressRules: [(layout: BarLayout, text: String)] {
        [(LegendCatalog.progressSpecimen, "now-marker on the right — behind the clock"),
         (LegendCatalog.markerlessSpecimen, "now-marker on the left — ahead of the clock"),
         (LegendCatalog.exhaustedSpecimen, "limit reached")]
    }

    // MARK: 5 · Icons

    private var iconSection: some View {
        Section(header: heading("Icons", detail: nil)) {
            ForEach(Array(Self.icons.enumerated()), id: \.offset) { _, icon in
                legendRow(swatch: { glyph(icon.symbol, tint: icon.tint) },
                          name: icon.name, detail: icon.detail)
            }
            statusDotRow
        }
    }

    /// The service dot, and the six states it can be in.
    ///
    /// A row of its own rather than one more entry in ``icons``, because the dot is not a symbol: it is
    /// a filled circle the widget draws, and its whole vocabulary is colour. Listing the six states
    /// under it is the only way this row says anything — a single orange dot beside "service status"
    /// would name the element without explaining it.
    ///
    /// **Grey covers two states**, and that is worth the reader's attention rather than a footnote:
    /// `unknown` means "we could not find out", which is not the same as `operational` even though the
    /// dot is only ever drawn for a problem — so the pairing shows a colour that says less than the
    /// others, not a duplicate.
    private var statusDotRow: some View {
        legendRow(swatch: { dot(ColorRole.orange.defaultColor) },
                  name: "service status",
                  detail: "a provider service has a problem · shown only when something’s wrong") {
            HStack(spacing: 10) {
                ForEach(Array(Self.serviceStates.enumerated()), id: \.offset) { _, state in
                    HStack(spacing: 4) {
                        dot(state.colour)
                        Text(state.name).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    /// The six service states in the order they escalate, with the colours the **menu bar** gives them.
    ///
    /// Taken from `StatusItemView.statusDotTarget`, not from the popup's table: this page explains the
    /// widget, and the two deliberately disagree on one state. `degraded` is neutral here and yellow
    /// there, because in the menu bar the dot is alone and a yellow with no action attached is noise,
    /// while in the popup it sits beside the service's name and status word.
    @MainActor
    private static var serviceStates: [(name: String, colour: NSColor)] {
        [("operational", ColorRole.gray.defaultColor),
         ("degraded", ColorRole.calmWhite.defaultColor),
         ("partial outage", ColorRole.orange.defaultColor),
         ("major outage", ColorRole.red.defaultColor),
         ("maintenance", ColorRole.blue.defaultColor),
         ("unknown", ColorRole.gray.defaultColor)]
    }

    /// The dot at the size the widget draws it (`StatusItemView.Metrics.statusDotDiameter`).
    private func dot(_ colour: NSColor) -> some View {
        Circle()
            .fill(Color(nsColor: colour))
            .frame(width: 6, height: 6)
    }

    private struct Icon {
        let symbol: String
        let tint: NSColor
        let name: String
        let detail: String
    }

    /// Each glyph beside the state it means — names from ``WidgetGlyph``, so this cannot advertise one
    /// the widget has stopped drawing.
    @MainActor
    private static var icons: [Icon] {
        [Icon(symbol: WidgetGlyph.awaitingInput, tint: ColorRole.label.defaultColor,
              name: "awaiting input",
              detail: "sessions waiting for your reply · turns orange, then red, as the session nears deletion"),
         Icon(symbol: WidgetGlyph.paused, tint: ColorRole.red.defaultColor,
              name: "paused", detail: "every limit spent · no credits to cover"),
         Icon(symbol: WidgetGlyph.credits(for: "EUR"), tint: ColorRole.label.defaultColor,
              name: "extra usage", detail: "paid credits burning now"),
         Icon(symbol: WidgetGlyph.dataConflict, tint: ColorRole.label.defaultColor,
              name: "usage API error", detail: "needs your attention"),
         Icon(symbol: WidgetGlyph.noData, tint: ColorRole.label.defaultColor,
              name: "no data", detail: "the usage API is unreachable or no usage activity"),
         Icon(symbol: WidgetGlyph.usageTrackingOff, tint: ColorRole.label.defaultColor,
              name: "usage tracking off", detail: "only services are watched")]
    }

    // MARK: Row building blocks

    /// A section's heading — its name, and the line that says what the section is for.
    ///
    /// Passed as the section's `header:`, so it sits **outside** the grouped box rather than as its
    /// first row. That is where a `Form` puts a section name, and it is also what keeps the box a list
    /// of like things: a heading inside it reads as an entry in that list, which is what the first
    /// draft looked like.
    ///
    /// Two lines rather than the single line of small caps a plain `Section("…")` gives, because half
    /// of each heading is explanation — "how fast you're spending, not how much" does more work here
    /// than the name above it. `.headline` on the name keeps the pair reading as one heading; the form
    /// styles a bare `Text` header down to a caption, which would bury it.
    private func heading(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline).foregroundStyle(.primary)
            if let detail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textCase(nil)
        .padding(.bottom, 2)
    }

    /// The two-line row every list section uses: name over explanation, with a specimen leading.
    ///
    /// The pair of tones is the popup's own (`label` over `dimmedLabel`), so the page reproduces the
    /// hierarchy the reader will meet in the app rather than inventing one.
    /// `extra` hangs under the detail line for a row that needs more than two lines — currently only
    /// the service dot, whose six states are the row's actual content.
    private func legendRow<Swatch: View, Extra: View>(
        @ViewBuilder swatch: () -> Swatch,
        name: String, detail: String,
        @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            swatch().frame(width: 34, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout)
                Text(.init(detail)).font(.caption).foregroundStyle(.secondary)
                extra()
            }
            Spacer(minLength: 0)
        }
    }

    /// A tier swatch: a stroke at the menu bar's own bar size, so the eye looks for that shape.
    ///
    /// 34 × 5 is `StatusItemView.Metrics.barWidth` × `barHeight` — the real strip, not the popup's
    /// 6 pt one. An abstract square would have been a colour chip; this is the thing itself.
    private func stroke(colour: Color, outlined: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(colour)
            .frame(width: 34, height: 5)
            .overlay(RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .strokeBorder(Color.primary.opacity(outlined ? 0.28 : 0), lineWidth: 0.5))
    }

    private func glyph(_ symbol: String, tint: NSColor) -> some View {
        Group {
            if let image = LegendRenderer.glyphImage(symbol, tint: tint) {
                Image(nsImage: image)
            }
        }
    }

    /// A wide specimen with the style's name and its one-line description above it.
    private func anatomy(style: BarStyle, subdivisions: Int = 0,
                         caption: String, name: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(.init("**\(name)** · \(caption)")).font(.callout)
            Image(nsImage: LegendRenderer.dropdownBarImage(
                LegendCatalog.markerlessSpecimen, style: style, width: Self.anatomyWidth,
                subdivisions: subdivisions, appearance: barAppearance))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    /// A short specimen beside the rule it demonstrates.
    private func ruleRow(style: BarStyle, layout: BarLayout, text: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: LegendRenderer.dropdownBarImage(
                layout, style: style, width: Self.ruleWidth, appearance: barAppearance))
            Text(.init(text)).font(.callout)
            Spacer(minLength: 0)
        }
    }

    /// Anatomy bars run wide — they are the section's subject and carry captions pointing into them.
    private static let anatomyWidth: CGFloat = 320
    /// Rule bars run short, so the row reads as "this shape means that" rather than as another anatomy.
    private static let ruleWidth: CGFloat = 160
}
