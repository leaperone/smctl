import SwiftUI

/// "Refresh every 1–5 s": the daemon's sensor interval, which also paces the app.
/// The slider commits once it settles, so dragging sends one change, not five.
struct SamplingSettings: View {
    let store: PulseStore
    @State private var draft: Double = 2
    @State private var editing = false

    static let range = 1...5

    var body: some View {
        Section("Sensors") {
            if let interval = store.samplingInterval {
                LabeledContent("Refresh every") {
                    HStack(spacing: 10) {
                        Slider(value: $draft, in: Double(Self.range.lowerBound)...Double(Self.range.upperBound), step: 1) {
                            Text("Refresh every")
                        } minimumValueLabel: {
                            Text("\(Self.range.lowerBound) s").font(.caption).foregroundStyle(.secondary)
                        } maximumValueLabel: {
                            Text("\(Self.range.upperBound) s").font(.caption).foregroundStyle(.secondary)
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
                .onAppear { draft = Double(interval) }
                .onChange(of: interval) { _, value in
                    if !editing { draft = Double(value) }
                }
                // Commit after the value settles (drag end or keyboard steps).
                .task(id: SettleKey(value: Int(draft), editing: editing)) {
                    guard !editing, Int(draft) != interval else { return }
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    await store.setSamplingInterval(Int(draft))
                }
                Text(Self.help(seconds: Int(draft)))
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

    private struct SettleKey: Equatable {
        var value: Int
        var editing: Bool
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
