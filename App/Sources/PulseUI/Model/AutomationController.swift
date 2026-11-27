import AppKit
import Foundation
import IOKit.ps
import Observation

/// Runs the automatic switching rules: keeps a `SystemSnapshot` up to date
/// from system notifications (nothing is polled) and, after each store poll,
/// asks the engine whether to switch profile.
@MainActor
@Observable
public final class AutomationController {
    public static let rulesKey = "automationRules"
    public static let enabledKey = "automationEnabled"

    public private(set) var rules: [AutomationRule]
    public var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Self.enabledKey)
            if enabled { engine = AutomationEngine(rules: rules) }
        }
    }
    public private(set) var snapshot = SystemSnapshot()
    /// The rule applied right now, if any.
    public private(set) var activeRule: AutomationRule?
    public private(set) var suspendedForSafety = false
    /// The Mac has a battery (battery rules are offered only then).
    public let hasBattery: Bool

    @ObservationIgnored private let store: PulseStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var engine: AutomationEngine
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var powerSource: CFRunLoopSource?

    public init(store: PulseStore, defaults: UserDefaults = .standard, observeSystem: Bool = true) {
        self.store = store
        self.defaults = defaults
        let rules = (defaults.data(forKey: Self.rulesKey)).flatMap { try? JSONDecoder().decode([AutomationRule].self, from: $0) } ?? []
        self.rules = rules
        self.enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        self.engine = AutomationEngine(rules: rules)
        self.hasBattery = Self.readOnBattery() != nil && Self.hasInternalBattery()
        if observeSystem { startObserving() }
        store.observeSafety { [weak self] event in
            guard let self, case .engaged = event else { return }
            self.engine.safetyTripped()
            self.suspendedForSafety = true
            self.activeRule = nil
        }
        store.onRefresh = { [weak self] in self?.tick() }
    }

    // MARK: Rules

    public func setRules(_ rules: [AutomationRule]) {
        self.rules = rules
        engine.rules = rules
        if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: Self.rulesKey) }
    }

    public func add(_ rule: AutomationRule) { setRules(rules + [rule]) }

    public func update(_ rule: AutomationRule) {
        setRules(rules.map { $0.id == rule.id ? rule : $0 })
    }

    public func remove(_ id: UUID) { setRules(rules.filter { $0.id != id }) }

    public func move(_ id: UUID, by offset: Int) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard rules.indices.contains(target) else { return }
        var reordered = rules
        reordered.swapAt(index, target)
        setRules(reordered)
    }

    // MARK: Evaluation

    /// After each poll: switch profile if the rules ask for it. Paused during a
    /// stress test, which owns the profile and restores the previous one at the
    /// end: the rules then see the same profile as before and carry on.
    func tick(now: Date = Date()) {
        guard enabled, !rules.isEmpty, store.canSwitchProfile, store.busyProfile == nil else { return }
        let wanted = engine.evaluate(snapshot, activeProfile: store.activeProfile, now: now)
        if activeRule != engine.activeRule { activeRule = engine.activeRule }
        if suspendedForSafety != engine.suspendedForSafety { suspendedForSafety = engine.suspendedForSafety }
        if let wanted {
            Task { await store.activate(wanted) }
        }
    }

    /// For tests and previews.
    func setSnapshot(_ snapshot: SystemSnapshot) { self.snapshot = snapshot }

    // MARK: System observation

    private func startObserving() {
        let workspace = NSWorkspace.shared
        snapshot.runningApps = Set(workspace.runningApplications.compactMap(\.bundleIdentifier))
        snapshot.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        snapshot.onBattery = Self.readOnBattery()

        let center = workspace.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                let launched = note.name == NSWorkspace.didLaunchApplicationNotification
                MainActor.assumeIsolated {
                    guard let self, let id else { return }
                    if launched { self.snapshot.runningApps.insert(id) } else {
                        // Another instance may still run.
                        let stillRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == id }
                        if !stillRunning { self.snapshot.runningApps.remove(id) }
                    }
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.snapshot.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
        })
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let controller = Unmanaged<AutomationController>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { controller.snapshot.onBattery = AutomationController.readOnBattery() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
    }

    /// true on battery, false on the adapter, nil if unknown.
    nonisolated static func readOnBattery() -> Bool? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return nil }
        return type == kIOPSBatteryPowerValue
    }

    nonisolated static func hasInternalBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    // MARK: Display

    /// Name of an app from its bundle identifier.
    public static func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    public static func describe(_ condition: AutomationCondition) -> String {
        switch condition {
        case .appsRunning(let ids):
            let names = ids.map(appName)
            return names.count == 1 ? "\(names[0]) is open" : "\(names.dropLast().joined(separator: ", ")) or \(names.last ?? "") is open"
        case .lowPowerMode: return "Low Power Mode is on"
        case .onBattery: return "On battery"
        case .onPowerAdapter: return "On power adapter"
        }
    }
}
