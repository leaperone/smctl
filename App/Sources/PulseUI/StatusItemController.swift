import AppKit
import Observation
import SwiftUI

/// The menu bar item, in AppKit rather than SwiftUI's MenuBarExtra: MenuBarExtra
/// re-rendered the status item (every display/appearance replica) on each scene
/// update, ~3% CPU at idle. Here the button is touched only when its text or
/// symbol actually changes.
@MainActor
public final class StatusItemController: NSObject, NSPopoverDelegate {
    /// Beat envelope: (delay since the previous frame, beat intensity). Two image
    /// updates per beat (each costs ~15 ms of AppKit status item work on
    /// macOS 26); the rest of the period shows the rest frame.
    static let beatFrames: [(delay: TimeInterval, beat: Double)] = [(0, 1), (0.16, 0)]

    private let store: PulseStore
    private let openSettings: @MainActor () -> Void
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var renderedKey: String?
    private var frameCache: [Double: NSImage] = [:]
    private var frameCacheKey: String?
    private var observers: [NSObjectProtocol] = []
    private var beatTimer: Timer?
    private var screensAsleep = false

    public init(store: PulseStore, openSettings: @escaping @MainActor () -> Void) {
        self.store = store
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("Pulse")
        }

        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        observers = [
            center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main, using: refresh),
            center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main, using: refresh),
            workspace.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main, using: refresh),
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensAsleep = true; self?.render() }
            },
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensAsleep = false; self?.render() }
            }
        ]
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

    /// The drawing for the current state and settings, at rest.
    private func drawing() -> (MenuBarDrawing, MenuBarConfiguration) {
        let configuration = MenuBarConfiguration.load()
        let state = store.menuBar
        let entries = state.entries(configuration)
        let drawing = MenuBarDrawing(
            icon: configuration.effectiveIcon(hasReadings: !entries.isEmpty),
            layout: configuration.layout,
            entries: entries,
            heatCelsius: state.heatCelsius,
            latched: state.latched,
            fanSymbol: state.symbol,
            monochrome: configuration.monochrome
        )
        return (drawing, configuration)
    }

    private var shouldAnimate: Bool {
        let (drawing, configuration) = drawing()
        return configuration.heartbeat.beats(celsius: drawing.heatCelsius) && drawing.icon.canAnimate
            && !drawing.latched && !screensAsleep
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Shows the rest frame for the current state and (re)starts the heartbeat.
    private func render() {
        show(beat: 0)
        if shouldAnimate {
            if beatTimer == nil { scheduleBeat(after: 0.3) }
        } else {
            beatTimer?.invalidate()
            beatTimer = nil
        }
    }

    /// Sets the button image for `beat`, touching AppKit only when it changes.
    private func show(beat: Double) {
        let (base, _) = drawing()
        let stateKey = "\(base.icon)|\(base.layout)|\(base.latched)|\(base.fanSymbol)|\(base.dotColor.map { "\($0)" } ?? "ink")|"
            + base.entries.map { "\($0.label)=\($0.value)" }.joined(separator: ",")
        if stateKey != frameCacheKey {
            frameCache.removeAll()
            frameCacheKey = stateKey
        }
        let key = stateKey + "|\(beat)"
        guard key != renderedKey, let button = statusItem.button else { return }
        renderedKey = key
        let image: NSImage
        if let cached = frameCache[beat] {
            image = cached
        } else {
            var frame = base
            frame.beat = beat
            image = MenuBarRenderer.image(frame)
            frameCache[beat] = image
        }
        button.image = image
        button.title = ""
        button.setAccessibilityValue(base.entries.map { "\($0.item.title) \($0.value)" }.joined(separator: ", "))
    }

    private func scheduleBeat(after delay: TimeInterval) {
        beatTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat(frame: 0) }
        }
        timer.tolerance = 0.03
        RunLoop.main.add(timer, forMode: .common)
        beatTimer = timer
    }

    /// Plays one heartbeat, then waits for the next one at the current heart rate.
    private func beat(frame index: Int) {
        guard shouldAnimate else {
            beatTimer = nil
            show(beat: 0)
            return
        }
        let frames = Self.beatFrames
        show(beat: frames[index].beat)
        let next = index + 1
        let delay: TimeInterval
        if next < frames.count {
            delay = frames[next].delay
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.beat(frame: next) }
            }
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)
            beatTimer = timer
        } else {
            let period = 60 / MenuBarState.beatsPerMinute(celsius: store.menuBar.heatCelsius)
            let elapsed = frames.map(\.delay).reduce(0, +)
            scheduleBeat(after: max(0.2, period - elapsed))
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    /// The popover's SwiftUI tree exists only while it is shown: a closed but
    /// retained hosting view keeps observing the store and re-rendering its
    /// charts on every poll (measured: 0.5% → 1.8% CPU and +75 MB after one opening).
    public func showPopover() {
        guard !popover.isShown, let button = statusItem.button else { return }
        let openSettings = self.openSettings
        popover.contentViewController = NSHostingController(rootView: PopoverView(store: store) { [weak self] in
            self?.closePopover()
            openSettings()
        })
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    public func closePopover() {
        popover.performClose(nil)
    }

    public func popoverWillShow(_ notification: Notification) {
        store.popoverDidOpen()
    }

    public func popoverDidClose(_ notification: Notification) {
        store.popoverDidClose()
        popover.contentViewController = nil
    }
}

/// The settings window: a toolbar-style tab view (like Safari's or Xcode's
/// Settings), one fixed-size SwiftUI pane per tab. Built on demand and released
/// when closed, so its live preview and observers cost nothing afterwards
/// (a retained closed window measured ~11% CPU).
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let store: PulseStore
    private var window: NSWindow?

    public init(store: PulseStore) {
        self.store = store
    }

    public func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        // Release after AppKit finishes closing it.
        DispatchQueue.main.async { [weak self] in
            closing.contentViewController = nil
            if self?.window === closing { self?.window = nil }
        }
    }

    public func show() {
        if window == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            tabs.transitionOptions = [.crossfade, .allowUserInteraction]
            tabs.canPropagateSelectedChildViewControllerTitle = false
            for pane in SettingsPane.allCases {
                let controller = NSHostingController(rootView: SettingsView(store: store, pane: pane))
                controller.sizingOptions = [.preferredContentSize]
                controller.preferredContentSize = pane.size
                controller.title = pane.title
                let item = NSTabViewItem(viewController: controller)
                item.label = pane.title
                item.image = NSImage(systemSymbolName: pane.systemImage, accessibilityDescription: pane.title)
                tabs.addTabViewItem(item)
            }
            let window = NSWindow(contentViewController: tabs)
            window.title = "Pulse Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(SettingsPane.general.size)
            if !window.setFrameUsingName("PulseSettings") { window.center() }
            window.setFrameAutosaveName("PulseSettings")
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    public func close() {
        window?.performClose(nil)
    }
}
