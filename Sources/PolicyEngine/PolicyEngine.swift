import Foundation

public enum PolicyEngine {
    public static let version = "0.1.6"
}

public protocol PolicyClock: Sendable {
    var now: Date { get }
}

public struct SystemPolicyClock: PolicyClock {
    public init() {}

    public var now: Date {
        Date()
    }
}

public enum BatteryPolicyAction: Codable, Equatable, Sendable {
    case setChargingEnabled(Bool)
    case setAdapterEnabled(Bool)
    case reevaluate
}

public protocol BatteryPolicyBackend {
    func setChargingEnabled(_ enabled: Bool) throws
    func setAdapterEnabled(_ enabled: Bool) throws
}

public struct ChargeLimit: Codable, Equatable, Sendable {
    public var upperBound: Int
    public var lowerDelta: Int

    public init(upperBound: Int, lowerDelta: Int = 2) {
        self.upperBound = min(100, max(0, upperBound))
        self.lowerDelta = max(0, lowerDelta)
    }

    public var isLimiting: Bool {
        upperBound < 100
    }

    public var lowerBound: Int {
        max(0, upperBound - lowerDelta)
    }

    public static let disabled = ChargeLimit(upperBound: 100, lowerDelta: 0)

    public static func parse(_ value: String, defaultDelta: Int = 2) throws -> ChargeLimit {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "stop" || trimmed == "off" || trimmed == "disabled" || trimmed == "100" {
            return .disabled
        }

        let parts = trimmed.split(separator: "-", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            guard let lower = Int(parts[0]), let upper = Int(parts[1]), lower >= 0, upper <= 100, lower <= upper else {
                throw PolicyError.invalidChargeLimit(value)
            }
            return ChargeLimit(upperBound: upper, lowerDelta: upper - lower)
        }

        guard let upper = Int(trimmed), upper >= 0, upper <= 100 else {
            throw PolicyError.invalidChargeLimit(value)
        }
        return ChargeLimit(upperBound: upper, lowerDelta: defaultDelta)
    }

    public var configString: String {
        if !isLimiting {
            return "100"
        }
        if lowerDelta == 2 {
            return "\(upperBound)"
        }
        return "\(lowerBound)-\(upperBound)"
    }
}

public enum PolicyError: Error, Equatable, CustomStringConvertible {
    case invalidChargeLimit(String)
    case invalidSleepPolicy(String)
    case invalidFanCurve(String)

    public var description: String {
        switch self {
        case .invalidChargeLimit(let value):
            return "Invalid charge limit '\(value)'"
        case .invalidSleepPolicy(let value):
            return "Invalid sleep policy '\(value)'"
        case .invalidFanCurve(let value):
            return "Invalid fan curve '\(value)'"
        }
    }
}

public struct BatteryObservation: Codable, Equatable, Sendable {
    public var chargePercent: Int
    /// Whether the SMC currently allows charging (CHTE / CH0B status), not whether current flows.
    public var isChargingAllowed: Bool
    /// Whether wall power is present (AC-W).
    public var isPluggedIn: Bool

    public init(chargePercent: Int, isChargingAllowed: Bool, isPluggedIn: Bool = true) {
        self.chargePercent = min(100, max(0, chargePercent))
        self.isChargingAllowed = isChargingAllowed
        self.isPluggedIn = isPluggedIn
    }

    /// Best available approximation of "actively charging": power present and charging allowed.
    public var isCharging: Bool {
        isPluggedIn && isChargingAllowed
    }
}

public struct ChargeEvaluation: Equatable, Sendable {
    public var actions: [BatteryPolicyAction]
    public var sleptSinceLastEvaluation: Bool
    public var lowerBound: Int
    public var upperBound: Int

    public init(
        actions: [BatteryPolicyAction],
        sleptSinceLastEvaluation: Bool,
        lowerBound: Int,
        upperBound: Int
    ) {
        self.actions = actions
        self.sleptSinceLastEvaluation = sleptSinceLastEvaluation
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }
}

public struct ChargeStateMachine: Sendable {
    public var period: TimeInterval
    public var missedBeatMultiplier: Double
    public private(set) var lastEvaluation: Date?

