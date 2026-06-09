import ArgumentParser
import Foundation
import SMCCore
import SMCtlProtocol

private final class LockedISO8601Formatter: @unchecked Sendable {
    private let formatter = ISO8601DateFormatter()
    private let lock = NSLock()

    func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }
}

private enum CLIFormatters {
    static let iso8601 = LockedISO8601Formatter()
}

@main
struct SMCtl: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "smctl",
        abstract: "Mac hardware control utility.",
        version: SMCtlProtocolInfo.version,
        subcommands: [Sensors.self, Fan.self, Battery.self, Power.self, Daemon.self, Debug.self]
    )
}

struct Sensors: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sensors",
        abstract: "Read SMC sensors without requiring root."
    )

    @Flag(name: .long, help: "Print machine-readable JSON.")
    var json = false

    @Flag(name: .long, help: "Refresh every second until interrupted.")
    var watch = false

    func run() throws {
        let reader = SensorReader(backend: try SMCConnection())

        repeat {
            let snapshot = reader.snapshot()
            if json {
                printJSON(snapshot)
            } else {
                if watch {
                    clearScreen()
                }
                printHuman(snapshot)
            }

            if watch {
                fflush(stdout)
                sleep(1)
            }
        } while watch
    }

    private func printJSON(_ snapshot: SensorSnapshot) {
        if let output = try? CLIJSON.encodeString(snapshot) {
            print(output)
        }
    }

    private func printHuman(_ snapshot: SensorSnapshot) {
        print("smctl sensors  \(CLIFormatters.iso8601.string(from: snapshot.timestamp))")
        print("")

        print("Temperatures")
        if snapshot.temperatures.isEmpty {
            print("  No readable temperature keys found.")
        } else {
            var currentGroup = ""
            for reading in snapshot.temperatures {
                if reading.group != currentGroup {
                    currentGroup = reading.group
                    print("  \(currentGroup)")
                }
                print("    \(reading.key)  \(format(reading.celsius, digits: 1)) C")
            }
        }

        print("")
        print("Fans")
        if snapshot.fans.isEmpty {
            print("  No fans reported by SMC.")
        } else {
            for fan in snapshot.fans {
                let actual = rpm(fan.actualRPM)
                let target = rpm(fan.targetRPM)
                let minimum = rpm(fan.minimumRPM)
                let maximum = rpm(fan.maximumRPM)
                let mode = fan.mode ?? "unknown"
                print("  Fan \(fan.index): actual \(actual), target \(target), min \(minimum), max \(maximum), mode \(mode)")
            }
        }

        print("")
        print("Battery")
        printReadings(snapshot.battery)

        print("")
        print("Power")
        printReadings(snapshot.power)
    }

    private func printReadings(_ readings: [NamedReading]) {
        if readings.isEmpty {
            print("  No readable keys found.")
            return
        }

        for reading in readings {
            if let value = reading.value {
                let suffix = reading.unit.map { " \($0)" } ?? ""
                print("  \(reading.name) (\(reading.key)): \(format(value, digits: 2))\(suffix)")
            } else if let rawBytes = reading.rawBytes {
                let hex = rawBytes.map { String(format: "%02x", $0) }.joined(separator: " ")
                print("  \(reading.name) (\(reading.key)): \(hex)")
            }
        }
    }

    private func rpm(_ value: Double?) -> String {
        guard let value else {
            return "-"
        }
        return "\(format(value, digits: 0)) RPM"
    }

    private func format(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }

    private func clearScreen() {
        print("\u{001B}[2J\u{001B}[H", terminator: "")
    }
}

struct Fan: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fan",
        abstract: "Inspect and control fans through smctld.",
        subcommands: [FanStatus.self, FanSet.self, FanAuto.self, FanProfile.self]
    )
}

