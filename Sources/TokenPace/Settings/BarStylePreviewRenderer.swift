import AppKit
import TokenPaceKit

// MARK: - BarStylePreviewRenderer

/// Draws the specimen widget each ``BarStyle`` tile in ``BarStylePicker`` shows — with the real
/// widget code, at runtime, instead of shipping screenshots of it.
///
/// Until #371 the three tiles were static PNGs captured from a running widget. That was a deliberate
/// interim step (ADR-0093 §1) with a named cost: a picture cannot follow the thing it depicts, so any
/// change to `StatusItemView.Metrics` or to the pacing palette silently made all three previews lie,
/// with nothing to catch it. Rendering closes that gap by construction — the tiles are drawn by the
/// same `render(in:)` the menu bar draws through, so they cannot disagree with it.
///
/// It also removes the app's only resource bundle, and with it the crash class of ADR-0095: the 0.94.0
/// release died on `Bundle.module` the first time this pane was opened. There is no disk read here.
enum BarStylePreviewRenderer {

    /// The specimen frame, in the terms the API reports.
    ///
    /// These are the `climbing` stub's first-poll values (`PollingShell.StubUsageTransport`), i.e. the
    /// exact frame the retired PNGs were captured from — a 5-hour window coasting behind pace and a
    /// 7-day window running ahead of it. Keeping the numbers means the switch to live rendering is
    /// invisible in the UI, which is what makes it reviewable: any difference on screen is a rendering
    /// difference, not a data one.
    ///
    /// One consequence is load-bearing rather than unfortunate. On the Pressure scale the 5-hour bar's
    /// signed lead is `r = −1`, so its ribbon clips to zero and draws as the bare minimum pill. That
    /// **is** the demonstration: the tile shows that Pressure spends its whole width on the ahead side
    /// and says nothing about a surplus, which is precisely the difference between it and the other
    /// two scales. Progress draws the same window as a mid-bar gap with a marker; Balance fills its
    /// entire left half. Three shapes, one dataset.
    private enum Specimen {
        /// 5-hour window: a fifth spent with 2 of its 5 hours left — behind pace.
        static let fiveHourUtilization = 20.0
        static let fiveHourRemaining: TimeInterval = 2 * 3600
        /// 7-day window: over half spent with 5 of its 7 days left — ahead of pace.
        static let sevenDayUtilization = 55.0
        static let sevenDayRemaining: TimeInterval = 5 * 24 * 3600
    }

    // MARK: Image

    /// The specimen widget drawn in `style`, ready for `Image(nsImage:)`.
    ///
    /// Not cached. Three 38×22 pt canvases cost microseconds, and a cache here would have to be
    /// invalidated on every theme flip — buying a staleness bug in exchange for nothing measurable.
    /// The retired PNG path cached because it hit the disk; this one does not.
    @MainActor
    static func image(for style: BarStyle) -> NSImage {
        let view = StatusItemView(frame: .zero)
        view.isPreviewSpecimen = true
        view.layout = specimenLayout()
        view.barStyle = style
        // The specimen is a constant: the tiles differ by style and by nothing else, so a viewer
        // comparing them is comparing scales rather than settings. Hence the palette is pinned here
        // instead of read from `PersistedConfig` — `.off` keeps every pacing colour at full strength,
        // which is what a swatch is for.
        view.colorsTell = .howItsGoing
        // No animator: colours resolve straight to their targets. The dev-tools preview does the same
        // (see `StatusItemView.colorAnimator`) — a specimen has no previous value to ease away from.
        view.colorAnimator = nil

        // Baked under **VibrantDark**, always, whatever the app's theme is.
        //
        // Two independent reasons, and both are needed:
        //
        // 1. *Dark*, because the tile's plate is black in both themes (`BarStylePicker`), and the menu
        //    bar is dark even under a light theme. Baking light neutrals for a black plate would draw
        //    near-black ticks on near-black backing.
        // 2. *Vibrant*, because the menu bar is a vibrant surface and system colours resolve
        //    differently there: measured, `labelColor` is α 0.847 in DarkAqua against 0.898 in
        //    VibrantDark, and `systemGreen` is `32D74B` against `3CE155`. This project has already
        //    paid for that lesson once — `PreviewChromeViews.vibrantAppearance` forces the same thing
        //    for the popup preview, because without it a preview's neutrals read lighter than the live
        //    surface, which is the one thing a preview must never do.
        //
        // The drawing must happen *inside* the block: `snapshotImage()` renders eagerly precisely so
        // every semantic colour is resolved against the appearance in force here, rather than against
        // whatever is current when the image is later composited.
        //
        // Force-unwrapped on purpose. `.vibrantDark` is a system-defined name that cannot be absent;
        // an optional-chained call would silently skip the render and leave a blank tile with nothing
        // to trace it to, which is strictly worse than a crash on an impossible condition.
        let appearance = NSAppearance(named: .vibrantDark)!
        var image = NSImage()
        appearance.performAsCurrentDrawingAppearance { image = view.snapshotImage() }
        return image
    }

    // MARK: Layout

    /// The specimen's `MenuBarLayout` — two bars, no decorations.
    ///
    /// Both bars go through `PacingModel.barLayout` rather than being written out as `BarLayout`
    /// literals. The pacing state, the near-reset overrides and the blue gate are all *computed* from
    /// the numbers, and hand-writing their results is how a specimen drifts away from what the app
    /// would actually draw for the same data. `now` is a constant, so the frame is deterministic.
    @MainActor
    private static func specimenLayout() -> MenuBarLayout {
        // Any fixed instant works — only the differences below are read.
        let now = Date(timeIntervalSinceReferenceDate: 0)

        // `blueAllowed: false` is not a nudge toward the colour we want; it is what the app computes
        // for this frame. `PacingModel.weeklyHasHeadroom` shuts the gate whenever the weekly window is
        // ahead of pace, and this specimen's 7-day window is (55 % spent against 28.6 % elapsed).
        //
        // Passing it explicitly also removes a genuine fragility. The 5-hour surplus is 0.60 − 0.20 =
        // 0.40, and `behindThreshold` for a 5-hour window is 3600/18000 = 0.40 as well: the frame sits
        // exactly on the blue/green boundary, where the strict `>` is decided by floating-point noise
        // in the seventeenth decimal. The gate short-circuits ahead of that comparison, so green is
        // determined rather than lucky.
        let fiveHour = BarView(
            layout: PacingModel.barLayout(
                utilization: Specimen.fiveHourUtilization,
                resetsAt: now.addingTimeInterval(Specimen.fiveHourRemaining),
                now: now, window: .fiveHour, blueAllowed: false),
            indicator: .neutral, window: .fiveHour)

        let sevenDay = BarView(
            layout: PacingModel.barLayout(
                utilization: Specimen.sevenDayUtilization,
                resetsAt: now.addingTimeInterval(Specimen.sevenDayRemaining),
                now: now, window: .sevenDay),
            indicator: .neutral, window: .sevenDay)

        // Bars only. A service dot, credits glyph, pause glyph or awaiting hand would each add width
        // and shift the bars sideways, making the three tiles about decorations rather than scales.
        return MenuBarLayout(mode: .expanded(fiveHour: fiveHour, sevenDay: sevenDay))
    }
}
