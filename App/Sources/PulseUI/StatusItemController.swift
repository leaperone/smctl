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
    private var renderedKey: String?
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
        let configuration = MenuBarConfiguration.load()
        let state = store.menuBar
        let entries = state.entries(configuration)
        // Never leave the item empty: no readings means the icon.
        let showsIcon = configuration.showsIcon || entries.isEmpty
        let symbol = state.symbol
        let key = "\(configuration.layout)|\(showsIcon)|\(symbol)|" + entries.map { "\($0.label)=\($0.value)" }.joined(separator: ",")
        guard key != renderedKey, let button = statusItem.button else {
            return
        }
        renderedKey = key
        switch configuration.layout {
        case .stacked where !entries.isEmpty:
            button.image = MenuBarRenderer.stackedImage(entries: entries, symbol: showsIcon ? symbol : nil)
            button.title = ""
        default:
            let text = entries.isEmpty ? "" : state.inlineText(configuration)
            if showsIcon {
                let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Pulse")
                image?.isTemplate = true
                button.image = image
            } else {
                button.image = nil
            }
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
            button.attributedTitle = NSAttributedString(string: showsIcon && !text.isEmpty ? " \(text)" : text, attributes: [.font: font])
        }
        button.setAccessibilityValue(entries.map { "\($0.item.title) \($0.value)" }.joined(separator: ", "))
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
