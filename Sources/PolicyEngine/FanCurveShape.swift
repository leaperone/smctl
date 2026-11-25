import Foundation

// MARK: - Shapes

/// Built-in curve families. Each is a monotonic map of [0, 1] onto [0, 1] with
/// f(0) = 0 and f(1) = 1, so `start`/`end` stretch it horizontally and
/// `minimum`/`maximum` scale it vertically without changing its character.
public enum FanCurveShapeKind: String, Codable, CaseIterable, Sendable {
    /// Even ramp.
    case linear
    /// Calm, then a decisive climb around the midpoint.
    case sigmoid
    /// Stays low for most of the range, then accelerates (quiet-leaning).
    case exponential
    /// Reacts early, then levels off (cooling-leaning).
    case logarithmic
    /// Discrete plateaus, like rule-based tools.
    case steps

    /// Default for `steepness`, chosen so each shape is clearly distinct from linear.
    public var defaultSteepness: Double {
        switch self {
        case .linear, .steps: return 0
        case .sigmoid: return 8
        case .exponential, .logarithmic: return 3
        }
    }
}

/// A parametric fan curve: a shape placed between two temperatures and two speed
/// fractions. Speeds are fractions of the fan's own range (0 = minimum RPM,
/// 1 = maximum RPM), so a single shape works across fans and Mac models.
public struct FanCurveShape: Codable, Equatable, Sendable {
    public static let maximumStepCount = 20
    public static let maximumSteepness = 30.0
    /// Below this, curved shapes are numerically indistinguishable from linear.
    static let minimumEffectiveSteepness = 1e-6

    public var kind: FanCurveShapeKind
    public var startCelsius: Double
    public var endCelsius: Double
    public var minimumFraction: Double
    public var maximumFraction: Double
    /// Curvature for sigmoid/exponential/logarithmic; ignored otherwise.
    public var steepness: Double
    /// Number of plateaus for `.steps`; ignored otherwise.
    public var stepCount: Int

    public init(
        kind: FanCurveShapeKind,
        startCelsius: Double,
        endCelsius: Double,
        minimumFraction: Double = 0,
        maximumFraction: Double = 1,
        steepness: Double? = nil,
        stepCount: Int = 4
    ) throws {
        let steepness = steepness ?? kind.defaultSteepness
        guard startCelsius.isFinite, endCelsius.isFinite, startCelsius < endCelsius else {
            throw PolicyError.invalidFanCurve("shape start (\(startCelsius)) must be below end (\(endCelsius))")
        }
        guard minimumFraction.isFinite, maximumFraction.isFinite,
              (0...1).contains(minimumFraction), (0...1).contains(maximumFraction) else {
            throw PolicyError.invalidFanCurve("shape speeds must be between 0% and 100%")
        }
        guard minimumFraction <= maximumFraction else {
            throw PolicyError.invalidFanCurve("shape minimum speed must not exceed maximum speed")
        }
        guard steepness.isFinite, steepness >= 0, steepness <= Self.maximumSteepness else {
            throw PolicyError.invalidFanCurve("shape steepness must be between 0 and \(Self.maximumSteepness)")
        }
        guard (1...Self.maximumStepCount).contains(stepCount) else {
            throw PolicyError.invalidFanCurve("shape step count must be between 1 and \(Self.maximumStepCount)")
        }
        self.kind = kind
        self.startCelsius = startCelsius
        self.endCelsius = endCelsius
        self.minimumFraction = minimumFraction
        self.maximumFraction = maximumFraction
        self.steepness = steepness
        self.stepCount = stepCount
    }

    /// The normalized shape function f: [0, 1] → [0, 1]; input is clamped.
    public func normalized(_ x: Double) -> Double {
        let x = min(1, max(0, x))
        let k = steepness
        switch kind {
        case .linear:
            return x
        case .sigmoid:
            guard k > Self.minimumEffectiveSteepness else { return x }
            let s = { (v: Double) in 1 / (1 + exp(-k * (v - 0.5))) }
            let low = s(0)
            let high = s(1)
            return (s(x) - low) / (high - low)
        case .exponential:
            guard k > Self.minimumEffectiveSteepness else { return x }
            return expm1(k * x) / expm1(k)
        case .logarithmic:
            guard k > Self.minimumEffectiveSteepness else { return x }
            return log1p(x * expm1(k)) / k
        case .steps:
            return min(1, floor(x * Double(stepCount) + 1e-12) / Double(stepCount))
        }
    }

    /// Fan speed fraction (of the fan's min→max range) at `temperature`.
    /// Flat at `minimumFraction` below `start` and at `maximumFraction` above `end`.
    public func fraction(at temperature: Double) -> Double {
        let x = (temperature - startCelsius) / (endCelsius - startCelsius)
        return minimumFraction + (maximumFraction - minimumFraction) * normalized(x)
    }

