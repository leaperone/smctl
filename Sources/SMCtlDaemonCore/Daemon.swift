import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt
import OSLog
import PolicyEngine
import SMCCore
import SMCtlProtocol
import TOMLKit

private let logger = Logger(subsystem: "one.leaper.smctl", category: "daemon")
/// Resolved once at startup; non-nil iff this binary is Developer ID signed.
private let enforcedTeamID = CodeSignPolicy.ownTeamID()
private let ioMessageCanSystemSleep = natural_t(0xe0000270)
private let ioMessageSystemWillSleep = natural_t(0xe0000280)
private let ioMessageSystemWillPowerOn = natural_t(0xe0000320)
private let ioMessageSystemHasPoweredOn = natural_t(0xe0000300)

struct DaemonConfig: Codable, Equatable, Sendable {
    var battery: BatteryConfig
    var fan: FanConfig
    var safety: SafetyConfig
    var update: UpdateConfig
    var sentry: SentryConfig
    var alerts: [AlertConfig]

    init(
        battery: BatteryConfig = BatteryConfig(),
        fan: FanConfig = FanConfig(),
        safety: SafetyConfig = SafetyConfig(),
        update: UpdateConfig = UpdateConfig(),
        sentry: SentryConfig = SentryConfig(),
        alerts: [AlertConfig] = []
    ) {
        self.battery = battery
        self.fan = fan
        self.safety = safety
        self.update = update
        self.sentry = sentry
        self.alerts = alerts
    }

    enum CodingKeys: String, CodingKey {
        case battery, fan, safety, update, sentry
        case alerts = "alert"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        battery = try container.decodeIfPresent(BatteryConfig.self, forKey: .battery) ?? BatteryConfig()
        fan = try container.decodeIfPresent(FanConfig.self, forKey: .fan) ?? FanConfig()
        safety = try container.decodeIfPresent(SafetyConfig.self, forKey: .safety) ?? SafetyConfig()
        update = try container.decodeIfPresent(UpdateConfig.self, forKey: .update) ?? UpdateConfig()
        sentry = try container.decodeIfPresent(SentryConfig.self, forKey: .sentry) ?? SentryConfig()
        alerts = try container.decodeIfPresent([AlertConfig].self, forKey: .alerts) ?? []
    }
}

struct UpdateConfig: Codable, Equatable, Sendable {
    /// When true, the daemon contacts the GitHub releases API once a day to learn the
    /// latest version, surfaced as a hint in the CLI. Set to false for a fully offline
    /// daemon when Sentry and alert webhooks are also unconfigured.
    var check: Bool

    init(check: Bool = true) {
        self.check = check
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        check = try container.decodeIfPresent(Bool.self, forKey: .check) ?? true
    }
}

struct SentryConfig: Codable, Equatable, Sendable {
    /// Empty means disabled. The project DSN is intentionally config-owned so public
    /// builds do not phone home unless the operator opts in.
    var dsn: String
    var environment: String
    var debug: Bool
    var traces_sample_rate: Double

    init(dsn: String = "", environment: String = "production", debug: Bool = false, traces_sample_rate: Double = 0) {
        self.dsn = dsn
        self.environment = environment
        self.debug = debug
        self.traces_sample_rate = traces_sample_rate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dsn = try container.decodeIfPresent(String.self, forKey: .dsn) ?? ""
        environment = try container.decodeIfPresent(String.self, forKey: .environment) ?? "production"
        debug = try container.decodeIfPresent(Bool.self, forKey: .debug) ?? false
        let sampleRate = try container.decodeLenientDoubleIfPresent(forKey: .traces_sample_rate) ?? 0
        traces_sample_rate = min(max(sampleRate, 0), 1)
    }
}

struct BatteryConfig: Codable, Equatable, Sendable {
    var limit: String
    var sleep_policy: String
    /// When true, maintain actively discharges down to the band by cutting
    /// adapter power while above the upper bound (unreliable in clamshell mode).
    var force_discharge: Bool

    init(limit: String = "100", sleep_policy: String = "strict", force_discharge: Bool = false) {
        self.limit = limit
        self.sleep_policy = sleep_policy
        self.force_discharge = force_discharge
    }

    // Defensive decoding: missing keys fall back to defaults. Synthesized decoding
    // would reject any hand-edited (or older-version) config and silently reset
    // EVERYTHING to defaults via loadConfig's catch — losing the user's policy.
    // Unknown keys (including the retired `magsafe_led`) are simply ignored.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limit = try container.decodeIfPresent(String.self, forKey: .limit) ?? "100"
        sleep_policy = try container.decodeIfPresent(String.self, forKey: .sleep_policy) ?? "strict"
        force_discharge = try container.decodeIfPresent(Bool.self, forKey: .force_discharge) ?? false
    }
}

struct FanConfig: Codable, Equatable, Sendable {
    var profile: String
    var curves: [FanCurveConfig]

    init(profile: String = "auto", curves: [FanCurveConfig] = []) {
        self.profile = profile
        self.curves = curves
    }

    // Defensive decoding — see BatteryConfig. The config file written by the daemon
    // itself omits `curves` when none are defined; synthesized decoding choked on
    // that and reset the whole config on every daemon restart.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profile = try container.decodeIfPresent(String.self, forKey: .profile) ?? "auto"
        curves = try container.decodeIfPresent([FanCurveConfig].self, forKey: .curves) ?? []
    }
}

struct FanCurveConfig: Codable, Equatable, Sendable {
    var name: String
    var sensors: [String]
    var points: [[FanPointValue]]
    var hysteresis: Double
    var slew_rate: Double?
    var fall_slew_rate: Double?
    var weights: [String: Double]?

    init(
        name: String,
        sensors: [String] = [],
        points: [[FanPointValue]],
        hysteresis: Double = 0,
        slew_rate: Double? = nil,
        fall_slew_rate: Double? = nil,
        weights: [String: Double]? = nil
    ) {
        self.name = name
        self.sensors = sensors
        self.points = points
        self.hysteresis = hysteresis
        self.slew_rate = slew_rate
        self.fall_slew_rate = fall_slew_rate
        self.weights = weights
    }

    enum CodingKeys: String, CodingKey {
        case name, sensors, points, hysteresis, slew_rate, fall_slew_rate, weights
    }

    // Custom decoding so optional numeric tuning fields default rather than throwing
    // keyNotFound and accept TOML integers — see decodeLenientDoubleIfPresent (#9).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        sensors = try container.decodeIfPresent([String].self, forKey: .sensors) ?? []
        points = try container.decode([[FanPointValue]].self, forKey: .points)
        hysteresis = try container.decodeLenientDoubleIfPresent(forKey: .hysteresis) ?? 0
        slew_rate = try container.decodeLenientDoubleIfPresent(forKey: .slew_rate)
        fall_slew_rate = try container.decodeLenientDoubleIfPresent(forKey: .fall_slew_rate)
        weights = try container.decodeLenientDoubleDictionaryIfPresent(forKey: .weights)
    }
}

enum FanPointValue: Codable, Equatable, Sendable {
    case number(Double)
    case maximum

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            self = .number(number)
            return
        }
        // TOML keeps integers and floats as distinct types, so `[50, "max"]` decodes
        // the 50 as Int, not Double. Accept it as a number instead of falling through
        // to the String branch and rejecting the whole curve.
        if let integer = try? container.decode(Int.self) {
            self = .number(Double(integer))
            return
        }
        let string = try container.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if string == "max" {
            self = .maximum
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Fan point values must be numbers or 'max'.")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value):
            try container.encode(value)
        case .maximum:
            try container.encode("max")
        }
    }
}

/// TOML keeps integers and floats as distinct types. A hand-written `100` for a
/// Double config field would otherwise throw a type mismatch and — via loadConfig's
/// catch — silently reset the entire config to defaults (issue #9). Accept integers
/// as Doubles; a genuinely wrong type still surfaces as a decoding error.
extension KeyedDecodingContainer {
    func decodeLenientDoubleIfPresent(forKey key: Key) throws -> Double? {
        guard contains(key) else { return nil }
        if let value = try? decode(Double.self, forKey: key) { return value }
        if let integer = try? decode(Int.self, forKey: key) { return Double(integer) }
        return try decode(Double.self, forKey: key)
    }

