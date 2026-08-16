import Testing
import Foundation
@testable import TokenPaceKit

// TEMPORARY probe — deleted before the PR. A stub with a frozen clock feeds every poll the *same*
// instant, so every interval is 0 s. Check the interpolator survives that: it must not treat a
// zero-length gap as a hole, and it must not let `acc` run away.

@Suite("probe: frozen clock")
struct FrozenClockProbe {

    @Test func replayTheStubUnderAFrozenClock() {
        let frozen = Date(timeIntervalSince1970: 1_768_392_000)   // the stub anchor, never advances
        var interp = WeeklyInterpolator()

        print("poll | h5 | raw |    acc |    est | source")
        for n in 0..<26 {
            let five = Double((n * 1) % 100)
            let weekly = 61.0 + Double(n / 8)          // the fixed stub: ticks every 8 polls
            interp = interp.advanced(with: UsageSnapshot(
                fiveHour: UsageWindow(utilization: five, resetsAt: ""),
                sevenDay: UsageWindow(utilization: weekly, resetsAt: "")), now: frozen)
            let v = interp.value(forRaw: weekly)
            if n % 2 == 0 || n > 20 {
                print(String(format: "%4d | %2.0f | %3.0f | %6.1f | %6.3f | %@",
                             n, five, weekly, interp.fiveHourSinceAnchor, v.effective,
                             v.source.rawValue))
            }
            #expect(!interp.isDegraded, "poll \(n): a zero-length interval must not read as a hole")
            #expect(interp.fiveHourSinceAnchor < 50,
                    "poll \(n): accumulation ran away (\(interp.fiveHourSinceAnchor))")
        }
    }
}
