import Charts
import PolicyEngine
import SMCtlClient
import SMCtlProtocol
import ProductIdentity
import SwiftUI

/// The window shown from the menu bar item.
public struct PopoverView: View {
    let store: PulseStore
    let openSettings: (SettingsDestination) -> Void
    @AppStorage(SettingsKey.fanSpeedUnit) private var unit: FanSpeedUnit = .rpm

    public init(store: PulseStore, openSettings: @escaping (SettingsDestination) -> Void = { _ in }) {
        self.store = store
        self.openSettings = openSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            notices
            TemperaturesCard(groups: store.displayGroups)
            if !store.fans.isEmpty {
                FansCard(fans: store.fans, curve: store.telemetry?.curve ?? [], unit: unit)
            }
            if store.history.count > 1 {
                HistoryChart(history: store.history, showsFan: !store.isFanless)
            }
            if store.daemonState.isConnected, !store.isFanless {
                ProfilesSection(store: store) { openSettings(.curve($0)) }
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Pulse").font(.headline)
            Spacer()
            StatusCapsule(store: store)
        }
    }

    @ViewBuilder
    private var notices: some View {
        if case .unavailable = store.daemonState {
            Notice(
                systemImage: "lock.shield",
                tint: .blue,
                title: "Fan control is not installed",
                message: "Temperatures are read-only until the Pulse service is installed.",
                actionTitle: ServiceInstaller.helpersAvailable ? "Install…" : nil
            ) {
                Task { @MainActor in
                    do {
                        try ServiceInstaller.installDaemon()
                    } catch {
                        store.actionError = error.localizedDescription
                    }
                    await store.refresh(forceLists: true)
                }
            }
        }
        UpdateNotices(updates: store.updates)
        if store.safetyLatched {
            Notice(
                systemImage: "exclamationmark.triangle.fill",
                tint: .red,
                title: "Safety guard engaged",
                message: store.telemetry?.safety.lastTripReason ?? "Fans were handed back to macOS until temperatures drop."
            )
        }
        ForEach(store.conflicts.filter(\.running), id: \.product) { conflict in
            Notice(
                systemImage: "exclamationmark.2",
                tint: .orange,
                title: "\(conflict.product) is also controlling fans",
                message: "Two controllers fight over the fans. Quit \(conflict.product) to use Pulse profiles."
            )
        }
        if let error = store.actionError {
            Notice(systemImage: "xmark.octagon", tint: .red, title: "Action failed", message: error, actionTitle: "Dismiss") {
                store.actionError = nil
            }
        }
    }

    /// Settings and Quit take equal widths, so Help sits exactly in the
    /// middle whatever the label lengths.
    private var footer: some View {
        HStack(spacing: 0) {
            Button { openSettings(.pane(.general)) } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",")
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                if let url = URL(string: ProductIdentity.helpURL) { NSWorkspace.shared.open(url) }
            } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            .keyboardShortcut("?")
            .help("Open the Pulse help in your browser")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .keyboardShortcut("q")
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

/// Fan speed as a fraction of the fan's range.
struct SpeedBar: View {
    var fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(Color.accentColor.gradient)
                    .frame(width: max(6, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
        .animation(.smooth, value: fraction)
        .accessibilityValue(Text(Format.percent(fraction * 100)))
    }
}

// MARK: - Header

struct StatusCapsule: View {
    let store: PulseStore

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }

    private var text: String {
        switch store.daemonState {
        case .connecting: return "Connecting…"
        case .unavailable: return "Read-only"
        case .connected:
            if store.isFanless { return "No fan" }
            return store.activeProfile == "auto" ? "macOS control" : store.title(forProfile: store.activeProfile)
        }
    }

