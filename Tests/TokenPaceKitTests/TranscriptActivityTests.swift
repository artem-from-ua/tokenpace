import Foundation
import Testing
@testable import TokenPaceKit

// MARK: - Fixtures

/// A fixture `ActivityFileIndex` driven by a table of `path suffix → mtime`, so a test states "the
/// history file was touched 30 s ago" without creating a single real file.
///
/// Matching is by **suffix** because the probe builds absolute URLs under an injected home: a test
/// writes `"history.jsonl"` and stays indifferent to what root the probe prefixed.
private struct StubIndex: ActivityFileIndex {
    /// Path suffix → the newest mtime under it.
    var newest: [String: Date] = [:]

    func hasFileModified(after cutoff: Date, under root: URL) -> Bool {
        for (suffix, modified) in newest where root.path.hasSuffix(suffix) {
            if modified > cutoff { return true }
        }
        return false
    }
}

private let home = URL(fileURLWithPath: "/fixture/.claude")
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// Builds a probe pinned to `t0` with the default 5-minute window.
private func probe(_ index: StubIndex) -> TranscriptActivityProbe {
    TranscriptActivityProbe(claudeHome: home, now: { t0 }, index: index)
}

// MARK: - Tests

@Suite("TranscriptActivityProbe")
struct TranscriptActivityProbeTests {

    // MARK: Session transcripts

    @Test("a transcript written inside the window counts as active")
    func freshTranscriptIsActive() {
        let index = StubIndex(newest: ["projects": t0.addingTimeInterval(-60)])
        #expect(probe(index).isClaudeRunning())
    }

    @Test("a transcript older than the window does not count")
    func staleTranscriptIsInactive() {
        let index = StubIndex(newest: ["projects": t0.addingTimeInterval(-10 * 60)])
        #expect(!probe(index).isClaudeRunning())
    }

    /// The boundary is pinned deliberately: `hasFileModified(after:)` is strict, so a write landing
    /// exactly `activityWindow` ago is **not** fresh. Without this test the comparison could drift
    /// between `>` and `>=` unnoticed.
    @Test("a write exactly at the window edge does not count")
    func windowEdgeIsExclusive() {
        let edge = t0.addingTimeInterval(-TranscriptActivityProbe.activityWindow)
        let index = StubIndex(newest: ["projects": edge])
        #expect(!probe(index).isClaudeRunning())
    }

    // MARK: The other two sources

    /// The user typing is activity **before** any token is spent: someone is at the keyboard looking
    /// at the widget, and spend follows within seconds (ADR-0118).
    @Test("a fresh history.jsonl counts even when every transcript is stale")
    func freshHistoryIsActive() {
        let index = StubIndex(newest: [
            "history.jsonl": t0.addingTimeInterval(-30),
            "projects": t0.addingTimeInterval(-60 * 60),
        ])
        #expect(probe(index).isClaudeRunning())
    }

    /// Background jobs progress with no interactive session open, so their timeline is the source
    /// that covers work the transcripts do not.
    @Test("a fresh job timeline counts even when every transcript is stale")
    func freshJobTimelineIsActive() {
        let index = StubIndex(newest: [
            "jobs": t0.addingTimeInterval(-45),
            "projects": t0.addingTimeInterval(-60 * 60),
        ])
        #expect(probe(index).isClaudeRunning())
    }

    @Test("all three sources stale → inactive")
    func allSourcesStaleIsInactive() {
        let index = StubIndex(newest: [
            "history.jsonl": t0.addingTimeInterval(-20 * 60),
            "jobs": t0.addingTimeInterval(-30 * 60),
            "projects": t0.addingTimeInterval(-60 * 60),
        ])
        #expect(!probe(index).isClaudeRunning())
    }

    /// Fail-safe: nothing on disk answers "inactive", which lands on the conservative 15-minute
    /// cadence rather than hammering the API on a machine with no Claude Code at all.
    @Test("an empty tree is inactive rather than an error")
    func emptyTreeIsInactive() {
        #expect(!probe(StubIndex()).isClaudeRunning())
    }

    // MARK: Roots

