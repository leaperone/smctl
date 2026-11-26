import Foundation

/// What a rule waits for.
public enum AutomationCondition: Codable, Hashable, Sendable {
    /// One of these apps (bundle identifiers) is open. Covers games: macOS
    /// publishes nothing usable about Game Mode, and many games don't declare
    /// themselves as games.
    case appsRunning([String])
    /// Low Power Mode is on.
    case lowPowerMode
    /// Running on battery.
    case onBattery
    /// Running on the power adapter.
    case onPowerAdapter

    func holds(in snapshot: SystemSnapshot) -> Bool {
        switch self {
        case .appsRunning(let ids): return !snapshot.runningApps.isDisjoint(with: ids)
        case .lowPowerMode: return snapshot.lowPowerMode
        case .onBattery: return snapshot.onBattery == true
        case .onPowerAdapter: return snapshot.onBattery == false
        }
    }
}

/// "When ‹condition›, use ‹profile›".
public struct AutomationRule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var condition: AutomationCondition
    public var profile: String
    public var enabled: Bool

    public init(id: UUID = UUID(), condition: AutomationCondition, profile: String, enabled: Bool = true) {
        self.id = id
        self.condition = condition
        self.profile = profile
        self.enabled = enabled
    }
}

/// The state of the Mac the rules look at.
public struct SystemSnapshot: Equatable, Sendable {
    public var runningApps: Set<String>
    public var lowPowerMode: Bool
    /// nil on Macs without a battery.
    public var onBattery: Bool?

    public init(runningApps: Set<String> = [], lowPowerMode: Bool = false, onBattery: Bool? = nil) {
        self.runningApps = runningApps
        self.lowPowerMode = lowPowerMode
        self.onBattery = onBattery
    }
}

/// Decides which profile the rules want. Pure: fed with the system state, the
/// daemon's active profile and the time, it returns a profile to activate.
///
/// - The first enabled rule whose condition has held for `settleSeconds` wins;
///   with none, the **base profile** (the last one chosen by hand) applies.
/// - A profile chosen by hand (app, command line) becomes the new base, and
///   the rules that hold at that moment are suspended until their condition
///   goes away: Pulse never undoes a choice the user just made.
/// - After a safety trip the daemon stays on automatic until the user picks a
///   profile: rules are suspended until then.
public struct AutomationEngine: Sendable {
    public static let settleSeconds: TimeInterval = 5

    public var rules: [AutomationRule]
    public private(set) var baseProfile: String?
    public private(set) var suspendedForSafety = false
    /// The rule currently applied, for display ("Performance · War Thunder").
    public private(set) var activeRule: AutomationRule?

    private var heldSince: [UUID: Date] = [:]
    private var suspended: Set<UUID> = []
    /// The profile Pulse last asked for; any other active profile was chosen
    /// by someone else.
    private var lastApplied: String?
    /// A switch Pulse asked for and the daemon hasn't reported yet: until it
    /// does, the old profile in telemetry is not a manual choice.
    private var awaiting: (profile: String, from: String, since: Date)?
    public static let confirmationTimeout: TimeInterval = 10

    public init(rules: [AutomationRule], baseProfile: String? = nil) {
        self.rules = rules
        self.baseProfile = baseProfile
    }

    /// Call when the safety guard trips: the daemon switched to "auto" itself.
    public mutating func safetyTripped() {
        suspendedForSafety = true
        awaiting = nil
        lastApplied = "auto"
        activeRule = nil
    }

    /// Returns the profile to activate now, or nil to leave things as they are.
    public mutating func evaluate(_ snapshot: SystemSnapshot, activeProfile: String, now: Date) -> String? {
        // Track how long each condition has held; a condition that goes away
        // lifts its manual suspension.
        for rule in rules {
            if rule.enabled && rule.condition.holds(in: snapshot) {
                if heldSince[rule.id] == nil { heldSince[rule.id] = now }
            } else {
                heldSince[rule.id] = nil
                suspended.remove(rule.id)
            }
        }
        let settled = rules.filter { rule in
            heldSince[rule.id].map { now.timeIntervalSince($0) >= Self.settleSeconds } ?? false
        }

        if let pending = awaiting {
            if activeProfile == pending.profile {
                awaiting = nil
            } else if activeProfile != pending.from {
                // Neither the old nor the new profile: chosen by hand meanwhile.
                awaiting = nil
            } else if now.timeIntervalSince(pending.since) < Self.confirmationTimeout {
                return nil
            } else {
                // The switch failed (daemon refused it): don't read the
                // unchanged profile as a manual choice, and try again later.
                awaiting = nil
                lastApplied = activeProfile
            }
        }
        if baseProfile == nil { baseProfile = activeProfile }
        if let lastApplied, activeProfile != lastApplied {
            // Chosen by hand (app, popover, command line).
            if activeProfile != "manual" { baseProfile = activeProfile }
            suspended.formUnion(settled.map(\.id))
            suspendedForSafety = false
            activeRule = nil
            self.lastApplied = activeProfile
            return nil
        }
        if lastApplied == nil { lastApplied = activeProfile }
        guard !suspendedForSafety else { return nil }

        let winner = settled.first { !suspended.contains($0.id) }
        activeRule = winner
        guard let wanted = winner?.profile ?? baseProfile, wanted != activeProfile else { return nil }
        lastApplied = wanted
        awaiting = (wanted, activeProfile, now)
        return wanted
    }
}
