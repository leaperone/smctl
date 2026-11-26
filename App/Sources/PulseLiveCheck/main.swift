import Foundation
import PolicyEngine
import PulseUI
import SMCtlProtocol

// End-to-end check of the curve editor's path against the real daemon:
//   swift run --package-path App PulseLiveCheck <path to the pulse CLI>
// Creates a temporary curve shaped like Balanced, activates it, changes it
// from the CLI (as over SSH), checks the editor's reconciliation, then puts
// the previous profile back and deletes the curve.

let cli = CommandLine.arguments.dropFirst().first ?? "pulse"
let name = "pulse-livecheck"
var failures = 0

@MainActor func check(_ condition: Bool, _ message: String) {
    print("\(condition ? "PASS" : "FAIL")  \(message)")
    if !condition { failures += 1 }
}

func run(_ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: cli.contains("/") ? cli : "/usr/bin/env")
    process.arguments = cli.contains("/") ? arguments : [cli] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, "\(error)") }
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}

@MainActor
func main() async {
    let service = DaemonPulseService()
    guard let before = try? service.telemetry() else {
        print("FAIL  the daemon is not reachable")
        exit(1)
    }
    let previous = before.profile
    print("Daemon \(before.daemonVersion), active profile: \(previous)")
    defer { _ = try? service.delete(curve: name) }

    // 1. Edit like the app: Balanced, ramp from 68 °C, CPU sensors, saved and activated.
    let fan = before.fans.first
    let range = FanSpeedRange(minimumRPM: fan?.minimumRPM ?? 0, maximumRPM: fan?.maximumRPM ?? 100)
    var spec = FanCurvePresets.balanced
    spec.name = name
    spec.label = "Live check"
    let editor = CurveEditorModel(spec: spec, range: range)
    editor.edit("Move") { $0.moveHandle(.start, celsius: 68, percent: 0) }
    editor.edit("Sensors") { $0.setSensorGroups([.cpu]) }
    check(editor.draft.validationError == nil, "the edited draft validates")
    do {
        try service.upsert(editor.draft.spec, activate: true)
        check(true, "saved and activated over XPC")
    } catch {
        check(false, "saved and activated over XPC: \(error)")
        exit(1)
    }
    editor.reload(spec: editor.draft.spec, range: range)

    try? await Task.sleep(for: .seconds(3))
    let telemetry = try? service.telemetry()
    check(telemetry?.profile == name, "daemon reports \(name) as the active profile")
    if let state = telemetry?.curve.first, let fan = telemetry?.fans.first, let low = fan.minimumRPM, let high = fan.maximumRPM {
        check((low - 1...high + 1).contains(state.targetRPM), "fan target \(Int(state.targetRPM)) RPM is within \(Int(low))–\(Int(high))")
    } else {
        check(fan == nil, "curve state reported (fanless Macs have none)")
    }
    let shown = run(["fan", "curve", "show", name])
    check(shown.status == 0 && shown.output.contains("68"), "`pulse fan curve show` sees the ramp starting at 68 °C")
    let status = run(["status"])
    check(status.output.contains(name), "`pulse status` shows the curve")

    // 2. Changed elsewhere (as over SSH) while the editor is clean: absorbed.
    let set = run(["fan", "curve", "set", name, "--hysteresis", "4"])
    check(set.status == 0, "`pulse fan curve set --hysteresis 4` succeeds\(set.status == 0 ? "" : ": " + set.output)")
    let listed = try? service.curves().curves.first { $0.spec.name == name }?.spec
    check(listed?.hysteresisCelsius == 4, "the app's list sees hysteresis 4 °C")
    if let listed {
        check(editor.savedCurveChanged(to: listed) == .absorbed && editor.draft.spec.hysteresisCelsius == 4,
              "a clean editor reloads the change silently")
        // 3. Changed elsewhere while the editor has edits: conflict.
        editor.edit("Steepness") { $0.setSteepness(5) }
        _ = run(["fan", "curve", "set", name, "--hysteresis", "5"])
        if let again = try? service.curves().curves.first(where: { $0.spec.name == name })?.spec {
            check(editor.savedCurveChanged(to: again) == .conflict, "an editor with edits reports a conflict")
        }
    }

    // 4. Restore and clean up.
    do {
        try service.activate(profile: previous)
        try service.delete(curve: name)
        check(true, "previous profile \(previous) restored, curve deleted")
    } catch {
        check(false, "restore: \(error)")
    }
    let after = try? service.telemetry()
    check(after?.profile == previous, "daemon is back on \(previous)")
    check((try? service.curves().curves.contains { $0.spec.name == name }) == false, "\(name) is gone")
    print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
    exit(failures == 0 ? 0 : 1)
}

await main()
