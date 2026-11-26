import Charts
import PolicyEngine
import SwiftUI

/// Editor for a user curve: shape picker, interactive chart and shape controls.
public struct CurveEditor: View {
    @Bindable var model: CurveEditorModel
    @Binding var unit: FanSpeedUnit
    let hasFanRange: Bool
    let preview: CurvePreview?
    /// False for presets: same chart and live readout, no handles or controls.
    let editable: Bool

    public init(model: CurveEditorModel, unit: Binding<FanSpeedUnit>, hasFanRange: Bool, preview: CurvePreview? = nil, editable: Bool = true) {
        self.model = model
        self._unit = unit
        self.hasFanRange = hasFanRange
        self.preview = preview
        self.editable = editable
    }

    private var draft: CurveDraft { model.draft }

    /// nil stands for "Points".
    private var kindSelection: Binding<FanCurveShapeKind?> {
        Binding {
            draft.spec.shape?.kind
        } set: { kind in
            model.setKind(kind)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if editable {
            HStack {
                Picker("Shape", selection: kindSelection) {
                    ForEach(FanCurveShapeKind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(Optional(kind))
                    }
                    Text("Points").tag(FanCurveShapeKind?.none)
                }
                .pickerStyle(.menu)
                .fixedSize()
                Spacer(minLength: 12)
                shapeControl
            }
            }
            EditableCurveChart(model: model, unit: hasFanRange ? unit : .percent, preview: preview, editable: editable)
                .frame(height: 240)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    if let preview {
                        Text(readout(preview))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                            .monospacedDigit()
                    }
                    if editable {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if hasFanRange {
                    Picker("Speed unit", selection: $unit) {
                        Text("%").tag(FanSpeedUnit.percent)
                        Text("RPM").tag(FanSpeedUnit.rpm)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var shapeControl: some View {
        if let shape = draft.spec.shape {
            switch shape.kind {
            case .linear:
                EmptyView()
            case .steps:
                Stepper(value: Binding(get: { shape.stepCount }, set: { count in
                    model.edit("Change Steps") { $0.setStepCount(count) }
                }), in: 1...FanCurveShape.maximumStepCount) {
                    Text("\(shape.stepCount) steps").monospacedDigit()
                }
                .fixedSize()
            default:
                HStack(spacing: 8) {
                    Text("Steepness").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { shape.steepness }, set: { value in
                        model.edit("Change Steepness") { $0.setSteepness(value) }
                    }), in: 0.5...20)
                    .frame(width: 140)
                    Text(String(format: "%.1f", shape.steepness))
                        .monospacedDigit()
                        .frame(width: 32, alignment: .trailing)
                }
                .font(.callout)
            }
        }
    }

    private func speed(_ percent: Double) -> String {
        let text = "\(Int(percent.rounded())) %"
        guard hasFanRange else { return text }
        return "\(text) (\(Format.rpm(model.draft.range.rpm(forFraction: percent / 100))) RPM)"
    }

    private func readout(_ preview: CurvePreview) -> String {
        var text = preview.handsOffToSystem
            ? "Now \(Int(preview.celsius.rounded())) °C → 0 %, macOS runs the fan"
            : "Now \(Int(preview.celsius.rounded())) °C → this curve asks \(speed(preview.percent))"
        if let fan = preview.fanPercent {
            text += " · fan at \(speed(fan))"
        }
        return text
    }

    private var hint: String {
        draft.isPoints
            ? "Drag a point to move it. Double-click to add one; select it and press Delete to remove it."
            : "Drag the two handles to set where the ramp starts and ends. Double-click to switch to free points."
    }
}

/// The curve with draggable handles. Data is in (°C, % of the fan's range);
/// the speed axis can be labelled in RPM.
struct EditableCurveChart: View {
    @Bindable var model: CurveEditorModel
    let unit: FanSpeedUnit
    var preview: CurvePreview?
    var editable = true
    @State private var hovered: EditorHandle?
    @FocusState private var focused: Bool

    static let temperatures = CurveDraft.temperatureRange

    private var line: [(celsius: Double, percent: Double)] { model.draft.outline }

    /// Plot area of the axes layer, in this view's coordinates.
    @State private var plotRect: CGRect = .zero

    /// Two layers: the axes and grid (which never change while dragging) and,
    /// on top and aligned to the axes' plot area, the curve and handles with
    /// no axes. Swift Charts recomputes every axis label whenever any mark
    /// changes; splitting the layers halves the cost of each drag frame.
    var body: some View {
        CurveAxes(unit: unit, range: model.draft.range)
            .equatable()
            .onPreferenceChange(PlotRectKey.self) { plotRect = $0 }
            .overlay(alignment: .topLeading) {
                marks
                    .frame(width: max(0, plotRect.width), height: max(0, plotRect.height))
                    .offset(x: plotRect.minX, y: plotRect.minY)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onDeleteCommand { model.deleteSelectedPoint() }
            .onKeyPress(.delete) {
                model.deleteSelectedPoint()
                return .handled
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Fan curve")
    }

    private var marks: some View {
        let handles = model.handles
        return Chart {
            ForEach(line, id: \.celsius) { point in
                AreaMark(x: .value("Temperature", point.celsius), y: .value("Fan speed", point.percent))
                    .foregroundStyle(Color.accentColor.opacity(0.12))
                LineMark(x: .value("Temperature", point.celsius), y: .value("Fan speed", point.percent))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            if let preview, CurveDraft.temperatureRange.contains(preview.celsius) {
                RuleMark(x: .value("Now", preview.celsius))
                    .foregroundStyle(.orange.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                PointMark(x: .value("Now", preview.celsius), y: .value("Fan speed", preview.percent))
                    .symbolSize(70)
                    .foregroundStyle(.orange)
            }
            ForEach(editable ? handles : [], id: \.handle) { item in
                PointMark(x: .value("Temperature", item.celsius), y: .value("Fan speed", item.percent))
                    .symbolSize(symbolSize(for: item.handle))
                    .foregroundStyle(isSelected(item.handle) ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                PointMark(x: .value("Temperature", item.celsius), y: .value("Fan speed", item.percent))
                    .symbol(Circle().strokeBorder(lineWidth: 2))
                    .symbolSize(symbolSize(for: item.handle))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .chartXScale(domain: Self.temperatures)
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            if editable {
                overlay(proxy: proxy, handles: handles)
            }
        }
    }

    private func overlay(proxy: ChartProxy, handles: [(handle: EditorHandle, celsius: Double, percent: Double)]) -> some View {
            GeometryReader { geometry in
                let plot = proxy.plotFrame.map { geometry[$0] } ?? .zero
                let positions = handles.compactMap { item -> (EditorHandle, CGPoint)? in
                    proxy.position(for: (x: item.celsius, y: item.percent)).map {
                        (item.handle, CGPoint(x: $0.x + plot.minX, y: $0.y + plot.minY))
                    }
                }
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle().inset(by: -12))
                    .gesture(dragGesture(proxy: proxy, plot: plot, positions: positions))
                    .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
                        if let value = values(at: tap.location, proxy: proxy, plot: plot) {
                            model.addPoint(celsius: value.celsius, percent: value.percent)
                        }
                    })
                    .simultaneousGesture(SpatialTapGesture(count: 1).onEnded { tap in
                        focused = true
                        if case .point(let index)? = CurveEditorModel.nearest(to: tap.location, in: positions) {
                            model.selectedPoint = index
                        } else {
                            model.selectedPoint = nil
                        }
                    })
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): hovered = CurveEditorModel.nearest(to: location, in: positions)
                        case .ended: hovered = nil
                        }
                    }
                    .pointerStyle(model.dragging != nil ? .grabActive : (hovered != nil ? .grabIdle : nil))
                accessibilityHandles(positions: positions)
            }
    }

    // MARK: Gestures

    private func dragGesture(proxy: ChartProxy, plot: CGRect, positions: [(EditorHandle, CGPoint)]) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { drag in
                if model.dragging == nil {
                    guard let handle = CurveEditorModel.nearest(to: drag.startLocation, in: positions) else { return }
                    focused = true
                    model.beginDrag(handle)
                }
                if let value = values(at: drag.location, proxy: proxy, plot: plot, clamped: true) {
                    model.drag(to: value.celsius, percent: value.percent)
                }
            }
            .onEnded { _ in model.endDrag() }
    }

    private func values(at location: CGPoint, proxy: ChartProxy, plot: CGRect, clamped: Bool = false) -> (celsius: Double, percent: Double)? {
        var point = CGPoint(x: location.x - plot.minX, y: location.y - plot.minY)
        if clamped {
            point.x = min(max(point.x, 0), plot.width)
            point.y = min(max(point.y, 0), plot.height)
        } else if !CGRect(origin: .zero, size: plot.size).contains(point) {
            return nil
        }
        guard let celsius: Double = proxy.value(atX: point.x), let percent: Double = proxy.value(atY: point.y) else { return nil }
        return (celsius, percent)
    }

    // MARK: Appearance

    private func isSelected(_ handle: EditorHandle) -> Bool {
        if case .point(let index) = handle { return model.selectedPoint == index }
        return false
    }

    private func symbolSize(for handle: EditorHandle) -> CGFloat {
        handle == model.dragging || handle == hovered ? 200 : 110
    }

    /// Multiples of 1000 RPM (500 for narrow ranges) inside the range, as %.
    static func rpmTicks(_ range: FanSpeedRange) -> [Double] {
        guard range.spanRPM > 0 else { return [0, 100] }
        let step: Double = range.spanRPM < 2000 ? 500 : 1000
        let first = (range.minimumRPM / step).rounded(.up) * step
        return stride(from: first, through: range.maximumRPM, by: step).map { range.fraction(forRPM: $0) * 100 }
    }

    private func describe(_ handle: EditorHandle, celsius: Double, percent: Double) -> String {
        let speed = unit == .rpm ? "\(Format.rpm(model.draft.range.rpm(forFraction: percent / 100))) RPM" : "\(Int(percent.rounded())) %"
        return "\(Int(celsius.rounded())) °C, \(speed)"
    }

    // MARK: Accessibility

    /// One adjustable element per handle: increment/decrement change the
    /// temperature by 1 °C; custom actions change the speed.
    private func accessibilityHandles(positions: [(EditorHandle, CGPoint)]) -> some View {
        ForEach(model.handles, id: \.handle) { item in
            let position = positions.first { $0.0 == item.handle }?.1 ?? .zero
            Color.clear
                .frame(width: 24, height: 24)
                .position(position)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel(name(of: item.handle))
                .accessibilityValue(describe(item.handle, celsius: item.celsius, percent: item.percent))
                .accessibilityAdjustableAction { direction in
                    nudge(item.handle, celsius: direction == .increment ? 1 : -1, percent: 0)
                }
                .accessibilityAction(named: "Faster") { nudge(item.handle, celsius: 0, percent: 1) }
                .accessibilityAction(named: "Slower") { nudge(item.handle, celsius: 0, percent: -1) }
        }
    }

    private func name(of handle: EditorHandle) -> String {
        switch handle {
        case .start: return "Ramp start"
        case .end: return "Ramp end"
        case .point(let index): return "Point \(index + 1)"
        }
    }

    private func nudge(_ handle: EditorHandle, celsius: Double, percent: Double) {
        guard let item = model.handles.first(where: { $0.handle == handle }) else { return }
        model.beginDrag(handle)
        model.drag(to: item.celsius + celsius, percent: item.percent + percent)
        model.endDrag()
    }
}

/// The editor's axes and grid, with no data: equal inputs mean SwiftUI skips
/// it entirely while a handle is dragged. Reports its plot area so the marks
/// layer can be laid exactly on top.
struct CurveAxes: View, Equatable {
    let unit: FanSpeedUnit
    let range: FanSpeedRange

    private var speedTicks: [Double] {
        unit == .rpm ? EditableCurveChart.rpmTicks(range) : [0, 25, 50, 75, 100]
    }

    private func speedLabel(_ percent: Double) -> String {
        if unit == .rpm {
            return Format.rpm((range.rpm(forFraction: percent / 100) / 10).rounded() * 10)
        }
        return "\(Int(percent))%"
    }

    /// The built-in presets, drawn faintly for reference.
    static let ghosts: [(name: String, outline: [(celsius: Double, percent: Double)])] =
        FanCurvePresets.all.map { ($0.label ?? $0.name, CurveDraft($0).outline) }

    var body: some View {
        Chart {
            // Charts draws nothing (not even axes) for an empty chart.
            PointMark(x: .value("Temperature", CurveDraft.temperatureRange.lowerBound), y: .value("Fan speed", 0))
                .opacity(0)
            ForEach(Self.ghosts, id: \.name) { ghost in
                ForEach(ghost.outline, id: \.celsius) { point in
                    LineMark(x: .value("Temperature", point.celsius), y: .value("Fan speed", point.percent),
                             series: .value("Preset", ghost.name))
                        .foregroundStyle(Color.secondary.opacity(0.28))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: CurveDraft.temperatureRange)
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: .stride(by: 10)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)°C") }
            }
        }
        .chartYAxis {
            AxisMarks(values: speedTicks) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { Text(speedLabel(value.as(Double.self) ?? 0)) }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear.preference(key: PlotRectKey.self, value: proxy.plotFrame.map { geometry[$0] } ?? .zero)
            }
        }
        .accessibilityHidden(true)
    }
}

struct PlotRectKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
