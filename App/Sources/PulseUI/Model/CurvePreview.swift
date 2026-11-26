import Foundation
import PolicyEngine
import SMCtlProtocol

/// What the curve being edited would do right now, computed like the daemon:
/// the same sensor selection and aggregation, the same curve.
public struct CurvePreview: Equatable, Sendable {
    /// The curve's input temperature from the latest readings (not smoothed).
    public var celsius: Double
    /// Speed the curve asks for at that temperature (before rates and hysteresis).
    public var percent: Double
    /// The fan's actual speed, when known.
    public var fanPercent: Double?

    /// The curve is at 0%, where its `idle` setting applies.
    public var atZero: Bool { percent < FanCurveHandoff.idleFraction * 100 }

    /// At 0% the daemon hands the fan to macOS (after a short delay).
    public var handsOffToSystem: Bool { atZero }

    public static func make(draft: CurveDraft, temperatures: [TemperatureDTO], fan: FanStatusDTO?) -> CurvePreview? {
        guard let celsius = input(spec: draft.spec, temperatures: temperatures) else { return nil }
        return CurvePreview(celsius: celsius, percent: draft.percent(at: celsius), fanPercent: fan.flatMap(PulseStore.percent))
    }

    /// `FanCurveEngine.aggregate` over the readings, as the daemon does it.
    public static func input(spec: FanCurveSpec, temperatures: [TemperatureDTO]) -> Double? {
        let samples = temperatures.map { FanTemperatureSample(sensor: $0.key, celsius: $0.celsius) }
        return try? FanCurveEngine.aggregate(samples: samples, sensors: spec.sensors, weights: spec.weights)
    }
}

/// Plain-language consequences of the response settings.
public enum ResponseSummary {
    public static func text(_ spec: FanCurveSpec, range: FanSpeedRange) -> String {
        var parts: [String] = []
        let rise = seconds(spec.riseRate, range: range)
        let fall = seconds(spec.fallRate, range: range)
        switch (rise, fall) {
        case (nil, nil): parts.append("The fan follows the curve immediately.")
        case (let r?, nil): parts.append("Minimum to full speed in \(r) s; slows down immediately.")
        case (nil, let f?): parts.append("Speeds up immediately; full speed to minimum in \(f) s.")
        case (let r?, let f?): parts.append("Minimum to full speed in \(r) s, back to minimum in \(f) s.")
        }
        if spec.hysteresisCelsius > 0 {
            parts.append("Slows down only once \(CurveSummary.number(spec.hysteresisCelsius)) °C cooler.")
        }
        if let smoothing = spec.smoothingSeconds, smoothing > 0 {
            parts.append("Ignores spikes shorter than about \(CurveSummary.number(smoothing)) s.")
        }
        return parts.joined(separator: " ")
    }

    /// Seconds to cross the whole range at `rate`, rounded.
    static func seconds(_ rate: FanRateValue?, range: FanSpeedRange) -> Int? {
        guard let rate else { return nil }
        let perSecond: Double
        switch rate {
        case .percentPerSecond(let v): perSecond = v
        case .rpmPerSecond(let v): perSecond = range.spanRPM > 0 ? v / range.spanRPM * 100 : 0
        }
        guard perSecond > 0 else { return nil }
        return Int((100 / perSecond).rounded())
    }
}
