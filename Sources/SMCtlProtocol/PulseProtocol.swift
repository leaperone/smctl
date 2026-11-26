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
    /// `[fan] interval`, 1 to 5 seconds between sensor reads.
    func setSamplingInterval(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void)
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
    /// What the fan is asked to do: the curve's target, or macOS's own target
    /// while `handedToSystem`.
    public var targetRPM: Double
    /// The curve is at 0% and macOS runs this fan (it may stop it, or spin it
    /// faster than the curve's floor). False from daemons that predate it.
    public var handedToSystem: Bool
    /// The curve is at 0% with `idle = "off"`: Pulse holds this fan stopped.
    public var stopped: Bool

    public init(index: Int, aggregatedCelsius: Double, effectiveCelsius: Double, targetRPM: Double,
                handedToSystem: Bool = false, stopped: Bool = false) {
        self.index = index
        self.aggregatedCelsius = aggregatedCelsius
        self.effectiveCelsius = effectiveCelsius
        self.targetRPM = targetRPM
        self.handedToSystem = handedToSystem
        self.stopped = stopped
    }

    private enum CodingKeys: String, CodingKey {
        case index, aggregatedCelsius, effectiveCelsius, targetRPM, handedToSystem, stopped
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        aggregatedCelsius = try container.decode(Double.self, forKey: .aggregatedCelsius)
        effectiveCelsius = try container.decode(Double.self, forKey: .effectiveCelsius)
        targetRPM = try container.decode(Double.self, forKey: .targetRPM)
        handedToSystem = try container.decodeIfPresent(Bool.self, forKey: .handedToSystem) ?? false
        stopped = try container.decodeIfPresent(Bool.self, forKey: .stopped) ?? false
    }
}

public struct SafetyStateDTO: Codable, Equatable, Sendable {
    public var latched: Bool
    public var ceilingCelsius: Double
    public var lastTripReason: String?
    /// `[safety] allow_below_minimum` is set, so curves with `idle = "off"` may
    /// stop fans. False from daemons that predate it.
    public var allowsStoppingFans: Bool

    public init(latched: Bool, ceilingCelsius: Double, lastTripReason: String?, allowsStoppingFans: Bool = false) {
        self.latched = latched
        self.ceilingCelsius = ceilingCelsius
        self.lastTripReason = lastTripReason
        self.allowsStoppingFans = allowsStoppingFans
    }

    private enum CodingKeys: String, CodingKey {
        case latched, ceilingCelsius, lastTripReason, allowsStoppingFans
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        latched = try container.decode(Bool.self, forKey: .latched)
        ceilingCelsius = try container.decode(Double.self, forKey: .ceilingCelsius)
        lastTripReason = try container.decodeIfPresent(String.self, forKey: .lastTripReason)
        allowsStoppingFans = try container.decodeIfPresent(Bool.self, forKey: .allowsStoppingFans) ?? false
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
    /// Seconds between the daemon's sensor reads on the power adapter (and on
    /// desktop Macs); nil from daemons that predate it.
    public var samplingInterval: Int?
    /// Seconds between reads on battery; nil means the same as `samplingInterval`.
    public var batterySamplingInterval: Int?
    /// The daemon's view of the power source; nil when unknown.
    public var onBattery: Bool?

    /// The interval in effect right now.
    public var currentSamplingInterval: Int? {
        (onBattery == true ? batterySamplingInterval : nil) ?? samplingInterval
    }

    public init(
        timestamp: Date,
        daemonVersion: String,
        profile: String,
        temperatures: [TemperatureDTO],
        fans: [FanStatusDTO],
        curve: [FanCurveStateDTO],
        power: [PowerReadingDTO],
        safety: SafetyStateDTO,
        lastError: String?,
        samplingInterval: Int? = nil,
        batterySamplingInterval: Int? = nil,
        onBattery: Bool? = nil
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
        self.samplingInterval = samplingInterval
        self.batterySamplingInterval = batterySamplingInterval
        self.onBattery = onBattery
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

public struct SetSamplingIntervalRequestDTO: Codable, Equatable, Sendable {
    /// nil with `onBattery` clears the battery interval (same as the adapter).
    public var seconds: Int?
    /// Sets `[fan] battery_interval` instead of `interval`.
    public var onBattery: Bool

    public init(seconds: Int?, onBattery: Bool = false) {
        self.seconds = seconds
        self.onBattery = onBattery
    }
}