    public init(period: TimeInterval = 10, missedBeatMultiplier: Double = 3, lastEvaluation: Date? = nil) {
        self.period = period
        self.missedBeatMultiplier = missedBeatMultiplier
        self.lastEvaluation = lastEvaluation
    }

    public mutating func evaluate(
        limit: ChargeLimit,
        observation: BatteryObservation,
        now: Date
    ) -> ChargeEvaluation {
        let slept = lastEvaluation.map { now.timeIntervalSince($0) > period * missedBeatMultiplier } ?? false
        lastEvaluation = now

        var effectiveObservation = observation
        var actions: [BatteryPolicyAction] = []
        // Missed-beat guard: we may have charged past the limit while asleep. Only write
        // the conservative disable when power is actually present — an unplugged Mac
        // cannot have overshot, and the write would needlessly flip the allowed state.
        if slept, effectiveObservation.isCharging {
            actions.append(.setChargingEnabled(false))
            effectiveObservation.isChargingAllowed = false
        }

        if !limit.isLimiting {
            if !effectiveObservation.isChargingAllowed {
                actions.append(.setChargingEnabled(true))
            }
            return ChargeEvaluation(
                actions: actions,
                sleptSinceLastEvaluation: slept,
                lowerBound: limit.lowerBound,
                upperBound: limit.upperBound
            )
        }

        // Dead-band transitions act on the allowed state regardless of plug presence:
        // restoring/blocking the allowed state while unplugged is harmless and makes the
        // policy already correct the moment power returns.
        if effectiveObservation.chargePercent < limit.lowerBound, !effectiveObservation.isChargingAllowed {
            actions.append(.setChargingEnabled(true))
        } else if effectiveObservation.chargePercent >= limit.upperBound, effectiveObservation.isChargingAllowed {
            actions.append(.setChargingEnabled(false))
        }

        return ChargeEvaluation(
            actions: actions,
            sleptSinceLastEvaluation: slept,
            lowerBound: limit.lowerBound,
            upperBound: limit.upperBound
        )
    }

    public mutating func evaluate<C: PolicyClock>(
        limit: ChargeLimit,
        observation: BatteryObservation,
        clock: C
    ) -> ChargeEvaluation {
        evaluate(limit: limit, observation: observation, now: clock.now)
    }
}

public enum SleepPolicy: String, Codable, Equatable, Sendable {
    case strict
    case relaxed

    public static func parse(_ value: String) throws -> SleepPolicy {
        guard let policy = SleepPolicy(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            throw PolicyError.invalidSleepPolicy(value)
        }
        return policy
    }
}

public enum SleepEvent: String, Codable, Equatable, Sendable {
    case canSystemSleep
    case systemWillSleep
    case systemWillPowerOn
    case systemHasPoweredOn
}

public struct SleepContext: Codable, Equatable, Sendable {
    public var limit: ChargeLimit
    public var observation: BatteryObservation

    public init(limit: ChargeLimit, observation: BatteryObservation) {
        self.limit = limit
        self.observation = observation
    }
}

public struct SleepEvaluation: Equatable, Sendable {
    public var actions: [BatteryPolicyAction]
    public var allowsPowerChange: Bool
    public var vetoesIdleSleep: Bool
    public var forcesReevaluation: Bool

    public init(
        actions: [BatteryPolicyAction],
        allowsPowerChange: Bool = true,
        vetoesIdleSleep: Bool = false,
        forcesReevaluation: Bool = false
    ) {
        self.actions = actions
        self.allowsPowerChange = allowsPowerChange
        self.vetoesIdleSleep = vetoesIdleSleep
        self.forcesReevaluation = forcesReevaluation
    }
}

public struct SleepStateMachine: Sendable {
    public var policy: SleepPolicy

    public init(policy: SleepPolicy = .strict) {
        self.policy = policy
    }

    public mutating func setPolicy(_ policy: SleepPolicy) {
        self.policy = policy
    }

