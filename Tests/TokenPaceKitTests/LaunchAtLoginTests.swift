import Testing
@testable import TokenPaceKit

// MARK: - LaunchAtLogin decision predicates

/// Covers the pure decision core of the launch-at-login feature (#14). The `SMAppService`-facing
/// glue (`LaunchAtLoginController`) is a system singleton and is verified manually, per the
/// project's pure-core / thin-shell convention (ADR-0009 §"Наслідки").
@Suite("LaunchAtLogin decisions")
struct LaunchAtLoginTests {

    /// Opt-out auto-registration is attempted whenever there is no active login item — both
    /// `.notRegistered` and `.notFound`. `.notFound` on a real install means the registration
    /// dropped with a replaced bundle on update, so re-`register()` self-heals it (#69). The
    /// `.notFound` case is the regression guard for #69 (it used to be `false`, greying the
    /// checkbox forever after an update). `.registered`/`.requiresApproval` are left alone.
    @Test func attemptsRegisterWhenNoActiveLoginItem() {
        #expect(LaunchAtLogin.shouldAttemptRegister(.notRegistered) == true)
        #expect(LaunchAtLogin.shouldAttemptRegister(.notFound) == true)
        #expect(LaunchAtLogin.shouldAttemptRegister(.registered) == false)
        #expect(LaunchAtLogin.shouldAttemptRegister(.requiresApproval) == false)
    }

    /// The checkbox is on only when the item is actually registered; `.requiresApproval` reads off.
    @Test func toggleOnOnlyWhenRegistered() {
        #expect(LaunchAtLogin.toggleState(for: .registered) == true)
        #expect(LaunchAtLogin.toggleState(for: .notRegistered) == false)
        #expect(LaunchAtLogin.toggleState(for: .requiresApproval) == false)
        #expect(LaunchAtLogin.toggleState(for: .notFound) == false)
    }

    /// The user is sent to System Settings only when approval is pending there.
    @Test func systemSettingsOnlyOnApprovalNeeded() {
        #expect(LaunchAtLogin.needsSystemSettings(.requiresApproval) == true)
        #expect(LaunchAtLogin.needsSystemSettings(.registered) == false)
        #expect(LaunchAtLogin.needsSystemSettings(.notRegistered) == false)
        #expect(LaunchAtLogin.needsSystemSettings(.notFound) == false)
    }
}