struct FanStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Per-fan actual/target/min/max RPM and control mode.")

    @Flag(name: .long, help: "Print machine-readable JSON.")
    var json = false

    func run() throws {
        let status: FansStatusDTO = try DaemonClient().getFans()
        if json {
            print(try CLIJSON.encodeString(status))
            return
        }
        printFansStatus(status)
    }
}

struct FanSet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set a manual fan target in RPM, clamped to the fan's min/max.")

    @Argument(help: "Target fan speed in RPM.")
    var rpm: Double

    @Option(name: .long, help: "0-based fan index. Omit to set all fans.")
    var fan: Int?

    @Flag(name: .long, help: "Allow targets below the fan's minimum RPM (requires allow_below_minimum = true under [safety] in the daemon config; the max RPM is always a hard ceiling).")
    var force = false

    func run() throws {
        guard rpm.isFinite, rpm >= 0 else {
            throw ValidationError("RPM must be a non-negative finite number.")
        }
        let client = DaemonClient()
        let indices: [Int]
        if let fan {
            indices = [fan]
        } else {
            let status = try client.getFans()
            indices = status.fans.map(\.index)
            guard !indices.isEmpty else {
                print("No fans were reported by smctld.")
                return
            }
        }
        for index in indices {
            try client.setFanManual(index: index, rpm: rpm, force: force)
        }
        print("Fan target set to \(formatRPM(rpm))\(fan.map { " on fan \($0)" } ?? " on all fans").")
    }
}

struct FanAuto: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "auto", abstract: "Return fans to system control.")

    @Option(name: .long, help: "0-based fan index. Omit to restore all fans.")
    var fan: Int?

    func run() throws {
        try DaemonClient().setFanAuto(index: fan)
        if let fan {
            print("Fan \(fan) restored to system auto control.")
        } else {
            print("All fans restored to system auto control.")
        }
    }
}

struct FanProfile: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "profile", abstract: "Apply a fan profile: auto, quiet, full, or a custom curve.")

    @Argument(help: "Profile name: auto, quiet, full, or a configured custom curve.")
    var name: String

    func run() throws {
        try DaemonClient().setFanProfile(name)
        print("Fan profile set to \(name).")
    }
}

struct Battery: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "battery",
        abstract: "Inspect and control battery charge policy through smctld.",
        subcommands: [BatteryStatus.self, Maintain.self, Charge.self, Discharge.self]
    )
}

struct BatteryStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Charge level, charging state, and the configured limit.")

    @Flag(name: .long, help: "Print machine-readable JSON.")
    var json = false

    func run() throws {
        let status: BatteryStatusDTO = try DaemonClient().getBatteryStatus()
        if json {
            print(try CLIJSON.encodeString(status))
            return
        }
        printBatteryStatus(status)
    }
}

struct Maintain: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "maintain", abstract: "Keep charge inside a limit, e.g. 80, 70-80, or stop.")

    @Argument(help: "Charge limit: 80, 70-80, or stop.")
    var limit: String

    func run() throws {
        let client = DaemonClient()
        let normalized = limit.lowercased() == "stop" ? "100" : limit
        try client.setChargeLimit(normalized)
        if normalized == "100" {
            _ = try? client.setChargingEnabled(true)
            _ = try? client.setAdapterEnabled(true)
            print("Battery charge limiting stopped; charging and adapter power were restored when supported.")
        } else {
            print("Battery maintain policy set to \(limit).")
        }
    }
}

struct Charge: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "charge", abstract: "One-shot charge up to a target percent.")

    @Argument(help: "Upper charge target percent.")
    var target: Int

    func run() throws {
        guard (0...100).contains(target) else {
            throw ValidationError("Charge target must be between 0 and 100.")
        }
        let client = DaemonClient()
        try client.setChargeLimit(String(target))
        _ = try? client.setAdapterEnabled(true)
        try client.setChargingEnabled(true)
        print("Charging enabled with upper target \(target)%.")
    }
}

