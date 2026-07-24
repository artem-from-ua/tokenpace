import Testing
import Foundation
@testable import TokenPaceKit

@Suite("ByteSize.humanReadable")
struct ByteSizeTests {

    @Test func zeroAndNegative() {
        #expect(ByteSize.humanReadable(0) == "0 B")
        #expect(ByteSize.humanReadable(-100) == "0 B")
    }

    @Test func bytesBelowAKilobyte() {
        #expect(ByteSize.humanReadable(1) == "1 B")
        #expect(ByteSize.humanReadable(512) == "512 B")
        #expect(ByteSize.humanReadable(1023) == "1023 B")
    }

    @Test func noDecimals() {
        // 1.5 KiB rounds to a whole number, never "1.5 KB".
        #expect(ByteSize.humanReadable(1536) == "2 KB")
        #expect(ByteSize.humanReadable(1024) == "1 KB")
    }

    @Test func megabytesAndGigabytes() {
        #expect(ByteSize.humanReadable(5 * 1024 * 1024) == "5 MB")
        #expect(ByteSize.humanReadable(1024 * 1024 * 1024) == "1 GB")
        // ~166 MB, the real archive's first-sync size ballpark.
        #expect(ByteSize.humanReadable(166_236_374) == "159 MB")
    }

    @Test func carryOnRoundingToNextUnit() {
        // Just under 1 MiB but rounds up past 1024 KB → carries to "1 MB", not "1024 KB".
        #expect(ByteSize.humanReadable(1024 * 1024 - 1) == "1 MB")
    }

    @Test func terabytes() {
        #expect(ByteSize.humanReadable(2 * 1024 * 1024 * 1024 * 1024) == "2 TB")
    }
}
