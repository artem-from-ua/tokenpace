import Foundation

// MARK: - JournalPrecision

/// How many decimals each journalled number is written with (#386).
///
/// The journal used to write `Double`s at full precision: `timePct` came out with **16–19** decimals
/// and `gap` with 11–20, which is **0.55 MB of a 4.6 MB monthly file** spent on digits that mean
/// nothing — all of the uncertainty sat in a `utilization` the API quantises to whole percent.
///
/// ## One rule, not a table of constants
///
/// For anything expressed as a *fraction of a window*, the step must be **no coarser than a second**
/// on that window — which makes the decimal count fall out of the window length rather than being
/// picked:
///
/// ```
/// decimals = ceil(log10(windowSeconds))
/// ```
///
/// | field | window | decimals | step |
/// |---|---|---|---|
/// | `h5.timePct` | 5 h | 5 | 0.18 s |
/// | `d7.timePct`, `scoped.timePct` | 7 d | 6 | 0.60 s |
/// | `spend.monthPct` | ~31 d | 7 | 0.27 s |
///
/// The fields stay **dimensionless fractions** rather than becoming elapsed seconds. Seconds would
/// give exact precision with no rule at all, but a reader would then need the window length to get
/// back to a fraction — and for `scoped` rows, which borrow the seven-day scale, it would need to
/// know *which* window a row belongs to. A fraction is multiplied by 100 and read.
///
/// ## Values that are not fractions of a window
///
/// - `util` / `raw` — **2 decimals**. The reconstruction's own step is ~0.1 pp (measured), so 0.01 pp
///   is an order of magnitude finer than anything observable; the smallest real change seen between
///   two polls is 0.053 pp, and one decimal already collapses distinct values.
/// - `n` — **2 decimals**. An estimate with a ±10 % confidence interval; more digits would be theatre.
/// - `spentFrac` — **4 decimals**, i.e. ~1 cent per €100 of limit.
///
/// Rounding here is a **write-side** concern only: everything upstream keeps full `Double` precision,
/// so no computation is affected. Verified across 4 362 records — integer-valued fields lose exactly
/// nothing, and the largest loss among the fractions moves a bar marker by 0.003 px.
enum JournalPrecision {

    /// Decimals for a fraction of a window of `windowSeconds` — the step is finer than one second.
    static func forFraction(ofWindowSeconds windowSeconds: Int) -> Int {
        guard windowSeconds > 1 else { return 6 }
        return Int(ceil(log10(Double(windowSeconds))))
    }

    /// Percentage points on a 0…100 scale (`util`, `raw`, `n`).
    static let percentPoints = 2
    /// A fraction of a money limit (`spentFrac`).
    static let moneyFraction = 4

    /// Round `value` to `decimals`, leaving non-finite values untouched (they encode as-is and the
    /// tolerant decoder handles them; silently turning a NaN into 0 would hide a real fault).
    static func round(_ value: Double, decimals: Int) -> Double {
        guard value.isFinite else { return value }
        let scale = pow(10.0, Double(decimals))
        return (value * scale).rounded() / scale
    }

    /// Round an optional, preserving `nil`.
    static func round(_ value: Double?, decimals: Int) -> Double? {
        value.map { round($0, decimals: decimals) }
    }
}
