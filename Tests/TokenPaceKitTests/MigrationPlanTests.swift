import Testing
@testable import TokenPaceKit

// MARK: - MigrationPlan decision predicates

/// Covers the pure decision core of on-launch config migration (#71). The `UserDefaults`-facing
/// storage (`PersistedConfig`) is a system singleton verified manually, per the project's
/// pure-core / thin-shell convention (ADR-0009, ADR-0023).
@Suite("MigrationPlan.transition")
struct MigrationPlanTransitionTests {

    /// No stored version (fresh install or a pre-persistence build) classifies as `.firstRun`.
    @Test func nilStoredIsFirstRun() {
        #expect(MigrationPlan.transition(stored: nil, current: "0.18.1") == .firstRun)
    }

    /// The stored version equal to the current one classifies as `.unchanged`.
    @Test func sameVersionIsUnchanged() {
        #expect(MigrationPlan.transition(stored: "0.18.1", current: "0.18.1") == .unchanged)
    }

    /// A different stored version classifies as `.upgraded`, carrying both endpoints so a migration
    /// can key off the exact from→to step.
    @Test func differentVersionIsUpgraded() {
        #expect(
            MigrationPlan.transition(stored: "0.18.0", current: "0.18.1")
                == .upgraded(from: "0.18.0", to: "0.18.1"))
    }

    /// The comparison is a plain inequality (scaffold), not version ordering: a "downgrade" — an
    /// older running build than what last wrote the config — is still just `.upgraded` with its
    /// endpoints, not a special case. Guards against someone assuming ordered comparison prematurely.
    @Test func downgradeIsStillUpgradedTransition() {
        #expect(
            MigrationPlan.transition(stored: "0.19.0", current: "0.18.1")
                == .upgraded(from: "0.19.0", to: "0.18.1"))
    }
}

@Suite("MigrationPlan.needsMigration")
struct MigrationPlanNeedsMigrationTests {

    /// Only an `.upgraded` transition has work to do.
    @Test func upgradeNeedsMigration() {
        #expect(MigrationPlan.needsMigration(.upgraded(from: "0.18.0", to: "0.18.1")) == true)
    }

    /// A first run records the version but migrates nothing.
    @Test func firstRunNeedsNoMigration() {
        #expect(MigrationPlan.needsMigration(.firstRun) == false)
    }

    /// An unchanged version has nothing to migrate.
    @Test func unchangedNeedsNoMigration() {
        #expect(MigrationPlan.needsMigration(.unchanged) == false)
    }
}
