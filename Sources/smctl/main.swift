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
        subcommands: [Sensors.self, Battery.self, Daemon.self]
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

struct Battery: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "battery",
        abstract: "Inspect and control battery charge policy through smctld.",
        subcommands: [BatteryStatus.self, Maintain.self, Charge.self, Discharge.self]
    )
}

struct BatteryStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status")

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
    static let configuration = CommandConfiguration(commandName: "maintain")

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
    static let configuration = CommandConfiguration(commandName: "charge")

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
    static let configuration = CommandConfiguration(commandName: "discharge")

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

struct Daemon: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Install, remove, and inspect smctld.",
        subcommands: [DaemonInstall.self, DaemonUninstall.self, DaemonStatus.self, DaemonPing.self]
    )
}

struct DaemonPing: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ping")

    func run() throws {
        let ping: PingDTO = try DaemonClient().ping()
        print("smctld ok \(ping.version) \(CLIFormatters.iso8601.string(from: ping.timestamp))")
    }
}

struct DaemonStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status")

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
    static let configuration = CommandConfiguration(commandName: "install")

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

    static let plistPath = "/Library/LaunchDaemons/dev.smctl.daemon.plist"

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
            <string>dev.smctl.daemon</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(smctldPath)</string>
            </array>
            <key>MachServices</key>
            <dict>
                <key>dev.smctl.daemon</key>
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
    static let configuration = CommandConfiguration(commandName: "uninstall")

    func run() throws {
        guard geteuid() == 0 else {
            throw ValidationError("daemon uninstall must be run as root. Try: sudo smctl daemon uninstall")
        }

        let client = DaemonClient(connectImmediately: false)
        _ = try? client.setChargingEnabled(true)
        _ = try? client.setAdapterEnabled(true)
        _ = try? runProcess("/bin/launchctl", ["bootout", "system", DaemonInstall.plistPath])
        if FileManager.default.fileExists(atPath: DaemonInstall.plistPath) {
            try FileManager.default.removeItem(atPath: DaemonInstall.plistPath)
        }
        print("Uninstalled smctld and restored charging/adapter power when supported.")
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

private final class DaemonClient {
    private let connection: NSXPCConnection

    init(connectImmediately: Bool = true) {
        connection = NSXPCConnection(machServiceName: SMCtlProtocolInfo.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: SMCtlDaemonXPCProtocol.self)
        if connectImmediately {
            connection.resume()
        }
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
        semaphore.wait()

        if let error = box.error {
            throw ValidationError(error)
        }
        guard let data = box.data else {
            throw ValidationError("Daemon returned no data.")
        }
        return try SMCtlProtocolCoding.decode(T.self, from: data)
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
