import SwiftUI
import TokenPaceKit

// MARK: - LegendPane (#261)

/// Appearance › Legend — the visual language, explained. The one page in Settings that **sets
/// nothing**; explains what the widget's colors/styles/glyphs mean.
///
/// Content rules: no word from the code (`surface`, `pacing`, `calm`) — use the reader's vocabulary;
/// a term is captioned before rules below it use it; explanation lines are drawn `.primary` since
/// they are the content here, not a subtitle.
struct LegendPane: View {

    /// Forces a rebuild on theme flip: the dropdown specimens are non-template `NSImage`s baked once,
    /// so they don't re-resolve on their own (same reason `BarStylePicker` reads this). Menu-bar
    /// specimens are immune (pinned `.vibrantDark`).
    @Environment(\.colorScheme) private var colorScheme

    /// Vibrant, not plain: the live bars draw inside an `NSMenu`, where the palette resolves
    /// differently (opaque track, different greens) from a plain window. Passed explicitly since
    /// this view can be hosted under a forced appearance.
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

    /// The five tiers, plus the muted white that is not a sixth. The subtitle's second half pre-empts
    /// the near-universal misreading (#254): a horizontal bar beside a percentage reads as "how full",
    /// which the color never means — it means pace.
    private var colorSection: some View {
        Section(header: heading("What a bar’s color says",
                                detail: "how fast you’re spending, not how much")) {
            ForEach(Array(LegendCatalog.tiers.enumerated()), id: \.offset) { _, tier in
                legendRow(swatch: { stroke(colour: Color(LegendRenderer.tierColor(tier.layout))) },
                          name: tier.word,
                          detail: Self.tierDetail[tier.word] ?? "")
            }
            legendRow(swatch: { stroke(colour: Color(nsColor: ColorRole.calmWhite.defaultColor),
                                       outlined: true) },
                      name: "no color",
                      detail: "optionally replaces non-critical colors in the menu bar")
        }
    }

    /// Kept here rather than in `LegendCatalog`: the kit type carries the testable *states*, this is
    /// presentation copy.
    private static let tierDetail: [String: String] = [
        "far behind pace": "big surplus · spend freely · 5-hour & 7-day bars only",
        "on pace": "all good · keep going",
        "ahead of pace": "a bit fast · nothing to do yet",
        "well ahead of pace": "slow down",
        "limit reached": "blocked until it resets",
    ]

    // MARK: 2 · Menu bar

    /// Two renders of the same widget: both bars, then only the seven-day one — showing what
    /// `TopBarHiding` does live. Two equal, centred halves rather than left-aligned: centring keeps
    /// the differently-sized specimens comparable instead of reading as the widget having moved.
    private var menuBarSection: some View {
        Section(header: heading("Menu bar", detail: nil)) {
            HStack(alignment: .top, spacing: 0) {
                menuBarCase(fiveHour: LegendCatalog.menuBarFiveHour,
                            sevenDay: LegendCatalog.menuBarSevenDay,
                            caption: "5-hour limit on top · 7-day below")
                menuBarCase(fiveHour: nil,
                            sevenDay: LegendCatalog.menuBarSevenDay,
                            caption: "7-day limit only · 5-hour hidden while calm")
            }
        }
    }