struct Discharge: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "discharge", abstract: "Cut adapter power and discharge to a target percent (foreground).")

    @Argument(help: "Discharge target percent.")
    var target: Int

    func run() throws {
        guard (0...100).contains(target) else {
            throw ValidationError("Discharge target must be between 0 and 100.")
        }
        let client = DaemonClient()
        var shouldRestoreAdapter = false
        defer {
            if shouldRestoreAdapter {
                _ = try? client.setAdapterEnabled(true)
            }
        }

        let initial: BatteryStatusDTO = try client.getBatteryStatus()
        guard initial.adapterControlSupported else {
            print("Adapter cutoff keys are unavailable on this Mac/system; active discharge is unsupported.")
            return
        }
        guard let charge = initial.chargePercent else {
            print("No readable battery was found; active discharge is unsupported on this Mac.")
            return
        }
        guard charge > target else {
            print("Battery is already at \(charge)%, not above target \(target)%.")
            return
        }

        try client.setAdapterEnabled(false)
        shouldRestoreAdapter = true
        print("Adapter disabled for foreground discharge to \(target)%. Press Ctrl-C to restore adapter power.")

        while true {
            sleep(10)
            let status: BatteryStatusDTO = try client.getBatteryStatus()
            guard let current = status.chargePercent else {
                print("Battery became unreadable; restoring adapter power.")
                return
            }
            print("Battery \(current)%")
            if current <= target {
                print("Target reached; restoring adapter power.")
                return
            }
        }
    }
}

struct Power: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "power",
        abstract: "Thermal pressure, CPU throttling, and power draw.",
        subcommands: [PowerStatus.self],
        defaultSubcommand: PowerStatus.self
    )
}

struct PowerStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show thermal pressure, CPU throttling, and power draw (no root, no daemon)."
    )

    @Flag(name: .long, help: "Print machine-readable JSON.")
    var json = false

    @Flag(name: .long, help: "Refresh every second until interrupted.")
    var watch = false

    func run() throws {
        let reader = PowerReader(backend: try SMCConnection())

        repeat {
            let snapshot = reader.snapshot()
            if json {
                print(try CLIJSON.encodeString(snapshot))
            } else {
                if watch {
                    print("\u{001B}[2J\u{001B}[H", terminator: "")
                }
                printPower(snapshot)
            }

            if watch {
                fflush(stdout)
                sleep(1)
            }
        } while watch
    }
}

private func printPower(_ snapshot: PowerSnapshot) {
    print("smctl power  \(CLIFormatters.iso8601.string(from: snapshot.timestamp))")
    print("")
    print("  Thermal pressure   \(snapshot.thermalPressure.rawValue)")
    print("  CPU throttling     \(throttleDescription(snapshot.cpu))")
    print("  Package power      \(watts(snapshot.packagePowerWatts))")
    print("  Input              \(inputDescription(snapshot))")
}

private func throttleDescription(_ cpu: CPUThrottleStatus) -> String {
    guard cpu.recorded else {
        return "none"
    }
    var parts: [String] = []
    if let speed = cpu.speedLimitPercent {
        let throttled = max(0, 100 - speed)
        parts.append(throttled > 0 ? "speed \(speed)% (\(throttled)% throttled)" : "speed \(speed)%")
    }
    if let scheduler = cpu.schedulerLimitPercent {
        parts.append("scheduler \(scheduler)%")
    }
    if let cpus = cpu.availableCPUs {
        parts.append("cores \(cpus)")
    }
    return parts.isEmpty ? "recorded (no detail)" : parts.joined(separator: ", ")
}

private func inputDescription(_ snapshot: PowerSnapshot) -> String {
    let power = watts(snapshot.inputPowerWatts)
    guard let voltage = snapshot.inputVoltage, let current = snapshot.inputCurrent else {
        return power
    }
    return "\(power)  (\(String(format: "%.2f", voltage)) V, \(String(format: "%.2f", current)) A)"
}

private func watts(_ value: Double?) -> String {
    guard let value else {
        return "unavailable"
    }
    return "\(String(format: "%.2f", value)) W"
}

