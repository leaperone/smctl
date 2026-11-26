import PolicyEngine
import SwiftUI

/// Sensors and response settings of a user curve, each change undoable.
struct CurveSettingsForm: View {
    @Bindable var model: CurveEditorModel
    /// The daemon allows stopping fans (`[safety] allow_below_minimum = true`).
    var allowsStopping = false

    private var draft: CurveDraft { model.draft }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    label("Sensors")
                    HStack(spacing: 14) {
                        ForEach(SensorGroup.allCases) { group in
                            Toggle(group.title, isOn: sensorBinding(group))
                                .toggleStyle(.checkbox)
                        }
                        if !draft.customSensors.isEmpty {
                            Text("+ \(draft.customSensors.joined(separator: ", "))")
                                .foregroundStyle(.secondary)
                                .help("Keys from the config file, kept as they are")
                        }
                        Spacer(minLength: 8)
                        Picker("Use", selection: aggregationBinding) {
                            ForEach(SensorAggregation.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    .gridCellColumns(3)
                }
                GridRow {
                    label("Speed up")
                    valueStepper(rateText(draft.riseRatePercent), value: draft.riseRatePercent ?? 0, range: 0...50, step: 1) { value in
                        model.edit("Change Speed-Up Rate") { $0.setRiseRate(percentPerSecond: value > 0 ? value : nil) }
                    }
                    label("Slow down")
                    valueStepper(rateText(draft.fallRatePercent), value: draft.fallRatePercent ?? 0, range: 0...50, step: 1) { value in
                        model.edit("Change Slow-Down Rate") { $0.setFallRate(percentPerSecond: value > 0 ? value : nil) }
                    }
                }
                if draft.spec.reachesZero {
                    GridRow {
                        label("At 0 %")
                        Picker("At 0 %", selection: Binding(get: { draft.spec.idle }, set: { idle in
                            model.edit("Change Behaviour at 0 %") { $0.setIdle(idle) }
                        })) {
                            Text("macOS decides").tag(FanCurveIdle.system)
                            Text("Minimum speed").tag(FanCurveIdle.minimum)
                            Text("Stopped (experimental)").tag(FanCurveIdle.off)
                        }
                        .labelsHidden()
                        .fixedSize()
                        .gridCellColumns(3)
                    }
                }
                GridRow {
                    label("Hysteresis")
                    valueStepper(draft.spec.hysteresisCelsius > 0 ? "\(CurveSummary.number(draft.spec.hysteresisCelsius)) °C" : "None",
                                 value: draft.spec.hysteresisCelsius, range: 0...20, step: 0.5) { value in
                        model.edit("Change Hysteresis") { $0.setHysteresis(value) }
                    }
                    label("Smoothing")
                    valueStepper((draft.spec.smoothingSeconds ?? 0) > 0 ? "\(CurveSummary.number(draft.spec.smoothingSeconds ?? 0)) s" : "None",
                                 value: draft.spec.smoothingSeconds ?? 0, range: 0...60, step: 1) { value in
                        model.edit("Change Smoothing") { $0.setSmoothing(seconds: value) }
                    }
                }
            }
            if draft.spec.reachesZero && draft.spec.idle == .off {
                Label {
                    Text(stopWarning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
            Text(ResponseSummary.text(draft.spec, range: draft.range)
                 + (draft.sensorGroups.isEmpty && draft.customSensors.isEmpty ? " No sensor checked: every sensor counts." : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    private var stopWarning: String {
        var text = "Forcing the fan to stop may harm your Mac, especially a Mac mini, whose fan macOS never stops. "
            + "Pulse restarts it above \(Int(FanCurveHandoff.stopChipLimitCelsius)) °C (CPU, GPU) or \(Int(FanCurveHandoff.stopOtherLimitCelsius)) °C (other sensors)."
        if !allowsStopping {
            text += " Not enabled yet: add allow_below_minimum = true under [safety] in /etc/pulse/config.toml, then run pulse daemon restart. Until then, macOS runs the fan at 0 %."
        }
        return text
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }

    private func sensorBinding(_ group: SensorGroup) -> Binding<Bool> {
        Binding {
            draft.sensorGroups.contains(group)
        } set: { on in
            var groups = draft.sensorGroups
            if on { groups.insert(group) } else { groups.remove(group) }
            model.edit("Change Sensors") { $0.setSensorGroups(groups) }
        }
    }

    private var aggregationBinding: Binding<SensorAggregation> {
        Binding {
            draft.aggregation
        } set: { aggregation in
            model.edit("Change Sensors") { $0.setAggregation(aggregation) }
        }
    }

    private func rateText(_ value: Double?) -> String {
        (value ?? 0) > 0 ? "\(CurveSummary.number(value ?? 0)) %/s" : "Immediate"
    }

    /// A value followed by its stepper arrows, sized so columns line up.
    private func valueStepper(_ text: String, value: Double, range: ClosedRange<Double>, step: Double,
                              set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
            Stepper(text, value: Binding(get: { value }, set: set), in: range, step: step)
                .labelsHidden()
        }
    }
}
