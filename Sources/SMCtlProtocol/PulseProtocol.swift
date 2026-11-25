import Foundation
import PolicyEngine

/// Pulse additions to the daemon's XPC surface. Inherits every smctl method, so
/// one interface serves the `pulse` CLI and the menu bar app.
@objc(PulseDaemonXPCProtocol)
public protocol PulseDaemonXPCProtocol: SMCtlDaemonXPCProtocol {
    /// Cached snapshot from the daemon's last 1 Hz tick: no extra SMC I/O.
    func getTelemetry(withReply reply: @escaping (Data?, String?) -> Void)
    func listFanCurves(withReply reply: @escaping (Data?, String?) -> Void)
    func upsertFanCurve(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void)
    func deleteFanCurve(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void)
}

public struct TemperatureDTO: Codable, Equatable, Sendable {
    public var key: String
    public var group: String
    public var celsius: Double

    public init(key: String, group: String, celsius: Double) {
        self.key = key
        self.group = group
        self.celsius = celsius
    }
}

public struct PowerReadingDTO: Codable, Equatable, Sendable {
    public var key: String
    public var name: String
    public var value: Double
    public var unit: String?

    public init(key: String, name: String, value: Double, unit: String?) {
        self.key = key
        self.name = name
        self.value = value
        self.unit = unit
    }
}

/// What the active curve computed for one fan on the last tick.
public struct FanCurveStateDTO: Codable, Equatable, Sendable {
    public var index: Int
    public var aggregatedCelsius: Double
    public var effectiveCelsius: Double
    public var targetRPM: Double

    public init(index: Int, aggregatedCelsius: Double, effectiveCelsius: Double, targetRPM: Double) {
        self.index = index
        self.aggregatedCelsius = aggregatedCelsius
        self.effectiveCelsius = effectiveCelsius
        self.targetRPM = targetRPM
    }
}

public struct SafetyStateDTO: Codable, Equatable, Sendable {
    public var latched: Bool
    public var ceilingCelsius: Double
    public var lastTripReason: String?

    public init(latched: Bool, ceilingCelsius: Double, lastTripReason: String?) {
        self.latched = latched
        self.ceilingCelsius = ceilingCelsius
        self.lastTripReason = lastTripReason
    }
}

public struct TelemetryDTO: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var daemonVersion: String
    public var profile: String
    public var temperatures: [TemperatureDTO]
    public var fans: [FanStatusDTO]
    public var curve: [FanCurveStateDTO]
    public var power: [PowerReadingDTO]
    public var safety: SafetyStateDTO
    public var lastError: String?

    public init(
        timestamp: Date,
        daemonVersion: String,
        profile: String,
        temperatures: [TemperatureDTO],
        fans: [FanStatusDTO],
        curve: [FanCurveStateDTO],
        power: [PowerReadingDTO],
        safety: SafetyStateDTO,
        lastError: String?
    ) {
        self.timestamp = timestamp
        self.daemonVersion = daemonVersion
        self.profile = profile
        self.temperatures = temperatures
        self.fans = fans
        self.curve = curve
        self.power = power
        self.safety = safety
        self.lastError = lastError
    }
}

public struct FanCurveEntryDTO: Codable, Equatable, Sendable {
    /// Built-in presets are read-only; duplicate them under a new name to customize.
    public var builtin: Bool
    public var spec: FanCurveSpec

    public init(builtin: Bool, spec: FanCurveSpec) {
        self.builtin = builtin
        self.spec = spec
    }
}

public struct FanCurveListDTO: Codable, Equatable, Sendable {
    public var activeProfile: String
    public var curves: [FanCurveEntryDTO]
    /// Curves present in the config file that failed validation, with the reason.
    public var invalid: [String: String]

    public init(activeProfile: String, curves: [FanCurveEntryDTO], invalid: [String: String]) {
        self.activeProfile = activeProfile
        self.curves = curves
        self.invalid = invalid
    }
}

public struct UpsertFanCurveRequestDTO: Codable, Equatable, Sendable {
    public var spec: FanCurveSpec
    /// Also make it the active profile.
    public var activate: Bool

    public init(spec: FanCurveSpec, activate: Bool = false) {
        self.spec = spec
        self.activate = activate
    }
}

public struct DeleteFanCurveRequestDTO: Codable, Equatable, Sendable {
    public var name: String

    public init(name: String) {
        self.name = name
    }
}
