import Foundation

// MARK: - JournalFixture

/// Generates a deterministic multi-day sequence of ``JournalRecord``s for downstream UI verification
/// (#242) — the data a future Insights chart (#239/#240/#241) reads back. Pure and clock-injected, so
/// the shell's dev hook just serialises the result to a file (the `TOKENPACE_JOURNAL_FILE` override).
///
/// The series is intentionally realistic: usage climbing through the day and resetting overnight,
/// interleaved status samples, a scattering of `error` lines (a 429 and a timeout), and one
/// deliberate multi-hour hole followed by a `resume` marker — so a reader that must render gaps as
/// gaps has something to render.
public enum JournalFixture {

    /// Build `days` worth of records ending at `endingAt`, one usage sample per `interval` (default 3
    /// min), with periodic status samples, a few errors, and one injected gap + resume on the last day.
    ///
    /// - Parameters:
    ///   - days: How many days of history to synthesize (≥ 1).
    ///   - endingAt: The instant the series ends (the most recent poll).
    ///   - interval: The usage-sample cadence in seconds (default 180).
    /// - Returns: `(record, instant)` pairs in chronological order — the instant lets the writer place
    ///   each line in the right monthly file.
    public static func multiDay(days: Int, endingAt: Date, interval: TimeInterval = 180) -> [(JournalRecord, Date)] {
        let dayCount = max(1, days)
        let start = endingAt.addingTimeInterval(-Double(dayCount) * 86_400)
        var records: [(JournalRecord, Date)] = []

        // The 7-day reset stays fixed across the run; the 5h reset rolls each ~5 hours.
        let sevenDayReset = endingAt.addingTimeInterval(2 * 86_400)

        var t = start
        var previous: Date?
        var pollIndex = 0
        while t <= endingAt {
            // One injected gap: skip a ~4-hour stretch midway through the last day, so the next record
            // carries a resume marker (a reader must not interpolate across it).
            let gapStart = endingAt.addingTimeInterval(-0.5 * 86_400)
            if t >= gapStart && t < gapStart.addingTimeInterval(4 * 3_600) {
                t = gapStart.addingTimeInterval(4 * 3_600)
                continue
            }

            if let marker = JournalGap.marker(previous: previous, now: t, expectedInterval: interval) {
                records.append((.resume(marker), t))
            }

            // Every ~40th poll (~2 h) fails: alternate a 429 and a timeout, so error lines appear.
            if pollIndex > 0 && pollIndex % 40 == 0 {
                records.append((errorRecord(index: pollIndex, at: t), t))
            } else {
                records.append((usageRecord(at: t, dayStart: start, sevenDayReset: sevenDayReset), t))
            }

            // A status sample every ~10th poll (~30 min), mostly operational with an occasional blip.
            if pollIndex % 10 == 0 {
                records.append((statusRecord(index: pollIndex, at: t), t))
            }

            previous = t
            t = t.addingTimeInterval(interval)
            pollIndex += 1
        }
        return records
    }

    // MARK: - Builders

    private static func usageRecord(at t: Date, dayStart: Date, sevenDayReset: Date) -> JournalRecord {
        // Utilisation climbs through each UTC day (0→~85 %) and resets at midnight — a legible daily saw-tooth.
        let secondsIntoDay = t.timeIntervalSince(dayStart).truncatingRemainder(dividingBy: 86_400)
        let dayFraction = secondsIntoDay / 86_400
        let h5Util = min(95, dayFraction * 90)
        let d7Util = min(90, (t.timeIntervalSince(dayStart) / (7 * 86_400)) * 100)

        // 5h window resets on the next 5-hour boundary from now; 7d fixed.
        let fiveReset = t.addingTimeInterval(5 * 3_600 - secondsIntoDay.truncatingRemainder(dividingBy: 5 * 3_600))

        let snapshot = UsageSnapshot(
            fiveHour: UsageWindow(utilization: h5Util, resetsAt: ResetClock.isoString(from: fiveReset)),
            sevenDay: UsageWindow(utilization: d7Util, resetsAt: ResetClock.isoString(from: sevenDayReset)))
        // Vary latency a little around 120 ms without a RNG (deterministic from the timestamp).
        let ms = 90 + Int(secondsIntoDay.truncatingRemainder(dividingBy: 80))
        return .usage(from: snapshot, now: t, durationMs: ms)
    }

    private static func statusRecord(index: Int, at t: Date) -> JournalRecord {
        // Mostly operational; one degraded blip every ~200 polls to give the status series texture.
        let blip = index % 200 == 100
        let summary = StatusSummary(components: [
            StatusComponent(name: StatusHealth.claudeAPIComponentName, status: "operational"),
            StatusComponent(name: StatusHealth.claudeCodeComponentName,
                            status: blip ? "degraded_performance" : "operational"),
            StatusComponent(name: StatusHealth.claudeWebComponentName, status: "operational"),
        ])
        let health = StatusHealth.from(summary, config: .default)
        return .status(from: summary, health: health, now: t)
    }

    private static func errorRecord(index: Int, at t: Date) -> JournalRecord {
        // Alternate a rate-limit (client, with retry-after) and a timeout (transport), so both error
        // shapes appear in the fixture.
        if (index / 40) % 2 == 0 {
            let d = FetchDiagnostics(attemptAt: t, httpStatus: 429, body: nil, outcome: .httpError,
                                     retryAfter: 60, durationMs: 140)
            return .error(diagnostics: d, failure: .serverProblem, now: t)
        } else {
            let d = FetchDiagnostics(attemptAt: t, httpStatus: nil, body: nil,
                                     outcome: .transportError(message: "timed out"), durationMs: 30_000)
            return .error(diagnostics: d, failure: .timeout, now: t)
        }
    }
}
