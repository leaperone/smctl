import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt
import OSLog
import PolicyEngine
import SMCCore
import SMCtlProtocol
import TOMLKit

private let logger = Logger(subsystem: "dev.smctl", category: "daemon")
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

    init(battery: BatteryConfig = BatteryConfig(), fan: FanConfig = FanConfig(), safety: SafetyConfig = SafetyConfig()) {
        self.battery = battery
        self.fan = fan
        self.safety = safety
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        battery = try container.decodeIfPresent(BatteryConfig.self, forKey: .battery) ?? BatteryConfig()
        fan = try container.decodeIfPresent(FanConfig.self, forKey: .fan) ?? FanConfig()
        safety = try container.decodeIfPresent(SafetyConfig.self, forKey: .safety) ?? SafetyConfig()
    }
}

struct BatteryConfig: Codable, Equatable, Sendable {
    var limit: String
    var sleep_policy: String
    var magsafe_led: Bool

    init(limit: String = "100", sleep_policy: String = "strict", magsafe_led: Bool = true) {
        self.limit = limit
        self.sleep_policy = sleep_policy
        self.magsafe_led = magsafe_led
    }
}

struct FanConfig: Codable, Equatable, Sendable {
    var profile: String
    var curves: [FanCurveConfig]

    init(profile: String = "auto", curves: [FanCurveConfig] = []) {
        self.profile = profile
        self.curves = curves
    }
}

struct FanCurveConfig: Codable, Equatable, Sendable {
    var name: String
    var sensors: [String]
    var points: [[FanPointValue]]
    var hysteresis: Double
    var slew_rate: Double?
    var weights: [String: Double]?

