import Foundation

/// What an alert rule watches. Kept deliberately small for the first cut:
/// temperature thresholds, the fan safety guard tripping, and SMC write
/// failures — all sourced from data the daemon already collects every tick.
public enum AlertTriggerKind: String, Codable, Equatable, Sendable {
    /// A temperature sensor sustained above a threshold.
    case temp
    /// The fan thermal safety guard forced fans back to auto.
    case guardTripped = "guard"
    /// An SMC write failed verification (data-correctness signal).
    case writeError = "write-error"
}

public struct AlertTrigger: Equatable, Sendable {
    public var kind: AlertTriggerKind
    /// For `.temp`: the sensor key to watch, or "any" to match the hottest sensor.
    public var sensor: String?
    /// For `.temp`: the ceiling in Celsius; firing requires a reading strictly above it.
    public var above: Double?

    public init(kind: AlertTriggerKind, sensor: String? = nil, above: Double? = nil) {
        self.kind = kind
        self.sensor = sensor
        self.above = above
    }
}

public struct AlertRule: Equatable, Sendable {
    public var name: String
    public var trigger: AlertTrigger
    /// Sustained-duration debounce: the condition must hold this long before firing.
    public var forSeconds: Double
    /// After firing, suppress re-firing for this long.
    public var cooldownSeconds: Double
    /// Emit a `.resolved` event when the condition clears after firing.
    public var resolve: Bool

    public init(
        name: String,
        trigger: AlertTrigger,
        forSeconds: Double = 0,
        cooldownSeconds: Double = 300,
        resolve: Bool = false
    ) {
        self.name = name
        self.trigger = trigger
        self.forSeconds = max(0, forSeconds)
        self.cooldownSeconds = max(0, cooldownSeconds)
        self.resolve = resolve
    }
}

/// The per-tick metric snapshot the engine evaluates rules against. The daemon
/// already has all of this in hand inside its 1 Hz fan loop.
public struct AlertConditionInput: Equatable, Sendable {
    public var samples: [FanTemperatureSample]
    public var guardTripped: Bool
    public var guardReason: String?
    /// Non-nil when the most recent SMC write failed (verification/IO error).
    public var writeError: String?

    public init(
        samples: [FanTemperatureSample] = [],
        guardTripped: Bool = false,
        guardReason: String? = nil,
        writeError: String? = nil
    ) {
        self.samples = samples
        self.guardTripped = guardTripped
        self.guardReason = guardReason
        self.writeError = writeError
    }
}

public enum AlertEventKind: String, Codable, Equatable, Sendable {
    case fired
    case resolved
}

public struct AlertEvent: Equatable, Sendable {
    public var ruleName: String
    public var kind: AlertEventKind
    public var triggerKind: AlertTriggerKind
    public var reason: String
    /// The numeric reading that crossed the threshold, when applicable (Celsius).
    public var value: Double?
    public var timestamp: Date

    public init(
        ruleName: String,
        kind: AlertEventKind,
        triggerKind: AlertTriggerKind,
        reason: String,
        value: Double?,
        timestamp: Date
    ) {
        self.ruleName = ruleName
        self.kind = kind
        self.triggerKind = triggerKind
        self.reason = reason
        self.value = value
        self.timestamp = timestamp
    }
}

/// Observable per-rule state, surfaced to the CLI via `smctl alert status`.
public enum AlertRuleStatus: String, Codable, Equatable, Sendable {
    /// Condition not met; ready to fire.
    case armed
    /// Condition met but `for` debounce not yet elapsed.
    case pending
    /// Fired and currently within its cooldown window.
    case cooling
    /// Fired, condition still active, cooldown elapsed (will re-fire next match).
    case firing
}

public struct AlertRuleState: Equatable, Sendable {
    public var name: String
    public var status: AlertRuleStatus
    public var lastFired: Date?
    public var lastValue: Double?

    public init(name: String, status: AlertRuleStatus, lastFired: Date? = nil, lastValue: Double? = nil) {
        self.name = name
        self.status = status
        self.lastFired = lastFired
        self.lastValue = lastValue
    }
}

