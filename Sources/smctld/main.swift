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
private let ioMessageCanSystemSleep = natural_t(0xe0000270)
private let ioMessageSystemWillSleep = natural_t(0xe0000280)
private let ioMessageSystemWillPowerOn = natural_t(0xe0000320)
private let ioMessageSystemHasPoweredOn = natural_t(0xe0000300)

struct DaemonConfig: Codable, Equatable, Sendable {
    var battery: BatteryConfig

    init(battery: BatteryConfig = BatteryConfig()) {
        self.battery = battery
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        battery = try container.decodeIfPresent(BatteryConfig.self, forKey: .battery) ?? BatteryConfig()
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

enum DaemonError: Error, CustomStringConvertible {
    case unsupported(String)
    case unauthorized

    var description: String {
        switch self {
        case .unsupported(let message):
            return message
        case .unauthorized:
            return "Write requests require root or an admin user."
        }
    }
}

final class BatteryDaemon: @unchecked Sendable {
    static let configPath = "/etc/smctl/config.toml"
    static let period: TimeInterval = 10

    private let queue = DispatchQueue(label: "dev.smctl.daemon.state")
    private var config = DaemonConfig()
    private var chargeMachine = ChargeStateMachine(period: BatteryDaemon.period)
    private var sleepMachine = SleepStateMachine(policy: .strict)
    private var capabilities = Capabilities()
    private var lastEvaluation: Date?
    private var lastError: String?
    private var timer: DispatchSourceTimer?
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
        source.schedule(deadline: .now() + .seconds(1), repeating: BatteryDaemon.period)
        source.setEventHandler { [weak self] in
            self?.evaluateLocked()
        }
        source.resume()
        queue.sync {
            timer = source
        }
    }

    func ping() -> PingDTO {
        PingDTO(ok: true, version: SMCtlProtocolInfo.version, timestamp: Date())
    }

    func daemonStatus() -> DaemonStatusDTO {
        queue.sync {
            DaemonStatusDTO(
                timestamp: Date(),
                periodSeconds: BatteryDaemon.period,
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
                batteryKeys: capabilities.batteryKeys
            )
        }
    }

    func batteryStatus() -> BatteryStatusDTO {
        queue.sync {
            makeBatteryStatusLocked(message: nil)
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
        let text = """
        [battery]
        limit = "\(config.battery.limit)"
        sleep_policy = "\(config.battery.sleep_policy)"
        magsafe_led = \(config.battery.magsafe_led ? "true" : "false")

        """
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Dead-man switch: when the daemon stops, nobody maintains policy anymore, so hand
    /// control back to the system defaults (charging + adapter enabled). Best-effort —
    /// failures must never block shutdown (design §5.3/§9, "never leave a brick").
    func restoreHardwareDefaultsBestEffort() {
        queue.sync {
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
    let daemon = Unmanaged<BatteryDaemon>.fromOpaque(context).takeUnretainedValue()
    daemon.handleSleepMessage(messageType, argument: messageArgument)
}

final class XPCService: NSObject, SMCtlDaemonXPCProtocol {
    private let daemon: BatteryDaemon
    private weak var connection: NSXPCConnection?

    init(daemon: BatteryDaemon, connection: NSXPCConnection) {
        self.daemon = daemon
        self.connection = connection
    }

    func daemonPing(withReply reply: @escaping (Data?, String?) -> Void) {
        send(daemon.ping(), reply)
    }

    func getBatteryStatus(withReply reply: @escaping (Data?, String?) -> Void) {
        send(daemon.batteryStatus(), reply)
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
        // TODO: add code-signing / Team ID validation at this boundary once distribution signing is configured.
        let uid = connection.effectiveUserIdentifier
        guard uid == 0 || Self.userIsAdmin(uid) else {
            throw DaemonError.unauthorized
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
    private let daemon: BatteryDaemon

    init(daemon: BatteryDaemon) {
        self.daemon = daemon
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: SMCtlDaemonXPCProtocol.self)
        connection.exportedObject = XPCService(daemon: daemon, connection: connection)
        connection.resume()
        return true
    }
}

let daemon = BatteryDaemon()
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

logger.notice("smctld started")
RunLoop.main.run()
