import AppKit
import Darwin
import PulseUI

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

    func run() async {
        // A full history, as after a few minutes of running.
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
        settings.show(.curve("balanced"))
        await measure("curves pane open")
        settings.close()
        await measure("curves pane closed")
        statusItem.showPopover()
        try? await Task.sleep(for: .seconds(1))
        statusItem.closePopover()
        settings.show()
        try? await Task.sleep(for: .seconds(1))
        settings.close()
        await measure("both opened and closed again")
        exit(0)
    }
}

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 20
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let bench = Bench(seconds: seconds)
app.delegate = bench
app.run()
