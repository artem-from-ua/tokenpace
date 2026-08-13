import Foundation
import Testing

@testable import TokenPaceKit

// MARK: - claudeApiLocked

@Suite("ProviderMonitoring.claudeApiLocked")
struct ProviderMonitoringLockTests {

    private func monitoring(usage: Bool, code: Bool, web: Bool) -> ProviderMonitoring {
        ProviderMonitoring(
            usageApiEnabled: usage,
            services: MonitoredServices(claudeCodeEnabled: code, webDesktopEnabled: web))
    }

    @Test func anythingOnLocksTheApi() {
        // Every combination with at least one thing enabled locks Claude API on (#341) — the flag is
        // an OR over the rest, so no enumeration of "which one" is needed.
        for usage in [true, false] {
            for code in [true, false] {
                for web in [true, false] {
                    let m = monitoring(usage: usage, code: code, web: web)
                    #expect(m.claudeApiLocked == (usage || code || web))
                    #expect(m.isMonitoringAnything == m.claudeApiLocked)
                }
            }
        }
    }

    @Test func everythingOffIsTheOnlyUnlockedState() {
        #expect(!monitoring(usage: false, code: false, web: false).claudeApiLocked)
    }

    @Test func defaultMonitorsEverything() {
        // The default is unchanged behaviour: usage poll on, both services on (#341 keeps existing
        // users where they were).
        #expect(ProviderMonitoring.default.usageApiEnabled)
        #expect(ProviderMonitoring.default.services == .default)
        #expect(ProviderMonitoring.default.claudeApiLocked)
    }
}

// MARK: - Codable

@Suite("ProviderMonitoring decoding")
struct ProviderMonitoringCodableTests {

    @Test func roundTripsThroughJSON() throws {
        let original = ProviderMonitoring(
            usageApiEnabled: false,
            services: MonitoredServices(
                claudeCodeEnabled: false, webDesktopEnabled: true, webDesktopMode: .chatAndCowork))
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(ProviderMonitoring.self, from: data) == original)
    }

    @Test func absentKeysTakeTheirDefaults() throws {
        // A blob written by a build that predates one of the keys must still load, per the same
        // forward-compatible philosophy as `MonitoredServices.init(from:)`.
        let data = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(ProviderMonitoring.self, from: data)
        #expect(decoded == .default)
    }

    @Test func aPartialBlobKeepsWhatItCarries() throws {
        let data = Data(#"{"usageApiEnabled": false}"#.utf8)
        let decoded = try JSONDecoder().decode(ProviderMonitoring.self, from: data)
        #expect(!decoded.usageApiEnabled)
        #expect(decoded.services == .default)
    }
}
