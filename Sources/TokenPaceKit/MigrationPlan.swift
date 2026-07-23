import Foundation

// MARK: - MigrationPlan

/// The pure, framework-free decision core for on-launch config migration (#71).
///
/// The app persists the marketing version it last wrote its settings under (`lastRunVersion`), so a
/// newer build can compare "version that last wrote the config" against the running version and, if
/// they differ, run any key-renaming / cleanup migrations before the config is used.
///
/// The `UserDefaults`-facing storage is a system singleton that lives in the `TokenPace` glue target
/// (`PersistedConfig`) and is verified manually, per the pure-core / thin-shell convention (ADR-0009,
/// ADR-0023). What *can* be tested — and reused in Phase 2 — is the classification of a launch into
/// first-run / unchanged / upgraded and the decision of whether there is anything to migrate. Those
/// live here, exactly like the `LaunchAtLogin` decision predicates.
///
/// Phase 1 scope (this ticket) is deliberately the scaffold only: the version marker plus an empty
/// migration extension point. No real migration steps exist yet, and the comparison is a plain string
/// inequality — a full SemVer comparison ("migrate only when stored < X.Y.Z") is deferred until the
/// first concrete migration needs it (#71).
public enum MigrationPlan {

    /// How a launch is classified from the stored versus the current version — the input every
    /// migration decision is made against.
    public enum Transition: Equatable, Sendable {
        /// No version was stored (`lastRunVersion == nil`): a fresh install, or an upgrade from a
        /// pre-persistence build. No migrations — just record the current version (ADR-0023).
        case firstRun
        /// The stored version equals the running version: nothing changed since the last write, so
        /// there is nothing to migrate.
        case unchanged
        /// The stored version differs from the running version: the config was last written by a
        /// different build, so any registered migrations for this `from`→`to` step should run.
        case upgraded(from: String, to: String)
    }

    /// Classify a launch from the stored marketing version (or `nil` on first run) and the current
    /// one. A pure function — no I/O, no clock, no `UserDefaults`. The comparison is a plain string
    /// inequality for now (scaffold); it does not attempt to order versions.
    public static func transition(stored: String?, current: String) -> Transition {
        guard let stored else { return .firstRun }
        return stored == current ? .unchanged : .upgraded(from: stored, to: current)
    }

    /// Whether a transition has migration work to run. Only ``Transition/upgraded(from:to:)`` does;
    /// a first run or an unchanged version never migrates. (There are no real steps yet — this is the
    /// extension point where a future migration list is consulted.)
    public static func needsMigration(_ transition: Transition) -> Bool {
        if case .upgraded = transition { return true }
        return false
    }
}