    /// Piecewise-linear approximation as (°C, fraction) pairs, ready to be mapped
    /// to RPM and fed to `FanCurveEngine`. Steps compile to exact plateaus joined
    /// by near-vertical risers. Other shapes start from an even grid and segments
    /// are split adaptively until linear interpolation stays within `tolerance`
    /// (as a fraction of full speed) — steep shapes get points where they bend.
    public func compiledPoints(
        initialSegments: Int = 16,
        tolerance: Double = 0.005,
        maximumPoints: Int = 160
    ) -> [(celsius: Double, fraction: Double)] {
        let span = endCelsius - startCelsius
        let scale = { (f: Double) in minimumFraction + (maximumFraction - minimumFraction) * f }
        if kind == .steps {
            // Risers are 1% of the span wide (at least 0.01 °C) so temperatures stay unique.
            let riser = max(0.01, span * 0.01)
            var points = [(celsius: startCelsius, fraction: scale(0))]
            for step in 1...stepCount {
                let edge = startCelsius + span * Double(step) / Double(stepCount)
                points.append((edge - riser, scale(Double(step - 1) / Double(stepCount))))
                points.append((edge, scale(Double(step) / Double(stepCount))))
            }
            return points
        }
        let segments = max(1, initialSegments)
        var xs = (0...segments).map { Double($0) / Double(segments) }
        // Error is measured on the normalized shape and scaled by the speed span,
        // so it is expressed in the same unit as the output.
        let spanFraction = maximumFraction - minimumFraction
        let tolerance = max(1e-6, tolerance)
        var refined = true
        while refined, xs.count < maximumPoints {
            refined = false
            var next = [xs[0]]
            var inserted = 0
            for (a, b) in zip(xs, xs.dropFirst()) {
                let fa = normalized(a), fb = normalized(b)
                // Probe at quarter points: catches bends a midpoint check can miss.
                let error = [0.25, 0.5, 0.75].map { t -> Double in
                    let x = a + (b - a) * t
                    return abs(normalized(x) - (fa + (fb - fa) * t))
                }.max() ?? 0
                if error * spanFraction > tolerance, xs.count + inserted < maximumPoints, b - a > 1e-6 {
                    next.append((a + b) / 2)
                    inserted += 1
                    refined = true
                }
                next.append(b)
            }
            xs = next
        }
        return xs.map { (startCelsius + span * $0, scale(normalized($0))) }
    }
}

// MARK: - Speed range

/// Maps speed fractions onto a specific fan: 0 is the fan's minimum RPM and 1 its
/// maximum, so percent curves never ask for less than the firmware floor.
public struct FanSpeedRange: Equatable, Sendable {
    public var minimumRPM: Double
    public var maximumRPM: Double

    public init(minimumRPM: Double, maximumRPM: Double) {
        let low = minimumRPM.isFinite ? max(0, minimumRPM) : 0
        let high = maximumRPM.isFinite ? maximumRPM : low
        self.minimumRPM = min(low, high)
        self.maximumRPM = max(low, high)
    }

    public var spanRPM: Double { maximumRPM - minimumRPM }

    public func rpm(forFraction fraction: Double) -> Double {
        let fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
        return minimumRPM + spanRPM * fraction
    }

    public func fraction(forRPM rpm: Double) -> Double {
        guard spanRPM > 0, rpm.isFinite else { return 0 }
        return min(1, max(0, (rpm - minimumRPM) / spanRPM))
    }
}

// MARK: - Sensor selection

/// Matches sensor keys against exact names or glob patterns (`*`, `?`),
/// e.g. `Tp*` for Apple Silicon hot-spot sensors. Matching is case-sensitive
/// because SMC keys are.
public enum SensorSelector {
    public static func matches(_ sensor: String, pattern: String) -> Bool {
        guard pattern.contains("*") || pattern.contains("?") else {
            return sensor == pattern
        }
        return globMatch(Array(sensor.utf8), Array(pattern.utf8))
    }

    public static func matches(_ sensor: String, anyOf patterns: [String]) -> Bool {
        patterns.contains { matches(sensor, pattern: $0) }
    }

    /// Weight for `sensor`: an exact key wins over patterns; among patterns the
    /// first match in sorted order wins, so results are deterministic.
    public static func weight(for sensor: String, in weights: [String: Double]) -> Double? {
        if let exact = weights[sensor] { return exact }
        return weights.keys.sorted().first { matches(sensor, pattern: $0) }.flatMap { weights[$0] }
    }

    private static func globMatch(_ text: [UInt8], _ pattern: [UInt8]) -> Bool {
        let star = UInt8(ascii: "*")
        let question = UInt8(ascii: "?")
        var t = 0, p = 0
        var starIndex: Int?
        var resume = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == question || pattern[p] == text[t] {
                t += 1; p += 1
            } else if p < pattern.count, pattern[p] == star {
                starIndex = p; resume = t; p += 1
            } else if let s = starIndex {
                p = s + 1; resume += 1; t = resume
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == star { p += 1 }
        return p == pattern.count
    }
}

// MARK: - Smoothing

/// Exponential moving average with a time constant, robust to irregular tick
/// spacing: alpha = 1 - e^(-dt/tau). A time constant of 0 disables smoothing.
/// Rising temperatures can bypass smoothing so the fans never lag real heat.
public struct TemperatureSmoother: Equatable, Sendable {
    public var timeConstantSeconds: Double
    public var followsRisesImmediately: Bool
    public private(set) var value: Double?
    public private(set) var lastUpdate: Date?

    public init(timeConstantSeconds: Double, followsRisesImmediately: Bool = false) {
        self.timeConstantSeconds = timeConstantSeconds.isFinite ? max(0, timeConstantSeconds) : 0
        self.followsRisesImmediately = followsRisesImmediately
    }

    public mutating func update(_ sample: Double, now: Date) -> Double {
        defer { lastUpdate = now }
        guard sample.isFinite else { return value ?? sample }
        guard timeConstantSeconds > 0, let previous = value, let lastUpdate else {
            value = sample
            return sample
        }
        if followsRisesImmediately, sample >= previous {
            value = sample
            return sample
        }
        let dt = max(0, now.timeIntervalSince(lastUpdate))
        let alpha = 1 - exp(-dt / timeConstantSeconds)
        let next = previous + alpha * (sample - previous)
        value = next
        return next
    }

    public mutating func reset() {
        value = nil
        lastUpdate = nil
    }
}
