import Foundation

// MARK: - Speed values

/// A fan speed as written in a curve: absolute RPM, a percentage of the fan's own
/// min→max range, or the fan's maximum.
public enum FanSpeedValue: Equatable, Sendable {
    case rpm(Double)
    case percent(Double)
    case maximum

    /// Parses `1600`, `"40%"`, `"max"` (case-insensitive, surrounding spaces ignored).
    public init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "max" {
            self = .maximum
        } else if trimmed.hasSuffix("%"), let value = Double(trimmed.dropLast().trimmingCharacters(in: .whitespaces)) {
            self = .percent(value)
        } else if let value = Double(trimmed) {
            self = .rpm(value)
        } else {
            throw PolicyError.invalidFanCurve("speed '\(text)' must be RPM, a percentage like \"40%\", or \"max\"")
        }
    }

    /// RPM for a given fan. Percentages map onto the fan's range and are clamped to
    /// 0–100%; absolute RPM is returned as written (the daemon clamps to the fan).
    public func rpm(in range: FanSpeedRange) -> Double {
        switch self {
        case .rpm(let value): return value
        case .percent(let value): return range.rpm(forFraction: value / 100)
        case .maximum: return range.maximumRPM
        }
    }

    /// Canonical text form, as written to TOML.
    public var configString: String {
        switch self {
        case .rpm(let value): return Self.format(value)
        case .percent(let value): return "\(Self.format(value))%"
        case .maximum: return "max"
        }
    }

    func validate(context: String) throws {
        switch self {
        case .rpm(let value):
            guard value.isFinite, value >= 0 else { throw PolicyError.invalidFanCurve("\(context): RPM must be a finite, non-negative number") }
        case .percent(let value):
            guard value.isFinite, (0...100).contains(value) else { throw PolicyError.invalidFanCurve("\(context): percentage must be between 0% and 100%") }
        case .maximum:
            break
        }
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }
}

extension FanSpeedValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            self = .rpm(number)
        } else if let integer = try? container.decode(Int.self) {
            self = .rpm(Double(integer))
        } else {
            self = try FanSpeedValue(parsing: container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if case .rpm(let value) = self {
            try container.encode(value)
        } else {
            try container.encode(configString)
        }
    }
}

/// A rate of speed change per second: absolute RPM/s or a percentage of the fan's
/// range per second (so the same curve feels the same on every fan).
public enum FanRateValue: Equatable, Sendable {
    case rpmPerSecond(Double)
    case percentPerSecond(Double)

    public init(parsing text: String) throws {
        switch try FanSpeedValue(parsing: text) {
        case .rpm(let value): self = .rpmPerSecond(value)
        case .percent(let value): self = .percentPerSecond(value)
        case .maximum: throw PolicyError.invalidFanCurve("rate '\(text)' must be RPM per second or a percentage like \"8%\"")
        }
    }

    public func rpmPerSecond(in range: FanSpeedRange) -> Double {
        switch self {
        case .rpmPerSecond(let value): return value
        case .percentPerSecond(let value): return range.spanRPM * value / 100
        }
    }

    public var configString: String {
        switch self {
        case .rpmPerSecond(let value): return FanSpeedValue.format(value)
        case .percentPerSecond(let value): return "\(FanSpeedValue.format(value))%"
        }
    }

    func validate(context: String) throws {
        let value: Double
        switch self {
        case .rpmPerSecond(let v): value = v
        case .percentPerSecond(let v): value = v
        }
        guard value.isFinite, value > 0 else { throw PolicyError.invalidFanCurve("\(context) must be a positive number") }
        if case .percentPerSecond(let v) = self, v > 100 {
            throw PolicyError.invalidFanCurve("\(context) must not exceed 100% per second")
        }
    }
}

extension FanRateValue: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    public init(integerLiteral value: Int) { self = .rpmPerSecond(Double(value)) }
    public init(floatLiteral value: Double) { self = .rpmPerSecond(value) }
}

