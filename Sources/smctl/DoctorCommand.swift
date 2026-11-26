import ArgumentParser
import Darwin
import Foundation
import PolicyEngine
import ProductIdentity
import SMCCore
import SMCtlClient
import SMCtlProtocol

// `pulse doctor`: one report describing what this Mac exposes (fans, Ftst,
// charging control, sensors) and whether Pulse can drive it. Meant to be pasted
// into a bug report. `--test-fans` additionally checks that fan writes take effect.

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Diagnose this Mac: hardware, SMC keys, daemon, conflicts. Paste the output into a bug report."
    )

    @Flag(name: .long, help: "Print machine-readable JSON.")
    var json = false

    @Flag(name: .long, help: "Briefly drive every fan to 40% and check it follows, then restore the previous profile.")
    var testFans = false

    func run() throws {
        let client = DaemonClient()
        var report = DoctorReport.collect(client: client)
        if testFans {
            report.fanTest = FanWriteTest.run(client: client, log: json ? { _ in } : { print($0); fflush(stdout) })
            report.checks = DoctorCheck.evaluate(report)
        }
        if json {
            print(try CLIJSON.encodeString(report))
        } else {
            print(report.humanDescription, terminator: "")
        }
    }
}

// MARK: - Report

struct DoctorReport: Codable, Equatable {
    struct Machine: Codable, Equatable {
        var model: String
        var chip: String
        var macOS: String
        var memoryGB: Int
    }

    struct Daemon: Codable, Equatable {
        var running: Bool
        var version: String?
        var cliVersion: String
        var profile: String?
        var configPath: String?
        var lastError: String?
        var message: String?
    }

    struct Fan: Codable, Equatable {
        var index: Int
        var modeKey: String?
        var minimumRPM: Double?
        var maximumRPM: Double?
        var actualRPM: Double?
        var mode: String?
    }

    struct SMC: Codable, Equatable {
        var readable: Bool
        var message: String?
        var fans: [Fan]
        var ftstAvailable: Bool
        /// "direct" (mode key writable as is), "ftst" (needs the Ftst unlock first), "none".
        var expectedUnlockPath: String
        var chargingControl: String?
        var adapterControl: String?
        var batteryReadable: Bool
        var temperatureGroups: [String: Int]
    }

    var timestamp: Date
    var machine: Machine
    var daemon: Daemon
    var smc: SMC
    var safety: SafetyStateDTO?
    var conflicts: [FanControlConflict]
    var fanTest: FanWriteTest.Result?
    var checks: [DoctorCheck] = []

    static func collect(client: DaemonClient) -> DoctorReport {
        let telemetry: TelemetryDTO?
        var daemonMessage: String?
        do {
            telemetry = try client.getTelemetry()
        } catch {
            telemetry = nil
            daemonMessage = (error as? SMCtlClientError)?.localizedDescription ?? String(describing: error)
        }
        let status = telemetry == nil ? nil : try? client.getDaemonStatus()
        var report = DoctorReport(
            timestamp: Date(),
            machine: .current(),
            daemon: Daemon(
                running: telemetry != nil,
                version: telemetry?.daemonVersion,
                cliVersion: SMCtlProtocolInfo.version,
                profile: telemetry?.profile,
                configPath: status?.configPath,
                lastError: telemetry?.lastError ?? status?.lastError,
                message: daemonMessage
            ),
            smc: .probe(liveFans: telemetry?.fans),
            safety: telemetry?.safety,
            conflicts: FanControlConflicts.detect()
        )
        report.checks = DoctorCheck.evaluate(report)
        return report
    }
}

