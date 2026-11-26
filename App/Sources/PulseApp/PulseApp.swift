import AppKit
import PulseUI
import SwiftUI

@main
struct PulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar item and windows are AppKit-managed (see StatusItemController).
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = PulseStore()
    private var statusItem: StatusItemController?
    private var settings: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsWindowController(store: store)
        self.settings = settings
        statusItem = StatusItemController(store: store) { settings.show($0) }
        store.start()
    }
}
