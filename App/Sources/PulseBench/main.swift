import AppKit
import Darwin
import PolicyEngine
import PulseUI
import SwiftUI

// Measures the app's own CPU cost with the real status item, popover and
// settings window, fed by sample data:
//   swift run -c release --package-path App PulseBench [seconds-per-phase]
// Each phase is measured after a short settle time. Heartbeat is left at its
// default ("when warm"); the sample readings stay below the warm threshold, so
// the status item itself should be still.

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

@MainActor
final class Bench: NSObject, NSApplicationDelegate {
    let seconds: Double
    var store: PulseStore!
    var statusItem: StatusItemController!
    var settings: SettingsWindowController!

    init(seconds: Double) { self.seconds = seconds }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await run() }
    }

    func measure(_ name: String, settle: Double = 3) async {
        try? await Task.sleep(for: .seconds(settle))
        let start = cpuSeconds()
        let began = Date()
        try? await Task.sleep(for: .seconds(seconds))
        let cpu = cpuSeconds() - start
        let percent = cpu / Date().timeIntervalSince(began) * 100
        setvbuf(stdout, nil, _IONBF, 0); print(String(format: "%-34@ %6.2f%% CPU   %5.1f MB", name as NSString, percent, footprintMB()))
    }

    /// Drags the end handle of a curve at 60 Hz in an on-screen editor and
    /// reports CPU and the time to lay out and draw each frame.
    func measureDrag() async {
        var spec = FanCurvePresets.balanced
        spec.name = "bench"
        let model = CurveEditorModel(spec: spec, range: FanSpeedRange(minimumRPM: 1000, maximumRPM: 4900))
        let root: AnyView = ProcessInfo.processInfo.environment["X_MIN_CHART"] != nil
            ? AnyView(MinimalChart(model: model).frame(width: 530, height: 240).padding(20))
            : AnyView(CurveEditor(model: model, unit: .constant(.percent), hasFanRange: true).frame(width: 530).padding(20))
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 570, height: 380), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1))
        model.beginDrag(.end)
        let start = cpuSeconds()
        let began = Date()
        var frameTimes: [Double] = []
        for frame in 0..<Int(seconds * 60) {
            let t0 = Date()
            model.drag(to: 90 + 10 * sin(Double(frame) / 20), percent: 70 + 30 * cos(Double(frame) / 15))
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            frameTimes.append(Date().timeIntervalSince(t0) * 1000)
            try? await Task.sleep(for: .milliseconds(16))
        }
        model.endDrag()
        let cpu = cpuSeconds() - start
        let percent = cpu / Date().timeIntervalSince(began) * 100
        let sorted = frameTimes.sorted()
        // Wall time per frame includes waiting for the display; CPU per frame
        // is the work that has to fit in the 16.7 ms budget.
        print(String(format: "%-34@ %6.2f%% CPU   %.1f ms CPU per frame (wall: median %.1f, p95 %.1f ms)",
                     "dragging a handle (60 Hz)" as NSString, percent, cpu * 1000 / Double(frameTimes.count),
                     sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)]))
        window.orderOut(nil)
    }

    static func hostsSwiftUI(_ view: NSView?) -> Bool {
        guard let view else { return false }
        if String(describing: type(of: view)).contains("NSHostingView") { return true }
        return view.subviews.contains { hostsSwiftUI($0) }
    }

    func run() async {
        // A full history, as after a few minutes of running.
        if ProcessInfo.processInfo.environment["PULSE_BENCH_DRAG_ONLY"] != nil {
            setvbuf(stdout, nil, _IONBF, 0)
            await measureDrag()
            exit(0)
        }
        store = await PulseStore.preview(samples: PulseStore.historyLength)
        settings = SettingsWindowController(store: store)
        statusItem = StatusItemController(store: store) { [settings] in settings?.show($0) }
        store.start()
        print("PulseBench: \(Int(seconds)) s per phase, poll every 2 s\n")

        await measure("idle, nothing opened yet")
        statusItem.showPopover()
        await measure("popover open")
        statusItem.closePopover()
        await measure("popover closed")
        settings.show()
        await measure("settings open")
        settings.close()
        await measure("settings closed")
        settings.show(.curve("night"))
        await measure("curve editor open")
        settings.close()
        await measure("curve editor closed")
        statusItem.showPopover()
        try? await Task.sleep(for: .seconds(1))
        statusItem.closePopover()
        settings.show()
        try? await Task.sleep(for: .seconds(1))
        settings.close()
        await measure("both opened and closed again")
        // Closed windows must not keep a SwiftUI tree alive (it would keep
        // observing the store and rendering).
        let leftovers = NSApp.windows.filter { !$0.isVisible && Self.hostsSwiftUI($0.contentView) }
        print(leftovers.isEmpty
              ? "no SwiftUI view left in closed windows"
              : "LEAK: \(leftovers.count) closed window(s) still host SwiftUI: \(leftovers.map { String(describing: type(of: $0)) })")
        await measureDrag()
        exit(0)
    }
}

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 20
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let bench = Bench(seconds: seconds)
app.delegate = bench
app.run()

import Charts
struct MinimalChart: View {
    let model: CurveEditorModel
    var body: some View {
        let line = model.draft.outline
        Chart {
            ForEach(line, id: \.celsius) { point in
                LineMark(x: .value("T", point.celsius), y: .value("S", point.percent))
            }
        }
        .chartXScale(domain: 30...110)
        .chartYScale(domain: 0...100)
    }
}
