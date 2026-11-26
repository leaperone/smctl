import SwiftUI

/// A small ⓘ button that explains a setting in a popover.
struct InfoButton: View {
    let title: String
    let text: String
    @State private var shown = false

    init(_ title: String, _ text: String) {
        self.title = title
        self.text = text
    }

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel("About \(title)")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 300, alignment: .leading)
        }
    }
}

/// Explanations of the curve settings, in terms of what the fan does.
enum CurveHelp {
    static let sensors = "Which temperatures drive this curve. CPU and GPU are the chip's hot spots; they react fastest to load. Unchecking everything uses every sensor."
    static let aggregation = "Hottest: the curve follows the warmest checked sensor, so any hot spot speeds the fan up (safest, Apple's own approach). Average: the mean of the checked sensors, calmer but slower to react to one busy core."
    static let rates = "How fast the fan may change speed, in % of its range per second. Lower values make speed changes gradual and less noticeable; Immediate follows the curve at once. Slowing down more gently than speeding up keeps the fan from pulsing."
    static let idle = "What happens when the curve asks for 0 %. macOS decides: Pulse hands the fan back to macOS after 15 s, which usually keeps it at its quiet minimum. Minimum speed: Pulse holds the lowest speed itself. Stopped: the fan stops completely (experimental, see the warning)."
    static let hysteresis = "Once the fan has sped up, the temperature must drop this much before it slows down again. Prevents the fan from going up and down when the temperature hovers around a step."
    static let smoothing = "Averages the temperature over this many seconds before reading the curve, so a one-second spike (opening an app) doesn't rev the fan. Longer is quieter but reacts later to sustained load."
    static let steepness = "How abrupt the ramp is between its two handles. Low: the speed changes gradually across the whole range. High: little change near the ends and a quick rise in the middle (S-curve), or early (logarithmic) or late (exponential)."
}