extension FanRateValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            self = .rpmPerSecond(number)
        } else if let integer = try? container.decode(Int.self) {
            self = .rpmPerSecond(Double(integer))
        } else {
            self = try FanRateValue(parsing: container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if case .rpmPerSecond(let value) = self {
            try container.encode(value)
        } else {
            try container.encode(configString)
        }
    }
}

// MARK: - Curve specification

/// What a fan does while its curve is at 0% (below the ramp, with a 0% floor).
public enum FanCurveIdle: String, Codable, CaseIterable, Sendable {
    /// macOS runs the fan (it may stop it, or spin it faster than the floor).
    case system
    /// The fan holds its minimum RPM: never faster than the curve, never stopped.
    case minimum
    /// Pulse stops the fan. Needs `[safety] allow_below_minimum = true`; guarded
    /// by `FanCurveHandoff.allowsStopping`. Possibly harmful: Apple's firmware
    /// never stops some fans (Mac mini).
    case off
}

public struct FanCurveSpecPoint: Codable, Equatable, Sendable {
    public var celsius: Double
    public var speed: FanSpeedValue

    public init(_ celsius: Double, _ speed: FanSpeedValue) {
        self.celsius = celsius
        self.speed = speed
    }
}

/// A fan curve as users and clients describe it — independent of any particular
/// fan. `resolve(for:)` turns it into an RPM `FanCurve` for one fan's range.
/// A curve is either a parametric `shape` or explicit `points`.
public struct FanCurveSpec: Codable, Equatable, Sendable {
    public static let maximumNameLength = 32
    public static let maximumLabelLength = 64

    /// Identifier used by `fan profile <name>`: lowercase letters, digits, `-`, `_`.
    public var name: String
    /// Optional display name for the app (any text).
    public var label: String?
    /// Sensor keys or glob patterns; empty means every temperature sensor.
    public var sensors: [String]
    public var weights: [String: Double]
    public var shape: FanCurveShape?
    public var points: [FanCurveSpecPoint]
    public var hysteresisCelsius: Double
    public var riseRate: FanRateValue?
    public var fallRate: FanRateValue?
    public var smoothingSeconds: Double?
    /// Behaviour at 0%; only matters when the curve's floor is 0%.
    public var idle: FanCurveIdle

    public init(
        name: String,
        label: String? = nil,
        sensors: [String] = [],
        weights: [String: Double] = [:],
        shape: FanCurveShape? = nil,
        points: [FanCurveSpecPoint] = [],
        hysteresisCelsius: Double = 0,
        riseRate: FanRateValue? = nil,
        fallRate: FanRateValue? = nil,
        smoothingSeconds: Double? = nil,
        idle: FanCurveIdle = .system
    ) {
        self.name = name
        self.label = label
        self.sensors = sensors
        self.weights = weights
        self.shape = shape
        self.points = points
        self.hysteresisCelsius = hysteresisCelsius
        self.riseRate = riseRate
        self.fallRate = fallRate
        self.smoothingSeconds = smoothingSeconds
        self.idle = idle
    }

    private enum CodingKeys: String, CodingKey {
        case name, label, sensors, weights, shape, points, hysteresisCelsius, riseRate, fallRate, smoothingSeconds, idle
    }

