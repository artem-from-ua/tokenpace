import Testing
@testable import CCTimerKit

@Suite("CCTimerKit")
struct CCTimerKitTests {
    @Test func versionIsNonEmpty() {
        #expect(!CCTimerKit.version.isEmpty)
    }
}
