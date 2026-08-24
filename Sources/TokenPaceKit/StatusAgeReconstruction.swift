import Foundation

// MARK: - StatusAgeReconstruction

/// When each component last **changed status**, recovered from the journal's own `status` records.
///
/// The fallback for a provider whose feed does not answer it. Codex's `components[].updated_at` is
/// the page's edit stamp — identical on all 34 components (measured) — so an age taken from it would
/// be measured from an unrelated event. Its incident feed does carry a real per-component timestamp,
/// but that feed is undocumented and may be unavailable; this is what stands in when it is.
///
/// The source is already written: every `status` line carries `t`, its `provider`, and `svc` — the
/// whole feed with names and raw statuses.
///
/// Its limits, stated so a reader does not over-trust the number:
///
/// - **Resolution is the poll cadence.** A change is dated to the first poll that *saw* it, so an age
///   is accurate to within one interval (five minutes at the politeness floor), never better.
/// - **A fresh install has no history**, and the answer is `nil` — a row with no age, not an age of
///   zero, which would claim the component just changed.
/// - **Depth is the journal's retention.** A component that has held one status longer than the
///   journal keeps lines reads as having changed at the oldest line, which understates the age. It
///   never overstates it.
public enum StatusAgeReconstruction {

    /// The instant each component of `provider` was first seen in the status it holds in the newest
    /// sample, or no entry when the journal cannot say.
    ///
    /// - Parameter samples: `status` records in any order; sorted here by `t`.
    public static func changedAt(
        from samples: [StatusSample],
        provider: ProviderID
    ) -> [String: Date] {
        let ordered = samples
            .filter { $0.provider == provider.rawValue }
            .compactMap { sample -> (Date, StatusSample)? in
                ResetClock.parse(sample.t).map { ($0, sample) }
            }
            .sorted { $0.0 < $1.0 }
        guard let (_, newest) = ordered.last else { return [:] }

        var result: [String: Date] = [:]
        for entry in newest.svc {
            // Walk back from the newest line while the component reads the same status, and take the
            // timestamp of the oldest line that still does. A line that does not name the component
            // at all ends the walk: absence is not evidence the status held.
            var since: Date?
            for (time, sample) in ordered.reversed() {
                guard let seen = sample.svc.first(where: { $0.n == entry.n }), seen.s == entry.s else {
                    break
                }
                since = time
            }
            // The oldest line in the journal is not evidence of a change — only of where the record
            // begins. Reporting it would date a months-old status to the retention window's edge.
            if let since, since > ordered[0].0 { result[entry.n] = since }
        }
        return result
    }
}