    public func handle(event: SleepEvent, context: SleepContext) -> SleepEvaluation {
        switch event {
        case .systemWillSleep:
            // Pre-sleep disable applies only while a limit is active. Writing it
            // unconditionally would leave charging disabled forever if the daemon
            // disappears during sleep — a "bricked" default state (design §6.2/§9).
            let actions: [BatteryPolicyAction] = context.limit.isLimiting
                ? [.setChargingEnabled(false)]
                : []
            return SleepEvaluation(actions: actions, allowsPowerChange: true)
        case .canSystemSleep:
            let distanceToLimit = context.limit.upperBound - context.observation.chargePercent
            let shouldVeto = policy == .strict
                && context.limit.isLimiting
                && context.observation.isCharging
                && distanceToLimit > 3
            return SleepEvaluation(actions: [], allowsPowerChange: !shouldVeto, vetoesIdleSleep: shouldVeto)
        case .systemWillPowerOn:
            return SleepEvaluation(actions: [], allowsPowerChange: true)
        case .systemHasPoweredOn:
            return SleepEvaluation(actions: [.reevaluate], allowsPowerChange: true, forcesReevaluation: true)
        }
    }
}

public struct FanCurvePoint: Codable, Equatable, Sendable {
    public var temperatureCelsius: Double
    public var rpm: Double

    public init(_ temperatureCelsius: Double, _ rpm: Double) {
        self.temperatureCelsius = temperatureCelsius
        self.rpm = rpm
    }
}

public struct FanTemperatureSample: Codable, Equatable, Sendable {
    public var sensor: String
    public var celsius: Double

    public init(sensor: String, celsius: Double) {
        self.sensor = sensor
        self.celsius = celsius
    }
}

public struct FanCurve: Codable, Equatable, Sendable {
    public var name: String
    public var sensors: [String]
    public var sensorWeights: [String: Double]
    public var points: [FanCurvePoint]
    public var hysteresisCelsius: Double
    public var slewRateRPMPerSecond: Double?

    public init(
        name: String,
        sensors: [String] = [],
        sensorWeights: [String: Double] = [:],
        points: [FanCurvePoint],
        hysteresisCelsius: Double = 0,
        slewRateRPMPerSecond: Double? = nil
    ) throws {
        let sortedPoints = points.sorted { $0.temperatureCelsius < $1.temperatureCelsius }
        guard sortedPoints.count >= 2 else {
            throw PolicyError.invalidFanCurve("\(name): at least two points are required")
        }
        for pair in zip(sortedPoints, sortedPoints.dropFirst()) where pair.0.temperatureCelsius == pair.1.temperatureCelsius {
            throw PolicyError.invalidFanCurve("\(name): duplicate temperature point \(pair.0.temperatureCelsius)")
        }
        self.name = name
        self.sensors = sensors
        self.sensorWeights = sensorWeights.filter { $0.value > 0 }
        self.points = sortedPoints
        self.hysteresisCelsius = max(0, hysteresisCelsius)
        self.slewRateRPMPerSecond = slewRateRPMPerSecond.map { max(0, $0) }
    }

    public static func quiet(maxRPM: Double) -> FanCurve {
        // Calibrated for Apple Silicon junction hot-spot aggregation (max over all
        // sensors): hot-spots idle at 75–85C and reach 95–105C under load, so the
        // Intel-era 45–95C anchors would pin a "quiet" curve near full speed at idle.
        // Quiet = stay at the floor until genuinely hot, then ramp decisively.
        try! FanCurve(
            name: "quiet",
            points: [
                FanCurvePoint(85, 0),
                FanCurvePoint(93, maxRPM * 0.25),
                FanCurvePoint(100, maxRPM * 0.55),
                FanCurvePoint(105, maxRPM)
            ],
            hysteresisCelsius: 3,
            slewRateRPMPerSecond: 400
        )
    }

    public static func full(maxRPM: Double) -> FanCurve {
        try! FanCurve(
            name: "full",
            points: [
                FanCurvePoint(0, maxRPM),
                FanCurvePoint(105, maxRPM)
            ],
            hysteresisCelsius: 0,
            slewRateRPMPerSecond: nil
        )
    }
}

public struct FanCurveEvaluation: Codable, Equatable, Sendable {
    public var aggregatedTemperature: Double
    public var effectiveTemperature: Double
    public var unclampedRPM: Double
    public var targetRPM: Double