    init(
        name: String,
        sensors: [String] = [],
        points: [[FanPointValue]],
        hysteresis: Double = 0,
        slew_rate: Double? = nil,
        weights: [String: Double]? = nil
    ) {
        self.name = name
        self.sensors = sensors
        self.points = points
        self.hysteresis = hysteresis
        self.slew_rate = slew_rate
        self.weights = weights
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

struct SafetyConfig: Codable, Equatable, Sendable {
    var temp_ceiling: Double

    init(temp_ceiling: Double = FanSafetyGuard.defaultCeilingCelsius) {
        self.temp_ceiling = temp_ceiling
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

final class SmctlDaemon: @unchecked Sendable {
    static let configPath = "/etc/smctl/config.toml"
    static let period: TimeInterval = 10

    private let queue = DispatchQueue(label: "dev.smctl.daemon.state")
    private var config = DaemonConfig()
    private var chargeMachine = ChargeStateMachine(period: SmctlDaemon.period)
    private var sleepMachine = SleepStateMachine(policy: .strict)
    private var capabilities = Capabilities()
    private var ftstGate = FtstGateManager()
    private var manualFanTargets: [Int: Double] = [:]
    private var fanCurveEngines: [Int: FanCurveEngine] = [:]
    private var runtimeFanProfile: String?
    // Stateful: carries the safety latch across ticks; ceiling refreshed from config.
    private var safetyGuard = FanSafetyGuard()
    private var lastEvaluation: Date?
    private var lastError: String?
    private var timer: DispatchSourceTimer?
    private var fanTimer: DispatchSourceTimer?
    private var powerConnection: io_connect_t = 0
    private var powerNotificationPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0

    private let backend: (any SMCWriteBackend)?
    private let reader: SensorReader?

    init() {
        do {
            let connection = try SMCConnection()
            backend = connection
            reader = SensorReader(backend: connection)
            capabilities = reader?.capabilities() ?? Capabilities()
        } catch {
            backend = nil
            reader = nil
            lastError = String(describing: error)
            logger.error("Unable to open AppleSMC: \(String(describing: error), privacy: .public)")
        }
        reloadConfig()
    }

    func start() {
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
            self?.evaluateFanSubsystemLocked()
        }
        fanSource.resume()
        queue.sync {
            timer = source
            fanTimer = fanSource
            reconcileFanStartupLocked()
        }
    }

    func ping() -> PingDTO {
        PingDTO(ok: true, version: SMCtlProtocolInfo.version, timestamp: Date())
    }

    func daemonStatus() -> DaemonStatusDTO {
        queue.sync {
            DaemonStatusDTO(
                timestamp: Date(),
                periodSeconds: SmctlDaemon.period,
                configPath: Self.configPath,
                lastEvaluation: lastEvaluation,
                lastError: lastError
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
            config = Self.loadConfig(path: Self.configPath)
            let policy = (try? SleepPolicy.parse(config.battery.sleep_policy)) ?? .strict
            sleepMachine.setPolicy(policy)
            evaluateLocked()
        }
    }

    func setChargeLimit(_ limit: String) throws {
        _ = try ChargeLimit.parse(limit)
        try queue.sync {
            config.battery.limit = limit
            try Self.writeConfig(config, path: Self.configPath)
            evaluateLocked()
        }
    }

    func setChargingEnabled(_ enabled: Bool) throws {
        try queue.sync {
            try applyChargingLocked(enabled)
            evaluateLocked()
        }
    }

    func setAdapterEnabled(_ enabled: Bool) throws {
        try queue.sync {
            try applyAdapterLocked(enabled)
            evaluateLocked()
        }
    }

    func setFanManual(index: Int, rpm: Double, force: Bool) throws {
        try queue.sync {
            try rejectIfSafetyLatchedLocked()
            let target = try normalizedFanRPM(index: index, rpm: rpm, force: force)
            let result = try fanControllerLocked().setManual(index: index, rpm: target)
            ftstGate.enterManual(index: index)
            manualFanTargets[index] = target
            fanCurveEngines.removeAll()
            runtimeFanProfile = "manual"
            logger.notice("Fan \(index, privacy: .public) manual target \(target, privacy: .public) RPM via \(result.unlockPath.rawValue, privacy: .public)")
        }
    }

    func setFanAuto(index: Int?) throws {
        try queue.sync {
            try restoreFansAutoLocked(indices: index.map { [$0] } ?? capabilities.fans.map(\.index))
            if index == nil {
                config.fan.profile = "auto"
                manualFanTargets.removeAll()
                fanCurveEngines.removeAll()
                runtimeFanProfile = nil
                try Self.writeConfig(config, path: Self.configPath)
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
            try Self.writeConfig(config, path: Self.configPath)
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
                try applyActionsLocked(evaluation.actions)
                if evaluation.forcesReevaluation {
                    evaluateLocked()
                    if hasLocalManualFanPolicyLocked() {
                        evaluateFanSubsystemLocked()
                    }
                }
            } catch {
                lastError = String(describing: error)
                logger.error("Sleep event handling failed: \(String(describing: error), privacy: .public)")
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

    private func evaluateLocked() {
        guard let observation = currentObservationLocked() else {
            lastEvaluation = Date()
            lastError = "No readable battery charge/charging state was found on this Mac."
            return
        }
        let now = Date()
        let limit = currentChargeLimitLocked()
        let evaluation = chargeMachine.evaluate(limit: limit, observation: observation, now: now)
        do {
            try applyActionsLocked(evaluation.actions)
            lastEvaluation = now
            lastError = nil
        } catch {
            lastEvaluation = now
            lastError = String(describing: error)
            logger.error("Battery policy evaluation failed: \(String(describing: error), privacy: .public)")
        }
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
            isPluggedIn: pluggedIn
        )
    }

    private func readChargingEnabledLocked() -> Bool? {
        guard let group = capabilities.chargingControl, let value = try? backend?.readValue(group.statusKey) else {
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
            try backend.writeKey(write.key, bytes: write.bytes)
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
            try backend.writeKey(write.key, bytes: write.bytes)
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
        guard !force else {
            return rpm
        }
        let status = try fanControllerLocked().status(index: index)
        let minimum = status.minimumRPM ?? 0
        let maximum = status.maximumRPM ?? rpm
        return min(maximum, max(minimum, rpm))
    }

    private func evaluateFanSubsystemLocked() {
        guard backend != nil, !capabilities.fans.isEmpty else {
            return
        }

        let samples = temperatureSamplesLocked()
        let profile = currentFanProfileLocked()
        // "Manual policy active" covers direct manual targets, residual Ftst/manual
        // modes, and curve profiles (which drive fans via manual mode every tick).
        let manualPolicyActive = ftstGate.hasManualFans
            || !manualFanTargets.isEmpty
            || (profile != "auto" && profile != "manual")

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
                try Self.writeConfig(config, path: Self.configPath)
            } catch {
                lastError = String(describing: error)
                logger.error("Fan safety restore failed: \(String(describing: error), privacy: .public)")
            }
            return
        }

        guard manualPolicyActive else {
            return
        }

        do {
            if profile == "manual" {
                try reapplyManualFanTargetsLocked()
            } else if profile != "auto" {
                try evaluateFanProfileLocked(profile: profile, samples: samples)
            }
        } catch {
            lastError = String(describing: error)
            logger.error("Fan policy evaluation failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func rejectIfSafetyLatchedLocked() throws {
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
        let controller = try fanControllerLocked()
        for (index, rpm) in manualFanTargets.sorted(by: { $0.key < $1.key }) {
            _ = try controller.setManual(index: index, rpm: rpm)
            ftstGate.enterManual(index: index)
        }
    }

    private func evaluateFanProfileLocked(profile: String, samples: [FanTemperatureSample]) throws {
        guard !samples.isEmpty else {
            throw DaemonError.unsupported("No readable temperature sensors are available for fan profile '\(profile)'.")
        }
        let controller = try fanControllerLocked()
        for fan in capabilities.fans {
            let maximum = readNumericLocked(fan.maximumKey) ?? 6000
            let minimum = readNumericLocked(fan.minimumKey) ?? 0
            let curve = try curveForProfileLocked(profile, maximumRPM: maximum)
            var engine = fanCurveEngines[fan.index] ?? FanCurveEngine()
            let evaluation = try engine.evaluate(curve: curve, samples: samples, now: Date())
            fanCurveEngines[fan.index] = engine
            let target = min(maximum, max(minimum, evaluation.targetRPM))
            _ = try controller.setManual(index: fan.index, rpm: target)
            ftstGate.enterManual(index: fan.index)
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
                slewRateRPMPerSecond: curve.slew_rate
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
            try controller.setAuto(index: index, otherManualFansRemaining: otherManual)
            _ = ftstGate.leaveManual(index: index)
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

    private func reconcileFanStartupLocked() {
        guard !hasLocalManualFanPolicyLocked(), !capabilities.fans.isEmpty else {
            evaluateFanSubsystemLocked()
            return
        }
        let modes = Dictionary(uniqueKeysWithValues: fanControllerStatusLocked().map { ($0.index, $0.rawMode ?? 0) })
        let ftst = readUInt8Locked("Ftst")
        if FanStartupReconciler().shouldRestoreAuto(hasLocalManualPolicy: false, fanModes: modes, ftstValue: ftst) {
            logger.notice("Detected leftover manual fan state at startup; restoring fans to auto")
            do {
                try restoreFansAutoLocked(indices: capabilities.fans.map(\.index), clearPolicy: true)
            } catch {
                // Likely an external fan tool re-asserting its own manual setting
                // (e.g. Macs Fan Control); surface it — never swallow a failed restore.
                lastError = String(describing: error)
                logger.error("Startup fan restore failed (external fan controller running?): \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func hasLocalManualFanPolicyLocked() -> Bool {
        currentFanProfileLocked() != "auto" || !manualFanTargets.isEmpty || ftstGate.hasManualFans
    }

    private func currentFanProfileLocked() -> String {
        runtimeFanProfile ?? config.fan.profile
    }

    private func fanControllerStatusLocked() -> [FanStatus] {
        (try? fanControllerLocked().status()) ?? []
    }

    private func temperatureSamplesLocked() -> [FanTemperatureSample] {
        guard let reader else {
            return []
        }
        return reader.snapshot().temperatures.map {
            FanTemperatureSample(sensor: $0.key, celsius: $0.celsius)
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
            message: statusMessage
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

    private static func loadConfig(path: String) -> DaemonConfig {
        guard FileManager.default.fileExists(atPath: path) else {
            return DaemonConfig()
        }
        do {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            return try TOMLDecoder().decode(DaemonConfig.self, from: text)
        } catch {
            logger.error("Unable to parse \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            return DaemonConfig()
        }
    }

    private static func writeConfig(_ config: DaemonConfig, path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var text = """
        [battery]
        limit = "\(config.battery.limit)"
        sleep_policy = "\(config.battery.sleep_policy)"
        magsafe_led = \(config.battery.magsafe_led ? "true" : "false")

        [fan]
        profile = "\(config.fan.profile)"

        [safety]
        temp_ceiling = \(FanSafetyGuard(configuredCeilingCelsius: config.safety.temp_ceiling).configuredCeilingCelsius)

        """
        for curve in config.fan.curves {
            text += """

            [[fan.curves]]
            name = "\(curve.name)"
            sensors = [\(curve.sensors.map { "\"\($0)\"" }.joined(separator: ", "))]
            points = [\(curve.points.map(formatFanPoint).joined(separator: ", "))]
            hysteresis = \(curve.hysteresis)

            """
            if let slewRate = curve.slew_rate {
                text += "slew_rate = \(slewRate)\n"
            }
            if let weights = curve.weights, !weights.isEmpty {
                let pairs = weights.sorted { $0.key < $1.key }.map { "\"\($0.key)\" = \($0.value)" }.joined(separator: ", ")
                text += "weights = { \(pairs) }\n"
            }
        }
        try text.write(toFile: path, atomically: true, encoding: .utf8)
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
    func restoreHardwareDefaultsBestEffort() {
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

    init(daemon: SmctlDaemon, connection: NSXPCConnection) {
        self.daemon = daemon
        self.connection = connection
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

    func setChargeLimit(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        doWrite(reply) {
            let request = try SMCtlProtocolCoding.decode(SetChargeLimitRequestDTO.self, from: requestData)
            try daemon.setChargeLimit(request.limit)
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
            try daemon.setAdapterEnabled(request.enabled)
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

    private static func userIsAdmin(_ uid: uid_t) -> Bool {
        guard let admin = getgrnam("admin") else {
            return false
        }
        guard let passwd = getpwuid(uid) else {
            return false
        }

        var count: Int32 = 64
        var groups = [gid_t](repeating: 0, count: Int(count))
        let baseGroup = Int32(passwd.pointee.pw_gid)
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

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let daemon: SmctlDaemon

    init(daemon: SmctlDaemon) {
        self.daemon = daemon
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: SMCtlDaemonXPCProtocol.self)
        connection.exportedObject = XPCService(daemon: daemon, connection: connection)
        connection.resume()
        return true
    }
}

let daemon = SmctlDaemon()
daemon.start()
let listener = NSXPCListener(machServiceName: SMCtlProtocolInfo.machServiceName)
let delegate = ListenerDelegate(daemon: daemon)
listener.delegate = delegate
listener.resume()

// Graceful termination (launchctl bootout, system shutdown): restore hardware defaults
// before exiting so a stopped-but-not-uninstalled daemon never leaves charging disabled.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let terminationSignals = [SIGTERM, SIGINT].map { signalNumber in
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        logger.notice("Received termination signal; restoring hardware defaults")
        daemon.restoreHardwareDefaultsBestEffort()
        exit(0)
    }
    source.resume()
    return source
}
_ = terminationSignals

if let enforcedTeamID {
    logger.notice("smctld started; XPC write authorization requires team \(enforcedTeamID, privacy: .public)")
} else {
    logger.notice("smctld started; unsigned build, XPC write authorization is euid-gated only")
}
RunLoop.main.run()