    /// Subagent transcripts nest a level deeper (`projects/<slug>/<uuid>/subagents/agent-<id>.jsonl`),
    /// so the `projects` root is handed to the index whole and walked recursively — the probe never
    /// assumes a fixed depth.
    @Test("all three roots are offered to the index")
    func offersAllThreeRoots() {
        final class Recorder: @unchecked Sendable {
            var seen: [String] = []
        }
        struct RecordingIndex: ActivityFileIndex {
            let recorder: Recorder
            func hasFileModified(after cutoff: Date, under root: URL) -> Bool {
                recorder.seen.append(root.lastPathComponent)
                return false
            }
        }
        let recorder = Recorder()
        let subject = TranscriptActivityProbe(
            claudeHome: home, now: { t0 }, index: RecordingIndex(recorder: recorder)
        )
        _ = subject.isClaudeRunning()
        #expect(recorder.seen == ["history.jsonl", "jobs", "projects"])
    }

    /// Cheapest-first ordering with an early exit: once `history.jsonl` answers yes, the recursive
    /// `projects` walk is never paid for.
    @Test("stops at the first source that answers yes")
    func stopsAtFirstHit() {
        final class Recorder: @unchecked Sendable {
            var seen: [String] = []
        }
        struct RecordingIndex: ActivityFileIndex {
            let recorder: Recorder
            func hasFileModified(after cutoff: Date, under root: URL) -> Bool {
                recorder.seen.append(root.lastPathComponent)
                return root.lastPathComponent == "history.jsonl"
            }
        }
        let recorder = Recorder()
        let subject = TranscriptActivityProbe(
            claudeHome: home, now: { t0 }, index: RecordingIndex(recorder: recorder)
        )
        #expect(subject.isClaudeRunning())
        #expect(recorder.seen == ["history.jsonl"])
    }

    @Test("roots are built under the injected home")
    func rootsAreUnderInjectedHome() {
        final class Recorder: @unchecked Sendable {
            var paths: [String] = []
        }
        struct RecordingIndex: ActivityFileIndex {
            let recorder: Recorder
            func hasFileModified(after cutoff: Date, under root: URL) -> Bool {
                recorder.paths.append(root.path)
                return false
            }
        }
        let recorder = Recorder()
        let subject = TranscriptActivityProbe(
            claudeHome: URL(fileURLWithPath: "/elsewhere/config"), now: { t0 },
            index: RecordingIndex(recorder: recorder)
        )
        _ = subject.isClaudeRunning()
        #expect(recorder.paths.allSatisfy { $0.hasPrefix("/elsewhere/config/") })
    }
}

// MARK: - Home resolution

@Suite("TranscriptActivityProbe.defaultClaudeHome")
struct DefaultClaudeHomeTests {

    /// `CLAUDE_CONFIG_DIR` relocates the entire tree; hard-coding `~/.claude` would make the probe
    /// blind for anyone who sets it — the same class of failure as hard-coding the binary name.
    @Test("CLAUDE_CONFIG_DIR redirects the root")
    func honorsConfigDirOverride() throws {
        let key = "CLAUDE_CONFIG_DIR"
        let original = ProcessInfo.processInfo.environment[key]
        defer {
            if let original { setenv(key, original, 1) } else { unsetenv(key) }
        }

        setenv(key, "/custom/claude-home", 1)
        #expect(TranscriptActivityProbe.defaultClaudeHome().path == "/custom/claude-home")

        unsetenv(key)
        #expect(TranscriptActivityProbe.defaultClaudeHome().lastPathComponent == ".claude")
    }

    @Test("an empty CLAUDE_CONFIG_DIR falls back to ~/.claude")
    func emptyOverrideFallsBack() throws {
        let key = "CLAUDE_CONFIG_DIR"
        let original = ProcessInfo.processInfo.environment[key]
        defer {
            if let original { setenv(key, original, 1) } else { unsetenv(key) }
        }

        setenv(key, "", 1)
        #expect(TranscriptActivityProbe.defaultClaudeHome().lastPathComponent == ".claude")
    }
}
