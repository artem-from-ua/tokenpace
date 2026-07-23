import Testing
import Foundation
@testable import TokenPaceKit

@Suite("SemanticVersion parsing")
struct SemanticVersionParsingTests {

    @Test func parsesPlainTriple() {
        let v = SemanticVersion("1.2.3")
        #expect(v == SemanticVersion(major: 1, minor: 2, patch: 3))
    }

    @Test func stripsLowercaseVPrefix() {
        #expect(SemanticVersion("v0.20.0") == SemanticVersion(major: 0, minor: 20, patch: 0))
    }

    @Test func stripsUppercaseVPrefix() {
        #expect(SemanticVersion("V1.0.0") == SemanticVersion(major: 1, minor: 0, patch: 0))
    }

    @Test func toleratesSurroundingWhitespace() {
        #expect(SemanticVersion("  1.2.3  ") == SemanticVersion(major: 1, minor: 2, patch: 3))
    }

    @Test func toleratesPreReleaseSuffix() {
        // The numeric core parses; the `-beta.1` suffix is dropped (documented simplification).
        #expect(SemanticVersion("1.2.3-beta.1") == SemanticVersion(major: 1, minor: 2, patch: 3))
    }

    @Test func toleratesBuildMetadataSuffix() {
        #expect(SemanticVersion("1.2.3+build.7") == SemanticVersion(major: 1, minor: 2, patch: 3))
    }

    @Test func rejectsEmpty() {
        #expect(SemanticVersion("") == nil)
    }

    @Test func rejectsTwoComponents() {
        #expect(SemanticVersion("1.2") == nil)
    }

    @Test func rejectsFourComponents() {
        #expect(SemanticVersion("1.2.3.4") == nil)
    }

    @Test func rejectsNonNumeric() {
        #expect(SemanticVersion("x.y.z") == nil)
        #expect(SemanticVersion("vabc") == nil)
    }

    @Test func rejectsNegativeComponent() {
        #expect(SemanticVersion("1.-2.3") == nil)
    }

    @Test func rejectsEmptyComponent() {
        #expect(SemanticVersion("1..3") == nil)
    }
}

@Suite("SemanticVersion ordering")
struct SemanticVersionOrderingTests {

    @Test func patchPrecedence() {
        #expect(SemanticVersion("1.2.4")! > SemanticVersion("1.2.3")!)
    }

    @Test func minorBeatsPatch() {
        // 1.10.0 > 1.9.9 — minor is compared numerically, not lexically.
        #expect(SemanticVersion("1.10.0")! > SemanticVersion("1.9.9")!)
    }

    @Test func majorBeatsEverything() {
        #expect(SemanticVersion("2.0.0")! > SemanticVersion("1.99.99")!)
    }

    @Test func equalVersionsAreNotLess() {
        #expect(!(SemanticVersion("1.2.3")! < SemanticVersion("1.2.3")!))
        #expect(SemanticVersion("1.2.3")! == SemanticVersion("1.2.3")!)
    }
}

@Suite("UpdateComparison.isNewer")
struct UpdateComparisonTests {

    @Test func newerTagIsNewer() {
        #expect(UpdateComparison.isNewer(tag: "v0.20.0", than: "0.18.0"))
    }

    @Test func equalIsNotNewer() {
        #expect(!UpdateComparison.isNewer(tag: "v0.18.0", than: "0.18.0"))
    }

    @Test func olderIsNotNewer() {
        #expect(!UpdateComparison.isNewer(tag: "v0.17.0", than: "0.18.0"))
    }

    @Test func vPrefixOnEitherSide() {
        #expect(UpdateComparison.isNewer(tag: "0.20.0", than: "v0.18.0"))
        #expect(UpdateComparison.isNewer(tag: "v0.20.0", than: "v0.18.0"))
    }

    @Test func malformedTagIsNotNewer() {
        // A garbage tag from the API must never surface a phantom update.
        #expect(!UpdateComparison.isNewer(tag: "not-a-version", than: "0.18.0"))
    }

    @Test func malformedCurrentIsNotNewer() {
        #expect(!UpdateComparison.isNewer(tag: "v0.20.0", than: "garbage"))
    }
}
