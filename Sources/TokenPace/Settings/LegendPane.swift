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
            anatomy(LegendCatalog.markerlessSpecimen, style: .balance,
                    caption: "zero in the middle · grows both ways", name: "Balance")
            // "Balance's right half" rides in the caption rather than standing as its own line below
            // the pair. As a separate sentence it read as a further fact about two things already
            // described; inside the caption it is the first thing said about Pressure, which is what
            // it actually is — the identity `pressureLength ≡ max(0, balanceOffset)` (ADR-0101), not
            // a resemblance noticed afterwards.
            anatomy(LegendCatalog.markerlessSpecimen, style: .pressure,
                    caption: "*Balance*’s right half · zero at the left · grows right only",
                    name: "Pressure")
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
            anatomy(LegendCatalog.progressSpecimen, style: .progress, subdivisions: 5,
                    caption: "the limit window edge to edge · two readings: time and usage",
                    name: "Progress",
                    callouts: Self.progressCallouts,
                    marker: Self.markerCallout)
            ForEach(Array(Self.progressRules.enumerated()), id: \.offset) { _, rule in
                ruleRow(style: .progress, layout: rule.layout, text: rule.text)
            }
        }
    }

    /// The three parts of a Progress bar, each pointing at the x it names.
    ///
    /// **The x values are constants**, worked out once for the geometry below and written down rather
    /// than derived at runtime. Deriving them looked tidier and was worse: it made the callouts depend
    /// on `PopupBarView`'s internals, which meant a page that silently mispointed if the renderer's
    /// inset ever changed shape rather than value. Fixed numbers with the arithmetic recorded beside
    /// them fail visibly instead — the label lands off its mark and a screenshot shows it.
    ///
    ///     scaleX(f)  = inset + f · (width − 2·inset)
    ///     inset      = minStripWidth / 2 = (0.75 · trackHeight − 1) / 2 = 1.75   (trackHeight 6)
    ///     width      = anatomyWidth = 320
    ///
    ///     used   f = usageFraction 0.35  →  112.5
    ///     marker f = timeFraction  0.50  →  160.0
    ///     tick 4 f = 4/5           0.80  →  255.0
    ///
    /// **Recompute these if `anatomyWidth`, `PopupBarView.trackHeight`, `minStripWidth` or the
    /// specimen's fractions change.** Any of the four moves every mark on this diagram.
    ///
    /// The alignment differs per label because the marks are not evenly spread: `used` and `marker`
    /// are 47.5 pt apart while their labels are two and three times that wide, so centring all three
    /// overlaps the first two. Anchoring the outer labels by their near edges and centring only the
    /// middle one spreads them across the width the bar actually occupies.
    ///
    /// The fourth tooth rather than the first: it is the one with room for a label under it without
    /// colliding with the capsule's own.
    /// Leader lengths are measured to the mark each one names, from the bottom of the track:
    ///
    ///     ticks   tickGap 2 + tickLength 5 × 2.4  = 14   — stops at the tooth's foot
    ///     capsule                          14 + 4 = 18   — runs past the teeth to the track itself
    ///
    /// Recompute alongside the `x` values above if the tick metrics or `tickScale` change.
    private static let progressCallouts: [Callout] = [
        Callout(x: 112.5, text: "used tokens/credits so far", anchor: .leading, leader: 18),
        Callout(x: 255.0, text: "ticks — hours / days", anchor: .trailing, leader: 14),
    ]

    /// The marker's own callout, which sits **above** the bar.
    ///
    /// Alone up there, and for the reason the other two are below: the marker stands proud of the
    /// track on both sides, so a label under it would have to clear the ruler as well, and the three
    /// captions would then be competing for one strip of space — which is exactly how they ended up
    /// overlapping. Splitting them across the bar gives each room, and puts the marker's name on the
    /// side the marker is read from.
    ///
    /// Its leader is short — 6 pt — because the marker reaches up toward it: the caption sits directly
    /// over a mark that already stands 4 pt proud of the track, unlike the two below, which have the
    /// ruler's depth to cross first.
    private static let markerCallout = Callout(x: 160.0, text: "now-marker", anchor: .center, leader: 6)

    /// One label beside an anatomy bar, pointing at `x`.
    private struct Callout {
        let x: CGFloat
        let text: String
        /// Which edge of the label's **frame** sits at `x`.
        ///
        /// The text itself is always centred on the line (see ``calloutRow(_:pointingDown:)``); this
        /// only decides which way the frame extends, so a caption near either end of the bar has room
        /// to spread inward instead of off the edge.
        let anchor: HorizontalAlignment
        /// How far the leader runs, in points, to reach the mark it names.
        let leader: CGFloat
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
            countdownRow
            statusDotRow
        }
    }

    /// The reset countdown — the one mark in the widget that is a number rather than a symbol.
    ///
    /// `25m` is the shape `ResetClock.timeToReset` produces: **one unit at any distance** (`45m`,
    /// `5h`, `4d`), never a wall clock and never a combined `1h30m` (ADR-0074). Set in the same
    /// monospaced digits the widget uses, so the specimen matches the thing it names.
    ///
    /// The detail line leads with the condition rather than the value, because the countdown does not
    /// appear until a limit is spent — a row saying only "time left" would describe a number the
    /// reader may never have seen.
    private var countdownRow: some View {
        legendRow(swatch: {
            Text("25m")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.primary)
        },
                  name: "reset countdown",
                  detail: "limit reached · time left until its reset")
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

    /// The six service states in the order they escalate.
    ///
    /// **`degraded` is yellow**, which is what the popup draws and what the escalation reads as: grey,
    /// yellow, orange, red is a scale a reader can follow without being told. The menu bar currently
    /// mutes this one state to the neutral (`StatusItemView.statusDotTarget`, #381) — a decision that
    /// pre-dates this page and is tracked separately (#410). The legend shows the scale rather than
    /// that exception: a reference whose own example is the odd case out teaches the exception.
    @MainActor
    private static var serviceStates: [(name: String, colour: NSColor)] {
        [("operational", ColorRole.green.defaultColor),
         ("degraded", ColorRole.yellow.defaultColor),
         ("partial outage", ColorRole.orange.defaultColor),
         ("major outage", ColorRole.red.defaultColor),
         ("maintenance", ColorRole.blue.defaultColor),
         ("unknown", ColorRole.gray.defaultColor)]
    }

    /// The dot at the size the widget draws it (`StatusItemView.Metrics.statusDotDiameter`), with the
    /// dropdown's own halo around it.
    ///
    /// The glow is `GlowDotView`'s: a shadow in the dot's own colour, radius 5 at 0.75 alpha
    /// (`PopupViewController.dotGlowRadius`/`dotGlowStrength`, #188). Six pixels of colour is very
    /// little to identify a hue by, and the halo is most of what makes these legible at this size — a
    /// legend that dropped it would show a duller mark than the one it is explaining.
    private func dot(_ colour: NSColor) -> some View {
        Circle()
            .fill(Color(nsColor: colour))
            .frame(width: 6, height: 6)
            .shadow(color: Color(nsColor: colour).opacity(0.75), radius: 5)
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
              detail: "sessions waiting for your reply"),
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
        // One line, name and explanation separated by the same `·` the style captions use — rather
        // than the two-line block this started as. The second line read as a subtitle *belonging* to
        // the heading, which put three ranks of text above every section (name, subtitle, then the
        // rows' own pairs) and pushed the diagrams down. Inline, the two halves are one sentence and
        // the page keeps two ranks: heading, then content.
        Group {
            if let detail {
                Text(title).font(.headline).foregroundStyle(.primary)
                    + Text(" · ").font(.callout).foregroundStyle(.secondary)
                    + Text(detail).font(.callout).foregroundStyle(.secondary)
            } else {
                Text(title).font(.headline).foregroundStyle(.primary)
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
                // Same size as the name above it, not the smaller caption a settings subtitle takes.
                // On this page the explanation *is* the content — the name is a label for it — so
                // shrinking it would rank the two the wrong way round. Tone still separates them.
                Text(.init(detail)).font(.callout).foregroundStyle(.secondary)
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

    /// A widget glyph, tinted **in SwiftUI** rather than baked.
    ///
    /// `.foregroundStyle` on a template image re-resolves whenever the theme changes, which is what
    /// keeps a `label`-coloured glyph readable on both grounds. Baking the colour into the bitmap —
    /// the first attempt — left it frozen at whatever the theme was when the page first drew.
    private func glyph(_ symbol: String, tint: NSColor) -> some View {
        Group {
            if let image = LegendRenderer.glyphImage(symbol) {
                Image(nsImage: image)
                    .foregroundStyle(Color(nsColor: tint))
            }
        }
    }

    /// A wide specimen with the style's name and its one-line description above it, and optionally a
    /// row of callouts naming the parts it is made of.
    ///
    /// `callouts` is empty for the two marker-less styles: their whole anatomy is one ribbon and its
    /// zero, both already named in the caption. Progress is the style with parts — a capsule whose far
    /// end is one reading, a marker that is another, and a ruler — so it is the one that needs them.
    private func anatomy(_ layout: BarLayout, style: BarStyle, subdivisions: Int = 0,
                         caption: String, name: String,
                         callouts: [Callout] = [], marker: Callout? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            // The name in full ink, the rest dimmed — the same split the row pairs use, and for the
            // same reason: what the thing is called ranks above what it does here, because the caption
            // is read once and the name is what the reader carries to the Style control.
            (Text(name).font(.callout).bold()
             + Text(" · ").font(.callout).foregroundColor(.secondary)
             + Text(.init(caption)).font(.callout).foregroundColor(.secondary))
            if let marker {
                calloutRow([marker], pointingDown: true)
            }
            // Pinned to the width it was baked at. Without this the form stretches the image to the
            // row, and every callout then points at a mark that has moved — which is exactly what the
            // first screenshot of this section showed.
            Image(nsImage: LegendRenderer.dropdownBarImage(
                layout, style: style, width: Self.anatomyWidth,
                subdivisions: subdivisions, showsRuler: !callouts.isEmpty || marker != nil,
                appearance: barAppearance))
                .frame(width: Self.anatomyWidth, alignment: .leading)
            if !callouts.isEmpty {
                calloutRow(callouts)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    /// The callouts under an anatomy bar: a tick at the x each one points to, its label beneath.
    ///
    /// Positioned by `alignmentGuide` against the bar's own coordinate space rather than laid out in a
    /// stack, because each label names a **point** on the track — the capsule's left end, the marker,
    /// the fourth tooth — and a label that merely sits nearby names nothing in particular. The x values
    /// come from the same `scaleX` inset the renderer uses, so they land on the mark rather than beside
    /// it.
    /// `pointingDown` puts the label above its leader line, for the callouts that sit over the bar.
    ///
    /// Laid out with `GeometryReader` + `position`, not `alignmentGuide`. The guide version collapsed
    /// every label onto one point: inside a `ZStack` the guide moves the *stack's* alignment rather
    /// than the child within it, so all three resolved to the same origin and printed on top of each
    /// other. `position` places a view's centre at an explicit coordinate, which is what "this label
    /// belongs at x = 112.5" actually means.
    private func calloutRow(_ callouts: [Callout], pointingDown: Bool = false) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(callouts.enumerated()), id: \.offset) { _, callout in
                // **Centred on the line**, whichever way the frame extends. The line marks the spot;
                // the caption sits under its middle, which is how a reader pairs the two without
                // having to work out which end of the text the line belongs to. `anchor` still decides
                // which direction the *frame* grows, so a caption near either end of the bar spreads
                // inward instead of off the edge.
                VStack(alignment: .center, spacing: 0) {
                    if pointingDown {
                        Text(callout.text).font(.callout).foregroundStyle(.secondary).fixedSize()
                        leaderLine(callout.leader)
                    } else {
                        leaderLine(callout.leader)
                        Text(callout.text).font(.callout).foregroundStyle(.secondary).fixedSize()
                    }
                }
                // **A padded frame, not an offset.** Two earlier attempts failed on the same thing:
                // both needed the label's own width, and neither could have it in time —
                // `alignmentGuide` inside a `ZStack` moves the stack rather than the child, and a
                // `GeometryReader` read into `@State` arrives a layout pass *after* the position is
                // used, so every label placed itself as if it were zero-wide and they piled up in the
                // middle.
                //
                // Here the width is never needed. A leading label is given a frame that starts at `x`
                // and runs to the bar's end, aligned leading; a trailing one gets a frame from zero to
                // `x`, aligned trailing; a centred one is centred in a symmetric frame around `x`. The
                // layout system does the arithmetic with a width it already knows.
                .frame(width: frameWidth(for: callout), alignment: frameAlignment(for: callout))
                .padding(.leading, framePadding(for: callout))
            }
        }
        .frame(width: Self.anatomyWidth, height: Self.calloutHeight, alignment: .topLeading)
    }

    /// How wide a callout's own frame is, given where it must anchor.
    private func frameWidth(for callout: Callout) -> CGFloat {
        switch callout.anchor {
        case .leading:  return Self.anatomyWidth - callout.x
        case .trailing: return callout.x
        // A symmetric window around the mark: whichever side is shorter bounds it, so the label stays
        // centred on `x` without running off either end of the bar.
        default:        return min(callout.x, Self.anatomyWidth - callout.x) * 2
        }
    }

    private func frameAlignment(for callout: Callout) -> Alignment {
        switch callout.anchor {
        case .leading:  return .leading
        case .trailing: return .trailing
        default:        return .center
        }
    }

    private func framePadding(for callout: Callout) -> CGFloat {
        switch callout.anchor {
        case .leading:  return callout.x
        case .trailing: return 0
        default:        return max(0, callout.x - frameWidth(for: callout) / 2)
        }
    }

    /// The hairline joining a caption to the mark it names.
    ///
    /// Each length is measured to reach its own target rather than shared, because the three marks sit
    /// at three different depths: the marker stands proud above the track, the ruler's teeth hang below
    /// it, and the capsule's edge is on the track itself. A single length would leave two of the three
    /// lines stopping in mid-air.
    private func leaderLine(_ length: CGFloat) -> some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 1, height: length)
    }

    /// Height reserved for a callout strip: leader line, gap, and one line of text.
    private static let calloutHeight: CGFloat = 24

    /// A short specimen beside the rule it demonstrates.
    ///
    /// **Indented**, so the rules read as belonging to the anatomy above them rather than as further
    /// entries in the section's list. The anatomy is the subject; these are the ways of reading it,
    /// and a flush-left row would give them the same standing as the diagram they explain.
    private func ruleRow(style: BarStyle, layout: BarLayout, text: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: LegendRenderer.dropdownBarImage(
                layout, style: style, width: Self.ruleWidth, appearance: barAppearance))
            Text(.init(text)).font(.callout)
            Spacer(minLength: 0)
        }
        .padding(.leading, Self.ruleIndent)
    }

    /// How far the reading rules sit in from the section's edge.
    private static let ruleIndent: CGFloat = 20

    /// Anatomy bars run wide — they are the section's subject and carry captions pointing into them.
    private static let anatomyWidth: CGFloat = 320
    /// Rule bars run short, so the row reads as "this shape means that" rather than as another anatomy.
    private static let ruleWidth: CGFloat = 160
}
