import Foundation
import TokenPaceKit

// MARK: - StatusPayloadLog

/// A dev-only JSONL of **raw** `status.claude.com` payloads, written only when something material
/// changed (ADR-0071 §10). Instrumentation for questions ADR-0071 left open — which events deserve a
/// banner, whether "recovered" needs a debounce — answered by "measure, don't guess".
///
/// One JSON object per line: capture instant, the fingerprint that triggered the write, and the
/// **verbatim** response body (parsed back so the line is a single well-formed object rather than a
/// string with escaped JSON inside it). Recording the raw body is the point — a re-encoded digest
/// would answer only the questions we already knew to ask.
///
/// Three gates, all must pass: the dev-tools checkbox (`PersistedConfig.statusPayloadLogEnabled`,
/// default off), the live-network scenario, and a changed ``StatusPayloadFingerprint``.
///
/// An `actor` for the same reason as ``UsageJournal``: it owns mutable state and does file I/O, and
/// must never block a poll. Every failure is logged and swallowed.
actor StatusPayloadLog {

    /// Month-partitioned like the usage journal so a long-running install doesn't grow one unbounded
    /// file.
    private let directory: URL
    /// A dev build writes to a `-dev` file so it can never pollute the release capture.
    private let isRelease: Bool
    private let fileManager: FileManager
    /// `nil` until the first write of this launch, so a relaunch always records one baseline line.
    private var lastFingerprint: String?

    init(
        directory: URL = UsageJournal.defaultDirectory,
        isRelease: Bool = UsageJournal.runningFromApplications,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.isRelease = isRelease
        self.fileManager = fileManager
    }

    // MARK: - Record

    /// Record one poll if its fingerprint differs from the last written line. Returns whether a line
    /// was written.
    @discardableResult
    func recordIfChanged(body: Data, summary: StatusSummary, at instant: Date) -> Bool {
        let fingerprint = StatusPayloadFingerprint.of(summary)
        guard fingerprint != lastFingerprint else { return false }
        lastFingerprint = fingerprint
        writeLine(body: body, fingerprint: fingerprint, at: instant)
        return true
    }

    func fileURL(for instant: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM"
        let suffix = isRelease ? "" : "-dev"
        return directory.appendingPathComponent("status-payloads\(suffix)-\(formatter.string(from: instant)).jsonl")
    }

    /// A fresh formatter per call: `ISO8601DateFormatter` is not `Sendable`, and writes happen at
    /// most once per material change.
    private static func timestamp(_ instant: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: instant)
    }

    // MARK: - Write

    private func writeLine(body: Data, fingerprint: String, at instant: Date) {
        let url = fileURL(for: instant)
        do {
            // Re-parse so it nests as a real JSON value; fall back to raw text rather than dropping
            // the sample if it somehow won't parse.
            let payload = (try? JSONSerialization.jsonObject(with: body))
                ?? String(data: body, encoding: .utf8) as Any
            let line: [String: Any] = [
                "t": Self.timestamp(instant),
                "fp": fingerprint,
                "payload": payload,
            ]
            var data = try JSONSerialization.data(withJSONObject: line, options: [.withoutEscapingSlashes])
            data.append(0x0A)  // '\n'

            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            appendLocked(data, to: url)
        } catch {
            AppLogger.journal.error(
                "status-payload-log: write failed \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Exactly as ``UsageJournal``: several instances run side by side, and `O_APPEND` alone is only
    /// atomic for small writes — a full status payload is far past that.
    private func appendLocked(_ data: Data, to url: URL) {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else {
            AppLogger.journal.error("status-payload-log: open failed errno=\(errno, privacy: .public)")
            return
        }
        defer { close(fd) }

        guard flock(fd, LOCK_EX) == 0 else {
            AppLogger.journal.error("status-payload-log: lock failed errno=\(errno, privacy: .public)")
            return
        }
        defer { flock(fd, LOCK_UN) }

        data.withUnsafeBytes { raw in
            var written = 0
            let total = raw.count
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            while written < total {
                let n = write(fd, base?.advanced(by: written), total - written)
                if n <= 0 {
                    AppLogger.journal.error("status-payload-log: write() failed errno=\(errno, privacy: .public)")
                    return
                }
                written += n
            }
        }
    }
}
