import AppKit
import Observation
import SwiftUI

/// The menu bar item, in AppKit rather than SwiftUI's MenuBarExtra: MenuBarExtra
/// re-rendered the status item (every display/appearance replica) on each scene
/// update, ~3% CPU at idle. Here the button is touched only when its text or
/// symbol actually changes.
@MainActor
public final class StatusItemController: NSObject, NSPopoverDelegate {
    private let store: PulseStore
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var rendered: (text: String, symbol: String)?
    private var defaultsObserver: NSObjectProtocol?

    public init(store: PulseStore, openSettings: @escaping @MainActor () -> Void) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverView(store: store) { [weak self] in
            self?.popover.performClose(nil)
            openSettings()
        })

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel("Pulse")
        }

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        observeMenuBarState()
    }

    /// Re-renders whenever `store.menuBar` changes (Observation is one-shot, so re-arm).
    private func observeMenuBarState() {
        withObservationTracking {
            _ = store.menuBar
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.render()
                self?.observeMenuBarState()
            }
        }
        render()
    }

    private func render() {
        let defaults = UserDefaults.standard
        let style = defaults.string(forKey: SettingsKey.menuBarStyle).flatMap(MenuBarStyle.init) ?? .temperatureAndFan
        let metric = defaults.string(forKey: SettingsKey.temperatureMetric).flatMap(TemperatureMetric.init) ?? .cpuAverage
        let unit = defaults.string(forKey: SettingsKey.fanSpeedUnit).flatMap(FanSpeedUnit.init) ?? .rpm
        let state = store.menuBar
        let text = state.text(style: style, metric: metric, unit: unit)
        let symbol = state.latched ? "exclamationmark.triangle.fill" : (state.curveActive ? "fan.fill" : "fan")
        guard rendered?.text != text || rendered?.symbol != symbol, let button = statusItem.button else {
            return
        }
        if rendered?.symbol != symbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Pulse")
            image?.isTemplate = true
            button.image = image
        }
        rendered = (text, symbol)
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        button.attributedTitle = NSAttributedString(string: text.isEmpty ? "" : " \(text)", attributes: [.font: font])
        button.setAccessibilityValue(text)
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    public func popoverWillShow(_ notification: Notification) {
        store.popoverDidOpen()
    }

    public func popoverDidClose(_ notification: Notification) {
        store.popoverDidClose()
    }
}

/// The settings window, owned explicitly: a menu bar-only app has no app menu,
/// and SettingsLink needs a SwiftUI scene around the popover.
@MainActor
public final class SettingsWindowController {
    private let store: PulseStore
    private var window: NSWindow?

    public init(store: PulseStore) {
        self.store = store
    }

    public func show() {
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView(store: store))
            let window = NSWindow(contentViewController: controller)
            window.title = "Pulse Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
