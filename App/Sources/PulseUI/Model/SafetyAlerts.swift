import Foundation
import SMCtlProtocol
@preconcurrency import UserNotifications

/// A change of the daemon's safety guard worth telling the user about.
public enum SafetyEvent: Equatable, Sendable {
    /// The guard tripped: the daemon handed the fans back to macOS and set the
    /// profile to automatic. `interruptedProfile` was active just before.
    case engaged(reason: String?, interruptedProfile: String?)
    /// Temperatures are back under the limit; fans stay under macOS control.
    case released(interruptedProfile: String?)
}

/// Turns successive daemon telemetry into safety events: one per transition,
/// none for the state found at launch.
public struct SafetyAlertTracker: Sendable {
    private var latched: Bool?
    /// The profile of the last poll before the trip (the trip itself switches
    /// the daemon to "auto" in the same tick).
    private var lastProfile: String?
    private var interrupted: String?

    public init() {}

    /// Call with each telemetry read from the daemon (not the direct-sensor
    /// fallback, which knows nothing of the guard).
    public mutating func update(_ telemetry: TelemetryDTO) -> SafetyEvent? {
        let now = telemetry.safety.latched
        defer {
            latched = now
            if !now { lastProfile = telemetry.profile }
        }
        switch (latched, now) {
        case (false?, true):
            interrupted = lastProfile.flatMap { ["auto", "manual"].contains($0) ? nil : $0 }
            return .engaged(reason: telemetry.safety.lastTripReason, interruptedProfile: interrupted)
        case (true?, false):
            defer { interrupted = nil }
            return .released(interruptedProfile: interrupted)
        default:
            return nil
        }
    }
}

/// The words of a safety notification.
public struct SafetyMessage: Equatable, Sendable {
    public var title: String
    public var body: String
    /// The profile the "Resume" action reactivates.
    public var resumeProfile: String?

    /// "temperature Tp0E 112.3C held at/above safety ceiling 110.0C for 2
    /// consecutive checks" → "Tp0E reached 112 °C (limit 110 °C)".
    static func describe(reason: String?) -> String? {
        guard let reason else { return nil }
        if reason.hasPrefix("no readable temperature") {
            return "No temperature sensor could be read"
        }
        let pattern = /temperature (\S+) ([0-9.]+)C held at\/above safety ceiling ([0-9.]+)C/
        guard let match = reason.firstMatch(of: pattern),
              let celsius = Double(match.2), let ceiling = Double(match.3) else { return nil }
        return "\(match.1) reached \(Int(celsius.rounded())) °C (limit \(Int(ceiling.rounded())) °C)"
    }

    public static func make(_ event: SafetyEvent, title profileTitle: (String) -> String) -> SafetyMessage {
        switch event {
        case .engaged(let reason, let profile):
            var body = (describe(reason: reason).map { "\($0). " } ?? "")
                + "Pulse handed the fans back to macOS."
            if let profile { body += " \(profileTitle(profile)) is paused." }
            return SafetyMessage(title: "Temperature limit reached", body: body, resumeProfile: nil)
        case .released(let profile):
            guard let profile else {
                return SafetyMessage(title: "Temperatures back to normal", body: "macOS keeps controlling the fans.", resumeProfile: nil)
            }
            return SafetyMessage(title: "Temperatures back to normal",
                                 body: "macOS is still controlling the fans. Resume \(profileTitle(profile)) when you're ready.",
                                 resumeProfile: profile)
        }
    }
}

/// Where safety messages go; the system notification center in the app.
@MainActor
public protocol SafetyMessageSink: AnyObject {
    func post(_ message: SafetyMessage)
}

/// Posts safety events as notifications, if the user allows them (Settings,
/// General). A "Resume" action on the all-clear reactivates the paused profile.
@MainActor
public final class SafetyNotifier: NSObject {
    public static let resumeAction = "resume"
    static let releasedCategory = "safety.released"

    private let store: PulseStore
    private let sink: SafetyMessageSink

    public init(store: PulseStore, sink: SafetyMessageSink? = nil) {
        self.store = store
        self.sink = sink ?? SystemNotifications()
        super.init()
        (self.sink as? SystemNotifications)?.onResume = { [weak store] profile in
            Task { await store?.activate(profile) }
        }
        store.onSafetyEvent = { [weak self] event in self?.handle(event) }
    }

    public static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.safetyNotifications) as? Bool ?? true
    }

    func handle(_ event: SafetyEvent) {
        guard Self.isEnabled else { return }
        sink.post(SafetyMessage.make(event) { [store] in store.title(forProfile: $0) })
    }
}

/// `UNUserNotificationCenter`, asked for permission on first use.
@MainActor
final class SystemNotifications: NSObject, SafetyMessageSink, @preconcurrency UNUserNotificationCenterDelegate {
    var onResume: ((String) -> Void)?
    private var configured = false

    func post(_ message: SafetyMessage) {
        let center = UNUserNotificationCenter.current()
        if !configured {
            configured = true
            center.delegate = self
            let resume = UNNotificationAction(identifier: SafetyNotifier.resumeAction, title: "Resume Profile")
            center.setNotificationCategories([
                UNNotificationCategory(identifier: SafetyNotifier.releasedCategory, actions: [resume], intentIdentifiers: []),
            ])
        }
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        if let profile = message.resumeProfile {
            content.categoryIdentifier = SafetyNotifier.releasedCategory
            content.userInfo = ["profile": profile]
        } else {
            content.sound = .default
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            // One notification per kind: the all-clear replaces the alert.
            center.add(UNNotificationRequest(identifier: "pulse.safety", content: content, trigger: nil))
        }
    }

    /// Shown even while Pulse is the active app (settings window in front).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == SafetyNotifier.resumeAction,
              let profile = response.notification.request.content.userInfo["profile"] as? String else { return }
        onResume?(profile)
    }
}