extension DoctorReport.Machine {
    static func current() -> Self {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return Self(
            model: sysctlString("hw.model") ?? "unknown",
            chip: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            macOS: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion) (\(sysctlString("kern.osversion") ?? "?"))",
            memoryGB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

extension DoctorReport.SMC {
    /// Reads the SMC directly (unprivileged reads) so the report works without
    /// the daemon. Live fan values come from the daemon when it runs.
    static func probe(liveFans: [FanStatusDTO]?) -> Self {
        let connection: SMCConnection
        do {
            connection = try SMCConnection()
        } catch {
            return Self(readable: false, message: String(describing: error), fans: [], ftstAvailable: false,
                        expectedUnlockPath: "none", chargingControl: nil, adapterControl: nil,
                        batteryReadable: false, temperatureGroups: [:])
        }
        let capabilities = KeyCatalog().detectCapabilities(using: connection)
        let local = FanController(backend: connection, capabilities: capabilities).status()
        let fans = capabilities.fans.map { fan in
            let live = liveFans?.first { $0.index == fan.index }
            let status = local.first { $0.index == fan.index }
            return DoctorReport.Fan(
                index: fan.index,
                modeKey: fan.modeKey,
                minimumRPM: live?.minimumRPM ?? status?.minimumRPM,
                maximumRPM: live?.maximumRPM ?? status?.maximumRPM,
                actualRPM: live?.actualRPM ?? status?.actualRPM,
                mode: live?.mode ?? status?.mode.map { "\($0)" }
            )
        }
        let groups = Dictionary(grouping: capabilities.temperatureKeys) { String($0.prefix(2)) }.mapValues(\.count)
        return Self(
            readable: true,
            message: nil,
            fans: fans,
            ftstAvailable: capabilities.ftstAvailable,
            expectedUnlockPath: Self.unlockPath(fans: capabilities.fans, ftstAvailable: capabilities.ftstAvailable),
            chargingControl: capabilities.chargingControl?.identifier,
            adapterControl: capabilities.adapterControl?.identifier,
            batteryReadable: capabilities.batteryKeys.contains("BUIC"),
            temperatureGroups: groups
        )
    }

    /// The daemon tries a direct mode write first and falls back to Ftst only
    /// when that fails, so the presence of Ftst says which path may be needed.
    static func unlockPath(fans: [FanCapability], ftstAvailable: Bool) -> String {
        guard fans.contains(where: { $0.modeKey != nil }) else { return "none" }
        return ftstAvailable ? "direct, Ftst fallback" : "direct"
    }
}

// MARK: - Checks

struct DoctorCheck: Codable, Equatable {
    enum Level: String, Codable { case ok, info, warning, problem }

    var level: Level
    var name: String
    var detail: String

    static func evaluate(_ report: DoctorReport) -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        let daemon = report.daemon

        if daemon.running {
            checks.append(.init(level: .ok, name: "daemon", detail: "\(ProductIdentity.daemonName) \(daemon.version ?? "?") responds"))
            if let version = daemon.version, version != daemon.cliVersion {
                checks.append(.init(level: .warning, name: "versions",
                                    detail: "daemon \(version) and CLI \(daemon.cliVersion) differ; reinstall the service"))
            }
            if let error = daemon.lastError {
                checks.append(.init(level: .warning, name: "daemon error", detail: error))
            }
        } else {
            checks.append(.init(level: .problem, name: "daemon",
                                detail: "not reachable (\(daemon.message ?? "unknown error")); Pulse is read-only"))
        }

        let smc = report.smc
        if !smc.readable {
            checks.append(.init(level: .problem, name: "SMC", detail: "cannot open AppleSMC: \(smc.message ?? "?")"))
        } else if smc.fans.isEmpty {
            checks.append(.init(level: .info, name: "fans", detail: "no fan: fanless Mac, monitoring only"))
        } else if !smc.fans.contains(where: { $0.modeKey != nil }) {
            checks.append(.init(level: .problem, name: "fans", detail: "\(smc.fans.count) fan(s) but no mode key: fan control unsupported"))
        } else {
            let ranges = smc.fans.map { fan in
                "\(fan.index): \(fan.minimumRPM.map { "\(Int($0))" } ?? "?")–\(fan.maximumRPM.map { "\(Int($0))" } ?? "?") RPM"
            }
            checks.append(.init(level: .ok, name: "fans", detail: "\(smc.fans.count) controllable (\(ranges.joined(separator: ", "))); unlock: \(smc.expectedUnlockPath)"))
        }

        if smc.readable {
            if smc.temperatureGroups.keys.contains(where: { $0 == "Tp" || $0 == "TC" }) {
                checks.append(.init(level: .ok, name: "sensors", detail: smc.temperatureGroups.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")))
            } else {
                checks.append(.init(level: .problem, name: "sensors", detail: "no CPU temperature sensor found; curves would have no input"))
            }
            if smc.batteryReadable {
                checks.append(.init(level: smc.chargingControl == nil ? .info : .ok, name: "battery",
                                    detail: smc.chargingControl.map { "charge limit supported (\($0))" }
                                        ?? "no charging-control keys: macOS manages charging, charge limits unavailable"))
            }
        }

        if let safety = report.safety, safety.latched {
            checks.append(.init(level: .warning, name: "safety", detail: "latched: fans handed back to macOS (\(safety.lastTripReason ?? "no reason recorded"))"))
        }

        for conflict in report.conflicts {
            checks.append(.init(level: conflict.running ? .problem : .warning, name: "conflict",
                                detail: "\(conflict.product) \(conflict.running ? "is running" : "is installed") (\(conflict.evidence))"))
        }

        if let test = report.fanTest {
            checks.append(.init(level: test.passed ? .ok : .problem, name: "fan write test", detail: test.summary))
        }
        return checks
    }
}

// MARK: - Fan write test

enum FanWriteTest {
    struct FanResult: Codable, Equatable {
        var index: Int
        var targetRPM: Double
        var reachedRPM: Double?
        var secondsToSettle: Double?
    }

    struct Result: Codable, Equatable {
        var fans: [FanResult]
        var restoredProfile: String?
        var error: String?

        var passed: Bool { error == nil && !fans.isEmpty && fans.allSatisfy { $0.secondsToSettle != nil } }

        var summary: String {
            if let error { return error }
            let parts = fans.map { fan in
                "fan \(fan.index) → \(Int(fan.targetRPM)) RPM " + (fan.secondsToSettle.map { String(format: "in %.0f s", $0) } ?? "NOT reached (last \(fan.reachedRPM.map { "\(Int($0))" } ?? "?") RPM)")
            }
            return parts.joined(separator: ", ") + (restoredProfile.map { "; restored \($0)" } ?? "")
        }
    }

    static let fraction = 0.4
    static let timeout: TimeInterval = 20

    /// A fan has settled once it is within 5% (at least 100 RPM) of its target.
    static func settled(actual: Double?, target: Double) -> Bool {
        guard let actual else { return false }
        return abs(actual - target) <= max(100, target * 0.05)
    }

    static func run(client: DaemonClient, log: (String) -> Void) -> Result {
        let telemetry: TelemetryDTO
        do {
            telemetry = try client.getTelemetry()
        } catch {
            return Result(fans: [], restoredProfile: nil, error: "daemon unreachable: \(error)")
        }
        if telemetry.safety.latched {
            return Result(fans: [], restoredProfile: nil, error: "safety guard latched; test skipped")
        }
        let previous = telemetry.profile == "manual" ? "auto" : telemetry.profile
        let targets: [(Int, Double)] = telemetry.fans.compactMap { fan in
            guard let minimum = fan.minimumRPM, let maximum = fan.maximumRPM, maximum > minimum else { return nil }
            return (fan.index, (FanSpeedRange(minimumRPM: minimum, maximumRPM: maximum).rpm(forFraction: fraction)).rounded())
        }
        guard !targets.isEmpty else {
            return Result(fans: [], restoredProfile: nil, error: "no fan with a known speed range")
        }

        // Always hand the fans back, including on Ctrl-C.
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler {
            try? client.setFanProfile(previous)
            fputs("\nInterrupted: restored profile \(previous).\n", stderr)
            exit(130)
        }
        interrupt.resume()
        defer {
            interrupt.cancel()
            signal(SIGINT, SIG_DFL)
        }

        var results = targets.map { FanResult(index: $0.0, targetRPM: $0.1, reachedRPM: nil, secondsToSettle: nil) }
        var failure: String?
        do {
            for (index, target) in targets {
                log("Fan \(index): asking \(Int(target)) RPM…")
                try client.setFanManual(index: index, rpm: target, force: false)
            }
            let start = Date()
            while Date().timeIntervalSince(start) < timeout, results.contains(where: { $0.secondsToSettle == nil }) {
                Thread.sleep(forTimeInterval: 1)
                let fans = try client.getTelemetry().fans
                for i in results.indices where results[i].secondsToSettle == nil {
                    let actual = fans.first { $0.index == results[i].index }?.actualRPM
                    results[i].reachedRPM = actual
                    if settled(actual: actual, target: results[i].targetRPM) {
                        results[i].secondsToSettle = Date().timeIntervalSince(start)
                        log("Fan \(results[i].index): \(Int(actual ?? 0)) RPM after \(Int(results[i].secondsToSettle!.rounded())) s")
                    }
                }
            }
        } catch {
            failure = "fan write failed: \((error as? SMCtlClientError)?.localizedDescription ?? String(describing: error))"
        }

        var restored: String?
        do {
            try client.setFanProfile(previous)
            restored = previous
            log("Restored profile \(previous).")
        } catch {
            failure = (failure.map { $0 + "; " } ?? "") + "could not restore \(previous): \(error) — run `\(ProductIdentity.cliName) fan profile \(previous)`"
        }
        return Result(fans: results, restoredProfile: restored, error: failure)
    }
}

// MARK: - Text output

extension DoctorReport {
    var humanDescription: String {
        var out = "\(ProductIdentity.cliName) doctor · \(ISO8601DateFormatter().string(from: timestamp))\n\n"
        out += "Machine   \(machine.model) · \(machine.chip) · \(machine.memoryGB) GB · macOS \(machine.macOS)\n"
        out += "Pulse     CLI \(daemon.cliVersion) · daemon \(daemon.version ?? "not running")"
        if let profile = daemon.profile { out += " · profile \(profile)" }
        out += "\n"
        if let path = daemon.configPath { out += "Config    \(path)\n" }
        if smc.readable {
            out += "SMC       fans \(smc.fans.count) · Ftst \(smc.ftstAvailable ? "present" : "absent") · unlock \(smc.expectedUnlockPath)"
            out += " · charging control \(smc.chargingControl ?? "none") · adapter control \(smc.adapterControl ?? "none")\n"
            for fan in smc.fans {
                out += "          fan \(fan.index): mode key \(fan.modeKey ?? "none") · range \(fan.minimumRPM.map { "\(Int($0))" } ?? "?")–\(fan.maximumRPM.map { "\(Int($0))" } ?? "?") RPM"
                out += " · now \(fan.actualRPM.map { "\(Int($0.rounded()))" } ?? "?") RPM · \(fan.mode ?? "?")\n"
            }
        }
        out += "\nChecks\n"
        for check in checks {
            let mark: String
            switch check.level {
            case .ok: mark = "✓"
            case .info: mark = "·"
            case .warning: mark = "!"
            case .problem: mark = "✗"
            }
            out += "  \(mark) \(check.name): \(check.detail)\n"
        }
        if !testFansRan {
            out += "\nRun `\(ProductIdentity.cliName) doctor --test-fans` to check that fan writes take effect.\n"
        }
        return out
    }

    private var testFansRan: Bool { fanTest != nil }
}
