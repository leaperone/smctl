import Foundation
import PolicyEngine

/// Sensor groups the editor offers; an empty selection means every sensor.
public enum SensorGroup: String, CaseIterable, Identifiable, Sendable {
    case cpu = "Tp*"
    case gpu = "Tg*"
    case enclosure = "Ts*"

    public var id: String { rawValue }
    public var pattern: String { rawValue }
    public var title: String { SensorGroupName.title(for: rawValue) }
}

/// How the selected sensors become one temperature.
public enum SensorAggregation: String, CaseIterable, Identifiable, Sendable {
    /// The hottest sensor (smctl's default, and every preset's).
    case hottest
    /// The average of the selected sensors.
    case average

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .hottest: return "Hottest sensor"
        case .average: return "Average"
        }
    }
}

/// The two ends of a shape's ramp.
public enum CurveHandle: Sendable {
    /// (start °C, minimum %).
    case start
    /// (end °C, maximum %).
    case end
}

/// A curve being edited. A value type with no UI: every operation keeps the
/// spec valid (clamping instead of failing), so the editor can never produce a
/// curve the daemon would reject, and undo is a matter of keeping old values.
/// Speeds are percent of the fan's range (0–100) throughout.
public struct CurveDraft: Equatable, Sendable {
    public static let temperatureRange: ClosedRange<Double> = 30...110
    /// Narrowest ramp, so start and end handles never cross.
    public static let minimumRampWidth = 2.0
    /// Closest two points may be, in °C.
    public static let minimumPointGap = 0.5
    public static let maximumPoints = 24

    public private(set) var spec: FanCurveSpec
    public let original: FanCurveSpec
    /// The fan range used to show and convert RPM values in hand-written point curves.
    public let range: FanSpeedRange

    public init(_ spec: FanCurveSpec, range: FanSpeedRange = FanSpeedRange(minimumRPM: 0, maximumRPM: 100)) {
        self.spec = spec
        self.original = spec
        self.range = range
    }

    public var isDirty: Bool { spec != original }

    /// Why the daemon would reject this curve, if it would.
    public var validationError: String? {
        do {
            try spec.validate()
            return nil
        } catch let error as PolicyError {
            if case .invalidFanCurve(let message) = error { return message }
            return String(describing: error)
        } catch {
            return error.localizedDescription
        }
    }

    /// Replaces the whole spec (undo, reload); the original is kept.
    public mutating func restore(_ spec: FanCurveSpec) {
        self.spec = spec
    }

    public mutating func revert() {
        spec = original
    }

    // MARK: Label

    public mutating func setLabel(_ text: String) {
        spec.label = CurveNaming.cleanLabel(text)
    }

    // MARK: Shape

    public var isPoints: Bool { spec.shape == nil }

    /// Switches family, keeping the ramp. From points, the ramp spans the first
    /// and last points.
    public mutating func setKind(_ kind: FanCurveShapeKind) {
        if let shape = spec.shape {
            guard shape.kind != kind else { return }
            spec.shape = Self.makeShape(kind: kind, start: shape.startCelsius, end: shape.endCelsius,
                                        minimum: shape.minimumFraction, maximum: shape.maximumFraction,
                                        steepness: nil, stepCount: shape.stepCount)
        } else {
            let points = percentPoints
            let first = points.first ?? (Self.temperatureRange.lowerBound, 0)
            let last = points.last ?? (Self.temperatureRange.upperBound, 100)
            let low = min(first.percent, last.percent) / 100
            let high = max(first.percent, last.percent) / 100
            let start = Self.clampTemperature(first.celsius)
            let end = max(start + Self.minimumRampWidth, Self.clampTemperature(last.celsius))
            spec.shape = Self.makeShape(kind: kind, start: min(start, Self.temperatureRange.upperBound - Self.minimumRampWidth),
                                        end: min(end, Self.temperatureRange.upperBound),
                                        minimum: low, maximum: high, steepness: nil, stepCount: 4)
            spec.points = []
        }
    }

    /// Position of a ramp handle as (°C, %).
    public func handle(_ handle: CurveHandle) -> (celsius: Double, percent: Double)? {
        guard let shape = spec.shape else { return nil }
        switch handle {
        case .start: return (shape.startCelsius, shape.minimumFraction * 100)
        case .end: return (shape.endCelsius, shape.maximumFraction * 100)
        }
    }