    /// Same integer leniency for a `[String: Double]` field (fan curve weights):
    /// `weights = { cpu = 2 }` decodes the values as Int and would otherwise throw,
    /// discarding the whole config.
    func decodeLenientDoubleDictionaryIfPresent(forKey key: Key) throws -> [String: Double]? {
        guard contains(key) else { return nil }
        if let value = try? decode([String: Double].self, forKey: key) { return value }
        if let integers = try? decode([String: Int].self, forKey: key) { return integers.mapValues(Double.init) }
        // Mixed integer/float entries: decode value-by-value (a wrong type still throws).
        let nested = try nestedContainer(keyedBy: LenientDictKey.self, forKey: key)
        var result: [String: Double] = [:]
        for entry in nested.allKeys {
            result[entry.stringValue] = try nested.decodeLenientDoubleIfPresent(forKey: entry)
        }
        return result
    }
}

private struct LenientDictKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

struct SafetyConfig: Codable, Equatable, Sendable {
    var temp_ceiling: Double
    /// Advanced opt-in: allows `fan set --force` to target below the fan's reported
    /// minimum RPM (e.g. full fan stop). Off by default; the flag alone is not enough.
    var allow_below_minimum: Bool

    init(temp_ceiling: Double = FanSafetyGuard.defaultCeilingCelsius, allow_below_minimum: Bool = false) {
        self.temp_ceiling = temp_ceiling
        self.allow_below_minimum = allow_below_minimum
    }

    // Defensive decoding — see BatteryConfig.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        temp_ceiling = try container.decodeLenientDoubleIfPresent(forKey: .temp_ceiling)
            ?? FanSafetyGuard.defaultCeilingCelsius
        allow_below_minimum = try container.decodeIfPresent(Bool.self, forKey: .allow_below_minimum) ?? false
    }
}

enum DaemonError: Error, CustomStringConvertible {
    case unsupported(String)
    case unauthorized
    case untrustedClient

    var description: String {
        switch self {
        case .unsupported(let message):
            return message
        case .unauthorized:
            return "Write requests require root or an admin user."
        case .untrustedClient:
            return "Write requests require a client signed by the same Developer ID team as smctld."
        }
    }
}

/// Wraps a daemon status message so it can be reported through the `Error`-based
/// Sentry path without pretending it was thrown.
private struct DaemonMessageError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private enum ForegroundDischarge {
    case active(owner: UUID, target: Int, expiresAt: TimeInterval)
    case restoring
}

public final class SmctlDaemon: @unchecked Sendable {
    let configPath: String
    static let period: TimeInterval = 10
    static let foregroundDischargeLease: TimeInterval = 30
    static let fanUnlockBackoff: TimeInterval = 30

    private let queue = DispatchQueue(label: "one.leaper.smctl.daemon.state")
    var config = DaemonConfig()
    private var chargeMachine = ChargeStateMachine(period: SmctlDaemon.period)
    private var sleepMachine = SleepStateMachine(policy: .strict)
    private var capabilities = Capabilities()
    var ftstGate = FtstGateManager()
    var manualFanTargets: [Int: Double] = [:]
    private var pendingFanRestores: Set<Int> = []
    /// Per-fan retry gate after a failed manual operation. Prevents the 1 Hz policy loop
    /// from re-entering the multi-second FTST retry loop (and blocking the state queue)
    /// on every single tick while the SMC keeps rejecting the mode write.
    private var fanUnlockBackoffUntil: [Int: Date] = [:]
    private var foregroundDischarge: ForegroundDischarge?
    private var fanCurveEngines: [Int: FanCurveEngine] = [:]
    private var runtimeFanProfile: String?
    // Stateful: carries the safety latch across ticks; ceiling refreshed from config.
    var safetyGuard = FanSafetyGuard()
    // Stateful: carries per-rule debounce/cooldown across ticks.
    var alertEngine = AlertEngine()
    private let alertRunner = AlertActionRunner()
    private var alertHistory: [AlertEvent] = []
    private static let alertHistoryLimit = 50
    private var lastEvaluation: Date?
    private var lastError: String?
    /// Set when the on-disk config fails to parse. The daemon keeps running on
    /// defaults, so without this the failure was invisible — `daemon status` showed
    /// `last error: -` while silently ignoring the user's config (issue #9).
    private var configError: String?
    private var lastWriteError: String?
    private var timer: DispatchSourceTimer?
    private var fanTimer: DispatchSourceTimer?
    private var updateTimer: DispatchSourceTimer?
    private var latestKnownVersion: String?
    private var powerConnection: io_connect_t = 0
    private var powerNotificationPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0

    private let backend: (any SMCWriteBackend)?
    private let reader: SensorReader?

    public convenience init() {
        var backend: SMCConnection?
        var initialError: String?
        do {
            backend = try SMCConnection()
        } catch {
            initialError = String(describing: error)
            logger.error("Unable to open AppleSMC: \(String(describing: error), privacy: .public)")
        }
        let reader = backend.map { SensorReader(backend: $0) }
        self.init(
            backend: backend,
            reader: reader,
            capabilities: reader?.capabilities() ?? Capabilities(),
            configPath: "/etc/smctl/config.toml",
            initialError: initialError
        )
    }

    /// Designated initializer with injectable seams; tests drive the daemon with a
    /// mock backend, synthetic capabilities, and a temporary config path.
    init(
        backend: (any SMCWriteBackend)?,
        reader: SensorReader?,
        capabilities: Capabilities,
        configPath: String,
        initialError: String? = nil
    ) {
        self.backend = backend
        self.reader = reader
        self.capabilities = capabilities
        self.configPath = configPath
        self.lastError = initialError
        reloadConfig()
    }