    private var color: Color {
        switch store.daemonState {
        case .connecting: return .gray
        case .unavailable: return .orange
        case .connected:
            if store.isFanless { return .secondary }
            return store.safetyLatched ? .red : (store.activeProfile == "auto" ? .secondary : .green)
        }
    }
}

struct Notice: View {
    var systemImage: String
    var tint: Color
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    init(systemImage: String, tint: Color, title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil,
         secondaryTitle: String? = nil, secondaryAction: (() -> Void)? = nil) {
        self.systemImage = systemImage
        self.tint = tint
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.secondaryTitle = secondaryTitle
        self.secondaryAction = secondaryAction
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    HStack(spacing: 6) {
                        Button(actionTitle, action: action)
                            .modifier(GlassButtonStyle())
                        if let secondaryTitle, let secondaryAction {
                            Button(secondaryTitle, action: secondaryAction)
                                .buttonStyle(.borderless)
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Temperatures

struct TemperaturesCard: View {
    let groups: [TemperatureGroupSummary]

    var body: some View {
        Card(title: "Temperatures", systemImage: "thermometer.medium") {
            if groups.isEmpty {
                Text("No readable sensors").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(groups.prefix(4), id: \.group) { group in
                HStack(spacing: 8) {
                    Text(group.label)
                        .font(.callout)
                        .frame(width: 58, alignment: .leading)
                    if let average = group.averageCelsius, let maximum = group.maximumCelsius {
                        TemperatureBar(average: average, maximum: maximum)
                        Text(Format.temperature(average))
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                        Text("max \(Format.temperature(maximum))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 58, alignment: .trailing)
                    } else {
                        Text("Off").font(.callout).foregroundStyle(.tertiary)
                        Spacer()
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Average as a filled bar, maximum as a tick, on a 30–110 °C scale.
struct TemperatureBar: View {
    var average: Double
    var maximum: Double
    static let scale: ClosedRange<Double> = 30...110

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(TemperatureColor.color(for: average).gradient)
                    .frame(width: max(6, width * Self.position(average)))
                Rectangle()
                    .fill(TemperatureColor.color(for: maximum))
                    .frame(width: 2, height: 10)
                    .offset(x: max(0, width * Self.position(maximum) - 1))
            }
        }
        .frame(height: 6)
    }

    static func position(_ celsius: Double) -> Double {
        min(1, max(0, (celsius - scale.lowerBound) / (scale.upperBound - scale.lowerBound)))
    }
}

enum TemperatureColor {
    static func color(for celsius: Double) -> Color {
        switch celsius {
        case ..<60: return .green
        case ..<80: return .yellow
        case ..<95: return .orange
        default: return .red
        }
    }
}

// MARK: - Fans

struct FansCard: View {
    let fans: [FanStatusDTO]
    let curve: [FanCurveStateDTO]
    let unit: FanSpeedUnit

    var body: some View {
        Card(title: fans.count == 1 ? "Fan" : "Fans", systemImage: "fan") {
            ForEach(fans, id: \.index) { fan in
                let percent = PulseStore.percent(fan)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        if fans.count > 1 {
                            Text("Fan \(fan.index + 1)").font(.callout)
                        }
                        Text(unit == .rpm ? "\(Format.rpm(fan.actualRPM)) RPM" : Format.percent(percent))
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(unit == .rpm ? Format.percent(percent) : "\(Format.rpm(fan.actualRPM)) RPM")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer()
                        Text(modeText(fan))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    SpeedBar(fraction: (percent ?? 0) / 100)
                    if let state = curve.first(where: { $0.index == fan.index }) {
                        let input = "Curve input \(Format.temperature(state.effectiveCelsius, decimals: 1)) → "
                        Text(state.stopped ? input + "0 %, fan stopped by Pulse"
                             : state.handedToSystem ? input + "0 %, macOS runs the fan"
                             : input + "target \(Format.rpm(state.targetRPM)) RPM")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private func modeText(_ fan: FanStatusDTO) -> String {
        switch fan.mode {
        case "auto", "system": return "macOS"
        case "manual": return "Pulse"
        default: return fan.mode
        }
    }
}

// MARK: - History

struct HistoryChart: View {
    let history: [HistorySample]
    var showsFan = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Last \(minutes) min").font(.caption).foregroundStyle(.secondary)
                Spacer()
                LegendDot(color: .orange, text: "CPU avg")
                if showsFan {
                    LegendDot(color: .accentColor, text: "Fan")
                }
            }
            Chart {
                ForEach(history) { sample in
                    if let fan = sample.fanPercent {
                        AreaMark(x: .value("Time", sample.date), y: .value("Fan", fan))
                            .foregroundStyle(Color.accentColor.opacity(0.18).gradient)
                    }
                }
                ForEach(history) { sample in
                    if let cpu = sample.cpuAverage {
                        LineMark(x: .value("Time", sample.date), y: .value("CPU", cpu))
                            .foregroundStyle(.orange)
                            .interpolationMethod(.monotone)
                    }
                }
            }
            .chartYScale(domain: 0...110)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: [25, 50, 75, 100]) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { Text("\(value.as(Int.self) ?? 0)°").font(.caption2) }
                }
            }
            .frame(height: 70)
            .accessibilityLabel("Temperature and fan history")
        }
    }

    private var minutes: Int {
        guard let first = history.first?.date, let last = history.last?.date else { return 0 }
        return max(1, Int((last.timeIntervalSince(first) / 60).rounded()))
    }
}

struct LegendDot: View {
    var color: Color
    var text: String

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Profiles

struct ProfilesSection: View {
    let store: PulseStore
    let editCurves: (String?) -> Void

    var body: some View {
        let choices = store.profileChoices
        let rows = stride(from: 0, to: choices.count, by: 2).map { Array(choices[$0..<min($0 + 2, choices.count)]) }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Profile").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Edit Curves…") {
                    editCurves(store.activeProfile == "auto" ? nil : store.activeProfile)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.tint)
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(rows, id: \.first?.id) { row in
                    GridRow {
                        ForEach(row) { choice in
                            ProfileButton(
                                choice: choice,
                                selected: store.activeProfile == choice.name,
                                busy: store.busyProfile == choice.name
                            ) {
                                Task { await store.activate(choice.name) }
                            }
                            .disabled(!store.canControlFans || store.busyProfile != nil)
                        }
                        if row.count == 1 {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
        }
    }
}

struct ProfileButton: View {
    let choice: ProfileChoice
    let selected: Bool
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: choice.systemImage)
                }
                Text(choice.title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .modifier(ProfileButtonStyle(selected: selected))
        .controlSize(.large)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ProfileButtonStyle: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        content.modifier(GlassButtonStyle(prominent: selected))
    }
}

extension EnvironmentValues {
    /// True when the view is drawn off screen (PulseSnapshots): Liquid Glass is
    /// composited by the window server, so an off-screen render drops the glass
    /// and draws the buttons' symbols white, even in light mode.
    @Entry public var rendersWithoutGlass = false
}

/// `.glass` / `.glassProminent`, or their bordered equivalents when the view is
/// rendered off screen (see `rendersWithoutGlass`).
struct GlassButtonStyle: ViewModifier {
    var prominent = false
    @Environment(\.rendersWithoutGlass) private var withoutGlass

    func body(content: Content) -> some View {
        switch (prominent, withoutGlass) {
        case (true, false): content.buttonStyle(.glassProminent)
        case (false, false): content.buttonStyle(.glass)
        case (true, true): content.buttonStyle(.borderedProminent)
        case (false, true): content.buttonStyle(.bordered)
        }
    }
}

// MARK: - Card

struct Card<Content: View>: View {
    var title: String
    var systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
