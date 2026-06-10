import Foundation
import IOKit.ps

/// Time-remaining estimates from IOKit power sources. These come from the OS
/// gauge (not the SMC), so they live here as presentation data for battery
/// status rather than in SMCCore.
enum PowerSourceTimeEstimate {
    /// Minutes to empty (discharging) and to full (charging) for the internal
    /// battery. IOKit reports -1 while still calculating; that and missing
    /// keys both map to nil.
    static func read() -> (toEmpty: Int?, toFull: Int?) {
        guard
            let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return (nil, nil)
        }

        for source in list {
            guard
                let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else {
                continue
            }
            let toEmpty = (description[kIOPSTimeToEmptyKey] as? Int).flatMap { $0 > 0 ? $0 : nil }
            let toFull = (description[kIOPSTimeToFullChargeKey] as? Int).flatMap { $0 > 0 ? $0 : nil }
            return (toEmpty, toFull)
        }
        return (nil, nil)
    }
}
