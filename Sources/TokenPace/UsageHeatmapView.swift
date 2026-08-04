import SwiftUI
import Charts
import TokenPaceKit

// MARK: - UsageHeatmapView (#245)

/// The pilot Insights chart: a **weekday × hours** heatmap of sample density (`dbg_sample_messages`).
/// Rows are the seven weekdays folded over the whole history ("when do I usually work"), columns are
/// the 24 local hours. Colour scales with the mean sample count, a genuine **zero** is the lightest
/// shade, and a slot never observed in any week is drawn hatched — visually distinct from zero, never
/// interpolated across (ADR-0027 honesty). Built with Swift Charts `RectangleMark` (ADR-0068).
///
/// Cells are a **fixed size**: the chart keeps its natural dimensions instead of stretching to fill the
/// window, so a cell means the same thing at any window size. The view scrolls if the window is smaller.
///
/// Static draw only — rebuilt on window open and on each poll; no timers/animation (a background
/// menu-bar app must stay cheap).
struct UsageHeatmapView: View {
    let grid: UsageGrid

    /// Colour ramp is normalised against a **fixed** ceiling, not the grid's own max, so a cell's shade
    /// means the same thing between opens (a busy hour looks busy regardless of the week around it). At
    /// the 3-min active cadence a fully-covered hour holds ~20 samples (ADR-0032), so 20 is the ceiling.
    private static let densityCeiling = 20.0

    /// Fixed cell geometry — the chart never stretches to the window (see the type doc).
    private enum Cell {
        static let width: CGFloat = 26
        static let height: CGFloat = 26
    }

    private var labels: [String] { grid.weekdayLabels() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView([.horizontal, .vertical]) {
                // A ScrollView centres content smaller than its bounds, which left the fixed-size chart
                // floating mid-pane. Wrapping in a top-leading-aligned full-width/height stack pins it.
                HStack(spacing: 0) {
                    chart
                        .frame(width: Cell.width * 24 + Self.yAxisWidth,
                               height: Cell.height * CGFloat(grid.weekdays.count) + Self.xAxisHeight)
                        // A little trailing room so the rightmost tick label isn't flush to the edge.
                        .padding(.trailing, Self.trailingLabelInset)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // Fixed-height scroll area: exactly the chart's own height, so it neither stretches nor
            // floats. Anything taller than the pane scrolls instead.
            .frame(height: Cell.height * CGFloat(grid.weekdays.count) + Self.xAxisHeight
                   + Self.trailingLabelInset)
            legend
            Spacer(minLength: 0)   // push chart + legend to the top of the pane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Room reserved for the axes inside the fixed frame.
    private static let yAxisWidth: CGFloat = 44
    private static let xAxisHeight: CGFloat = 28
    /// The last X label straddles the plot's right edge, so reserve half a label's width beyond it.
    private static let trailingLabelInset: CGFloat = 20

    private var chart: some View {
        Chart(grid.points) { point in
            RectangleMark(
                xStart: .value("Hour start", Double(point.hour)),
                xEnd: .value("Hour end", Double(point.hour + 1)),
                y: .value("Day", label(point.rowIndex)))
            .foregroundStyle(fill(for: point))
        }
        .chartXScale(domain: 0...24)
        // Rows in the grid's own order (first weekday at the top), not Charts' alphabetical default.
        .chartYScale(domain: labels)
        .chartXAxis {
            // Every 4 h rather than every 3: the last 3-hourly tick (21) sits so close to the plot's
            // right edge that Charts clips its label to "2".
            AxisMarks(values: [0, 4, 8, 12, 16, 20]) { value in
                AxisValueLabel {
                    if let h = value.as(Int.self) { Text(String(format: "%02d", h)) }
                }
                AxisTick()
            }
        }
        .chartYAxis {
            AxisMarks(preset: .aligned, values: .automatic) { _ in
                AxisValueLabel()
            }
        }
        .chartLegend(.hidden)   // the custom legend below explains colour + gap
    }

    // MARK: Cell fill

    /// The fill for a cell: a hatched neutral for a never-observed slot, else a density-scaled tint.
    private func fill(for point: UsageGridPoint) -> AnyShapeStyle {
        guard let value = point.value else {
            return AnyShapeStyle(Self.gapHatch)   // never observed — hatched, distinct from zero
        }
        let t = min(1, value / Self.densityCeiling)               // 0…1 against the fixed ceiling
        // Lightest (near-empty) → saturated accent. A single hue so density reads as intensity.
        return AnyShapeStyle(Color.accentColor.opacity(0.10 + 0.90 * t))
    }

    /// A diagonal-hatch shape style for never-observed cells — a tiled stripe image, so the pattern is
    /// obviously "not a value" and never mistaken for a light zero.
    private static let gapHatch: ImagePaint = {
        let size = 6.0
        let img = Image(size: CGSize(width: size, height: size)) { ctx in
            ctx.fill(Path(CGRect(x: 0, y: 0, width: size, height: size)),
                     with: .color(.secondary.opacity(0.12)))
            var stroke = Path()
            stroke.move(to: CGPoint(x: 0, y: size))
            stroke.addLine(to: CGPoint(x: size, y: 0))
            ctx.stroke(stroke, with: .color(.secondary.opacity(0.55)), lineWidth: 1)
        }
        return ImagePaint(image: img)
    }()

    // MARK: Axes / legend

    /// The row's short weekday name, e.g. "Mon" (localised).
    private func label(_ rowIndex: Int) -> String {
        let names = labels
        guard rowIndex >= 0, rowIndex < names.count else { return "\(rowIndex)" }
        return names[rowIndex]
    }

    private var legend: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Text("less").font(.caption2).foregroundStyle(.secondary)
                ForEach([0.1, 0.3, 0.55, 0.8, 1.0], id: \.self) { t in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.10 + 0.90 * t))
                        .frame(width: 14, height: 12)
                }
                Text("more").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Self.gapHatch)
                    .frame(width: 14, height: 12)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(.secondary.opacity(0.3)))
                Text("never observed").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(6)
    }
}
