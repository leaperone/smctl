import Foundation
import IOKit.ps
import OSLog
import ProductIdentity
import PolicyEngine
import SMCCore
import SMCtlProtocol

private let samplingLogger = Logger(subsystem: ProductIdentity.logSubsystem, category: "daemon")

/// Pulse: configurable sampling interval. The 1 Hz timer stays (it is cheap
/// without SMC reads); a full tick, which reads ~50 SMC keys, runs only every
/// `[fan] interval` seconds, or every second near the safety ceiling.
extension SmctlDaemon {
    static let samplingIntervalRange = 1...5
    static let defaultSamplingInterval = 2
    /// Within this many degrees of a sensor's ceiling, ticks run every second so
    /// the guard trips as fast as with a 1 s interval (it needs two readings).
    static let fastSamplingMarginCelsius = 20.0
    /// Timer jitter tolerance when deciding whether a tick is due.
    static let samplingTolerance: TimeInterval = 0.25

    static func clampedSamplingInterval(_ seconds: Int) -> Int {
        min(max(seconds, samplingIntervalRange.lowerBound), samplingIntervalRange.upperBound)
    }

    /// The interval the next tick uses: the configured one, or 1 s while the
    /// guard is latched or a sensor is near its ceiling.
    func effectiveSamplingIntervalLocked() -> TimeInterval {
        if safetyGuard.isLatched || nearSafetyCeilingLocked() { return 1 }
        return TimeInterval(configuredSamplingIntervalLocked())
    }

    /// `battery_interval` on battery when set, `interval` otherwise.
    func configuredSamplingIntervalLocked() -> Int {
        (onBattery == true ? config.fan.battery_interval : nil) ?? config.fan.interval
    }

    /// Tracks the power source (adapter or battery) through an IOKit
    /// notification on the main run loop: no polling.
    func observePowerSource() {
        let update: () -> Void = { [weak self] in
            guard let queue = self?.queue else { return }
            let value = Self.readOnBattery()
            queue.async { [weak self] in self?.onBattery = value }
        }
        update()
        let box = Unmanaged.passRetained(PowerSourceCallback(update)).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerSourceCallback>.fromOpaque(context).takeUnretainedValue().handler()
        }, box)?.takeRetainedValue() else {
            Unmanaged<PowerSourceCallback>.fromOpaque(box).release()
            return
        }
        // The run loop retains the source for the daemon's lifetime.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    /// true on battery, false on the adapter, nil when unknown (desktop Macs
    /// report the adapter).
    static func readOnBattery() -> Bool? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return nil }
        return type == kIOPSBatteryPowerValue
    }

    func nearSafetyCeilingLocked() -> Bool {
        guard let temperatures = lastSnapshot?.temperatures else { return false }
        return temperatures.contains { reading in
            let sample = FanTemperatureSample(sensor: reading.key, celsius: reading.celsius)
            return reading.celsius.isFinite
                && reading.celsius >= safetyGuard.effectiveCeiling(for: sample) - Self.fastSamplingMarginCelsius
        }
    }

    /// Called by the 1 Hz timer. Battery discharge tracking keeps its 1 s cadence.
    func samplingTickLocked(now: Date = Date()) {
        if let last = lastSampledTick,
           now.timeIntervalSince(last) < effectiveSamplingIntervalLocked() - Self.samplingTolerance {
            evaluateForegroundDischargeLocked()
            return
        }
        lastSampledTick = now
        tickFanAndAlertsLocked()
    }

    /// The last snapshot, re-read when stale. While ticks sample, a snapshot up
    /// to one interval old is current; otherwise (macOS drives the fans) reads
    /// happen only on request, at most about once per second.
    func freshSnapshotLocked(now: Date = Date()) -> SensorSnapshot? {
        let maxAge = tickNeedsSamplesLocked() ? effectiveSamplingIntervalLocked() + 0.5 : 0.9
        if let snapshot = lastSnapshot, now.timeIntervalSince(snapshot.timestamp) < maxAge {
            return snapshot
        }
        guard let reader else { return lastSnapshot }
        let snapshot = reader.snapshot(includingBatteryAndPower: false)
        lastSnapshot = snapshot
        return snapshot
    }

    /// Power readings for telemetry, read on request rather than every tick.
    func powerReadingsLocked() -> [NamedReading] {
        reader?.powerReadings() ?? []
    }

    /// Sets the interval on the adapter (`onBattery: false`) or on battery;
    /// `nil` on battery means "same as on the adapter".
    func setSamplingInterval(_ seconds: Int?, onBattery: Bool = false) throws {
        if let seconds, !Self.samplingIntervalRange.contains(seconds) {
            throw DaemonError.unsupported("The sampling interval must be between \(Self.samplingIntervalRange.lowerBound) and \(Self.samplingIntervalRange.upperBound) seconds.")
        }
        guard seconds != nil || onBattery else {
            throw DaemonError.unsupported("The sampling interval on the power adapter cannot be cleared.")
        }
        try queue.sync {
            if onBattery {
                guard config.fan.battery_interval != seconds else { return }
                config.fan.battery_interval = seconds
            } else {
                guard let seconds, config.fan.interval != seconds else { return }
                config.fan.interval = seconds
            }
            try Self.writeConfig(config, path: configPath)
            samplingLogger.notice("Sampling interval \(onBattery ? "on battery" : "on adapter", privacy: .public) set to \(seconds.map { "\($0) s" } ?? "same as adapter", privacy: .public)")
        }
    }
}

private final class PowerSourceCallback {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
}

extension XPCService {
    @objc func setSamplingInterval(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        doWrite(reply) {
            let request = try SMCtlProtocolCoding.decode(SetSamplingIntervalRequestDTO.self, from: requestData)
            try daemon.setSamplingInterval(request.seconds, onBattery: request.onBattery)
        }
    }
}
