import Foundation

// MARK: - ByteSize

/// Human-readable byte-size formatting, **integer only** (no decimals) and **locale-independent**
/// (#110) — for the archive's "… · 1 GB" status line.
///
/// Deliberately not `ByteCountFormatter`: that formatter is locale-formatted (it would render "1 ГБ"
/// under a Ukrainian system locale) and emits decimals ("1.4 GB"). The whole UI is English and the
/// user asked for whole numbers, so this is a small pure function instead — and, being pure, it is
/// unit-tested.
///
/// Uses binary units (1 KB = 1024 B), the convention for on-disk file sizes, and rounds to the
/// nearest whole unit. Bytes below 1 KB are shown as an exact byte count ("512 B").
public enum ByteSize {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// Format `bytes` as e.g. `"0 B"`, `"512 B"`, `"3 KB"`, `"1 GB"` — the largest unit under which
    /// the value is ≥ 1, rounded to the nearest whole number. Negative inputs clamp to `"0 B"`.
    public static func humanReadable(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        // Rounding can push e.g. 1023.6 KB to "1024 KB"; carry to the next unit so it reads "1 MB".
        var rounded = value.rounded()
        if rounded >= 1024, unit < units.count - 1 {
            rounded /= 1024
            unit += 1
        }
        return "\(Int(rounded)) \(units[unit])"
    }
}