    /// Moves a ramp handle; values are clamped so the ramp stays valid
    /// (start below end by at least `minimumRampWidth`, minimum ≤ maximum).
    public mutating func moveHandle(_ handle: CurveHandle, celsius: Double, percent: Double) {
        guard let shape = spec.shape, celsius.isFinite, percent.isFinite else { return }
        let fraction = min(1, max(0, percent / 100))
        var start = shape.startCelsius, end = shape.endCelsius
        var low = shape.minimumFraction, high = shape.maximumFraction
        let range = Self.temperatureRange
        switch handle {
        case .start:
            start = min(max(celsius, range.lowerBound), end - Self.minimumRampWidth)
            low = min(fraction, high)
        case .end:
            end = max(min(celsius, range.upperBound), start + Self.minimumRampWidth)
            high = max(fraction, low)
        }
        spec.shape = Self.makeShape(kind: shape.kind, start: Self.round(start), end: Self.round(end),
                                    minimum: Self.round(low * 100) / 100, maximum: Self.round(high * 100) / 100,
                                    steepness: shape.steepness, stepCount: shape.stepCount)
    }

    public mutating func setSteepness(_ value: Double) {
        guard let shape = spec.shape, value.isFinite else { return }
        let steepness = min(FanCurveShape.maximumSteepness, max(0, (value * 10).rounded() / 10))
        spec.shape = Self.makeShape(kind: shape.kind, start: shape.startCelsius, end: shape.endCelsius,
                                    minimum: shape.minimumFraction, maximum: shape.maximumFraction,
                                    steepness: steepness, stepCount: shape.stepCount)
    }

    public mutating func setStepCount(_ count: Int) {
        guard let shape = spec.shape else { return }
        spec.shape = Self.makeShape(kind: shape.kind, start: shape.startCelsius, end: shape.endCelsius,
                                    minimum: shape.minimumFraction, maximum: shape.maximumFraction,
                                    steepness: shape.steepness,
                                    stepCount: min(FanCurveShape.maximumStepCount, max(1, count)))
    }

    // MARK: Points

    /// Points as (°C, %), sorted. RPM and `max` values are converted with `range`.
    public var percentPoints: [(celsius: Double, percent: Double)] {
        spec.points
            .map { ($0.celsius, percent(of: $0.speed)) }
            .sorted { $0.0 < $1.0 }
            .map { (celsius: $0.0, percent: $0.1) }
    }

    func percent(of speed: FanSpeedValue) -> Double {
        switch speed {
        case .percent(let value): return min(100, max(0, value))
        case .maximum: return 100
        case .rpm(let rpm): return range.fraction(forRPM: rpm) * 100
        }
    }

    /// Replaces the shape with editable points that follow it within ~1% of
    /// full speed: the ramp's ends plus the points where the shape bends most
    /// (twice the step count plus one for steps, so plateaus stay exact).
    public mutating func convertToPoints(count: Int = 10) {
        guard let shape = spec.shape else { return }
        let chosen: [(celsius: Double, percent: Double)]
        if shape.kind == .steps {
            // Plateaus joined by risers `minimumPointGap` wide (the compiled
            // risers are narrower than the editor allows between two points).
            let span = shape.endCelsius - shape.startCelsius
            let level = { (step: Int) in
                (shape.minimumFraction + (shape.maximumFraction - shape.minimumFraction) * Double(step) / Double(shape.stepCount)) * 100
            }
            var points = [(celsius: shape.startCelsius, percent: level(0))]
            for step in 1...shape.stepCount {
                let edge = shape.startCelsius + span * Double(step) / Double(shape.stepCount)
                points.append((edge - Self.minimumPointGap, level(step - 1)))
                points.append((edge, level(step)))
            }
            chosen = Array(points.prefix(Self.maximumPoints))
        } else {
            let dense = shape.compiledPoints(initialSegments: 64, tolerance: 0.001, maximumPoints: 400)
                .map { (celsius: $0.celsius, percent: $0.fraction * 100) }
            chosen = Self.simplify(dense, count: min(Self.maximumPoints, max(2, count)))
        }
        spec.shape = nil
        spec.points = chosen.map { FanCurveSpecPoint(Self.round($0.celsius), .percent(Self.round($0.percent))) }
        normalizePoints()
    }

