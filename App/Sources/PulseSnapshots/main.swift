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
}

await main()
