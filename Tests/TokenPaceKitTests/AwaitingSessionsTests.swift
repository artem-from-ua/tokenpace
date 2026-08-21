import Testing
@testable import TokenPaceKit

/// Grouping, ordering and derived counts on ``AwaitingSessions`` (#438).
///
/// Separate from `AwaitingInputScannerTests`, which drives the same types through a real fixture tree
/// on disk: everything here is a pure value, so building sessions directly says what is under test
/// without a temp directory in the way.
@Suite("AwaitingSessions")
struct AwaitingSessionsTests {
    /// A session in `project` with `daysLeft` days before Claude Code's cleanup deletes it.
    private func session(_ project: String, _ daysLeft: Double, name: String? = nil) -> AwaitingSession {
        AwaitingSession(project: project, daysUntilDeletion: daysLeft, name: name)
    }

    // MARK: grouping

    @Test func perProjectGroupsSessionsUnderTheirProject() {
        let sessions = AwaitingSessions([
            session("/repo/app", 20, name: "a"),
            session("/repo/lib", 20, name: "b"),
            session("/repo/app", 10, name: "c"),
        ])
        let per = sessions.perProject
        #expect(per.count == 2)
        #expect(per.first { $0.projectName == "app" }?.sessions.count == 2)
        #expect(per.first { $0.projectName == "lib" }?.sessions.count == 1)
    }

    @Test func derivedCountsMatchTheSessionsTheySummarize() {
        let stat = ProjectAwaitingStats(projectName: "app", sessions: [
            session("/repo/app", 3),    // red
            session("/repo/app", 10),   // orange
            session("/repo/app", 20),   // neutral
            session("/repo/app", 25),   // neutral
        ])
        #expect(stat.red == 1)
        #expect(stat.orange == 1)
        #expect(stat.recent == 2)
        #expect(stat.total == 4)
    }

    // MARK: ordering

    /// Projects sort alphabetically, **not** by urgency — the heading no longer displays the chips
    /// that ordering was read from, so ranking by them would order the list by something invisible.
    @Test func projectsSortByName() {
        let sessions = AwaitingSessions([
            session("/repo/zzz", 3),      // the only red one
            session("/repo/aaa", 25),
            session("/repo/mmm", 10),
        ])
        #expect(sessions.perProject.map(\.projectName) == ["aaa", "mmm", "zzz"])
    }

    /// Freshest first: more days left before deletion means a more recently updated session.
    @Test func sessionsSortFreshestFirst() {
        let sessions = AwaitingSessions([
            session("/repo/app", 5, name: "stale"),
            session("/repo/app", 28, name: "fresh"),
            session("/repo/app", 12, name: "middling"),
        ])
        #expect(sessions.perProject.first!.sessions.map(\.name) == ["fresh", "middling", "stale"])
    }

    /// The tie-break carries real weight: the scanner clamps age at `max(0, …)`, so every session
    /// touched in the last instant lands on the *same* `daysUntilDeletion`. Without a total order the
    /// rows would follow directory order, and since ``AwaitingSessions`` is `Equatable`, the watcher
    /// would read each reshuffle as a change and re-render on every scan.
    @Test func equalRecencyStillYieldsOneStableOrder() {
        let forwards = AwaitingSessions([
            session("/repo/app", 30, name: "beta"),
            session("/repo/app", 30, name: "alpha"),
        ])
        let backwards = AwaitingSessions([
            session("/repo/app", 30, name: "alpha"),
            session("/repo/app", 30, name: "beta"),
        ])
        #expect(forwards.perProject.first!.sessions.map(\.name) == ["alpha", "beta"])
        #expect(backwards.perProject.first!.sessions.map(\.name) == ["alpha", "beta"])
    }

    /// Two unnamed sessions cannot be told apart by name, so the order falls through to `project` —
    /// still a total order, never directory order.
    @Test func unnamedSessionsAtEqualRecencyFallBackToProject() {
        let sessions = AwaitingSessions([
            session("/repo/b/app", 30),
            session("/repo/a/app", 30),
        ])
        #expect(sessions.perProject.first!.sessions.map(\.project) == ["/repo/a/app", "/repo/b/app"])
    }

    @Test func repeatedReadsAgree() {
        let sessions = AwaitingSessions([
            session("/repo/app", 30, name: "one"),
            session("/repo/lib", 30, name: "two"),
            session("/repo/app", 30, name: "three"),
        ])
        #expect(sessions.perProject == sessions.perProject)
    }

    // MARK: name

    @Test func aSessionWithoutANameKeepsNil() {
        #expect(session("/repo/app", 20).name == nil)
    }

    /// The watcher dedupes on `==`, so a rename has to register as a change — otherwise the popup
    /// would keep showing the old title until something else moved.
    @Test func renamingASessionMakesItUnequal() {
        let before = AwaitingSessions([session("/repo/app", 20, name: "old title")])
        let after = AwaitingSessions([session("/repo/app", 20, name: "new title")])
        #expect(before != after)
    }
}
