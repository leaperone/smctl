import SwiftUI

/// "Refresh every 1–5 s": the daemon's sensor interval, which also paces the
/// app. On a Mac with a battery, an optional second interval applies on
/// battery; the daemon switches on its own, even with the app closed.
public struct SamplingSettings: View {
    let store: PulseStore
    let hasBattery: Bool

    static let range = 1...5

    public init(store: PulseStore, hasBattery: Bool? = nil) {
        self.store = store
        self.hasBattery = hasBattery ?? AutomationController.hasInternalBattery()
    }

    public var body: some View {
        Section("Sensors") {
            if let interval = store.samplingInterval {
                IntervalSlider(title: hasBattery ? "On power adapter" : "Refresh every", value: interval) { seconds in
                    await store.setSamplingInterval(seconds)
                }
                if hasBattery {
                    Toggle(isOn: Binding(
                        get: { store.batterySamplingInterval != nil },
                        set: { enabled in
                            Task { await store.setSamplingInterval(enabled ? min(interval + 2, Self.range.upperBound) : nil, onBattery: true) }
                        }
                    )) {
                        Text("Different pace on battery")
                        Text("The service switches as soon as you unplug or plug in, even with Pulse closed.")
                    }
                    if let battery = store.batterySamplingInterval {
                        IntervalSlider(title: "On battery", value: battery) { seconds in
                            await store.setSamplingInterval(seconds, onBattery: true)
                        }
                    }
                }
                Text(Self.help(seconds: store.currentSamplingInterval ?? interval))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Refresh every", value: store.daemonState.isConnected ? "1 s" : "2 s")
                Text(store.daemonState.isConnected
                     ? "Reinstall the fan control service (Service tab) to choose how often sensors are read."
                     : "Install the fan control service (Service tab) to choose how often sensors are read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func help(seconds: Int) -> String {
        let pace: String
        switch seconds {
        case 1: pace = "Fans react within a second; uses the most energy."
        case 5: pace = "Uses the least energy; fans react up to 5 s later."
        default: pace = "Shorter reacts faster to heat; longer uses less energy."
        }
        return pace + " Readings and charts update at the same pace. Near the temperature limit, the service checks every second anyway."
    }
}

/// A 1–5 s stepped slider that commits once the value settles, so a drag
/// sends one change rather than one per step.
private struct IntervalSlider: View {
    let title: String
    let value: Int
    let commit: (Int) async -> Void
    @State private var draft: Double = 2
    @State private var editing = false

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: $draft, in: Double(SamplingSettings.range.lowerBound)...Double(SamplingSettings.range.upperBound), step: 1) {
                    Text(title)
                } minimumValueLabel: {
                    Text("\(SamplingSettings.range.lowerBound) s").font(.caption).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("\(SamplingSettings.range.upperBound) s").font(.caption).foregroundStyle(.secondary)
                } onEditingChanged: { isEditing in
                    editing = isEditing
                }
                .labelsHidden()
                .frame(width: 220)
                Text("\(Int(draft)) s")
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
            }
        }
        .accessibilityValue("\(Int(draft)) seconds")
        .onAppear { draft = Double(value) }
        .onChange(of: value) { _, newValue in
            if !editing { draft = Double(newValue) }
        }
        .task(id: SettleKey(value: Int(draft), editing: editing)) {
            guard !editing, Int(draft) != value else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await commit(Int(draft))
        }
    }

    private struct SettleKey: Equatable {
        var value: Int
        var editing: Bool
    }
}
