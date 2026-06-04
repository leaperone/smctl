import Foundation

public enum PolicyEngine {
    public static let version = "0.2.0"
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

    public var description: String {
        switch self {
        case .invalidChargeLimit(let value):
            return "Invalid charge limit '\(value)'"
        case .invalidSleepPolicy(let value):
            return "Invalid sleep policy '\(value)'"
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