/// Edge-triggered alert state machine. One runtime per rule name; the machine is
/// stateful (debounce timers, cooldown, fired latch) and must be evaluated every
/// tick so it can both fire and resolve. Pure: no I/O, `now` injected for tests.
///
/// Per-rule lifecycle:
///   armed → (condition true) pending(remember start)
///         → (held ≥ for) FIRED, cooling(cooldown)
///         → (condition false) [resolve? RESOLVED] → armed
public struct AlertEngine: Equatable, Sendable {
    private struct Runtime: Equatable {
        var pendingSince: Date?
        var fired: Bool = false
        var cooldownUntil: Date?
        var lastFired: Date?
        var lastValue: Double?
    }

    private var runtimes: [String: Runtime] = [:]

    public init() {}

    public mutating func evaluate(rules: [AlertRule], input: AlertConditionInput, now: Date) -> [AlertEvent] {
        var events: [AlertEvent] = []
        var liveNames = Set<String>()

        for rule in rules {
            liveNames.insert(rule.name)
            var runtime = runtimes[rule.name] ?? Runtime()
            let match = condition(rule.trigger, input: input)

            if match.active {
                runtime.lastValue = match.value
                if runtime.pendingSince == nil {
                    runtime.pendingSince = now
                }
                let heldLongEnough = now.timeIntervalSince(runtime.pendingSince ?? now) >= rule.forSeconds
                let cooledDown = runtime.cooldownUntil.map { now >= $0 } ?? true
                if heldLongEnough, cooledDown {
                    events.append(AlertEvent(
                        ruleName: rule.name,
                        kind: .fired,
                        triggerKind: rule.trigger.kind,
                        reason: match.reason,
                        value: match.value,
                        timestamp: now
                    ))
                    runtime.fired = true
                    runtime.lastFired = now
                    runtime.cooldownUntil = now.addingTimeInterval(rule.cooldownSeconds)
                }
            } else {
                if runtime.fired, rule.resolve {
                    events.append(AlertEvent(
                        ruleName: rule.name,
                        kind: .resolved,
                        triggerKind: rule.trigger.kind,
                        reason: "Condition cleared",
                        value: match.value,
                        timestamp: now
                    ))
                }
                runtime.fired = false
                runtime.pendingSince = nil
            }

            runtimes[rule.name] = runtime
        }

        // Drop runtimes for rules removed from config so state never leaks.
        runtimes = runtimes.filter { liveNames.contains($0.key) }
        return events
    }

    public func states(for rules: [AlertRule], now: Date) -> [AlertRuleState] {
        rules.map { rule in
            let runtime = runtimes[rule.name] ?? Runtime()
            let status: AlertRuleStatus
            if runtime.fired {
                let cooling = runtime.cooldownUntil.map { now < $0 } ?? false
                status = cooling ? .cooling : .firing
            } else if runtime.pendingSince != nil {
                status = .pending
            } else {
                status = .armed
            }
            return AlertRuleState(
                name: rule.name,
                status: status,
                lastFired: runtime.lastFired,
                lastValue: runtime.lastValue
            )
        }
    }

    private struct Condition {
        var active: Bool
        var reason: String
        var value: Double?
    }

    private func condition(_ trigger: AlertTrigger, input: AlertConditionInput) -> Condition {
        switch trigger.kind {
        case .temp:
            guard let above = trigger.above else {
                return Condition(active: false, reason: "No threshold configured", value: nil)
            }
            let matching = input.samples.filter { sample in
                guard let sensor = trigger.sensor, sensor.lowercased() != "any" else { return true }
                return sample.sensor == sensor
            }
            // Fire on the hottest matching sensor that exceeds the ceiling.
            if let hottest = matching.filter({ $0.celsius > above }).max(by: { $0.celsius < $1.celsius }) {
                return Condition(
                    active: true,
                    reason: "\(hottest.sensor) at \(format(hottest.celsius))C exceeds \(format(above))C",
                    value: hottest.celsius
                )
            }
            // Report the current hottest matching reading for `status`/resolve context.
            let peak = matching.max(by: { $0.celsius < $1.celsius })?.celsius
            return Condition(active: false, reason: "Below threshold", value: peak)
        case .guardTripped:
            return Condition(
                active: input.guardTripped,
                reason: input.guardReason ?? "Fan safety guard tripped",
                value: nil
            )
        case .writeError:
            return Condition(
                active: input.writeError != nil,
                reason: input.writeError ?? "SMC write failed",
                value: nil
            )
        }
    }

    private func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
