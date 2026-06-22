import Testing
@testable import CCTimerKit

// MARK: - LaunchAtLogin decision predicates

/// Covers the pure decision core of the launch-at-login feature (#14). The `SMAppService`-facing
/// glue (`LaunchAtLoginController`) is a system singleton and is verified manually, per the
/// project's pure-core / thin-shell convention (ADR-0009 §"Наслідки").
@Suite("LaunchAtLogin decisions")
struct LaunchAtLoginTests {

    /// Opt-out auto-registration fires for `.notRegistered` only — every other status is left alone.
    @Test func registersOnlyWhenNotRegistered() {
        #expect(LaunchAtLogin.shouldRegisterOnFirstLaunch(.notRegistered) == true)
        #expect(LaunchAtLogin.shouldRegisterOnFirstLaunch(.registered) == false)
        #expect(LaunchAtLogin.shouldRegisterOnFirstLaunch(.requiresApproval) == false)
        #expect(LaunchAtLogin.shouldRegisterOnFirstLaunch(.notFound) == false)
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

    /// The toggle is controllable for every status except `.notFound` (no registerable login item
    /// in this run context — bare `swift run` or an ad-hoc bundle SMAppService rejects).
    @Test func unavailableOnlyWhenNotFound() {
        #expect(LaunchAtLogin.isAvailable(.notFound) == false)
        #expect(LaunchAtLogin.isAvailable(.registered) == true)
        #expect(LaunchAtLogin.isAvailable(.notRegistered) == true)
        #expect(LaunchAtLogin.isAvailable(.requiresApproval) == true)
    }
}