    /// One half of the Menu bar row: the specimen over its caption, both centred, filling half the
    /// width. `maxWidth: .infinity` on each of two siblings is what divides the row evenly.
    private func menuBarCase(fiveHour: BarLayout?, sevenDay: BarLayout?,
                             caption: String) -> some View {
        VStack(alignment: .center, spacing: 7) {
            Image(nsImage: LegendRenderer.menuBarImage(fiveHour: fiveHour, sevenDay: sevenDay))
                // The menu bar is dark under either theme, so the specimen needs a dark plate.
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

    /// Both marker-less styles, drawn from **one** state: `pressureLength ≡ max(0, balanceOffset)`
    /// (ADR-0101). Balance first (shows the whole scale), Pressure is captioned as its right half.
    private var markerlessSection: some View {
        Section(header: heading("Balance & Pressure bar styles",
                                detail: "how far you’ve drifted from steady spending")) {
            anatomy(LegendCatalog.markerlessSpecimen, style: .balance,
                    caption: "zero in the middle · grows both ways", name: "Balance")
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
    /// **The x values are constants**, worked out once and written down rather than derived at
    /// runtime — a fixed number that drifts fails visibly (label off its mark), while deriving from
    /// `PopupBarView`'s internals would fail silently if the renderer's inset ever changed shape.
    ///
    ///     scaleX(f)  = inset + f · (width − 2·inset)
    ///     inset      = minStripWidth / 2 = (0.75 · trackHeight − 1) / 2 = 1.75   (trackHeight 6)
    ///     width      = anatomyWidth = 320
    ///
    ///     used   f = usageFraction 0.35  →  112.5
    ///     marker f = timeFraction  0.71  →  226.5  (drawn at 226 — see `markerCallout`)
    ///     tick 4 f = 4/5           0.80  →  255.0
    ///
    /// **Recompute these if `anatomyWidth`, `PopupBarView.trackHeight`, `minStripWidth` or the
    /// specimen's fractions change** — any of the four moves every mark on this diagram.
    ///
    /// Leader lengths are not stated here — ``Geometry`` measures them from the mark each caption
    /// names. Only the horizontal positions are constants (from the renderer's `scaleX`).
    private static let progressCallouts: [Callout] = [
        Callout(x: 112.5, text: "tokens/credits spent"),
        // 254.5, not 255: the tooth is a 1 pt stroke centred on its coordinate, and so is the leader —
        // an integer x lands the two on opposite halves of the same device pixel at 2×.
        Callout(x: 254.5, text: "hour/day ticks", namesTheRuler: true),
    ]

    /// Sits **above** the bar (the other two are below): the marker stands proud of the track on both
    /// sides, so a label under it would collide with the ruler captions.
    ///
    /// 226, not the arithmetic's 226.5: the marker is a 7 pt wide mark read against its **centre**, so
    /// the half-point correction that squares a 1 pt hairline reads as standing right of the mark here.
    private static let markerCallout = Callout(x: 226, text: "now-marker")

    /// One label beside an anatomy bar, pointing at `x`.
    private struct Callout {
        let x: CGFloat
        let text: String
        /// The ruler and the track sit at different depths; `Geometry` measures each leader from
        /// whichever mark this names, rather than storing an unchecked length here.
        var namesTheRuler = false
    }

    /// How to read a Progress bar. Worded in **`pace`**, the same word ``LegendCatalog/tiers`` uses,
    /// since where the marker sits relative to the capsule is the same fact as the color tiers.
    private static var progressRules: [(layout: BarLayout, text: String)] {
        [(LegendCatalog.progressSpecimen, "now-marker on the right — you're behind pace"),
         (LegendCatalog.markerlessSpecimen, "now-marker on the left — you're ahead of pace"),
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

    /// `25m` is the shape `ResetClock.timeToReset` produces: **one unit at any distance** (`45m`,
    /// `5h`, `4d`), never a combined `1h30m` (ADR-0074). Detail line leads with the condition, since
    /// the countdown doesn't appear until a limit is spent.
    private var countdownRow: some View {
        legendRow(swatch: {
            Text("25m")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.primary)
        },
                  name: "reset countdown",
                  detail: "limit reached · time left until its reset")
    }

    /// A row of its own rather than an ``icons`` entry: the dot is a filled circle, not a symbol, and
    /// its whole vocabulary is color, so the six states must be listed to say anything. Grey covers
    /// two states worth calling out: `unknown` ("we could not find out") is not `operational`.
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

    /// In escalation order: grey, yellow, orange, red — a scale a reader can follow without being
    /// told. All three surfaces draw the same six tones (ADR-0111).
    @MainActor
    private static var serviceStates: [(name: String, colour: NSColor)] {
        [("operational", ColorRole.green.defaultColor),
         ("degraded", ColorRole.yellow.defaultColor),
         ("partial outage", ColorRole.orange.defaultColor),
         ("major outage", ColorRole.red.defaultColor),
         ("maintenance", ColorRole.blue.defaultColor),
         ("unknown", ColorRole.gray.defaultColor)]
    }

    /// At the widget's own size — mirrors `StatusItemView.Metrics.statusDotDiameter` (6, not the
    /// popup's same-named 9) — with the dropdown's own halo (`GlowDotView`: radius 5, 0.75 alpha,
    /// #188) — six pixels of color needs the glow to read at this size.
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

    /// Names from ``WidgetGlyph``, so this cannot advertise a glyph the widget has stopped drawing.
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

    /// Passed as the section's `header:`, so it sits **outside** the grouped box like a `Form`'s
    /// section name, rather than reading as a list entry. `.headline` on the name keeps the
    /// name+detail pair reading as one heading — a bare `Text` header would style down to a caption.
    private func heading(_ title: String, detail: String?) -> some View {
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

    /// Name over explanation, with a specimen leading — the popup's own tone pair (`label` over
    /// `dimmedLabel`). `extra` hangs under the detail line for a row needing more than two lines
    /// (currently only the service dot).
    private func legendRow<Swatch: View, Extra: View>(
        @ViewBuilder swatch: () -> Swatch,
        name: String, detail: String,
        @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            swatch().frame(width: 34, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout)
                // Same size as the name, not a smaller subtitle caption: here the explanation is the
                // content, so shrinking it would rank the two the wrong way round.
                Text(.init(detail)).font(.callout).foregroundStyle(.secondary)
                extra()
            }
            Spacer(minLength: 0)
        }
    }

    /// 34 × 5 is `StatusItemView.Metrics.barWidth` × `barHeight` — the real strip, not the popup's
    /// 6 pt one, so the eye looks for the actual shape rather than an abstract color chip.
    private func stroke(colour: Color, outlined: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(colour)
            .frame(width: 34, height: 5)
            .overlay(RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .strokeBorder(Color.primary.opacity(outlined ? 0.28 : 0), lineWidth: 0.5))
    }

    /// Tinted **in SwiftUI** rather than baked: `.foregroundStyle` on a template image re-resolves on
    /// theme change, keeping a `label`-colored glyph readable on both grounds.
    private func glyph(_ symbol: String, tint: NSColor) -> some View {
        Group {
            if let image = LegendRenderer.glyphImage(symbol) {
                Image(nsImage: image)
                    .foregroundStyle(Color(nsColor: tint))
            }
        }
    }

    /// `callouts` is empty for the two marker-less styles — their whole anatomy is one ribbon and its
    /// zero, already named in the caption. Progress has parts (capsule end, marker, ruler), so it's
    /// the one that needs them.
    private func anatomy(_ layout: BarLayout, style: BarStyle, subdivisions: Int = 0,
                         caption: String, name: String,
                         callouts: [Callout] = [], marker: Callout? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The name in full ink, the rest dimmed — the reader carries the name to the Style control.
            (Text(name).font(.callout).bold()
             + Text(" · ").font(.callout).foregroundColor(.secondary)
             + Text(.init(caption)).font(.callout).foregroundColor(.secondary))
                .padding(.bottom, 6)
            figure(layout, style: style, subdivisions: subdivisions,
                   callouts: callouts, marker: marker)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    /// The bar and everything pointing at it, laid out in **one coordinate space**: everything placed
    /// by `offset` from the figure's top edge against ``Geometry``, so a leader's length is the
    /// distance between two known values (`captionTop − trackBottom`) rather than a guess compensating
    /// for stack spacing across separate rows.
    private func figure(_ layout: BarLayout, style: BarStyle, subdivisions: Int,
                        callouts: [Callout], marker: Callout?) -> some View {
        let showsRuler = !callouts.isEmpty || marker != nil
        let imageTop = marker == nil ? 0 : Geometry.imageTop
        return ZStack(alignment: .topLeading) {
            // Explicit frame at the baked width — without it the form stretches the bar and every
            // mark below points at a place the mark has left.
            Image(nsImage: LegendRenderer.dropdownBarImage(
                layout, style: style, width: Self.anatomyWidth,
                subdivisions: subdivisions, showsRuler: showsRuler,
                appearance: barAppearance))
                .frame(width: Self.anatomyWidth, alignment: .leading)
                .offset(y: imageTop)

            if let marker {
                // Above the bar: caption at the top, leader runs down to the marker's tip (the
                // image's own top edge, the marker being the tallest thing the bar draws). Centred on
                // its own leader, not on the figure — the two only coincide when the marker is at the
                // halfway point.
                Text(marker.text)
                    .font(.callout).foregroundStyle(.secondary).fixedSize()
                    .position(x: marker.x, y: Geometry.captionHeight / 2)
                    .frame(width: Self.anatomyWidth,
                           height: Geometry.height(imageTop: imageTop, hasCallouts: true))
                leaderLine(Geometry.imageTop - Geometry.captionHeight)
                    .offset(x: marker.x, y: Geometry.captionHeight)
            }

            // Below the bar: each leader starts at the mark it names and ends on the shared caption
            // line, so the two differ by exactly how deep their marks sit — no compensation needed.
            ForEach(Array(callouts.enumerated()), id: \.offset) { _, callout in
                leaderLine(Geometry.captionTop(imageTop: imageTop) - markTop(callout, imageTop: imageTop))
                    .offset(x: callout.x, y: markTop(callout, imageTop: imageTop))
            }
            ForEach(Array(callouts.enumerated()), id: \.offset) { _, callout in
                // Centred on the leader via `position`, which places the view's **centre** at a
                // coordinate — "this label belongs under that line" — rather than anchored to an edge.
                // The frame stays full-width only so `position` has a container to resolve against.
                Text(callout.text)
                    .font(.callout).foregroundStyle(.secondary).fixedSize()
                    .position(x: callout.x,
                              y: Geometry.captionTop(imageTop: imageTop) + Geometry.captionHeight / 2)
                    .frame(width: Self.anatomyWidth,
                           height: Geometry.height(imageTop: imageTop, hasCallouts: true))
            }
        }
        .frame(width: Self.anatomyWidth,
               height: Geometry.height(imageTop: imageTop, hasCallouts: !callouts.isEmpty),
               alignment: .topLeading)
    }

    /// Where a below-bar leader begins: at the foot of the mark it names. The ruler's leader starts a
    /// hair below the teeth (both are 1 pt of the same ink; butted together they'd read as one line).
    /// The track's edge needs no gap — it's a filled shape, already legible as a separate mark.
    private func markTop(_ callout: Callout, imageTop: CGFloat) -> CGFloat {
        callout.namesTheRuler
            ? Geometry.rulerBottom(imageTop: imageTop) + Geometry.rulerLeaderGap
            : Geometry.trackBottom(imageTop: imageTop)
    }

    /// The figure's vertical arithmetic, measured from its top edge and derived from `PopupBarView`'s
    /// own metrics, so a change there moves the captions with it.
    @MainActor
    private enum Geometry {
        /// One line of `.callout` text, plus its leading.
        static let captionHeight: CGFloat = 17
        /// Clear space between a caption and the bar, the same above and below (one constant feeds
        /// both `imageTop` and `captionTop`, so the figure can't drift out of symmetry when tuned).
        static let gap: CGFloat = 10

        /// The break between the ruler's teeth and the leader pointing at them (only the ruler's
        /// leader takes it — see ``LegendPane/markTop(_:imageTop:)``).
        static let rulerLeaderGap: CGFloat = 1

        /// Where the bar's image starts when a caption sits above it.
        static var imageTop: CGFloat { captionHeight + gap }
        /// The image's height, including the ruler strip the renderer adds for this page.
        static var imageHeight: CGFloat { PopupBarView.viewHeight + PopupBarView.rulerDepth }

        /// The track's lower edge — where the capsule's leader begins.
        static func trackBottom(imageTop: CGFloat) -> CGFloat {
            imageTop + PopupBarView.markerOverhang + PopupBarView.trackHeight
        }
        /// The teeth's lower edge — where the ruler's leader begins.
        static func rulerBottom(imageTop: CGFloat) -> CGFloat {
            trackBottom(imageTop: imageTop) + PopupBarView.rulerDepth
        }
        /// The line the below-bar captions share: clear of the **teeth**, minus `tickGap` (already
        /// blank space within `rulerDepth`) so the gap isn't counted twice.
        static func captionTop(imageTop: CGFloat) -> CGFloat {
            rulerBottom(imageTop: imageTop) + gap - PopupBarView.tickGap
        }

        static func height(imageTop: CGFloat, hasCallouts: Bool) -> CGFloat {
            hasCallouts
                ? captionTop(imageTop: imageTop) + captionHeight
                : imageTop + imageHeight
        }
    }

    /// Each length is measured to reach its own target: the marker stands proud above the track, the
    /// ruler's teeth hang below it, the capsule's edge is on the track — three different depths.
    private func leaderLine(_ length: CGFloat) -> some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 1, height: length)
    }


    /// **Indented**, so the rules read as belonging to the anatomy above them rather than as further
    /// entries in the section's list.
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
