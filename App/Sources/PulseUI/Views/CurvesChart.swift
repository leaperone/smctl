import Charts
import PolicyEngine
import SwiftUI

/// Fan speed (% of range) against temperature for one or more curves, computed
/// with the same `FanCurveSpec.resolve` the daemon uses.
public struct CurvesChart: View {
    public struct Series: Identifiable {
        public var name: String
        public var color: Color
        public var points: [(celsius: Double, percent: Double)]
        public var id: String { name }
    }

    let series: [Series]
    let temperatures: ClosedRange<Double>

    public init(specs: [(FanCurveSpec, Color)], temperatures: ClosedRange<Double> = 40...110) {
        self.temperatures = temperatures
        // Resolved on a 0–100 "RPM" range, so the values read directly as percent.
        let range = FanSpeedRange(minimumRPM: 0, maximumRPM: 100)
        series = specs.compactMap { spec, color in
            guard let curve = try? spec.resolve(for: range) else { return nil }
            let points = stride(from: temperatures.lowerBound, through: temperatures.upperBound, by: 0.5).map {
                (celsius: $0, percent: FanCurveEngine.interpolate(points: curve.points, temperature: $0))
            }
            return Series(name: spec.label ?? spec.name.capitalized, color: color, points: points)
        }
    }

    public var body: some View {
        Chart {
            ForEach(series) { line in
                ForEach(line.points, id: \.celsius) { point in
                    LineMark(
                        x: .value("Temperature", point.celsius),
                        y: .value("Fan speed", point.percent),
                        series: .value("Curve", line.name)
                    )
                    .foregroundStyle(by: .value("Curve", line.name))
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.color))
        .chartXScale(domain: temperatures)
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: .stride(by: 10)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)°C") }
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
            }
        }
        .chartXAxisLabel("Smoothed temperature (max of all sensors)")
        .chartYAxisLabel("Fan speed (% of the fan's range)")
        .chartLegend(position: .top, alignment: .leading)
    }
}

extension CurvesChart {
    /// Pulse's built-in presets in their app colors.
    public static var presets: CurvesChart {
        CurvesChart(specs: [
            (FanCurvePresets.silent, .indigo),
            (FanCurvePresets.balanced, .teal),
            (FanCurvePresets.performance, .orange)
        ])
    }
}
