import Charts
import SMCtlClient
import SMCtlProtocol
import SwiftUI

/// Heats the Mac under one curve and shows how it responds: temperatures, the
/// temperature the curve acts on and the fan speed, live, then a summary next
/// to the previous run of the same curve.
public struct StressTestSheet: View {
    @Bindable var model: StressTestModel
    /// The fan's range, for the speed axis; nil on Macs without one.
    let fanRange: ClosedRange<Double>?
    @Environment(\.dismiss) private var dismiss

    public init(model: StressTestModel, fanRange: ClosedRange<Double>?) {
        self.model = model
        self.fanRange = fanRange
    }

    private var plan: StressPlan { model.shownPlan }
    private var total: Double { Double(plan.loadSeconds + plan.coolSeconds) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            options
            StressCharts(samples: model.samples, previous: model.previous?.samples, loadSeconds: Double(plan.loadSeconds),
                         totalSeconds: total, fanRange: fanRange)
            status
            if model.state == .finished, let summary = model.summary {
                StressSummaryGrid(current: summary, previous: model.previous?.summary)
            }
            Divider()
            buttons
        }
        .padding(20)
        .frame(width: 640)
        .onDisappear { model.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stress Test: \(model.title)").font(.title3.weight(.semibold))
            Text("Heats every CPU core and the GPU to see how this curve responds, then records the cool-down. Your current profile comes back at the end.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var options: some View {
        HStack(spacing: 16) {
            Picker("Load", selection: $model.duration) {
                ForEach(StressTestModel.Duration.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Picker("Heat", selection: $model.load) {
                Text("CPU + GPU").tag(StressLoadKind.cpuAndGPU)
                Text("CPU").tag(StressLoadKind.cpu)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer()
            Text("then \(model.coolSeconds / 60) min of cool-down")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .disabled(model.isRunning)
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 16) {
            if let sample = model.samples.last, model.isRunning || model.state == .finished {
                Readout(title: "CPU", value: sample.cpuMaximum.map { String(format: "%.1f °C", $0) })
                Readout(title: "Curve", value: sample.curveEffective.map { String(format: "%.1f °C", $0) })
                Readout(title: "Fan", value: sample.fanRPM.map { rpm in
                    sample.handedToSystem ? "\(Int(rpm)) RPM · macOS" : "\(Int(rpm)) RPM · \(Int((sample.fanPercent ?? 0).rounded())) %"
                })
                Readout(title: "Power", value: sample.packageWatts.map { String(format: "%.1f W", $0) })
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                phaseText
                if model.isRunning, case .running = model.state {
                    ProgressView(value: min(model.elapsed, total), total: total)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .frame(width: 150)
                }
            }
        }
        .frame(minHeight: 36)
    }

    @ViewBuilder
    private var phaseText: some View {
        switch model.state {
        case .ready:
            Text(model.previous == nil ? "Ready." : "The previous run is drawn faded.")
                .font(.caption).foregroundStyle(.secondary)
        case .settling(let cpu, let target):
            Text("Waiting for the CPU to cool to \(Int(target)) °C\(cpu.map { " (now \(Int($0)) °C)" } ?? "")…")
                .font(.caption).foregroundStyle(.secondary)
        case .running(let phase):
            Text("\(phase == .load ? "Heating" : "Cooling down") · \(Self.clock(model.elapsed)) of \(Self.clock(total))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        case .stopping:
            Text("Stopping…").font(.caption).foregroundStyle(.secondary)
        case .finished:
            if let active = model.takenOverBy ?? model.result?.profileChange {
                Label("Stopped: the profile changed to \(active) during the test, so this run does not measure \(model.title) and is not kept for comparison.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
            } else if model.summary?.tripped == true {
                Label("The safety guard tripped: the fans went back to macOS.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text(model.result?.completed == false ? "Stopped early." : "Done. Adjust the curve, then run again to compare.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    private var buttons: some View {
        HStack {
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if model.isRunning {
                Button("Stop") { model.stop() }
                    .disabled(model.state == .stopping)
            } else {
                Button(model.samples.isEmpty ? "Start" : "Run Again") { model.start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct Readout: View {
    let title: String
    let value: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value ?? "—").font(.callout.monospacedDigit())
        }
    }
}

// MARK: - Charts

struct StressCharts: View {
    let samples: [StressSample]
    let previous: [StressSample]?
    let loadSeconds: Double
    let totalSeconds: Double
    let fanRange: ClosedRange<Double>?

    private var xDomain: ClosedRange<Double> { 0...max(totalSeconds, samples.last?.seconds ?? 0, 10) }

    private var temperatureDomain: ClosedRange<Double> {
        let values = (samples + (previous ?? [])).flatMap { [$0.cpuMaximum, $0.gpuMaximum, $0.curveEffective].compactMap { $0 } }
        let low = min((values.min() ?? 30) - 5, 30), high = max((values.max() ?? 90) + 5, 60)
        return (low / 10).rounded(.down) * 10...(high / 10).rounded(.up) * 10
    }

    private var fanDomain: ClosedRange<Double> {
        let rpms = (samples + (previous ?? [])).compactMap(\.fanRPM)
        // A fan stopped by the curve reads below its minimum.
        if let fanRange { return min(fanRange.lowerBound, rpms.min() ?? .infinity)...fanRange.upperBound }
        return 0...max(rpms.max() ?? 3000, 1000) * 1.1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                LegendDot(color: .orange, text: "CPU")
                LegendDot(color: .teal, text: "GPU")
                LegendDot(color: .purple, text: "Curve input, smoothed")
                LegendDot(color: .accentColor, text: "Fan")
                if previous != nil {
                    HStack(spacing: 3) {
                        Rectangle().fill(.secondary).frame(width: 10, height: 1.5)
                        Text("Previous run").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            temperatureChart.frame(height: 150)
            fanChart.frame(height: 80)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Temperatures and fan speed during the stress test")
    }

    private var temperatureChart: some View {
        Chart {
            loadEndRule
                .annotation(position: .trailing, alignment: .top, spacing: 4) {
                    Text("Heat off").font(.caption2).foregroundStyle(.secondary)
                }
            if let previous {
                ForEach(previous.indices, id: \.self) { i in
                    if let cpu = previous[i].cpuMaximum {
                        LineMark(x: .value("Time", previous[i].seconds), y: .value("°C", cpu), series: .value("Series", "CPU before"))
                            .foregroundStyle(Color.orange.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                }
            }
            ForEach(samples.indices, id: \.self) { i in
                let s = samples[i]
                if let gpu = s.gpuMaximum {
                    LineMark(x: .value("Time", s.seconds), y: .value("°C", gpu), series: .value("Series", "GPU"))
                        .foregroundStyle(.teal)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
                if let curve = s.curveEffective {
                    LineMark(x: .value("Time", s.seconds), y: .value("°C", curve), series: .value("Series", "Curve"))
                        .foregroundStyle(.purple)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                if let cpu = s.cpuMaximum {
                    LineMark(x: .value("Time", s.seconds), y: .value("°C", cpu), series: .value("Series", "CPU"))
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: temperatureDomain)
        .chartXAxis {
            AxisMarks(values: .stride(by: xStride)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { axisLabel("\(value.as(Int.self) ?? 0) °C") }
            }
        }
    }

    private var fanChart: some View {
        Chart {
            loadEndRule
            ForEach(samples.indices, id: \.self) { i in
                if let rpm = samples[i].fanRPM {
                    AreaMark(x: .value("Time", samples[i].seconds), yStart: .value("RPM", fanDomain.lowerBound), yEnd: .value("RPM", rpm))
                        .foregroundStyle(Color.accentColor.opacity(0.18).gradient)
                    LineMark(x: .value("Time", samples[i].seconds), y: .value("RPM", rpm), series: .value("Series", "Fan"))
                        .foregroundStyle(Color.accentColor)
                }
            }
            if let previous {
                ForEach(previous.indices, id: \.self) { i in
                    if let rpm = previous[i].fanRPM {
                        LineMark(x: .value("Time", previous[i].seconds), y: .value("RPM", rpm), series: .value("Series", "Fan before"))
                            .foregroundStyle(Color.secondary.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                }
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: fanDomain)
        .chartXAxis {
            AxisMarks(values: .stride(by: xStride)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { Text(StressTestSheet.clock(value.as(Double.self) ?? 0)).font(.caption2) }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { axisLabel("\(value.as(Int.self) ?? 0) RPM") }
            }
        }
    }

    private var xStride: Double { totalSeconds > 300 ? 60 : 30 }

    /// Same width on both charts, so their plot areas line up.
    private func axisLabel(_ text: String) -> some View {
        Text(text).font(.caption2).monospacedDigit().frame(width: 58, alignment: .trailing)
    }

    @ChartContentBuilder
    private var loadEndRule: some ChartContent {
        RuleMark(x: .value("Load stops", loadSeconds))
            .foregroundStyle(.secondary.opacity(0.5))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
    }
}

// MARK: - Summary

struct StressSummaryGrid: View {
    let current: StressSummary
    let previous: StressSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    Text("")
                    Text("This run").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if previous != nil { Text("Previous").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                }
                row("CPU, steady") { $0.steadyCPU.map(Self.celsius) }
                row("CPU, peak") { $0.peakCPU.map(Self.celsius) }
                row("Fan, steady") { s in s.steadyRPM.map { "\(Int($0)) RPM\(s.steadySpreadRPM.map { " ± \(Int($0.rounded()))" } ?? "")" } }
                row("Fan, peak") { s in "\(Int(s.peakRPM)) RPM\(s.peakPercent.map { " (\(Int($0.rounded())) %)" } ?? "")" }
                row("Speeds up") { s in s.rampSeconds.map { "at \(StressTestSheet.clock($0))\(s.rampCPU.map { ", \(Int($0)) °C" } ?? "")" } ?? "never" }
                row("Back to rest") { s in s.restSeconds.map { "\(StressTestSheet.clock($0)) after" } ?? (s.returnedToRest ? "—" : "not yet") }
            }
            .font(.callout)
            Text("Steady: the last 30 s of heating. A large ± means the fan hunts: add smoothing or hysteresis, or slow its fall.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ title: String, _ value: @escaping (StressSummary) -> String?) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value(current) ?? "—").monospacedDigit()
            if let previous { Text(value(previous) ?? "—").monospacedDigit().foregroundStyle(.secondary) }
        }
    }

    static func celsius(_ value: Double) -> String { String(format: "%.1f °C", value) }
}