    public init(aggregatedTemperature: Double, effectiveTemperature: Double, unclampedRPM: Double, targetRPM: Double) {
        self.aggregatedTemperature = aggregatedTemperature
        self.effectiveTemperature = effectiveTemperature
        self.unclampedRPM = unclampedRPM
        self.targetRPM = targetRPM
    }
}

public struct FanCurveEngine: Sendable {
    public private(set) var lastEffectiveTemperature: Double?
    public private(set) var lastRPM: Double?
    public private(set) var lastEvaluationDate: Date?

    public init(lastEffectiveTemperature: Double? = nil, lastRPM: Double? = nil, lastEvaluationDate: Date? = nil) {
        self.lastEffectiveTemperature = lastEffectiveTemperature
        self.lastRPM = lastRPM
        self.lastEvaluationDate = lastEvaluationDate
    }

    public mutating func evaluate(
        curve: FanCurve,
        samples: [FanTemperatureSample],
        now: Date
    ) throws -> FanCurveEvaluation {
        let aggregated = try Self.aggregate(samples: samples, sensors: curve.sensors, weights: curve.sensorWeights)
        let effectiveTemperature: Double
        if
            let previous = lastEffectiveTemperature,
            abs(aggregated - previous) <= curve.hysteresisCelsius
        {
            effectiveTemperature = previous
        } else {
            effectiveTemperature = aggregated
        }

        let interpolated = Self.interpolate(points: curve.points, temperature: effectiveTemperature)
        let target = slewLimitedTarget(rawTarget: interpolated, slewRate: curve.slewRateRPMPerSecond, now: now)

        lastEffectiveTemperature = effectiveTemperature
        lastRPM = target
        lastEvaluationDate = now
        return FanCurveEvaluation(
            aggregatedTemperature: aggregated,
            effectiveTemperature: effectiveTemperature,
            unclampedRPM: interpolated,
            targetRPM: target
        )
    }

    public static func interpolate(points: [FanCurvePoint], temperature: Double) -> Double {
        let sorted = points.sorted { $0.temperatureCelsius < $1.temperatureCelsius }
        guard let first = sorted.first, let last = sorted.last else {
            return 0
        }
        if temperature <= first.temperatureCelsius {
            return first.rpm
        }
        if temperature >= last.temperatureCelsius {
            return last.rpm
        }
        for pair in zip(sorted, sorted.dropFirst()) {
            let lower = pair.0
            let upper = pair.1
            if temperature >= lower.temperatureCelsius, temperature <= upper.temperatureCelsius {
                let span = upper.temperatureCelsius - lower.temperatureCelsius
                guard span > 0 else {
                    return upper.rpm
                }
                let fraction = (temperature - lower.temperatureCelsius) / span
                return lower.rpm + (upper.rpm - lower.rpm) * fraction
            }
        }
        return last.rpm
    }

    public static func aggregate(
        samples: [FanTemperatureSample],
        sensors: [String] = [],
        weights: [String: Double] = [:]
    ) throws -> Double {
        let selected = samples.filter { sample in
            sensors.isEmpty || sensors.contains(sample.sensor)
        }
        guard !selected.isEmpty else {
            throw PolicyError.invalidFanCurve("no temperature samples match configured sensors")
        }

        let positiveWeights = weights.filter { $0.value > 0 }
        if !positiveWeights.isEmpty {
            var weightedSum = 0.0
            var totalWeight = 0.0
            for sample in selected {
                guard let weight = positiveWeights[sample.sensor] else {
                    continue
                }
                weightedSum += sample.celsius * weight
                totalWeight += weight
            }
            if totalWeight > 0 {
                return weightedSum / totalWeight
            }
        }

        return selected.map(\.celsius).max() ?? 0
    }

    private func slewLimitedTarget(rawTarget: Double, slewRate: Double?, now: Date) -> Double {
        guard
            let slewRate,
            slewRate > 0,
            let lastRPM,
            let lastEvaluationDate
        else {
            return rawTarget
        }
        let maxDelta = slewRate * max(0, now.timeIntervalSince(lastEvaluationDate))
        if rawTarget > lastRPM {
            return min(rawTarget, lastRPM + maxDelta)
        }
        return max(rawTarget, lastRPM - maxDelta)
    }
}