    /// `idle` is absent from older clients and daemons: it defaults to `.system`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        sensors = try container.decode([String].self, forKey: .sensors)
        weights = try container.decode([String: Double].self, forKey: .weights)
        shape = try container.decodeIfPresent(FanCurveShape.self, forKey: .shape)
        points = try container.decode([FanCurveSpecPoint].self, forKey: .points)
        hysteresisCelsius = try container.decode(Double.self, forKey: .hysteresisCelsius)
        riseRate = try container.decodeIfPresent(FanRateValue.self, forKey: .riseRate)
        fallRate = try container.decodeIfPresent(FanRateValue.self, forKey: .fallRate)
        smoothingSeconds = try container.decodeIfPresent(Double.self, forKey: .smoothingSeconds)
        idle = try container.decodeIfPresent(FanCurveIdle.self, forKey: .idle) ?? .system
    }

    /// Whether the curve ever asks for 0% (its floor), where `idle` applies.
    public var reachesZero: Bool {
        if let shape { return shape.minimumFraction <= FanCurveHandoff.idleFraction }
        return points.contains { point in
            switch point.speed {
            case .percent(let value): return value <= FanCurveHandoff.idleFraction * 100
            case .rpm(let value): return value <= 0
            case .maximum: return false
            }
        }
    }

    public static func isValidName(_ name: String) -> Bool {
        guard (1...maximumNameLength).contains(name.count), let first = name.unicodeScalars.first,
              CharacterSet.lowercaseLetters.contains(first) || CharacterSet.decimalDigits.contains(first) else {
            return false
        }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" }
    }

    /// Full validation for new or edited curves: name rules plus `validateContent()`.
    /// `allowReservedName` is for built-in presets only.
    public func validate(allowReservedName: Bool = false) throws {
        guard Self.isValidName(name) else {
            throw PolicyError.invalidFanCurve("name '\(name)' must be 1–\(Self.maximumNameLength) characters: lowercase letters, digits, '-' or '_'")
        }
        guard allowReservedName || !FanCurvePresets.reservedNames.contains(name) else {
            throw PolicyError.invalidFanCurve("name '\(name)' is reserved for a built-in profile")
        }
        try validateContent()
    }

    /// Everything except the name, so curves from older hand-written configs keep
    /// working even if their names predate the naming rules.
    public func validateContent() throws {
        if let label {
            guard label.count <= Self.maximumLabelLength, !label.contains(where: { $0.isNewline }) else {
                throw PolicyError.invalidFanCurve("\(name): label must be a single line of at most \(Self.maximumLabelLength) characters")
            }
        }
        guard sensors.allSatisfy({ !$0.isEmpty && $0.count <= 16 && !$0.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "\\" }) }) else {
            throw PolicyError.invalidFanCurve("\(name): sensors must be SMC keys or patterns like \"Tp*\"")
        }
        guard weights.allSatisfy({ !$0.key.isEmpty && $0.value.isFinite && $0.value >= 0 }) else {
            throw PolicyError.invalidFanCurve("\(name): weights must be finite and non-negative")
        }
        guard hysteresisCelsius.isFinite, (0...20).contains(hysteresisCelsius) else {
            throw PolicyError.invalidFanCurve("\(name): hysteresis must be between 0 and 20 °C")
        }
        if let smoothingSeconds {
            guard smoothingSeconds.isFinite, (0...120).contains(smoothingSeconds) else {
                throw PolicyError.invalidFanCurve("\(name): smoothing must be between 0 and 120 seconds")
            }
        }
        try riseRate?.validate(context: "\(name): rise rate")
        try fallRate?.validate(context: "\(name): fall rate")
        switch (shape, points.isEmpty) {
        case (.some, false):
            throw PolicyError.invalidFanCurve("\(name): use either a shape or points, not both")
        case (nil, true):
            throw PolicyError.invalidFanCurve("\(name): a shape or at least two points are required")
        case (.some(let shape), true):
            // Re-run the shape's own invariants in case it was decoded, not constructed.
            _ = try FanCurveShape(
                kind: shape.kind, startCelsius: shape.startCelsius, endCelsius: shape.endCelsius,
                minimumFraction: shape.minimumFraction, maximumFraction: shape.maximumFraction,
                steepness: shape.steepness, stepCount: shape.stepCount
            )
        case (nil, false):
            guard points.count >= 2 else { throw PolicyError.invalidFanCurve("\(name): at least two points are required") }
            for (index, point) in points.enumerated() {
                guard point.celsius.isFinite, (-40...150).contains(point.celsius) else {
                    throw PolicyError.invalidFanCurve("\(name): point \(index + 1) temperature must be between -40 and 150 °C")
                }
                try point.speed.validate(context: "\(name): point \(index + 1)")
            }
            guard Set(points.map(\.celsius)).count == points.count else {
                throw PolicyError.invalidFanCurve("\(name): point temperatures must be unique")
            }
        }
    }

    /// Points as (°C, RPM) for one fan, sorted by temperature.
    public func resolvedPoints(for range: FanSpeedRange) -> [FanCurvePoint] {
        if let shape {
            return shape.compiledPoints().map { FanCurvePoint($0.celsius, range.rpm(forFraction: $0.fraction)) }
        }
        return points
            .map { FanCurvePoint($0.celsius, $0.speed.rpm(in: range)) }
            .sorted { $0.temperatureCelsius < $1.temperatureCelsius }
    }

    /// The executable curve for one fan.
    public func resolve(for range: FanSpeedRange) throws -> FanCurve {
        try validateContent()
        return try FanCurve(
            name: name,
            sensors: sensors,
            sensorWeights: weights,
            points: resolvedPoints(for: range),
            hysteresisCelsius: hysteresisCelsius,
            slewRateRPMPerSecond: riseRate?.rpmPerSecond(in: range),
            fallSlewRateRPMPerSecond: fallRate?.rpmPerSecond(in: range),
            smoothingSeconds: smoothingSeconds
        )
    }
}