    /// Moves point `index` (in sorted order); it stays between its neighbours.
    /// Point operations apply to point curves only: convert a shape first.
    public mutating func movePoint(at index: Int, celsius: Double, percent: Double) {
        guard isPoints else { return }
        var points = percentPoints
        guard points.indices.contains(index), celsius.isFinite, percent.isFinite else { return }
        let lower = index > 0 ? points[index - 1].celsius + Self.minimumPointGap : Self.temperatureRange.lowerBound
        let upper = index < points.count - 1 ? points[index + 1].celsius - Self.minimumPointGap : Self.temperatureRange.upperBound
        guard lower <= upper else { return }
        points[index] = (Self.round(min(max(celsius, lower), upper)), Self.round(min(100, max(0, percent))))
        setPoints(points)
    }

    /// Adds a point and returns its index, or nil when there is no room (too
    /// close to another point, or already `maximumPoints`).
    @discardableResult
    public mutating func addPoint(celsius: Double, percent: Double) -> Int? {
        guard isPoints else { return nil }
        var points = percentPoints
        let celsius = Self.round(Self.clampTemperature(celsius))
        guard points.count < Self.maximumPoints, celsius.isFinite, percent.isFinite,
              !points.contains(where: { abs($0.celsius - celsius) < Self.minimumPointGap }) else { return nil }
        points.append((celsius, Self.round(min(100, max(0, percent)))))
        points.sort { $0.celsius < $1.celsius }
        setPoints(points)
        return points.firstIndex { $0.celsius == celsius }
    }

    /// Removes point `index`; a curve keeps at least two points.
    public mutating func removePoint(at index: Int) {
        guard isPoints else { return }
        var points = percentPoints
        guard points.count > 2, points.indices.contains(index) else { return }
        points.remove(at: index)
        setPoints(points)
    }

    private mutating func setPoints(_ points: [(celsius: Double, percent: Double)]) {
        spec.shape = nil
        spec.points = points.map { FanCurveSpecPoint($0.celsius, .percent($0.percent)) }
    }

    /// Sorts, clamps and de-duplicates points (hand-written configs may not).
    private mutating func normalizePoints() {
        var result: [(celsius: Double, percent: Double)] = []
        for point in percentPoints {
            let celsius = Self.clampTemperature(point.celsius)
            if let last = result.last, celsius - last.celsius < Self.minimumPointGap { continue }
            result.append((celsius, point.percent))
        }
        if result.count < 2 {
            result = [(Self.temperatureRange.lowerBound, result.first?.percent ?? 0), (Self.temperatureRange.upperBound, 100)]
        }
        setPoints(result)
    }

    // MARK: Inputs and response

    /// Selected sensor groups; empty means every sensor.
    public var sensorGroups: Set<SensorGroup> {
        Set(spec.sensors.compactMap(SensorGroup.init(rawValue:)))
    }

    /// Sensor keys or patterns that are not one of the editor's groups
    /// (hand-written configs); kept untouched.
    public var customSensors: [String] {
        spec.sensors.filter { SensorGroup(rawValue: $0) == nil }
    }

    public mutating func setSensorGroups(_ groups: Set<SensorGroup>) {
        spec.sensors = SensorGroup.allCases.filter(groups.contains).map(\.pattern) + customSensors
        applyAggregation(aggregation)
    }

    public var aggregation: SensorAggregation {
        spec.weights.isEmpty ? .hottest : .average
    }

    public mutating func setAggregation(_ aggregation: SensorAggregation) {
        applyAggregation(aggregation)
    }

    /// Average = equal weights on the selected patterns (or every sensor).
    private mutating func applyAggregation(_ aggregation: SensorAggregation) {
        switch aggregation {
        case .hottest:
            spec.weights = [:]
        case .average:
            let keys = spec.sensors.isEmpty ? ["*"] : spec.sensors
            spec.weights = Dictionary(uniqueKeysWithValues: keys.map { ($0, 1.0) })
        }
    }

    public mutating func setHysteresis(_ celsius: Double) {
        guard celsius.isFinite else { return }
        spec.hysteresisCelsius = Self.round(min(20, max(0, celsius)))
    }

    /// Rise rate in % of the fan's range per second; nil means immediate.
    public var riseRatePercent: Double? { percentRate(spec.riseRate) }
    public var fallRatePercent: Double? { percentRate(spec.fallRate) }

    public mutating func setRiseRate(percentPerSecond value: Double?) {
        spec.riseRate = Self.rate(value)
    }

