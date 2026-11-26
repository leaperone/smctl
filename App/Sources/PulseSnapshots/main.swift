import AppKit
import PulseUI
import SMCtlClient
import SwiftUI

// Renders the popover and settings with sample data to PNG files:
//   swift run PulseSnapshots <output-directory>

@MainActor
func render<V: View>(_ view: V, scheme: ColorScheme, to url: URL) async {
    // A real (off-screen) window, so AppKit-backed controls and glass draw as in the app.
    let hosting = NSHostingView(rootView: view
        .environment(\.colorScheme, scheme)
        .background(scheme == .dark ? Color(white: 0.13) : Color(white: 0.96)))
    hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    let size = hosting.fittingSize
    let window = NSWindow(
        contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
        styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.appearance = hosting.appearance
    window.contentView = hosting
    window.orderFrontRegardless()
    hosting.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(400))
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    window.orderOut(nil)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("could not render \(url.lastPathComponent)\n".utf8))
        return
    }
    try? png.write(to: url)
    print(url.path)
}

@MainActor
func main() async {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "snapshots", isDirectory: true)
    try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    let normal = await PulseStore.preview()
    let readOnly = await PulseStore.preview(SampleService(failing: true))
    let alerts = await PulseStore.preview(SampleService(
        profile: "performance",
        conflicts: [FanControlConflict(product: "TG Pro", evidence: "process TG Pro", running: true)],
        latched: true
    ))

    for (name, store) in [("popover", normal), ("popover-readonly", readOnly), ("popover-alerts", alerts)] {
        for scheme in [ColorScheme.light, .dark] {
            await render(PopoverView(store: store), scheme: scheme, to: output.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
    // Menu bar item variants, drawn on light and dark menu bar strips.
    let state = normal.menuBar
    let variants: [(String, MenuBarConfiguration)] = [
        ("stacked-cpu-fan", MenuBarConfiguration(layout: .stacked, items: [.cpu, .fan])),
        ("stacked-all", MenuBarConfiguration(layout: .stacked, items: MenuBarItem.allCases)),
        ("stacked-noicon", MenuBarConfiguration(icon: .none, layout: .stacked, items: [.cpu, .gpu])),
        ("heartbeat-stacked", MenuBarConfiguration(icon: .heartbeat, layout: .stacked, items: [.cpu, .fan])),
        ("fan-inline", MenuBarConfiguration(icon: .fan, layout: .inline, items: [.cpu, .fan])),
        ("pulse-only", MenuBarConfiguration(icon: .pulse, showsReadings: false)),
        ("heartbeat-only", MenuBarConfiguration(icon: .heartbeat, showsReadings: false)),
        ("inline-cpu-fan", MenuBarConfiguration(layout: .inline, items: [.cpu, .fan])),
        ("stacked-mono", MenuBarConfiguration(monochrome: true, layout: .stacked, items: [.cpu, .fan]))
    ]
    for (name, configuration) in variants {
        for scheme in [ColorScheme.light, .dark] {
            await render(MenuBarPreview(state: state, configuration: configuration, animated: false).frame(width: 220).padding(8),
                         scheme: scheme, to: output.appendingPathComponent("menubar-\(name)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
    for (name, store, curve) in [("curves", normal, "balanced"), ("curves-user", normal, "night"), ("curves-points", normal, "steady"), ("curves-readonly", readOnly, "silent")] {
        for scheme in [ColorScheme.light, .dark] {
            await render(SettingsView(store: store, pane: .curves, navigation: SettingsNavigation(selectedCurve: curve)), scheme: scheme,
                         to: output.appendingPathComponent("settings-\(name)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
    for scheme in [ColorScheme.light, .dark] {
        await render(SettingsView(store: normal, pane: .general), scheme: scheme, to: output.appendingPathComponent("settings-\(scheme == .dark ? "dark" : "light").png"))
    }
    // Heartbeat frames (rest, decay, peak) at several temperatures.
    let strip = VStack(alignment: .leading, spacing: 10) {
        ForEach([MenuBarIcon.pulse, .heartbeat], id: \.self) { icon in
            HStack(spacing: 18) {
                ForEach([50.0, 70.0, 88.0, 100.0], id: \.self) { celsius in
                    HStack(spacing: 6) {
                        ForEach([0.0, 0.45, 1.0], id: \.self) { beat in
                            let drawing = MenuBarDrawing(icon: icon, layout: .stacked, entries: [], heatCelsius: celsius, beat: beat)
                            Image(nsImage: MenuBarRenderer.image(drawing))
                                .renderingMode(drawing.isTemplate ? .template : .original)
                        }
                    }
                    .padding(4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }
            }
        }
    }
    .padding(10)
    for scheme in [ColorScheme.light, .dark] {
        await render(strip, scheme: scheme, to: output.appendingPathComponent("beats-\(scheme == .dark ? "dark" : "light").png"))
    }

    // Preset curves for the README (assets/img/curves-{light,dark}.png).
    for scheme in [ColorScheme.light, .dark] {
        await render(CurvesChart.presets.frame(width: 720, height: 360).padding(24),
                     scheme: scheme, to: output.appendingPathComponent("curves-\(scheme == .dark ? "dark" : "light").png"))
    }
}

await main()