// MARK: - Presets

/// Built-in percent-based profiles. They aggregate every sensor with `max`, like
/// smctl's `quiet`, because Apple Silicon hot-spots (`Tp*`) lead the heat: they
/// idle around 55–65 °C and reach 95–105 °C under sustained load.
/// Every preset smooths its input over at least ~5 s (EMA time constant), so a
/// one-second hot-spot spike never revs the fan. Values are starting points to
/// be tuned against real traces.
public enum FanCurvePresets {
    /// Names that user curves may not take: system modes, smctl built-ins and Pulse presets.
    public static let reservedNames: Set<String> = ["auto", "manual", "quiet", "full", "silent", "balanced", "performance"]

    public static let silent = preset(
        name: "silent", label: "Silent",
        shape: (.exponential, 80, 105, 0, 1, 3),
        hysteresis: 3, rise: 5, fall: 2, smoothing: 10
    )

    public static let balanced = preset(
        name: "balanced", label: "Balanced",
        shape: (.sigmoid, 70, 100, 0, 1, 8),
        hysteresis: 3, rise: 8, fall: 3, smoothing: 6
    )

    /// Follows the CPU *average* rather than the hottest hot-spot: a single
    /// busy core (70–80 °C under light load) no longer revs the fan, and a
    /// straight ramp keeps the response predictable. The CPU average idles
    /// around 45–55 °C.
    public static let performance = preset(
        name: "performance", label: "Performance",
        sensors: ["Tp*"], weights: ["Tp*": 1],
        shape: (.linear, 55, 90, 0.1, 1, 1),
        hysteresis: 2, rise: 10, fall: 4, smoothing: 5
    )

    public static let all: [FanCurveSpec] = [silent, balanced, performance]

    public static func named(_ name: String) -> FanCurveSpec? {
        all.first { $0.name == name }
    }

    private static func preset(
        name: String, label: String,
        sensors: [String] = [], weights: [String: Double] = [:],
        shape: (FanCurveShapeKind, Double, Double, Double, Double, Double),
        hysteresis: Double, rise: Double, fall: Double, smoothing: Double
    ) -> FanCurveSpec {
        // Constant, validated by tests; a failure here is a programming error.
        let curveShape = try! FanCurveShape(
            kind: shape.0, startCelsius: shape.1, endCelsius: shape.2,
            minimumFraction: shape.3, maximumFraction: shape.4, steepness: shape.5
        )
        return FanCurveSpec(
            name: name, label: label, sensors: sensors, weights: weights, shape: curveShape,
            hysteresisCelsius: hysteresis,
            riseRate: .percentPerSecond(rise), fallRate: .percentPerSecond(fall),
            smoothingSeconds: smoothing
        )
    }
}