    public mutating func setFallRate(percentPerSecond value: Double?) {
        spec.fallRate = Self.rate(value)
    }

    public mutating func setSmoothing(seconds: Double?) {
        guard let seconds, seconds.isFinite, seconds > 0 else {
            spec.smoothingSeconds = nil
            return
        }
        spec.smoothingSeconds = Self.round(min(120, seconds))
    }

    private func percentRate(_ value: FanRateValue?) -> Double? {
        switch value {
        case .percentPerSecond(let v): return v
        case .rpmPerSecond(let v): return range.spanRPM > 0 ? v / range.spanRPM * 100 : nil
        case nil: return nil
        }
    }

    private static func rate(_ value: Double?) -> FanRateValue? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return .percentPerSecond(round(min(100, value)))
    }

    // MARK: Evaluation

    /// Fan speed (%) the curve asks for at `celsius`, before hysteresis and rates.
    public func percent(at celsius: Double) -> Double {
        if let shape = spec.shape {
            return shape.fraction(at: celsius) * 100
        }
        let points = percentPoints
        guard let first = points.first, let last = points.last else { return 0 }
        if celsius <= first.celsius { return first.percent }
        if celsius >= last.celsius { return last.percent }
        for (a, b) in zip(points, points.dropFirst()) where celsius <= b.celsius {
            let t = (celsius - a.celsius) / (b.celsius - a.celsius)
            return a.percent + (b.percent - a.percent) * t
        }
        return last.percent
    }

    /// The curve's vertices across `temperatureRange`, for drawing: the
    /// shape's adaptive compilation (within 0.5% of full speed) or the points,
    /// extended flat to both ends. About 20–40 vertices instead of a dense grid.
    public var outline: [(celsius: Double, percent: Double)] {
        var vertices: [(celsius: Double, percent: Double)]
        if let shape = spec.shape {
            vertices = shape.compiledPoints().map { (celsius: $0.celsius, percent: $0.fraction * 100) }
        } else {
            vertices = percentPoints
        }
        guard let first = vertices.first, let last = vertices.last else { return [] }
        let range = Self.temperatureRange
        vertices = vertices.filter { range.contains($0.celsius) }
        if first.celsius > range.lowerBound || vertices.first?.celsius != range.lowerBound {
            vertices.insert((range.lowerBound, percent(at: range.lowerBound)), at: 0)
        }
        if last.celsius < range.upperBound || vertices.last?.celsius != range.upperBound {
            vertices.append((range.upperBound, percent(at: range.upperBound)))
        }
        return vertices
    }

    // MARK: Helpers

    static func makeShape(kind: FanCurveShapeKind, start: Double, end: Double, minimum: Double, maximum: Double,
                          steepness: Double?, stepCount: Int) -> FanCurveShape {
        // Inputs are clamped by the callers; fall back to a linear ramp rather
        // than crash if a hand-written config was out of range.
        (try? FanCurveShape(kind: kind, startCelsius: start, endCelsius: end, minimumFraction: minimum,
                            maximumFraction: maximum, steepness: steepness, stepCount: stepCount))
            ?? (try! FanCurveShape(kind: .linear, startCelsius: 60, endCelsius: 100))
    }

    static func clampTemperature(_ celsius: Double) -> Double {
        min(max(celsius, temperatureRange.lowerBound), temperatureRange.upperBound)
    }

    /// One decimal: what the editor shows and the TOML stores.
    static func round(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    /// Greedy simplification: keeps the ends, then repeatedly adds the point
    /// farthest from the current piecewise-linear approximation.
    static func simplify(_ points: [(celsius: Double, percent: Double)], count: Int) -> [(celsius: Double, percent: Double)] {
        guard points.count > count, count >= 2 else { return points }
        var kept: Set<Int> = [0, points.count - 1]
        while kept.count < count {
            let sorted = kept.sorted()
            var best: (index: Int, error: Double)?
            for (a, b) in zip(sorted, sorted.dropFirst()) where b - a > 1 {
                for i in (a + 1)..<b {
                    let t = (points[i].celsius - points[a].celsius) / (points[b].celsius - points[a].celsius)
                    let error = abs(points[i].percent - (points[a].percent + (points[b].percent - points[a].percent) * t))
                    if error > (best?.error ?? -1) { best = (i, error) }
                }
            }
            guard let best, best.error > 1e-6 else { break }
            kept.insert(best.index)
        }
        return kept.sorted().map { points[$0] }
    }
}
