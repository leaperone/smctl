import PolicyEngine
import ProductIdentity
import SwiftUI

/// One help topic: a title and a few short paragraphs.
struct HelpTopic: Identifiable, Equatable {
    var id: String { title }
    var title: String
    var systemImage: String
    var paragraphs: [String]
}

/// Settings > Help: what each setting does to the fans. Numbers come from the
/// code (presets, safety ceilings, refresh range) so the text cannot drift.
enum HelpContent {
    /// Paragraphs may open with a **bold** setting name. Markdown only: unlike
    /// LocalizedStringKey, no format specifiers, so "0 %" stays as written.
    static func attributed(_ paragraph: String) -> AttributedString {
        (try? AttributedString(markdown: paragraph)) ?? AttributedString(paragraph)
    }

    static var topics: [HelpTopic] {
        [howItWorks, profiles, curves, response, refresh, automation, safety, troubleshooting]
    }

    static let howItWorks = HelpTopic(
        title: "How Pulse drives the fans",
        systemImage: "fan",
        paragraphs: [
            "A small background service (installed from the Service tab) reads the temperature sensors and sets the fan speed. The app and the \(ProductIdentity.cliName) command only talk to it, so the fans keep following your profile when Pulse is closed.",
            "Speeds are in percent of each fan's own range: 0 % is its slowest spinning speed, 100 % its fastest. The same curve therefore suits a Mac mini and a MacBook Pro with two different fans.",
            "On Auto, macOS drives the fans exactly as it would without Pulse."
        ]
    )

    static var profiles: HelpTopic {
        HelpTopic(
            title: "Profiles",
            systemImage: "slider.horizontal.3",
            paragraphs: [
                "**Auto**: macOS decides. Pulse only shows the readings."
            ] + FanCurvePresets.all.map(describe) + [
                "The presets are read-only. Duplicate one in the Curves tab to make your own version."
            ]
        )
    }

    static func describe(_ preset: FanCurveSpec) -> String {
        let name = preset.label ?? preset.name.capitalized
        guard let shape = preset.shape else { return "\(name)." }
        let range = "\(Int(shape.startCelsius))–\(Int(shape.endCelsius)) °C"
        let follows = preset.weights.isEmpty ? "the hottest sensor" : "the CPU average"
        let floor = shape.minimumFraction > 0 ? ", never below \(Int((shape.minimumFraction * 100).rounded())) %" : ""
        let character: String
        switch preset.name {
        case "silent": character = "Stays quiet as long as it can, then ramps up late and fast."
        case "balanced": character = "Calm at rest, a clear rise in the middle of the range."
        case "performance": character = "A straight ramp that cools early, for sustained work."
        default: character = ""
        }
        return "**\(name)**: \(character) Follows \(follows) from \(range)\(floor)."
    }

    static let curves = HelpTopic(
        title: "Reading a curve",
        systemImage: "chart.xyaxis.line",
        paragraphs: [
            "Left to right is temperature, bottom to top is fan speed. Below the first handle the fan runs at the curve's floor; above the last one, at its ceiling.",
            "Drag the two handles to move where the ramp starts and ends, and the floor or ceiling. The shape sets how the speed climbs in between: Linear (steady), S-curve (calm, then a clear rise in the middle), Exponential (quiet for longer, then fast), Logarithmic (reacts early, then levels off), Steps (plateaus), or free Points.",
            "**Steepness.** " + CurveHelp.steepness,
            "The live marker shows the current temperature and the speed the curve asks for. The faint lines are the presets, for reference."
        ]
    )

    static let response = HelpTopic(
        title: "Response settings",
        systemImage: "waveform.path.ecg",
        paragraphs: [
            "**Sensors.** " + CurveHelp.sensors,
            "**Hottest or average.** " + CurveHelp.aggregation,
            "**Smoothing.** " + CurveHelp.smoothing,
            "**Hysteresis.** " + CurveHelp.hysteresis,
            "**Speed up and slow down.** " + CurveHelp.rates,
            "**At 0 %.** " + CurveHelp.idle
        ]
    )

    static var refresh: HelpTopic {
        HelpTopic(
            title: "Sensor refresh",
            systemImage: "timer",
            paragraphs: [
                "General › Sensors sets how often the service reads the sensors, from \(SamplingSettings.range.lowerBound) to \(SamplingSettings.range.upperBound) seconds. Shorter reacts faster to heat; longer uses less energy. Readings and charts in Pulse update at the same pace.",
                "Curves keep their character at any pace: how fast the fan may change speed is measured in real time, so a longer interval only delays the reaction a little.",
                "On a MacBook you can choose a slower pace on battery. The service switches by itself when you unplug or plug in, even with Pulse closed.",
                "Near the temperature limit the service reads every second, whatever the setting."
            ]
        )
    }

    static let automation = HelpTopic(
        title: "Automation",
        systemImage: "wand.and.stars",
        paragraphs: [
            "Rules switch the profile on their own: while a game or app is open, in Low Power Mode, on battery or on the power adapter. A condition must hold for a few seconds before the switch, and the first rule that applies wins.",
            "When no rule applies, Pulse goes back to the profile you chose. Picking a profile yourself always wins until the rule's condition goes away. Rules run while Pulse is open."
        ]
    )

    static var safety: HelpTopic {
        HelpTopic(
            title: "Temperature limit",
            systemImage: "thermometer.high",
            paragraphs: [
                "A safety guard watches every sensor while Pulse drives the fans. If one stays above \(Int(FanSafetyGuard.defaultCeilingCelsius)) °C (\(Int(FanSafetyGuard.defaultCeilingCelsius + FanSafetyGuard.hotSpotAllowanceCelsius)) °C for the chip's hot spots), or if no sensor can be read, it hands the fans back to macOS at once. It cannot be turned off.",
                "The Mac then stays on Auto and Pulse notifies you. It means the cooling could not keep up: check the Mac's vents and the curve, then pick a profile again to resume. Automatic rules wait for that choice too."
            ]
        )
    }

    static let troubleshooting = HelpTopic(
        title: "If something looks wrong",
        systemImage: "stethoscope",
        paragraphs: [
            "**Fans not following the curve**: check that the service is installed and up to date in the Service tab (Reinstall after updating Pulse), and that no other fan app (TG Pro, Macs Fan Control, …) is running; Pulse warns when it finds one.",
            "**Temperatures but no fan readings**: this Mac has no fan (MacBook Air). Pulse shows temperatures only.",
            "For a bug report, run \(ProductIdentity.cliName) doctor in Terminal: it lists the Mac, its fans and sensors, and the service's state. \(ProductIdentity.cliName) doctor --test-fans also checks that each fan obeys, then restores your profile."
        ]
    )
}

struct HelpView: View {
    var body: some View {
        Form {
            ForEach(HelpContent.topics) { topic in
                Section {
                    ForEach(topic.paragraphs, id: \.self) { paragraph in
                        Text(HelpContent.attributed(paragraph))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                } header: {
                    Label(topic.title, systemImage: topic.systemImage)
                }
            }
        }
        .formStyle(.grouped)
    }
}