public struct FanSafetyDecision: Equatable, Sendable {
    public var forceAuto: Bool
    public var reason: String?

    public init(forceAuto: Bool, reason: String? = nil) {
        self.forceAuto = forceAuto
        self.reason = reason
    }
}

public struct FanSafetyGuard: Codable, Equatable, Sendable {
    /// Calibrated against field data: Apple Silicon junction hot-spot sensors (Tp0E/Tp3P
    /// class) routinely sit at 95–103C under ordinary compile load while the silicon is
    /// rated to ~110C. 95C made manual control unusable under any load; 100C still trips
    /// well before firmware-level throttling/shutdown territory.
    public static let defaultCeilingCelsius = 100.0
    public static let hardMaximumCeilingCelsius = 105.0
    /// The latch releases only after cooling this far below the ceiling, so a trip
    /// cannot be immediately re-armed into a hot system.
    public static let releaseHysteresisCelsius = 5.0
    /// Overheat must persist for this many consecutive ticks (1s cadence) to trip —
    /// debounces momentary hot-spot spikes while keeping reaction time under ~2.5s.
    /// Sensor blindness is NOT debounced: it trips immediately.
    public static let consecutiveTripsRequired = 2

    public var configuredCeilingCelsius: Double
    /// Set when the guard trips; manual fan control must be rejected while latched.
    public private(set) var isLatched: Bool
    private var consecutiveOverCeiling: Int

    public init(configuredCeilingCelsius: Double = Self.defaultCeilingCelsius, isLatched: Bool = false) {
        if configuredCeilingCelsius <= 0 {
            self.configuredCeilingCelsius = Self.defaultCeilingCelsius
        } else {
            self.configuredCeilingCelsius = min(configuredCeilingCelsius, Self.hardMaximumCeilingCelsius)
        }
        self.isLatched = isLatched
        self.consecutiveOverCeiling = 0
    }

    /// One evaluation tick. Fail-safe semantics: while a manual fan policy is active the
    /// guard is the only thermal floor (thermalmonitord is hands-off), so *no readable
    /// temperature* counts as unsafe — blind manual control is never allowed.
    public mutating func evaluate(samples: [FanTemperatureSample], manualPolicyActive: Bool) -> FanSafetyDecision {
        let peak = samples.map(\.celsius).max()

        // Latch release requires a credible reading comfortably below the ceiling.
        if isLatched, let peak, peak <= configuredCeilingCelsius - Self.releaseHysteresisCelsius {
            isLatched = false
        }

        guard manualPolicyActive else {
            // System is in control; nothing to enforce.
            consecutiveOverCeiling = 0
            return FanSafetyDecision(forceAuto: false)
        }

        guard let peak else {
            isLatched = true
            consecutiveOverCeiling = 0
            return FanSafetyDecision(
                forceAuto: true,
                reason: "no readable temperature sensors while fans are under manual control"
            )
        }
        if peak >= configuredCeilingCelsius {
            consecutiveOverCeiling += 1
            if consecutiveOverCeiling >= Self.consecutiveTripsRequired {
                isLatched = true
                return FanSafetyDecision(
                    forceAuto: true,
                    reason: "temperature \(peak)C held at/above safety ceiling \(configuredCeilingCelsius)C for \(consecutiveOverCeiling) consecutive checks"
                )
            }
        } else {
            consecutiveOverCeiling = 0
        }
        if isLatched {
            return FanSafetyDecision(
                forceAuto: true,
                reason: "safety latch active until temperature falls below \(configuredCeilingCelsius - Self.releaseHysteresisCelsius)C"
            )
        }
        return FanSafetyDecision(forceAuto: false)
    }
}

public struct FanStartupReconciler: Sendable {
    public init() {}

    public func shouldRestoreAuto(hasLocalManualPolicy: Bool, fanModes: [Int: UInt8], ftstValue: UInt8?) -> Bool {
        guard !hasLocalManualPolicy else {
            return false
        }
        if fanModes.values.contains(FanModeValue.manual.rawValue) {
            return true
        }
        return ftstValue == 1
    }
}

public enum FanModeValue: UInt8, Codable, Equatable, Sendable {
    case auto = 0
    case manual = 1
    case system = 3
}
