import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - MonitoredServices defaults

@Suite("MonitoredServices defaults")
struct MonitoredServicesDefaultsTests {

    @Test func defaultEnablesBothToggleableServices() {
        let d = MonitoredServices.default
        #expect(d.claudeCodeEnabled == true)
        #expect(d.webDesktopEnabled == true)
    }

    @Test func defaultModeIsChatOnly() {
        #expect(MonitoredServices.default.webDesktopMode == .chatOnly)
    }
}

// MARK: - WebDesktopMode

@Suite("WebDesktopMode")
struct WebDesktopModeTests {

    @Test func rawValuesAreStable() {
        // These strings are persisted in UserDefaults JSON — changing them would silently break a
        // migration, so pin them.
        #expect(WebDesktopMode.chatOnly.rawValue == "chat_only")
        #expect(WebDesktopMode.chatAndCowork.rawValue == "chat_and_cowork")
    }

    @Test func allCasesCovered() {
        #expect(Set(WebDesktopMode.allCases) == [.chatOnly, .chatAndCowork])
    }

    @Test func unknownRawFallsBackToChatOnly() throws {
        // A future/corrupt mode string decodes to .chatOnly rather than throwing (forward-compat).
        let json = #""future_mode""#.data(using: .utf8)!
        let mode = try JSONDecoder().decode(WebDesktopMode.self, from: json)
        #expect(mode == .chatOnly)
    }
}

// MARK: - MonitoredServices Codable round-trip

@Suite("MonitoredServices Codable round-trip")
struct MonitoredServicesCodableTests {

    private func roundTrip(_ value: MonitoredServices) throws -> MonitoredServices {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(MonitoredServices.self, from: data)
    }

    @Test func roundTripsAllCombinations() throws {
        for code in [true, false] {
            for web in [true, false] {
                for mode in WebDesktopMode.allCases {
                    let original = MonitoredServices(
                        claudeCodeEnabled: code, webDesktopEnabled: web, webDesktopMode: mode)
                    #expect(try roundTrip(original) == original)
                }
            }
        }
    }

    @Test func decodesPartialJSONWithDefaults() throws {
        // An older blob that stored only one key → the rest take defaults, not a decode failure.
        let json = #"{"claudeCodeEnabled":false}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MonitoredServices.self, from: json)
        #expect(decoded.claudeCodeEnabled == false)
        #expect(decoded.webDesktopEnabled == MonitoredServices.default.webDesktopEnabled)
        #expect(decoded.webDesktopMode == MonitoredServices.default.webDesktopMode)
    }

    @Test func decodesEmptyObjectAsDefault() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MonitoredServices.self, from: json)
        #expect(decoded == .default)
    }

    @Test func decodesUnknownModeInBlobAsChatOnly() throws {
        let json = #"{"webDesktopEnabled":true,"webDesktopMode":"turbo"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MonitoredServices.self, from: json)
        #expect(decoded.webDesktopMode == .chatOnly)
    }
}
