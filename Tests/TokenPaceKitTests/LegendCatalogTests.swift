import Foundation
import Testing
@testable import TokenPaceKit

// MARK: - LegendCatalogTests (#261)

/// The Legend pane's specimens are load-bearing in a way ordinary sample data is not: the page's
/// whole claim is that it shows what the app actually draws, so a state that quietly drifted into a
/// neighbouring colour would make the reference wrong about itself while still looking plausible.
///
/// These tests pin what each specimen is *for* — the tier it lands in, the side it leans to — rather
/// than its raw numbers. A threshold change should either keep these passing (the specimen still
/// demonstrates its tier) or fail loudly (it no longer does), and neither outcome should require
/// re-reading the pane to discover.
@Suite("LegendCatalog")
struct LegendCatalogTests {

    /// Every tier renders the colour its status word promises.
    ///
    /// `severity` collapses green and yellow into `.calm`, so the two calm tiers are separated by the
    /// same comparison the render layer uses — `aheadThreshold` for the yellow one, the behind
    /// threshold for blue — rather than by re-stating a colour this target cannot see.
    @Test("each tier lands in the band its word names")
    func tiersLandInTheirBands() {
        let byWord = Dictionary(uniqueKeysWithValues: LegendCatalog.tiers.map { ($0.word, $0.layout) })

        let farBehind = try! #require(byWord["far behind pace"])
        #expect(farBehind.severity == .farBehind)

        let onPace = try! #require(byWord["on pace"])
        #expect(onPace.severity == .calm)
        #expect(onPace.pacing == .onPaceOrBehind)

        // Yellow: ahead, but by less than the dynamic threshold — the branch that keeps it `.calm`.
        let mildLead = try! #require(byWord["ahead of pace"])
        #expect(mildLead.pacing == .ahead)
        #expect(mildLead.severity == .calm)
        #expect(mildLead.usageFraction - mildLead.timeFraction
                < PacingModel.aheadThreshold(timeFraction: mildLead.timeFraction))

        let wellAhead = try! #require(byWord["well ahead of pace"])
        #expect(wellAhead.severity == .ahead)

        let spent = try! #require(byWord["limit reached"])
        #expect(spent.severity == .exhausted)
    }

    /// The five tiers are distinct states, and all five are listed.
    ///
    /// A duplicate would show the reader two identical strokes under different words — the failure
    /// this catches is a copy-paste in the table, which reads correctly and renders wrongly.
    @Test("the five tiers are five different states")
    func tiersAreDistinct() {
        #expect(LegendCatalog.tiers.count == 5)
        let severities = Set(LegendCatalog.tiers.map(\.layout.severity))
        // Four severities across five tiers: green and yellow share `.calm` by design.
        #expect(severities.count == 4)
    }

    /// No specimen sits on a threshold, where floating-point noise decides its colour.
    ///
    /// `BarStylePreviewRenderer` documents having hit exactly this: a 5-hour surplus that landed on
    /// `behindThreshold` to the seventeenth decimal, leaving the tile's colour to chance. A margin
    /// wide enough to see is a margin wide enough to be sure of.
    @Test("no tier sits within a hair of its boundary")
    func tiersClearTheirBoundaries() {
        for tier in LegendCatalog.tiers where tier.layout.usageFraction < 1 {
            let layout = tier.layout
            if layout.pacing == .ahead {
                let lead = layout.usageFraction - layout.timeFraction
                let threshold = PacingModel.aheadThreshold(timeFraction: layout.timeFraction)
                #expect(abs(lead - threshold) > 0.01,
                        "\(tier.word) sits on the ahead threshold")
            } else {
                let surplus = layout.timeFraction - layout.usageFraction
                let threshold = PacingModel.behindThreshold(
                    windowDurationSeconds: layout.windowDurationSeconds)
                #expect(abs(surplus - threshold) > 0.01,
                        "\(tier.word) sits on the behind threshold")
            }
        }
    }

    /// The marker-less anatomy specimen leans right by a length both scales can draw.
    ///
    /// Its whole job is to show that Pressure is Balance's right half, which needs a lead wide enough
    /// that neither collapses to the minimum pill — the state in which the two look identical and the
    /// section proves nothing.
    @Test("the anatomy specimen is a visible lead on both scales")
    func markerlessSpecimenIsVisible() {
        let layout = LegendCatalog.markerlessSpecimen
        #expect(layout.pacing == .ahead)
        #expect(layout.balanceOffset > 0.2)
        // The identity the section states in words (ADR-0101).
        #expect(layout.pressureLength == max(0, layout.balanceOffset))
    }

    /// On-pace is *exactly* zero on both scales, which is what makes the "dot at the zero" rule a dot.
    @Test("the on-pace specimen is a true zero")
    func onPaceSpecimenIsZero() {
        let layout = LegendCatalog.onPaceSpecimen
        #expect(layout.balanceOffset == 0)
        #expect(layout.pressureLength == 0)
    }

    /// The Progress specimen is behind pace, so its marker falls to the **right** of the capsule —
    /// the arrangement that section's first reading rule names.
    @Test("the Progress specimen puts the marker right of the capsule")
    func progressSpecimenIsBehind() {
        let layout = LegendCatalog.progressSpecimen
        #expect(layout.pacing == .onPaceOrBehind)
        #expect(layout.timeFraction > layout.usageFraction)
        #expect(layout.gapEnd == layout.timeFraction)
    }

    /// The exhausted specimen is full on every scale, at any elapsed fraction.
    @Test("the exhausted specimen is full and red")
    func exhaustedSpecimenIsFull() {
        let layout = LegendCatalog.exhaustedSpecimen
        #expect(layout.severity == .exhausted)
        #expect(layout.pressureLength == 1)
    }

    /// The menu-bar pair differs in exactly one thing: whether the five-hour bar needs attention.
    ///
    /// That is the section's entire subject — one story told in two frames — so a change making both
    /// bars calm, or both loud, would leave the caption describing something the picture no longer
    /// shows.
    @Test("the menu-bar pair is one calm bar and one that is not")
    func menuBarPairDiffersOnlyInAttention() {
        #expect(LegendCatalog.menuBarFiveHour.isCalm)
        #expect(!LegendCatalog.menuBarSevenDay.isCalm)
    }

    /// Specimens are computed against a fixed instant, so the pane renders identically every launch.
    @Test("the time base is constant")
    func timeBaseIsFixed() {
        #expect(LegendCatalog.now == Date(timeIntervalSinceReferenceDate: 0))
    }
}
