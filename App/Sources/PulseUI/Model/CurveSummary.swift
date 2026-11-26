import Foundation
import PolicyEngine

/// Plain-language description of a curve's settings, for the Curves pane.
public enum CurveSummary {
    public static func shape(_ spec: FanCurveSpec) -> String {
        if let shape = spec.shape {
            var text = "\(shape.kind.title), \(number(shape.startCelsius))–\(degrees(shape.endCelsius)), "
                + "\(number(shape.minimumFraction * 100))–\(percent(shape.maximumFraction * 100))"
            switch shape.kind {
            case .linear: break
            case .steps: text += ", \(shape.stepCount) steps"
            default: text += ", steepness \(number(shape.steepness))"
            }
            return text
        }
        return "\(spec.points.count) points"
    }

    public static func sensors(_ spec: FanCurveSpec) -> String {
        let source: String
        if spec.sensors.isEmpty {
            source = "All sensors"
        } else {
            source = spec.sensors.map { SensorGroupName.title(for: $0) }.joined(separator: ", ")
        }
        return source + (spec.weights.isEmpty ? ", hottest" : ", weighted average")
    }

    public static func response(_ spec: FanCurveSpec) -> String {
        let rise = spec.riseRate.map { "up \(rate($0))" } ?? "up immediately"
        let fall = spec.fallRate.map { "down \(rate($0))" } ?? "down immediately"
        return "\(rise), \(fall)"
    }

    public static func hysteresis(_ spec: FanCurveSpec) -> String {
        spec.hysteresisCelsius > 0 ? degrees(spec.hysteresisCelsius) : "None"
    }

    public static func smoothing(_ spec: FanCurveSpec) -> String {
        guard let seconds = spec.smoothingSeconds, seconds > 0 else { return "None" }
        return "\(number(seconds)) s"
    }

    static func rate(_ value: FanRateValue) -> String {
        switch value {
        case .percentPerSecond(let v): return "\(number(v)) %/s"
        case .rpmPerSecond(let v): return "\(number(v)) RPM/s"
        }
    }

    static func degrees(_ value: Double) -> String { "\(number(value)) °C" }
    static func percent(_ value: Double) -> String { "\(number(value)) %" }

    static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

extension FanCurveShapeKind {
    public var title: String {
        switch self {
        case .linear: return "Linear"
        case .sigmoid: return "S-curve"
        case .exponential: return "Exponential"
        case .logarithmic: return "Logarithmic"
        case .steps: return "Steps"
        }
    }
}

/// Readable names for the sensor patterns Pulse writes.
public enum SensorGroupName {
    public static func title(for pattern: String) -> String {
        switch pattern {
        case "Tp*": return "CPU"
        case "Tg*": return "GPU"
        case "Ts*": return "Enclosure"
        case "TC*": return "CPU (Intel)"
        case "TG*": return "GPU (Intel)"
        default: return pattern
        }
    }
}