struct Daemon: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Install, remove, and inspect smctld.",
        subcommands: [DaemonInstall.self, DaemonUninstall.self, DaemonRestart.self, DaemonStatus.self, DaemonPing.self]
    )
}

struct DaemonPing: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ping", abstract: "Round-trip check that smctld is alive.")

    func run() throws {
        let ping: PingDTO = try DaemonClient().ping()
        print("smctld ok \(ping.version) \(CLIFormatters.iso8601.string(from: ping.timestamp))")
    }
}

struct DaemonRestart: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "Restart smctld so it picks up an upgraded binary (requires root)."
    )

    func run() throws {
        guard geteuid() == 0 else {
            throw ValidationError("daemon restart must be run as root. Try: sudo smctl daemon restart")
        }
        try runProcess("/bin/launchctl", ["kickstart", "-k", "system/\(SMCtlProtocolInfo.machServiceName)"])
        print("smctld restarted.")
    }
}

struct DaemonStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Daemon health: config path, evaluation loop, last error.")

    @Flag(name: .long, help: "Print machine-readable JSON.")
    var json = false

    func run() throws {
        let status: DaemonStatusDTO = try DaemonClient().getDaemonStatus()
        if json {
            print(try CLIJSON.encodeString(status))
            return
        }
        print("smctld")
        print("  config: \(status.configPath)")
        print("  period: \(format(status.periodSeconds))s")
        print("  last evaluation: \(status.lastEvaluation.map { CLIFormatters.iso8601.string(from: $0) } ?? "-")")
        print("  last error: \(status.lastError ?? "-")")
    }

    private func format(_ value: Double) -> String {
        String(format: "%.0f", value)
    }
}

