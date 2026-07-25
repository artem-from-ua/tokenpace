import Foundation
import IOKit.ps

// MARK: - PowerSource

/// Reads whether the Mac is currently on AC power (#123) — the gate that defers an auto-install while
/// on battery, so a drained battery can't interrupt a download/replace. A thin, synchronous IOKit
/// read; the *decision* to defer lives in the pure ``TokenPaceKit/UpdateInstallPlan``, this only
/// supplies the fact.
///
/// A desktop Mac (no battery) reports AC power, so it always installs — the gate only ever holds back
/// a laptop running unplugged.
enum PowerSource {

    /// Whether the providing power source is AC (adapter connected). Uses `IOPSGetProvidingPowerSource`
    /// against a fresh power-sources snapshot; on any IOKit hiccup returns `true` (fail-open) so a
    /// diagnostic glitch never permanently blocks updates — the worst case is installing on battery
    /// once, which the other safeguards (verify, atomic replace) still cover.
    static var isOnACPower: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeRetainedValue() as String?
        else { return true }
        // kIOPMACPowerKey == "AC Power"; kIOPMBatteryPowerKey == "Battery Power".
        return type == kIOPMACPowerKey
    }
}
