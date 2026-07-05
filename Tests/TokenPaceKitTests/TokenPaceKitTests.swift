import Testing
@testable import TokenPaceKit

@Suite("TokenPaceKit")
struct TokenPaceKitTests {
    @Test func versionIsNonEmpty() {
        #expect(!TokenPaceKit.version.isEmpty)
    }
}

@Suite("AppLogger")
struct AppLoggerTests {
    @Test func subsystemMatchesBundleIdentifier() {
        // Regression guard: subsystem must stay in sync with CFBundleIdentifier
        // in scripts/Info.plist.in — otherwise `log stream` predicates break.
        #expect(AppLogger.subsystem == "com.artem-n.tokenpace")
    }

    @Test func categoriesAreInstantiable() {
        // Loggers are lazily created; touching them must not crash.
        _ = AppLogger.network
        _ = AppLogger.keychain
        _ = AppLogger.lifecycle
    }
}