struct DaemonInstall: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install", abstract: "Register smctld as a LaunchDaemon (requires root).")

    func run() throws {
        guard geteuid() == 0 else {
            throw ValidationError("daemon install must be run as root. Try: sudo smctl daemon install")
        }

        let smctldPath = try Self.currentSmctldPath()
        let plist = Self.plist(smctldPath: smctldPath)
        try plist.write(toFile: Self.plistPath, atomically: true, encoding: .utf8)
        try runProcess("/bin/chmod", ["0644", Self.plistPath])
        try runProcess("/usr/sbin/chown", ["root:wheel", Self.plistPath])
        try runProcess("/bin/launchctl", ["bootstrap", "system", Self.plistPath])
        print("Installed smctld at \(Self.plistPath)")
    }

    static let plistPath = "/Library/LaunchDaemons/one.leaper.smctl.daemon.plist"

    private static func currentSmctldPath() throws -> String {
        let rawCommand = CommandLine.arguments[0]
        let command = rawCommand.hasPrefix("/")
            ? URL(fileURLWithPath: rawCommand)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(rawCommand)
        let directory = command.deletingLastPathComponent()
        let candidate = directory.appendingPathComponent("smctld").standardizedFileURL.path
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        throw ValidationError("Could not find smctld next to the current smctl executable.")
    }

    private static func plist(smctldPath: String) -> String {
        // SMAppService requires an app bundle. The CLI-only M2 milestone installs a hand-written LaunchDaemon plist.
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>one.leaper.smctl.daemon</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(smctldPath)</string>
            </array>
            <key>MachServices</key>
            <dict>
                <key>one.leaper.smctl.daemon</key>
                <true/>
            </dict>
            <key>KeepAlive</key>
            <true/>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """
    }
}

struct DaemonUninstall: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "uninstall", abstract: "Stop smctld, restore hardware defaults, remove the LaunchDaemon (requires root).")

    func run() throws {
        guard geteuid() == 0 else {
            throw ValidationError("daemon uninstall must be run as root. Try: sudo smctl daemon uninstall")
        }

        // The connection must be resumed for the restore calls to be delivered; if the
        // daemon is already gone they fail fast via the error handler and are ignored.
        let client = DaemonClient()
        _ = try? client.setFanAuto(index: nil)
        _ = try? client.setChargingEnabled(true)
        _ = try? client.setAdapterEnabled(true)
        // Current identifier plus the pre-0.1.2 legacy one (dev.smctl.*).
        for plistPath in [DaemonInstall.plistPath, "/Library/LaunchDaemons/dev.smctl.daemon.plist"] {
            _ = try? runProcess("/bin/launchctl", ["bootout", "system", plistPath])
            if FileManager.default.fileExists(atPath: plistPath) {
                try FileManager.default.removeItem(atPath: plistPath)
            }
        }
        print("Uninstalled smctld and restored fans plus charging/adapter power when supported.")
    }
}

private func printBatteryStatus(_ status: BatteryStatusDTO) {
    print("Battery")
    if let charge = status.chargePercent {
        print("  charge: \(charge)%")
    } else {
        print("  charge: unreadable")
    }
    print("  charging: \(status.isCharging.map { $0 ? "enabled" : "disabled" } ?? "unknown")")
    print("  plugged in: \(status.pluggedIn.map { $0 ? "yes" : "no" } ?? "unknown")")
    print("  maintain: \(status.configuredLimit) (lower \(status.lowerBound)%, upper \(status.upperBound)%)")
    print("  sleep policy: \(status.sleepPolicy)")
    print("  charging control: \(status.chargingControlGroup ?? "unsupported")")
    print("  adapter control: \(status.adapterControlGroup ?? "unsupported")")
    if let message = status.message {
        print("  note: \(message)")
    }
}

private func printFansStatus(_ status: FansStatusDTO) {
    print("Fans")
    print("  profile: \(status.profile)")
    if status.fans.isEmpty {
        print("  No fans reported by smctld.")
    } else {
        for fan in status.fans {
            print("  Fan \(fan.index): actual \(formatOptionalRPM(fan.actualRPM)), target \(formatOptionalRPM(fan.targetRPM)), min \(formatOptionalRPM(fan.minimumRPM)), max \(formatOptionalRPM(fan.maximumRPM)), mode \(fan.mode)")
        }
    }
    if let message = status.message {
        print("  note: \(message)")
    }
}

private func formatOptionalRPM(_ value: Double?) -> String {
    guard let value else {
        return "-"
    }
    return formatRPM(value)
}

private func formatRPM(_ value: Double) -> String {
    "\(String(format: "%.0f", value)) RPM"
}

struct Debug: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug",
        abstract: "Low-level SMC inspection (read-only, no daemon required).",
        shouldDisplay: false,
        subcommands: [DebugKeys.self, DebugRead.self, DebugWrite.self]
    )
}

struct DebugWrite: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "write",
        abstract: "Write raw bytes to one SMC key (root only; development diagnostics)."
    )

    @Argument(help: "Four-character SMC key.")
    var key: String

    @Argument(help: "Hex bytes, e.g. '01' or '00 00 1c 45'.")
    var hexBytes: [String]

    @Flag(name: .long, help: "Skip the read-back verification.")
    var noVerify = false

    func run() throws {
        guard geteuid() == 0 else {
            throw ValidationError("debug write must run as root.")
        }
        let bytes = try hexBytes.flatMap { chunk -> [UInt8] in
            try stride(from: 0, to: chunk.count, by: 2).map { offset in
                let start = chunk.index(chunk.startIndex, offsetBy: offset)
                let end = chunk.index(start, offsetBy: 2, limitedBy: chunk.endIndex) ?? chunk.endIndex
                guard let byte = UInt8(chunk[start..<end], radix: 16) else {
                    throw ValidationError("Invalid hex byte in '\(chunk)'.")
                }
                return byte
            }
        }
        let connection = try SMCConnection()
        if noVerify {
            try connection.writeRawValue(key, bytes: bytes)
            print("wrote \(key) (no verify)")
        } else {
            try connection.writeKey(key, bytes: bytes, retryPolicy: SMCWriteRetryPolicy(maxAttempts: 1, initialBackoffNanoseconds: 0))
            print("wrote \(key) (verified)")
        }
        let value = try connection.readValue(key)
        print("read-back: \(value.bytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
    }
}

struct DebugKeys: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "keys", abstract: "Enumerate SMC keys.")

    @Option(name: .long, help: "Only list keys with this prefix.")
    var prefix: String?

    func run() throws {
        let connection = try SMCConnection()
        var keys = try connection.enumerateKeys()
        if let prefix {
            keys = keys.filter { $0.hasPrefix(prefix) }
        }
        for key in keys {
            let info = try? connection.readKeyInfo(key)
            let type = info.map { $0.dataTypeString } ?? "?"
            let size = info.map { String($0.dataSize) } ?? "?"
            let attributes = info.map { String(format: "0x%02x", $0.dataAttributes) } ?? "?"
            print("\(key)  type=\(type) size=\(size) attr=\(attributes)")
        }
    }
}

struct DebugRead: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "read", abstract: "Read one SMC key.")

    @Argument(help: "Four-character SMC key.")
    var key: String

    func run() throws {
        let connection = try SMCConnection()
        let value = try connection.readValue(key)
        let hex = value.bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        print("\(key)  type=\(value.info.dataTypeString) size=\(value.info.dataSize) attr=\(String(format: "0x%02x", value.info.dataAttributes))")
        print("  bytes: \(hex)")
        if let decoded = value.decoded?.doubleValue {
            print("  decoded: \(decoded)")
        }
    }
}

private final class DaemonClient {
    private let connection: NSXPCConnection

    init() {
        connection = NSXPCConnection(machServiceName: SMCtlProtocolInfo.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: SMCtlDaemonXPCProtocol.self)
        // Resumed exactly once here; a second resume would trap (over-resume).
        connection.resume()
    }

    deinit {
        connection.invalidate()
    }

    func ping() throws -> PingDTO {
        try call { proxy, reply in
            proxy.daemonPing(withReply: reply)
        }
    }

    func getBatteryStatus() throws -> BatteryStatusDTO {
        try call { proxy, reply in
            proxy.getBatteryStatus(withReply: reply)
        }
    }

    func getFans() throws -> FansStatusDTO {
        try call { proxy, reply in
            proxy.getFans(withReply: reply)
        }
    }

    func getDaemonStatus() throws -> DaemonStatusDTO {
        try call { proxy, reply in
            proxy.getDaemonStatus(withReply: reply)
        }
    }

    func setChargeLimit(_ limit: String) throws {
        let data = try SMCtlProtocolCoding.encode(SetChargeLimitRequestDTO(limit: limit))
        let _: EmptyResponseDTO = try call { proxy, reply in
            proxy.setChargeLimit(data, withReply: reply)
        }
    }

    func setChargingEnabled(_ enabled: Bool) throws {
        let data = try SMCtlProtocolCoding.encode(SetEnabledRequestDTO(enabled: enabled))
        let _: EmptyResponseDTO = try call { proxy, reply in
            proxy.setChargingEnabled(data, withReply: reply)
        }
    }

    func setAdapterEnabled(_ enabled: Bool) throws {
        let data = try SMCtlProtocolCoding.encode(SetEnabledRequestDTO(enabled: enabled))
        let _: EmptyResponseDTO = try call { proxy, reply in
            proxy.setAdapterEnabled(data, withReply: reply)
        }
    }

    func setFanManual(index: Int, rpm: Double, force: Bool) throws {
        let data = try SMCtlProtocolCoding.encode(SetFanManualRequestDTO(index: index, rpm: rpm, force: force))
        let _: EmptyResponseDTO = try call { proxy, reply in
            proxy.setFanManual(data, withReply: reply)
        }
    }

    func setFanAuto(index: Int?) throws {
        let data = try SMCtlProtocolCoding.encode(SetFanAutoRequestDTO(index: index))
        let _: EmptyResponseDTO = try call { proxy, reply in
            proxy.setFanAuto(data, withReply: reply)
        }
    }

    func setFanProfile(_ name: String) throws {
        let data = try SMCtlProtocolCoding.encode(SetFanProfileRequestDTO(name: name))
        let _: EmptyResponseDTO = try call { proxy, reply in
            proxy.setFanProfile(data, withReply: reply)
        }
    }

    private func call<T: Decodable>(
        _ body: (SMCtlDaemonXPCProtocol, @escaping (Data?, String?) -> Void) -> Void
    ) throws -> T {
        // Note: the connection is resumed exactly once in init. Resuming an already
        // active NSXPCConnection is an over-resume and traps (SIGTRAP).
        let semaphore = DispatchSemaphore(value: 0)
        let box = XPCResultBox()

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == 4099 {
                // Connection invalidated: the mach service is not registered with launchd.
                box.error = "smctld is not running. Install it with 'sudo smctl daemon install' (check with 'smctl daemon status')."
            } else {
                box.error = String(describing: error)
            }
            semaphore.signal()
        } as? SMCtlDaemonXPCProtocol
        guard let proxy else {
            throw ValidationError("Could not create XPC proxy.")
        }
        body(proxy) { data, error in
            box.data = data
            box.error = error
            semaphore.signal()
        }
        // Bounded wait: never hang the CLI on a wedged daemon or undelivered message.
        if semaphore.wait(timeout: .now() + 15) == .timedOut {
            throw ValidationError("Timed out waiting for smctld (15s). Check 'smctl daemon status'.")
        }

        if let error = box.error {
            throw ValidationError(error)
        }
        guard let data = box.data else {
            throw ValidationError("Daemon returned no data.")
        }
        let result = try SMCtlProtocolCoding.decode(T.self, from: data)
        warnOnVersionIssues(result)
        return result
    }

    /// Two stderr hints, checked once per CLI invocation, both sourced from the
    /// daemon's ping (piggybacked on the command's own reply when it is a PingDTO,
    /// otherwise via one extra ping):
    ///   - version skew: brew swaps binaries but never restarts the daemon, so a
    ///     stale daemon keeps serving safety fixes that are not actually active
    ///     (observed live: a 0.1.2 daemon served a 0.1.5 CLI for three releases).
    ///   - update available: the daemon's daily check found a newer release.
    private var versionChecked = false

    private func warnOnVersionIssues<T>(_ result: T) {
        guard !versionChecked else { return }
        versionChecked = true  // set before any nested call() to prevent recursion

        let ping: PingDTO?
        if let p = result as? PingDTO {
            ping = p
        } else {
            ping = try? call { proxy, reply in
                proxy.daemonPing(withReply: reply)
            }
        }
        guard let ping else { return }

        if ping.version != SMCtlProtocolInfo.version {
            emit("""
            warning: smctl is \(SMCtlProtocolInfo.version) but the running smctld is \(ping.version).
            Fixes in this version are NOT active until the daemon restarts:
              sudo smctl daemon restart
            """)
        } else if let latest = ping.latestVersion,
                  SMCtlProtocolInfo.isVersion(latest, newerThan: SMCtlProtocolInfo.version) {
            emit("""
            note: smctl \(latest) is available (you have \(SMCtlProtocolInfo.version)). Upgrade:
              brew upgrade smctl && sudo smctl daemon restart
            """)
        }
    }

    private func emit(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n\n").utf8))
    }
}

private final class XPCResultBox: @unchecked Sendable {
    var data: Data?
    var error: String?
}

private enum CLIJSON {
    static func encodeString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

@discardableResult
private func runProcess(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        throw ValidationError(output.isEmpty ? "\(executable) failed with status \(process.terminationStatus)" : output)
    }
    return output
}
