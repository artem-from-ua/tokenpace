import Testing
@testable import TokenPaceKit

@Suite("LastUpdateFailure")
struct LastUpdateFailureTests {

    // MARK: Stage.displayName

    @Test("Each stage has a human-readable activity name")
    func stageDisplayNames() {
        #expect(LastUpdateFailure.Stage.download.displayName == "downloading")
        #expect(LastUpdateFailure.Stage.unzip.displayName == "unzipping")
        #expect(LastUpdateFailure.Stage.verify.displayName == "verification")
        #expect(LastUpdateFailure.Stage.replace.displayName == "installing")
    }

    @Test("Stage raw values round-trip through PersistedConfig strings")
    func stageRawValueRoundTrip() {
        for stage in LastUpdateFailure.Stage.allCases {
            #expect(LastUpdateFailure.Stage(rawValue: stage.rawValue) == stage)
        }
    }

    // MARK: shouldClear

    @Test("Same version as the newest known release is kept")
    func keepWhenStillNewest() {
        #expect(LastUpdateFailure.shouldClear(failedTag: "v0.54.0", latestKnownTag: "v0.54.0") == false)
    }

    @Test("A v-prefixed and a bare tag for the same version are treated as the same release")
    func keepAcrossPrefixDifference() {
        #expect(LastUpdateFailure.shouldClear(failedTag: "v0.54.0", latestKnownTag: "0.54.0") == false)
        #expect(LastUpdateFailure.shouldClear(failedTag: "0.54.0", latestKnownTag: "v0.54.0") == false)
    }

    @Test("A newer known release makes the stored failure stale")
    func clearWhenSuperseded() {
        #expect(LastUpdateFailure.shouldClear(failedTag: "v0.54.0", latestKnownTag: "v0.55.0"))
    }

    @Test("No newer release known (nil) clears the failure — the build has caught up")
    func clearWhenNothingNewer() {
        #expect(LastUpdateFailure.shouldClear(failedTag: "v0.54.0", latestKnownTag: nil))
    }

    @Test("An unparsable pair only stays if the strings are identical")
    func unparsablePairFallsBackToStringEquality() {
        #expect(LastUpdateFailure.shouldClear(failedTag: "weird", latestKnownTag: "weird") == false)
        #expect(LastUpdateFailure.shouldClear(failedTag: "weird", latestKnownTag: "other"))
    }
}
