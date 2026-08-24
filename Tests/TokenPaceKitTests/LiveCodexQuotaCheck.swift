import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Live Codex quota check (opt-in)

/// Reads the real `codex` account three times and runs each payload through the production path —
/// decode, normalize, rows — reporting what the server actually said and what the row became.
///
/// **Opt-in.** Skipped unless `TOKENPACE_LIVE_CODEX` names the `codex` binary, so CI and everyday
/// `swift test` never spawn a process or touch an account. It reads; it writes nothing.
///
/// It exists because the fixture in `CodexQuotaTests` is one captured payload, while the defect it
/// answers is a value that **moves between reads**. A single frozen sample cannot show that, and the
/// creep is the whole reason the state needs a name: three reads seconds apart are the evidence, and
/// this is what produces them again on demand.
@Suite("Live Codex quota", .enabled(if: ProcessInfo.processInfo.environment["TOKENPACE_LIVE_CODEX"] != nil))
struct LiveCodexQuotaCheck {

    private static var binary: String {
        ProcessInfo.processInfo.environment["TOKENPACE_LIVE_CODEX"] ?? ""
    }

    /// One `initialize` + `account/rateLimits/read` exchange, returning the instant the request went
    /// out beside the `result` body. `now` is taken **before** the round trip, so the offset it
    /// yields is a lower bound on the reset's distance rather than a flattering one.
    private static func read() throws -> (now: Date, data: Data)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        let now = Date()
        input.fileHandleForWriting.write(Data("""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"tokenpace-live-check","title":"tokenpace-live-check","version":"0.0.1"}}}
        {"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}

        """.utf8))

        // Matched by `id`, because `remoteControl/status/changed` is observed arriving between a
        // request and its response — taking "the next line" hands back a notification.
        var buffer = Data()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            for line in String(decoding: buffer, as: UTF8.self).split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["id"] as? Int == 2, let result = object["result"] else { continue }
                return (now, try JSONSerialization.data(withJSONObject: result))
            }
        }
        return nil
    }

    @Test("three live reads agree with the not-started rule")
    func liveReadsAgreeWithTheRule() throws {
        var offsets: [TimeInterval] = []
        var resets: [Date] = []

        for attempt in 1...3 {
            guard let (now, data) = try Self.read() else {
                Issue.record("read \(attempt) returned no result")
                continue
            }
            let decoded = try JSONDecoder().decode(CodexRateLimitsResult.self, from: data)
            let snapshot = try CodexQuotaNormalizer.snapshot(from: decoded)
            let rows = CodexQuotaNormalizer.rows(from: snapshot, now: now)

            for (window, row) in zip(snapshot.windows, rows) {
                let ahead = window.resetsAt?.timeIntervalSince(now)
                print("""
                read \(attempt): used=\(window.utilization)% \
                duration=\(window.durationSeconds)s \
                resetsAt=\(window.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "nil") \
                ahead=\(ahead.map { String(Int($0)) } ?? "nil")s \
                offBy=\(ahead.map { String(Int($0) - window.durationSeconds) } ?? "nil")s \
                notStarted=\(window.hasNotStarted(now: now)) \
                → row idle=\(row.sessionIdle) reset=\(row.resetLine ?? "none")
                """)

                // The rule and the row must never disagree: an idle row is exactly a window that has
                // not started, and it is the one shape that carries no reset line.
                #expect(row.sessionIdle == window.hasNotStarted(now: now))
                if row.sessionIdle { #expect(row.resetLine == nil) }
                if let ahead, window.durationSeconds > 0 {
                    offsets.append(ahead - Double(window.durationSeconds))
                }
                if let reset = window.resetsAt { resets.append(reset) }
            }
            if attempt < 3 { Thread.sleep(forTimeInterval: 6) }
        }

        // Whether the account is in the not-started state is not this check's to decide — it depends
        // on whether anything has been spent this week. What it does assert is the shape: every
        // offset from a whole window either sits inside the tolerance on all three reads or outside
        // it on all three, because a value that is `now + duration` stays that way as `now` moves.
        let inside = offsets.filter { abs($0) <= CodexQuotaWindow.notStartedTolerance }.count
        print("offsets from a whole window: \(offsets.map { Int($0) }) — \(inside)/\(offsets.count) inside ±\(Int(CodexQuotaWindow.notStartedTolerance))s")
        #expect(inside == 0 || inside == offsets.count)

        // The creep itself, when it is happening: a reset that is an instant holds still across
        // reads, one that is `now + duration` advances with the clock.
        if inside == offsets.count, resets.count >= 2 {
            print("reset advanced by \(Int(resets[resets.count - 1].timeIntervalSince(resets[0])))s across the reads")
        }
    }
}
