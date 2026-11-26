import Foundation
import PolicyEngine
import SMCCore
import SMCtlClient
import SMCtlProtocol

/// Everything the app needs from the system. Implementations block, so the store
/// calls them off the main actor.
public protocol PulseService: Sendable {
    func telemetry() throws -> TelemetryDTO
    func curves() throws -> FanCurveListDTO
    func activate(profile: String) throws
    func upsert(_ spec: FanCurveSpec, activate: Bool) throws
    func delete(curve name: String) throws
    func conflicts() -> [FanControlConflict]
    /// The daemon's `[fan] interval` (or `battery_interval`), 1 to 5 seconds
    /// between sensor reads; nil on battery means "same as on the adapter".
    func setSamplingInterval(_ seconds: Int?, onBattery: Bool) throws
}

extension PulseService {
    public func setSamplingInterval(_ seconds: Int?, onBattery: Bool) throws {
        throw CocoaError(.featureUnsupported)
    }
}

/// Talks to `pulsed` over XPC. The client is recreated after a failure: an
/// NSXPCConnection to a service that was not registered yet stays invalid, so
/// installing the daemon while the app runs would otherwise never be noticed.
public final class DaemonPulseService: PulseService, @unchecked Sendable {
    private let lock = NSLock()
    private var client: DaemonClient?

    public init() {}

    private func withClient<T>(_ body: (DaemonClient) throws -> T) throws -> T {
        try lock.withLock {
            let current = client ?? DaemonClient()
            client = current
            do {
                return try body(current)
            } catch {
                client = nil
                throw error
            }
        }
    }

    public func telemetry() throws -> TelemetryDTO { try withClient { try $0.getTelemetry() } }
    public func curves() throws -> FanCurveListDTO { try withClient { try $0.listFanCurves() } }
    public func activate(profile: String) throws { try withClient { try $0.setFanProfile(profile) } }
    public func upsert(_ spec: FanCurveSpec, activate: Bool) throws { try withClient { try $0.upsertFanCurve(spec, activate: activate) } }
    public func delete(curve name: String) throws { try withClient { try $0.deleteFanCurve(named: name) } }
    public func conflicts() -> [FanControlConflict] { FanControlConflicts.detect() }
    public func setSamplingInterval(_ seconds: Int?, onBattery: Bool) throws {
        try withClient { try $0.setSamplingInterval(seconds: seconds, onBattery: onBattery) }
    }
}

/// Read-only fallback when the daemon is not installed: reads the SMC directly,
/// which needs no privileges.
public final class DirectSensorService: @unchecked Sendable {
    private let lock = NSLock()
    private var reader: SensorReader?

    public init() {}

    public func telemetry() throws -> TelemetryDTO {
        try lock.withLock {
            if reader == nil {
                reader = SensorReader(backend: try SMCConnection())
            }
            guard let snapshot = reader?.snapshot() else {
                throw CocoaError(.featureUnsupported)
            }
            return TelemetryDTO(
                timestamp: snapshot.timestamp,
                daemonVersion: "",
                profile: "auto",
                temperatures: snapshot.temperatures.compactMap {
                    $0.celsius.isFinite ? TemperatureDTO(key: $0.key, group: $0.group, celsius: $0.celsius) : nil
                },
                fans: snapshot.fans.map {
                    FanStatusDTO(index: $0.index, actualRPM: $0.actualRPM, targetRPM: $0.targetRPM,
                                 minimumRPM: $0.minimumRPM, maximumRPM: $0.maximumRPM, mode: $0.mode ?? "unknown")
                },
                curve: [],
                power: snapshot.power.compactMap { reading in
                    reading.value.map { PowerReadingDTO(key: reading.key, name: reading.name, value: $0, unit: reading.unit) }
                },
                safety: SafetyStateDTO(latched: false, ceilingCelsius: FanSafetyGuard.defaultCeilingCelsius, lastTripReason: nil),
                lastError: nil
            )
        }
    }
}
