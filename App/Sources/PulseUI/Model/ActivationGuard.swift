import AppKit
import OSLog
import ProductIdentity

/// Keeps Pulse in front while a privileged action runs. The administrator
/// prompt belongs to another process; when it closes, macOS activates the
/// previous regular app, and Pulse (a menu bar app, not in the Dock) loses
/// its window behind it. A cooperative `NSApp.activate()` afterwards may be
/// declined, since the user did not ask for that switch.
///
/// While the guard is armed, a regular app becoming active (the prompt hosts
/// are not regular apps) is taken as that unwanted switch and undone at once.
@MainActor
final class ActivationGuard {
    private static let logger = Logger(subsystem: ProductIdentity.logSubsystem, category: "activation")
    private var observer: NSObjectProtocol?
    private let window: () -> NSWindow?

    init(window: @escaping () -> NSWindow?) {
        self.window = window
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier ?? "?"
            let regular = app?.activationPolicy == .regular
            let isSelf = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            MainActor.assumeIsolated { self?.didActivate(id: id, regular: regular, isSelf: isSelf) }
        }
    }

    func didActivate(id: String, regular: Bool, isSelf: Bool) {
        Self.logger.info("Activated during privileged action: \(id, privacy: .public) (regular: \(regular, privacy: .public))")
        guard !isSelf, Self.shouldReclaim(regular: regular) else { return }
        reclaim()
    }

    /// The password prompt runs in non-regular processes (SecurityAgent,
    /// osascript); a regular app means the system switched away after it.
    nonisolated static func shouldReclaim(regular: Bool) -> Bool { regular }

    /// Disarms the guard and brings Pulse back if it is not in front.
    func finish() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            reclaim()
        }
    }

    private func reclaim() {
        Self.logger.info("Bringing Pulse back in front")
        // A cooperative `NSApp.activate()` is declined here (tested on macOS
        // 27): the user did not ask for the switch we undo, so nobody yields.
        // Activating "from" the app in front counts as that app yielding.
        if let front = NSWorkspace.shared.frontmostApplication {
            NSRunningApplication.current.activate(from: front, options: [.activateAllWindows])
        }
        window()?.makeKeyAndOrderFront(nil)
    }
}