    public func start() {
        registerPowerNotifications()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .seconds(1), repeating: SmctlDaemon.period)
        source.setEventHandler { [weak self] in
            self?.evaluateLocked()
        }
        source.resume()
        let fanSource = DispatchSource.makeTimerSource(queue: queue)
        fanSource.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        fanSource.setEventHandler { [weak self] in
            self?.tickFanAndAlertsLocked()
        }
        fanSource.resume()
        queue.sync {
            timer = source
            fanTimer = fanSource
            reconcileAdapterStartupLocked()
            reconcileFanStartupLocked()
        }
        startUpdateCheck()
    }

    /// Daily update check (opt-out via `[update] check = false`). First check is
    /// delayed so it never competes with startup; the result is cached for the CLI
    /// to surface. Network and parse failures are silent — this must never affect
    /// the daemon's real job.
    private func startUpdateCheck() {
        guard config.update.check else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .seconds(10), repeating: .seconds(24 * 60 * 60))
        source.setEventHandler { [weak self] in
            self?.performUpdateCheck()
        }
        source.resume()
        queue.sync { updateTimer = source }
    }

    private func performUpdateCheck() {
        guard let url = URL(string: "https://api.github.com/repos/leaperone/smctl/releases/latest") else { return }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("smctl/\(SMCtlProtocolInfo.version)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard
                let self,
                let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tag = json["tag_name"] as? String
            else { return }
            self.queue.async {
                self.latestKnownVersion = tag
                if SMCtlProtocolInfo.isVersion(tag, newerThan: SMCtlProtocolInfo.version) {
                    logger.notice("Update available: \(tag, privacy: .public) (running \(SMCtlProtocolInfo.version, privacy: .public))")
                }
            }
        }
        task.resume()
    }

    func ping() -> PingDTO {
        queue.sync {
            PingDTO(ok: true, version: SMCtlProtocolInfo.version, timestamp: Date(), latestVersion: latestKnownVersion)
        }
    }

    func daemonStatus() -> DaemonStatusDTO {
        queue.sync {
            DaemonStatusDTO(
                timestamp: Date(),
                periodSeconds: SmctlDaemon.period,
                configPath: configPath,
                lastEvaluation: lastEvaluation,
                // A config parse failure is more actionable than a transient runtime
                // error and persists until the user fixes the file, so it wins.
                lastError: configError ?? lastError
            )
        }
    }

    func capabilitiesDTO() -> CapabilitiesDTO {
        queue.sync {
            CapabilitiesDTO(
                chargingControlSupported: capabilities.chargingControl != nil,
                adapterControlSupported: capabilities.adapterControl != nil,
                chargingControlGroup: capabilities.chargingControl?.identifier,
                adapterControlGroup: capabilities.adapterControl?.identifier,
                batteryKeys: capabilities.batteryKeys,
                fanCount: capabilities.fans.count,
                fanControlSupported: capabilities.fans.contains { $0.modeKey != nil },
                ftstAvailable: capabilities.ftstAvailable
            )
        }
    }

    func batteryStatus() -> BatteryStatusDTO {
        queue.sync {
            makeBatteryStatusLocked(message: nil)
        }
    }

    func fansStatus() -> FansStatusDTO {
        queue.sync {
            makeFansStatusLocked(message: nil)
        }
    }

    func reloadConfig() {
        queue.sync {
            let wasForcing = config.battery.force_discharge
            let loaded = Self.loadConfig(path: configPath)
            config = loaded.config
            configError = loaded.error
            SentryReporter.startIfConfigured(config: config.sentry)
            let policy = (try? SleepPolicy.parse(config.battery.sleep_policy)) ?? .strict
            sleepMachine.setPolicy(policy)
            if wasForcing, !config.battery.force_discharge, readAdapterEnabledLocked() == false {
                try? applyAdapterLocked(true)
            }
            evaluateLocked()
        }
    }

    func setChargeLimit(_ limit: String, forceDischarge: Bool = false) throws {
        let parsedLimit = try ChargeLimit.parse(limit)
        let effectiveForceDischarge = parsedLimit.isLimiting && forceDischarge
        try queue.sync {
            if effectiveForceDischarge, foregroundDischarge != nil {
                throw DaemonError.unsupported("Stop the foreground discharge before enabling force-discharge.")
            }
            let wasForcing = config.battery.force_discharge
            config.battery.limit = limit
            config.battery.force_discharge = effectiveForceDischarge
            try Self.writeConfig(config, path: configPath)
            // Leaving force-discharge with the adapter cut would strand the Mac
            // on battery; hand the adapter back before the policy stops owning it.
            if wasForcing, !effectiveForceDischarge, readAdapterEnabledLocked() == false {
                try? applyAdapterLocked(true)
            }
            evaluateLocked()
        }
    }

    func setChargingEnabled(_ enabled: Bool) throws {
        try queue.sync {
            try applyChargingLocked(enabled)
            evaluateLocked()
        }
    }

    func setAdapterEnabled(_ enabled: Bool, dischargeTarget: Int? = nil, owner: UUID? = nil, now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        try queue.sync {
            if let target = dischargeTarget {
                guard !enabled, (0...100).contains(target), let owner else {
                    throw DaemonError.unsupported("Foreground discharge requires an owner and a target between 0 and 100.")
                }
                guard !config.battery.force_discharge else {
                    throw DaemonError.unsupported("Stop force-discharge before starting a foreground discharge.")
                }
                if let foregroundDischarge {
                    guard case .active(let currentOwner, _, _) = foregroundDischarge, currentOwner == owner else {
                        throw DaemonError.unsupported("Another discharge is active or adapter restoration is pending.")
                    }
                }
                guard let charge = readNumericLocked("BUIC"), charge.isFinite else {
                    throw DaemonError.unsupported("No readable battery was found.")
                }
                guard charge > Double(target) else {
                    try restoreForegroundDischargeLocked()
                    return
                }
                foregroundDischarge = .active(owner: owner, target: target, expiresAt: now + Self.foregroundDischargeLease)
                do {
                    try applyAdapterLocked(false)
                } catch {
                    let operationError = error
                    try? restoreForegroundDischargeLocked()
                    throw operationError
                }
                return
            }
            if enabled, foregroundDischarge != nil {
                try restoreForegroundDischargeLocked()
            } else {
                guard foregroundDischarge == nil else {
                    throw DaemonError.unsupported("A foreground discharge already controls the adapter.")
                }
                try applyAdapterLocked(enabled)
            }
            evaluateLocked()
        }
    }

    func cancelForegroundDischarge(owner: UUID) {
        queue.async { [self] in
            guard case .active(let currentOwner, _, _) = foregroundDischarge, currentOwner == owner else { return }
            do {
                try restoreForegroundDischargeLocked()
            } catch {
                recordErrorLocked(error, context: "Foreground discharge restore failed")
            }
        }
    }

    private func restoreForegroundDischargeLocked() throws {
        foregroundDischarge = .restoring
        try applyAdapterLocked(true)
        foregroundDischarge = nil
    }

    func evaluateForegroundDischargeLocked(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let foregroundDischarge else { return }
        if case .active(_, let target, let expiresAt) = foregroundDischarge,
           now < expiresAt, !config.battery.force_discharge,
           let charge = readNumericLocked("BUIC"), charge.isFinite, charge > Double(target) {
            do {
                if readAdapterEnabledLocked() != false { try applyAdapterLocked(false) }
                return
            } catch {
                lastError = String(describing: error)
            }
        }
        do {
            try restoreForegroundDischargeLocked()
        } catch {
            recordErrorLocked(error, context: "Foreground discharge restore failed")
        }
    }

    func reconcileAdapterStartupLocked() {
        guard capabilities.adapterControl != nil, !config.battery.force_discharge else { return }
        foregroundDischarge = .restoring
        evaluateForegroundDischargeLocked()
    }

    func setFanManual(index: Int, rpm: Double, force: Bool) throws {
        try queue.sync {
            try rejectIfSafetyLatchedLocked()
            if isFanUnlockBackingOff(index) {
                throw DaemonError.unsupported(
                    "Fan \(index) manual control is retrying after a recent failure; try again in a few seconds."
                )
            }
            let target = try normalizedFanRPM(index: index, rpm: rpm, force: force)
            let result = try setManualFanTargetLocked(index: index, rpm: target)
            manualFanTargets[index] = target
            fanCurveEngines.removeAll()
            runtimeFanProfile = "manual"
            logger.notice("Fan \(index, privacy: .public) manual target \(target, privacy: .public) RPM via \(result.unlockPath.rawValue, privacy: .public)")
        }
    }

    func setFanAuto(index: Int?) throws {
        try queue.sync {
            // A curve profile drives every fan on every tick. Restoring just one fan
            // to auto would be undone within a second, so reject it explicitly instead
            // of printing a success message that is not true.
            if let index, Self.isCurveProfile(currentFanProfileLocked()) {
                throw DaemonError.unsupported(
                    "Fan profile '\(currentFanProfileLocked())' drives every fan and would re-assert manual control immediately. "
                        + "Run 'smctl fan profile auto' to leave the curve before restoring fan \(index)."
                )
            }
            try restoreFansAutoLocked(indices: index.map { [$0] } ?? capabilities.fans.map(\.index))
            if index == nil {
                config.fan.profile = "auto"
                manualFanTargets.removeAll()
                fanCurveEngines.removeAll()
                runtimeFanProfile = nil
                try Self.writeConfig(config, path: configPath)
            } else if let index {
                manualFanTargets.removeValue(forKey: index)
                if manualFanTargets.isEmpty, runtimeFanProfile == "manual" {
                    runtimeFanProfile = nil
                }
            }
        }
    }

    func setFanProfile(_ name: String) throws {
        try queue.sync {
            let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "auto" {
                try restoreFansAutoLocked(indices: capabilities.fans.map(\.index))
                manualFanTargets.removeAll()
                fanCurveEngines.removeAll()
                runtimeFanProfile = nil
            } else {
                try rejectIfSafetyLatchedLocked()
                guard capabilities.fans.contains(where: { $0.modeKey != nil }) else {
                    throw DaemonError.unsupported("No writable fan mode keys were detected on this Mac/system.")
                }
                _ = try curveForProfileLocked(normalized, maximumRPM: capabilities.fans.first.flatMap { readNumericLocked($0.maximumKey) } ?? 6000)
                manualFanTargets.removeAll()
                fanCurveEngines.removeAll()
                runtimeFanProfile = nil
            }
            config.fan.profile = normalized
            try Self.writeConfig(config, path: configPath)
            evaluateFanSubsystemLocked()
        }
    }

    func handleSleepMessage(_ messageType: natural_t, argument: UnsafeMutableRawPointer?) {
        let event: SleepEvent?
        switch messageType {
        case ioMessageCanSystemSleep:
            event = .canSystemSleep
        case ioMessageSystemWillSleep:
            event = .systemWillSleep
        case ioMessageSystemWillPowerOn:
            event = .systemWillPowerOn
        case ioMessageSystemHasPoweredOn:
            event = .systemHasPoweredOn
        default:
            event = nil
        }

        guard let event else {
            return
        }

        let evaluation = queue.sync { () -> SleepEvaluation in
            let limit = currentChargeLimitLocked()
            let observation = currentObservationLocked()
                ?? BatteryObservation(chargePercent: 100, isChargingAllowed: false, isPluggedIn: false)
            let evaluation = sleepMachine.handle(event: event, context: SleepContext(limit: limit, observation: observation))
            do {
                if event == .systemWillSleep, foregroundDischarge != nil {
                    try restoreForegroundDischargeLocked()
                }
                try applyActionsLocked(evaluation.actions)
                if evaluation.forcesReevaluation {
                    evaluateLocked()
                    if hasLocalManualFanPolicyLocked() {
                        evaluateFanSubsystemLocked()
                    }
                }
            } catch {
                recordErrorLocked(error, context: "Sleep event handling failed")
            }
            return evaluation
        }

        guard powerConnection != 0, let argument else {
            return
        }
        let changeID = Int(bitPattern: argument)
        if event == .canSystemSleep, evaluation.vetoesIdleSleep {
            IOCancelPowerChange(powerConnection, changeID)
        } else if event == .canSystemSleep || event == .systemWillSleep {
            IOAllowPowerChange(powerConnection, changeID)
        }
    }

    func evaluateLocked() {
        guard let observation = currentObservationLocked() else {
            lastEvaluation = Date()
            recordErrorLocked(
                "No readable battery charge/charging state was found on this Mac.",
                context: "Battery observation unavailable"
            )
            return
        }
        let now = Date()
        let limit = currentChargeLimitLocked()
        let evaluation = chargeMachine.evaluate(
            limit: limit,
            observation: observation,
            now: now,
            forceDischarge: config.battery.force_discharge
        )
        do {
            try applyActionsLocked(evaluation.actions)
            lastEvaluation = now
            lastError = nil
        } catch {
            lastEvaluation = now
            recordErrorLocked(error, context: "Battery policy evaluation failed")
        }
    }

    /// Record a failure once per distinct message.
    ///
    /// These paths run on the 1 Hz / 10 s timers and are retried on every tick. Logging
    /// and reporting the same error each time floods both the unified log and Sentry
    /// (and hides a *new* failure in the noise). A changed message is always reported.
    @discardableResult
    private func recordErrorLocked(_ error: Error, context: String) -> Bool {
        return recordErrorLocked(String(describing: error), context: context)
    }

    @discardableResult
    private func recordErrorLocked(_ message: String, context: String) -> Bool {
        let isNew = lastError != message
        lastError = message
        guard isNew else { return false }
        logger.error("\(context, privacy: .public): \(message, privacy: .public)")
        SentryReporter.capture(DaemonMessageError(message), context: context)
        return true
    }

    private func currentChargeLimitLocked() -> ChargeLimit {
        (try? ChargeLimit.parse(config.battery.limit)) ?? .disabled
    }

    private func currentObservationLocked() -> BatteryObservation? {
        guard let charge = readNumericLocked("BUIC") else {
            return nil
        }
        let chargingAllowed = readChargingEnabledLocked() ?? false
        // Unknown plug state defaults to true (conservative: keeps missed-beat guard active).
        let pluggedIn = readPluggedInLocked() ?? true
        return BatteryObservation(
            chargePercent: Int(charge.rounded()),
            isChargingAllowed: chargingAllowed,
            isPluggedIn: pluggedIn,
            isAdapterEnabled: readAdapterEnabledLocked()
        )
    }

    private func readChargingEnabledLocked() -> Bool? {
        guard let group = capabilities.chargingControl, let value = try? backend?.readValue(group.statusKey) else {
            return nil
        }
        return value.bytes.allSatisfy { $0 == 0 }
    }

    private func readAdapterEnabledLocked() -> Bool? {
        guard let group = capabilities.adapterControl, let value = try? backend?.readValue(group.statusKey) else {
            return nil
        }
        return value.bytes.allSatisfy { $0 == 0 }
    }

    private func readPluggedInLocked() -> Bool? {
        guard let value = readNumericLocked("AC-W") else {
            return nil
        }
        return value > 0
    }

    private func readNumericLocked(_ key: String) -> Double? {
        guard let value = try? backend?.readValue(key) else {
            return nil
        }
        return value.decoded?.doubleValue
    }

    private func applyActionsLocked(_ actions: [BatteryPolicyAction]) throws {
        for action in actions {
            switch action {
            case .setChargingEnabled(let enabled):
                try applyChargingLocked(enabled)
            case .setAdapterEnabled(let enabled):
                try applyAdapterLocked(enabled)
            case .reevaluate:
                evaluateLocked()
            }
        }
    }

    private func applyChargingLocked(_ enabled: Bool) throws {
        guard let backend else {
            throw DaemonError.unsupported("AppleSMC is not available.")
        }
        guard let group = capabilities.chargingControl else {
            throw DaemonError.unsupported("Charging control keys are not available on this Mac/system.")
        }
        for write in enabled ? group.enableWrites : group.disableWrites {
            try writeSMCKeyLocked(write.key, bytes: write.bytes, backend: backend)
        }
    }

    private func applyAdapterLocked(_ enabled: Bool) throws {
        guard let backend else {
            throw DaemonError.unsupported("AppleSMC is not available.")
        }
        guard let group = capabilities.adapterControl else {
            throw DaemonError.unsupported("Adapter control keys are not available on this Mac/system.")
        }
        for write in enabled ? group.enableWrites : group.disableWrites {
            try writeSMCKeyLocked(write.key, bytes: write.bytes, backend: backend)
        }
    }

    private func writeSMCKeyLocked(_ key: String, bytes: [UInt8], backend: any SMCWriteBackend) throws {
        do {
            try backend.writeKey(key, bytes: bytes)
            lastWriteError = nil
        } catch {
            lastWriteError = "\(key): \(String(describing: error))"
            throw error
        }
    }

    @discardableResult
    private func writeSMCOperationLocked<T>(_ operation: () throws -> T) throws -> T {
        do {
            let result = try operation()
            lastWriteError = nil
            return result
        } catch {
            lastWriteError = String(describing: error)
            throw error
        }
    }

    private func fanControllerLocked() throws -> FanController {
        guard let backend else {
            throw DaemonError.unsupported("AppleSMC is not available.")
        }
        return FanController(backend: backend, capabilities: capabilities)
    }

    private func normalizedFanRPM(index: Int, rpm: Double, force: Bool) throws -> Double {
        guard rpm.isFinite, rpm >= 0 else {
            throw DaemonError.unsupported("Fan RPM must be a non-negative finite number.")
        }
        let status = try fanControllerLocked().status(index: index)
        let minimum = status.minimumRPM ?? 0
        let maximum = status.maximumRPM ?? rpm

        // The reported maximum is a hard ceiling under all circumstances.
        let capped = min(maximum, rpm)

        if capped >= minimum {
            return capped
        }
        // Below-idle targets reduce cooling below what the firmware considers safe.
        // This is double-gated: the --force flag alone is not enough — the operator
        // must also opt in via `[safety] allow_below_minimum = true` in the config
        // (editing the root-owned config is itself an administrative act).
        guard force else {
            return minimum
        }
        guard config.safety.allow_below_minimum else {
            throw DaemonError.unsupported(
                "Targets below the fan's minimum (\(Int(minimum)) RPM) are dangerous and disabled. "
                    + "To enable, set `allow_below_minimum = true` under [safety] in \(configPath) and retry. "
                    + "The thermal safety guard remains active regardless."
            )
        }
        logger.notice("Below-minimum fan target \(capped, privacy: .public) RPM accepted for fan \(index, privacy: .public) (allow_below_minimum enabled)")
        return capped
    }

    /// One 1 Hz tick: read temperatures once, drive the fan subsystem, then the
    /// alert engine. Alerts run even on fanless Macs (where the fan subsystem
    /// early-returns) so temperature/write-error alerts still work there.
    func tickFanAndAlertsLocked() {
        evaluateForegroundDischargeLocked()
        let samples = temperatureSamplesLocked()
        evaluateFanSubsystemLocked(samples: samples)
        evaluateAlertsLocked(samples: samples)
    }

    func evaluateFanSubsystemLocked(samples providedSamples: [FanTemperatureSample]? = nil) {
        guard backend != nil, !capabilities.fans.isEmpty else {
            return
        }

        for index in pendingFanRestores.sorted() {
            do {
                try restoreFansAutoLocked(indices: [index])
            } catch {
                recordErrorLocked(error, context: "Pending fan restore failed")
            }
        }
        let samples = (providedSamples ?? temperatureSamplesLocked()).filter { $0.celsius.isFinite }
        let profile = currentFanProfileLocked()
        // "Manual policy active" covers direct manual targets, residual Ftst/manual
        // modes, and curve profiles (which drive fans via manual mode every tick).
        let manualPolicyActive = ftstGate.hasManualFans
            || !manualFanTargets.isEmpty
            || Self.isCurveProfile(profile)

        // The guard is stateful (latch); it must be evaluated every tick — including
        // with manualPolicyActive == false — so the latch can release after cooling.
        safetyGuard.configuredCeilingCelsius = FanSafetyGuard(
            configuredCeilingCelsius: config.safety.temp_ceiling
        ).configuredCeilingCelsius
        let decision = safetyGuard.evaluate(samples: samples, manualPolicyActive: manualPolicyActive)
        if decision.forceAuto {
            logger.notice("Fan safety guard tripped: \(decision.reason ?? "unknown", privacy: .public); restoring all fans to auto")
            do {
                try restoreFansAutoLocked(indices: capabilities.fans.map(\.index), clearPolicy: true)
                config.fan.profile = "auto"
                runtimeFanProfile = nil
                try Self.writeConfig(config, path: configPath)
            } catch {
                recordErrorLocked(error, context: "Fan safety restore failed")
            }
            return
        }

        guard manualPolicyActive else {
            return
        }
        guard pendingFanRestores.isEmpty else { return }

        do {
            if profile == "manual" {
                try reapplyManualFanTargetsLocked()
            } else if profile != "auto" {
                try evaluateFanProfileLocked(profile: profile, samples: samples)
            }
        } catch {
            recordErrorLocked(error, context: "Fan policy evaluation failed")
        }
    }

    /// Evaluate alert rules against the current tick's metrics and dispatch any
    /// edge-triggered events to the (isolated) action runner. Runs on the state
    /// queue; the runner does all blocking work off-queue.
    private func evaluateAlertsLocked(samples: [FanTemperatureSample]) {
        let rules = config.alerts.compactMap(\.rule)
        guard !rules.isEmpty else { return }
        let latched = safetyGuard.isLatched
        let input = AlertConditionInput(
            samples: samples,
            guardTripped: latched,
            guardReason: latched ? "Fan safety guard latched (overheat or unreadable temperature sensors)" : nil,
            writeError: lastWriteError
        )
        let events = alertEngine.evaluate(rules: rules, input: input, now: Date())
        guard !events.isEmpty else { return }
        let actionByName = Dictionary(
            config.alerts.map { ($0.name, $0.resolvedAction) },
            uniquingKeysWith: { first, _ in first }
        )
        for event in events {
            recordAlertLocked(event)
            alertRunner.run(event: event, action: actionByName[event.ruleName] ?? .log)
        }
    }

    private func recordAlertLocked(_ event: AlertEvent) {
        alertHistory.append(event)
        if alertHistory.count > Self.alertHistoryLimit {
            alertHistory.removeFirst(alertHistory.count - Self.alertHistoryLimit)
        }
    }

    func alertStatus() -> AlertStatusDTO {
        queue.sync {
            let rules = config.alerts.compactMap(\.rule)
            let now = Date()
            let states = alertEngine.states(for: rules, now: now).map { state in
                AlertRuleStateDTO(
                    name: state.name,
                    status: state.status.rawValue,
                    lastFired: state.lastFired,
                    lastValue: state.lastValue
                )
            }
            let history = alertHistory.suffix(20).map { event in
                AlertEventDTO(
                    ruleName: event.ruleName,
                    kind: event.kind.rawValue,
                    trigger: event.triggerKind.rawValue,
                    reason: event.reason,
                    value: event.value,
                    timestamp: event.timestamp
                )
            }
            return AlertStatusDTO(
                timestamp: now,
                definitions: config.alerts.map(\.definition),
                rules: states,
                recent: Array(history)
            )
        }
    }

    /// Fire one rule's action immediately, bypassing trigger evaluation, so an
    /// operator can verify a freshly-configured webhook/exec actually works.
    func testAlert(name: String) throws {
        try queue.sync {
            guard let config = config.alerts.first(where: { $0.name == name }) else {
                throw DaemonError.unsupported("No alert named '\(name)' is configured.")
            }
            let trigger = config.rule?.trigger.kind ?? .temp
            let event = AlertEvent(
                ruleName: name,
                kind: .fired,
                triggerKind: trigger,
                reason: "Test trigger via 'smctl alert test'",
                value: nil,
                timestamp: Date()
            )
            recordAlertLocked(event)
            alertRunner.run(event: event, action: config.resolvedAction)
        }
    }

    private func rejectIfSafetyLatchedLocked() throws {
        guard pendingFanRestores.isEmpty else {
            throw DaemonError.unsupported("Manual fan control is unavailable until pending auto restoration succeeds.")
        }
        guard safetyGuard.isLatched else {
            return
        }
        throw DaemonError.unsupported(
            "Fan safety guard is latched (overheat or unreadable temperature sensors). "
                + "Fans stay under system control until temperatures fall at least "
                + "\(Int(FanSafetyGuard.releaseHysteresisCelsius))C below the ceiling."
        )
    }

    private func reapplyManualFanTargetsLocked() throws {
        guard !manualFanTargets.isEmpty else {
            return
        }
        for (index, rpm) in manualFanTargets.sorted(by: { $0.key < $1.key }) {
            guard !isFanUnlockBackingOff(index) else { continue }
            _ = try setManualFanTargetLocked(index: index, rpm: rpm)
        }
    }

    private func setManualFanTargetLocked(index: Int, rpm: Double) throws -> FanManualResult {
        do {
            let result = try writeSMCOperationLocked {
                try fanControllerLocked().setManual(
                    index: index,
                    rpm: rpm,
                    otherManualFansRemaining: ftstGate.otherManualFansRemain(afterLeaving: index)
                )
            }
            ftstGate.enterManual(index: index)
            fanUnlockBackoffUntil.removeValue(forKey: index)
            return result
        } catch {
            manualFanTargets.removeValue(forKey: index)
            if case FanControlError.restorationFailed = error {
                ftstGate.enterManual(index: index)
                pendingFanRestores.insert(index)
            } else {
                _ = ftstGate.leaveManual(index: index)
            }
            fanUnlockBackoffUntil[index] = Date().addingTimeInterval(Self.fanUnlockBackoff)
            throw error
        }
    }

    /// True while a fan is inside its post-unlock-failure retry gate. Expired gates are
    /// cleared so the next tick tries again.
    private func isFanUnlockBackingOff(_ index: Int) -> Bool {
        guard let retryAt = fanUnlockBackoffUntil[index] else { return false }
        if Date() >= retryAt {
            fanUnlockBackoffUntil.removeValue(forKey: index)
            return false
        }
        return true
    }

    private func evaluateFanProfileLocked(profile: String, samples: [FanTemperatureSample]) throws {
        guard !samples.isEmpty else {
            throw DaemonError.unsupported("No readable temperature sensors are available for fan profile '\(profile)'.")
        }
        for fan in capabilities.fans {
            guard !isFanUnlockBackingOff(fan.index) else { continue }
            let maximum = readNumericLocked(fan.maximumKey) ?? 6000
            let minimum = readNumericLocked(fan.minimumKey) ?? 0
            let curve = try curveForProfileLocked(profile, maximumRPM: maximum)
            var engine = fanCurveEngines[fan.index] ?? FanCurveEngine()
            let evaluation = try engine.evaluate(curve: curve, samples: samples, now: Date())
            fanCurveEngines[fan.index] = engine
            let target = min(maximum, max(minimum, evaluation.targetRPM))
            _ = try setManualFanTargetLocked(index: fan.index, rpm: target)
        }
    }

    private func curveForProfileLocked(_ profile: String, maximumRPM: Double) throws -> FanCurve {
        switch profile {
        case "quiet":
            return .quiet(maxRPM: maximumRPM)
        case "full":
            return .full(maxRPM: maximumRPM)
        default:
            guard let curve = config.fan.curves.first(where: { $0.name == profile }) else {
                throw DaemonError.unsupported("Fan profile '\(profile)' is not configured.")
            }
            let points = try curve.points.map { values -> FanCurvePoint in
                guard values.count == 2 else {
                    throw DaemonError.unsupported("Fan curve '\(curve.name)' points must contain [temperature, rpm].")
                }
                guard case .number(let temperature) = values[0] else {
                    throw DaemonError.unsupported("Fan curve '\(curve.name)' temperature must be numeric.")
                }
                let rpm: Double
                switch values[1] {
                case .number(let value):
                    rpm = value
                case .maximum:
                    rpm = maximumRPM
                }
                return FanCurvePoint(temperature, rpm)
            }
            return try FanCurve(
                name: curve.name,
                sensors: curve.sensors,
                sensorWeights: curve.weights ?? [:],
                points: points,
                hysteresisCelsius: curve.hysteresis,
                slewRateRPMPerSecond: curve.slew_rate,
                fallSlewRateRPMPerSecond: curve.fall_slew_rate
            )
        }
    }

    private func restoreFansAutoLocked(indices: [Int], clearPolicy: Bool = false) throws {
        let controller = try fanControllerLocked()
        let ordered = indices.sorted()
        for (offset, index) in ordered.enumerated() {
            let laterRestores = ordered.suffix(from: offset + 1)
            let otherManual = ftstGate.otherManualFansRemain(afterLeaving: index)
                || laterRestores.isEmpty == false
            try writeSMCOperationLocked {
                try controller.setAuto(index: index, otherManualFansRemaining: otherManual)
            }
            _ = ftstGate.leaveManual(index: index)
            pendingFanRestores.remove(index)
            fanUnlockBackoffUntil.removeValue(forKey: index)
            manualFanTargets.removeValue(forKey: index)
        }
        if clearPolicy {
            manualFanTargets.removeAll()
            fanCurveEngines.removeAll()
            ftstGate.removeAll()
            runtimeFanProfile = nil
            try? controller.clearFtstIfSet()
        }
    }

    func reconcileFanStartupLocked() {
        // Fans without a writable mode key cannot be restored and must not be counted
        // as "unreadable state" — otherwise every startup would try and fail.
        let controllable = capabilities.fans.filter { $0.modeKey != nil }
        guard !hasLocalManualFanPolicyLocked(), !controllable.isEmpty else {
            evaluateFanSubsystemLocked()
            return
        }
        let controllableIndices = Set(controllable.map(\.index))
        let readable: [(index: Int, mode: UInt8)] = fanControllerStatusLocked().compactMap { status in
            guard controllableIndices.contains(status.index), let mode = status.rawMode else { return nil }
            return (status.index, mode)
        }
        let modes = Dictionary(readable.map { ($0.index, $0.mode) }, uniquingKeysWith: { first, _ in first })
        let ftst = readUInt8Locked("Ftst")
        let unreadableState = readable.count < controllable.count
            || (capabilities.ftstAvailable && ftst == nil)
        if FanStartupReconciler().shouldRestoreAuto(
            hasLocalManualPolicy: false,
            fanModes: modes,
            ftstValue: ftst,
            hasUnreadableState: unreadableState
        ) {
            logger.notice("Detected leftover or unreadable manual fan state at startup; restoring fans to auto")
            do {
                try restoreFansAutoLocked(indices: controllable.map(\.index), clearPolicy: true)
            } catch {
                // Likely an external fan tool re-asserting its own manual setting
                // (e.g. Macs Fan Control); surface it — never swallow a failed restore.
                lastError = String(describing: error)
                logger.error("Startup fan restore failed (external fan controller running?): \(String(describing: error), privacy: .public)")
                SentryReporter.capture(error, context: "Startup fan restore failed")
            }
        }
    }

    private func hasLocalManualFanPolicyLocked() -> Bool {
        currentFanProfileLocked() != "auto" || !manualFanTargets.isEmpty || ftstGate.hasManualFans
    }

    private func currentFanProfileLocked() -> String {
        runtimeFanProfile ?? config.fan.profile
    }

    /// `auto` and `manual` are modes; any other name is a declarative curve.
    static func isCurveProfile(_ profile: String) -> Bool {
        profile != "auto" && profile != "manual"
    }

    private func fanControllerStatusLocked() -> [FanStatus] {
        (try? fanControllerLocked().status()) ?? []
    }

    private func temperatureSamplesLocked() -> [FanTemperatureSample] {
        guard let reader else {
            return []
        }
        return reader.temperatures().compactMap {
            $0.celsius.isFinite ? FanTemperatureSample(sensor: $0.key, celsius: $0.celsius) : nil
        }
    }

    private func readUInt8Locked(_ key: String) -> UInt8? {
        guard let value = try? backend?.readValue(key) else {
            return nil
        }
        if let number = value.decoded?.doubleValue {
            return UInt8(clamping: Int(number.rounded()))
        }
        return value.bytes.first
    }

    private func makeBatteryStatusLocked(message: String?) -> BatteryStatusDTO {
        let limit = currentChargeLimitLocked()
        let observation = currentObservationLocked()
        let statusMessage: String?
        if let message {
            statusMessage = message
        } else if observation == nil {
            statusMessage = "No readable battery was found. Battery commands are read-only or unsupported on this Mac."
        } else if capabilities.chargingControl == nil {
            statusMessage = "Charging control keys are unavailable; policy writes are unsupported on this Mac/system."
        } else {
            statusMessage = nil
        }

        let timeEstimate = PowerSourceTimeEstimate.read()
        return BatteryStatusDTO(
            timestamp: Date(),
            chargePercent: observation?.chargePercent,
            isCharging: observation?.isCharging,
            pluggedIn: readPluggedInLocked(),
            chargingControlSupported: capabilities.chargingControl != nil,
            adapterControlSupported: capabilities.adapterControl != nil,
            chargingControlGroup: capabilities.chargingControl?.identifier,
            adapterControlGroup: capabilities.adapterControl?.identifier,
            configuredLimit: limit.configString,
            lowerBound: limit.lowerBound,
            upperBound: limit.upperBound,
            sleepPolicy: sleepMachine.policy.rawValue,
            message: statusMessage,
            timeToEmptyMinutes: timeEstimate.toEmpty,
            timeToFullMinutes: timeEstimate.toFull,
            forceDischarge: config.battery.force_discharge,
            foregroundDischargeSupported: true
        )
    }

    private func makeFansStatusLocked(message: String?) -> FansStatusDTO {
        let statuses = fanControllerStatusLocked().map { status in
            FanStatusDTO(
                index: status.index,
                actualRPM: status.actualRPM,
                targetRPM: status.targetRPM,
                minimumRPM: status.minimumRPM,
                maximumRPM: status.maximumRPM,
                mode: modeString(status)
            )
        }
        let statusMessage: String?
        if let message {
            statusMessage = message
        } else if capabilities.fans.isEmpty {
            statusMessage = "No fans were reported by SMC."
        } else if statuses.isEmpty {
            statusMessage = "Fan control keys are unavailable; fan status is read-only or unsupported on this Mac/system."
        } else {
            statusMessage = nil
        }
        return FansStatusDTO(
            timestamp: Date(),
            profile: currentFanProfileLocked(),
            fans: statuses,
            message: statusMessage
        )
    }

    private func modeString(_ status: FanStatus) -> String {
        if let mode = status.mode {
            switch mode {
            case .auto:
                return "auto"
            case .manual:
                return "manual"
            case .system:
                return "system"
            }
        }
        if let raw = status.rawMode {
            return "unknown(\(raw))"
        }
        return "unknown"
    }

    private static func loadConfig(path: String) -> (config: DaemonConfig, error: String?) {
        guard FileManager.default.fileExists(atPath: path) else {
            return (DaemonConfig(), nil)
        }
        do {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            var config = try TOMLDecoder().decode(DaemonConfig.self, from: text)
            let duplicates = duplicateAlertNames(config.alerts)
            if !duplicates.isEmpty {
                config.alerts = deduplicatedAlerts(config.alerts)
                return (
                    config,
                    "config at \(path): duplicate alert rule name(s) \(duplicates.joined(separator: ", ")); only the first of each is used"
                )
            }
            return (config, nil)
        } catch {
            logger.error("Unable to parse \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            return (DaemonConfig(), "config at \(path) failed to parse, running on defaults: \(String(describing: error))")
        }
    }

    private static func duplicateAlertNames(_ alerts: [AlertConfig]) -> [String] {
        var seen = Set<String>()
        var reported = Set<String>()
        var duplicates: [String] = []
        for alert in alerts {
            let name = alert.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if !seen.insert(name).inserted, reported.insert(name).inserted {
                duplicates.append(name)
            }
        }
        return duplicates
    }

    private static func deduplicatedAlerts(_ alerts: [AlertConfig]) -> [AlertConfig] {
        var seen = Set<String>()
        return alerts.filter { alert in
            let name = alert.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return true }
            return seen.insert(name).inserted
        }
    }

    /// Resolve a symlink first so the dotfiles workflow (`config.toml` linking into a
    /// dotfiles repository) updates the link target instead of replacing the link with
    /// a regular file on the first write.
    static func configWriteTarget(path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    static func writeConfig(_ config: DaemonConfig, path: String) throws {
        let target = configWriteTarget(path: path)
        let directory = (target as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let updates = configUpdates(config)
        let text: String
        if FileManager.default.fileExists(atPath: target) {
            // Patch the existing document instead of regenerating it: comments, unknown
            // keys, and user-authored curve/alert tables must survive a CLI write.
            let existing = try String(contentsOfFile: target, encoding: .utf8)
            text = TomlConfigPatcher.patch(text: existing, sections: updates)
        } else {
            text = renderNewConfig(config, updates: updates)
        }
        // Never persist a document the daemon itself would refuse to load.
        _ = try TOMLDecoder().decode(DaemonConfig.self, from: text)
        try text.write(toFile: target, atomically: true, encoding: .utf8)
        // The file can contain webhook tokens and a Sentry DSN. Keep it readable by
        // root only instead of inheriting the default 0644 creation mode.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target)
    }

    private static func configUpdates(_ config: DaemonConfig) -> [TomlConfigPatcher.SectionUpdate] {
        let string = TomlConfigPatcher.stringLiteral
        return [
            .init(name: "battery", values: [
                ("limit", string(config.battery.limit)),
                ("sleep_policy", string(config.battery.sleep_policy)),
                ("force_discharge", config.battery.force_discharge ? "true" : "false")
            ]),
            .init(name: "fan", values: [
                ("profile", string(config.fan.profile))
            ]),
            .init(name: "safety", values: [
                ("temp_ceiling", "\(FanSafetyGuard(configuredCeilingCelsius: config.safety.temp_ceiling).configuredCeilingCelsius)"),
                ("allow_below_minimum", config.safety.allow_below_minimum ? "true" : "false")
            ]),
            .init(name: "update", values: [
                ("check", config.update.check ? "true" : "false")
            ]),
            .init(name: "sentry", values: [
                ("dsn", string(config.sentry.dsn)),
                ("environment", string(config.sentry.environment)),
                ("debug", config.sentry.debug ? "true" : "false"),
                ("traces_sample_rate", "\(config.sentry.traces_sample_rate)")
            ])
        ]
    }

    /// Full-document fallback for when the config file does not exist (first write, or
    /// it was deleted while the daemon was running). Curves and alerts are carried over
    /// from the in-memory config so they are never dropped.
    private static func renderNewConfig(
        _ config: DaemonConfig,
        updates: [TomlConfigPatcher.SectionUpdate]
    ) -> String {
        var text = ""
        for section in updates {
            text += "[\(section.name)]\n"
            for value in section.values {
                text += "\(value.key) = \(value.literal)\n"
            }
            text += "\n"
        }
        let string = TomlConfigPatcher.stringLiteral
        for curve in config.fan.curves {
            text += """
            [[fan.curves]]
            name = \(string(curve.name))
            sensors = [\(curve.sensors.map(string).joined(separator: ", "))]
            points = [\(curve.points.map(formatFanPoint).joined(separator: ", "))]
            hysteresis = \(curve.hysteresis)

            """
            if let slewRate = curve.slew_rate {
                text += "slew_rate = \(slewRate)\n"
            }
            if let fallSlewRate = curve.fall_slew_rate {
                text += "fall_slew_rate = \(fallSlewRate)\n"
            }
            if let weights = curve.weights, !weights.isEmpty {
                let pairs = weights.sorted { $0.key < $1.key }.map { "\(string($0.key)) = \($0.value)" }.joined(separator: ", ")
                text += "weights = { \(pairs) }\n"
            }
            text += "\n"
        }
        for alert in config.alerts {
            text += formatAlert(alert)
        }
        return text
    }

    private static func formatAlert(_ alert: AlertConfig) -> String {
        let string = TomlConfigPatcher.stringLiteral
        var lines = ["", "[[alert]]", "name = \(string(alert.name))", "on = \(string(alert.on))"]
        if let sensor = alert.sensor { lines.append("sensor = \(string(sensor))") }
        if let above = alert.above { lines.append("above = \(above)") }
        if let forSeconds = alert.forSeconds { lines.append("for = \(forSeconds)") }
        if let cooldown = alert.cooldown { lines.append("cooldown = \(cooldown)") }
        if let resolve = alert.resolve { lines.append("resolve = \(resolve ? "true" : "false")") }
        if let action = alert.action { lines.append("action = \(string(action))") }
        if let url = alert.url { lines.append("url = \(string(url))") }
        if let command = alert.command {
            lines.append("command = [\(command.map(string).joined(separator: ", "))]")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func formatFanPoint(_ values: [FanPointValue]) -> String {
        "[" + values.map { value in
            switch value {
            case .number(let number):
                return String(number)
            case .maximum:
                return "\"max\""
            }
        }.joined(separator: ", ") + "]"
    }

    /// Dead-man switch: when the daemon stops, nobody maintains policy anymore, so hand
    /// control back to the system defaults (charging + adapter enabled). Best-effort —
    /// failures must never block shutdown (design §5.3/§9, "never leave a brick").
    public func restoreHardwareDefaultsBestEffort() {
        queue.sync {
            try? restoreFansAutoLocked(indices: capabilities.fans.map(\.index), clearPolicy: true)
            try? applyChargingLocked(true)
            try? applyAdapterLocked(true)
        }
    }

    private func registerPowerNotifications() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        var port: IONotificationPortRef?
        var notifier: io_object_t = 0
        let connection = IORegisterForSystemPower(context, &port, powerCallback, &notifier)
        guard connection != 0 else {
            logger.error("IORegisterForSystemPower failed")
            return
        }

        powerConnection = connection
        powerNotificationPort = port
        powerNotifier = notifier
        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }
}

private func powerCallback(
    context: UnsafeMutableRawPointer?,
    service: io_service_t,
    messageType: natural_t,
    messageArgument: UnsafeMutableRawPointer?
) {
    guard let context else {
        return
    }
    let daemon = Unmanaged<SmctlDaemon>.fromOpaque(context).takeUnretainedValue()
    daemon.handleSleepMessage(messageType, argument: messageArgument)
}

final class XPCService: NSObject, SMCtlDaemonXPCProtocol {
    private let daemon: SmctlDaemon
    private weak var connection: NSXPCConnection?
    private let owner: UUID

    init(daemon: SmctlDaemon, connection: NSXPCConnection, owner: UUID) {
        self.daemon = daemon
        self.connection = connection
        self.owner = owner
    }

    func daemonPing(withReply reply: @escaping (Data?, String?) -> Void) {
        send(daemon.ping(), reply)
    }

    func getBatteryStatus(withReply reply: @escaping (Data?, String?) -> Void) {
        send(daemon.batteryStatus(), reply)
    }

    func getFans(withReply reply: @escaping (Data?, String?) -> Void) {
        send(daemon.fansStatus(), reply)
    }

    func getCapabilities(withReply reply: @escaping (Data?, String?) -> Void) {
        send(daemon.capabilitiesDTO(), reply)
    }

    func getDaemonStatus(withReply reply: @escaping (Data?, String?) -> Void) {
        send(daemon.daemonStatus(), reply)
    }

    func getAlertStatus(withReply reply: @escaping (Data?, String?) -> Void) {
        send(daemon.alertStatus(), reply)
    }

    func testAlert(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        doWrite(reply) {
            let request = try SMCtlProtocolCoding.decode(TestAlertRequestDTO.self, from: requestData)
            try daemon.testAlert(name: request.name)
        }
    }

    func setChargeLimit(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        doWrite(reply) {
            let request = try SMCtlProtocolCoding.decode(SetChargeLimitRequestDTO.self, from: requestData)
            try daemon.setChargeLimit(request.limit, forceDischarge: request.forceDischarge ?? false)
        }
    }

    func setFanManual(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        doWrite(reply) {
            let request = try SMCtlProtocolCoding.decode(SetFanManualRequestDTO.self, from: requestData)
            try daemon.setFanManual(index: request.index, rpm: request.rpm, force: request.force)
        }
    }

    func setFanAuto(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        doWrite(reply) {
            let request = try SMCtlProtocolCoding.decode(SetFanAutoRequestDTO.self, from: requestData)
            try daemon.setFanAuto(index: request.index)
        }
    }

    func setFanProfile(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        doWrite(reply) {
            let request = try SMCtlProtocolCoding.decode(SetFanProfileRequestDTO.self, from: requestData)
            try daemon.setFanProfile(request.name)
        }
    }

    func setChargingEnabled(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        doWrite(reply) {
            let request = try SMCtlProtocolCoding.decode(SetEnabledRequestDTO.self, from: requestData)
            try daemon.setChargingEnabled(request.enabled)
        }
    }

    func setAdapterEnabled(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        doWrite(reply) {
            let request = try SMCtlProtocolCoding.decode(SetEnabledRequestDTO.self, from: requestData)
            try daemon.setAdapterEnabled(request.enabled, dischargeTarget: request.dischargeTarget, owner: owner)
        }
    }

    func reloadConfig(withReply reply: @escaping (Data?, String?) -> Void) {
        doWrite(reply) {
            daemon.reloadConfig()
        }
    }

    private func doWrite(_ reply: @escaping (Data?, String?) -> Void, _ body: () throws -> Void) {
        do {
            try authorizeWrite()
            try body()
            send(EmptyResponseDTO(), reply)
        } catch {
            reply(nil, String(describing: error))
        }
    }

    private func authorizeWrite() throws {
        guard let connection else {
            throw DaemonError.unauthorized
        }
        let uid = connection.effectiveUserIdentifier
        guard uid == 0 || Self.userIsAdmin(uid) else {
            throw DaemonError.unauthorized
        }
        // Team ID enforcement: active whenever the daemon itself is Developer ID
        // signed. Unsigned/source builds cannot enforce this by construction and
        // rely on the euid gate above (see CodeSignPolicy).
        if let teamID = enforcedTeamID {
            guard CodeSignPolicy.clientMatches(teamID: teamID, connection: connection) else {
                logger.error("Rejected write from pid \(connection.processIdentifier, privacy: .public): client not signed with team \(teamID, privacy: .public)")
                throw DaemonError.untrustedClient
            }
        }
    }

    static func userIsAdmin(_ uid: uid_t) -> Bool {
        guard let admin = getgrnam("admin") else {
            return false
        }
        guard let passwd = getpwuid(uid) else {
            return false
        }

        var count: Int32 = 64
        var groups = [gid_t](repeating: 0, count: Int(count))
        // bitPattern: system accounts use "negative" ids (nobody's gid -2 is
        // 4294967294 as gid_t); a checked Int32() conversion traps on them.
        let baseGroup = Int32(bitPattern: passwd.pointee.pw_gid)
        let result = groups.withUnsafeMutableBufferPointer { buffer in
            getgrouplist(passwd.pointee.pw_name, baseGroup, buffer.baseAddress, &count)
        }
        if result == -1 {
            groups = [gid_t](repeating: 0, count: Int(count))
            _ = groups.withUnsafeMutableBufferPointer { buffer in
                getgrouplist(passwd.pointee.pw_name, baseGroup, buffer.baseAddress, &count)
            }
        }
        return groups.prefix(Int(count)).contains(admin.pointee.gr_gid)
    }

    private func send<T: Encodable>(_ value: T, _ reply: @escaping (Data?, String?) -> Void) {
        do {
            reply(try SMCtlProtocolCoding.encode(value), nil)
        } catch {
            reply(nil, String(describing: error))
        }
    }
}

public final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let daemon: SmctlDaemon

    public init(daemon: SmctlDaemon) {
        self.daemon = daemon
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let owner = UUID()
        let daemon = self.daemon
        connection.exportedInterface = NSXPCInterface(with: SMCtlDaemonXPCProtocol.self)
        connection.exportedObject = XPCService(daemon: daemon, connection: connection, owner: owner)
        connection.invalidationHandler = { [weak daemon] in daemon?.cancelForegroundDischarge(owner: owner) }
        connection.interruptionHandler = { [weak daemon] in daemon?.cancelForegroundDischarge(owner: owner) }
        connection.resume()
        return true
    }
}

/// Termination hook for the executable entry point: log, restore hardware
/// defaults, then exit. Lives in the core so the entry point stays logic-free.
public func smctldHandleTermination(daemon: SmctlDaemon) -> Never {
    logger.notice("Received termination signal; restoring hardware defaults")
    daemon.restoreHardwareDefaultsBestEffort()
    exit(0)
}

/// Startup-mode banner, emitted once the daemon is listening.
public func smctldLogStartupMode() {
    if let enforcedTeamID {
        logger.notice("smctld started; XPC write authorization requires team \(enforcedTeamID, privacy: .public)")
    } else {
        logger.notice("smctld started; unsigned build, XPC write authorization is euid-gated only")
    }
}
