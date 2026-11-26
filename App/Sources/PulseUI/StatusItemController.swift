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
    private let openSettings: @MainActor (SettingsDestination) -> Void
    private let statusItem: NSStatusItem
    /// Created on open and dropped on close (see `showPopover`).
    private var popover: NSPopover?
    private var renderedKey: String?
    private var frameCache: [Double: NSImage] = [:]
    private var frameCacheKey: String?
    private var observers: [NSObjectProtocol] = []
    private var beatTimer: Timer?
    private var screensAsleep = false

    public init(store: PulseStore, openSettings: @escaping @MainActor (SettingsDestination) -> Void) {
        self.store = store
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

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
        if popover?.isShown == true {
            closePopover()
        } else {
            showPopover()
        }
    }

    /// The popover and its SwiftUI tree exist only while shown. A closed popover
    /// keeps its window and hosting view (clearing `contentViewController` does
    /// not release them), which kept observing the store and re-rendering the
    /// charts on every poll: ~3.5% CPU and +75 MB after a single opening.
    public func showPopover() {
        guard popover?.isShown != true, let button = statusItem.button else { return }
        let openSettings = self.openSettings
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverView(store: store) { [weak self] destination in
            self?.closePopover()
            openSettings(destination)
        })
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    public func closePopover() {
        popover?.performClose(nil)
    }

    public func popoverWillShow(_ notification: Notification) {
        store.popoverDidOpen()
    }

    /// Releases the popover as soon as it starts closing. `popoverDidClose`
    /// is not a reliable signal: when the close animation cannot run (app not
    /// active) it never arrives, and the hidden popover kept rendering.
    public func popoverWillClose(_ notification: Notification) {
        store.popoverDidClose()
        guard let closing = notification.object as? NSPopover, closing === popover else { return }
        popover = nil
        // Let the close animation finish before tearing down the content.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if closing.isShown { closing.close() }
            closing.contentViewController = nil
        }
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
    private var tabs: NSTabViewController?
    public let navigation = SettingsNavigation()
    public static let windowIdentifier = NSUserInterfaceItemIdentifier("PulseSettings")

    private let automation: AutomationController?

    public init(store: PulseStore, automation: AutomationController? = nil) {
        self.store = store
        self.automation = automation
    }

    /// Saves unsaved curve edits before quitting; `reply(true)` lets the app
    /// quit. Only edits that cannot be saved (invalid curve, daemon error)
    /// make it ask.
    public func confirmTermination(_ reply: @escaping @MainActor (Bool) -> Void) {
        guard navigation.hasUnsavedEdits, let editor = navigation.editor else {
            reply(true)
            return
        }
        Task { @MainActor in
            if await autosave(editor) {
                reply(true)
                return
            }
            show(.curve(nil))
            reply(unsavableAlert(editor, quitting: true).runModal() == .alertFirstButtonReturn && discard(editor))
        }
    }

    /// Saves unsaved curve edits, then closes; asks only when they cannot be
    /// saved.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard navigation.hasUnsavedEdits, let editor = navigation.editor else { return true }
        Task { @MainActor [weak self, weak sender] in
            guard let self, let sender else { return }
            if await self.autosave(editor) {
                sender.close()
                return
            }
            self.unsavableAlert(editor, quitting: false).beginSheetModal(for: sender) { [weak self, weak sender] response in
                MainActor.assumeIsolated {
                    if response == .alertFirstButtonReturn, let self, self.discard(editor) { sender?.close() }
                }
            }
        }
        return false
    }

    /// Saves the editor's draft as is; false when it is invalid or the
    /// daemon refused it.
    private func autosave(_ editor: CurveEditorModel) async -> Bool {
        guard editor.draft.validationError == nil else { return false }
        let spec = editor.draft.spec
        guard await store.save(spec, activate: false) else { return false }
        editor.reload(spec: spec, range: editor.draft.range)
        return true
    }

    private func discard(_ editor: CurveEditorModel) -> Bool {
        editor.revert()
        return true
    }

    private func unsavableAlert(_ editor: CurveEditorModel, quitting: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Changes to “\(editor.draft.spec.label ?? editor.draft.spec.name)” can't be saved"
        alert.informativeText = (editor.draft.validationError ?? store.actionError ?? "The Pulse service refused them.")
            + (quitting ? "\n\nQuit anyway and lose them?" : "\n\nClose anyway and lose them?")
        alert.addButton(withTitle: quitting ? "Quit and Discard" : "Discard").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    public func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        // Release after AppKit finishes closing it.
        DispatchQueue.main.async { [weak self] in
            closing.contentViewController = nil
            if self?.window === closing {
                self?.window = nil
                self?.tabs = nil
            }
        }
    }

    public func show(_ destination: SettingsDestination = .pane(.general)) {
        navigation.apply(destination)
        if window == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            tabs.transitionOptions = [.crossfade, .allowUserInteraction]
            tabs.canPropagateSelectedChildViewControllerTitle = false
            for pane in SettingsPane.allCases {
                let controller = NSHostingController(rootView: SettingsView(store: store, pane: pane, navigation: navigation, automation: automation))
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
            window.identifier = Self.windowIdentifier
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(SettingsPane.general.size)
            if !window.setFrameUsingName("PulseSettings") { window.center() }
            window.setFrameAutosaveName("PulseSettings")
            self.window = window
            self.tabs = tabs
        }
        if let index = SettingsPane.allCases.firstIndex(of: destination.pane), tabs?.selectedTabViewItemIndex != index {
            tabs?.selectedTabViewItemIndex = index
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    public func close() {
        window?.performClose(nil)
    }
}
