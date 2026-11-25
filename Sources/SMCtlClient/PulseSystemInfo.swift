import Darwin
import Foundation
import PolicyEngine
import ProductIdentity
import SMCtlProtocol

// MARK: - Sensor groups

/// Human labels for SMC temperature key prefixes. Apple documents none of these;
/// the mapping follows observed Apple Silicon behavior (see docs/fan-profiles.md).
public enum SensorGroups {
    public static func label(for group: String) -> String {
        switch group {
        case "Tp", "TC": return "CPU"
        case "Tg", "TG": return "GPU"
        case "Ts": return "Board"
        case "Tm": return "Memory"
        case "TB": return "Battery"
        case "Ta", "TA": return "Ambient"
        case "TW": return "Wireless"
        case "TH": return "Storage"
        default: return group
        }
    }

    /// Display order: the groups that drive fan curves first.
    public static func sortKey(for group: String) -> Int {
        ["Tp", "TC", "Tg", "TG", "Ts", "Tm", "TH", "TB", "Ta", "TA", "TW"].firstIndex(of: group) ?? 100
    }

    /// Curve sensor pattern selecting a whole group, e.g. `Tp*`.
    public static func pattern(for group: String) -> String {
        "\(group)*"
    }
}

/// Per-group temperature summary shared by `pulse status` and the app.
/// Powered-down sensors (an idle GPU reads ~0 °C) are counted but excluded
/// from the average and maximum.
public struct TemperatureGroupSummary: Codable, Equatable, Sendable {
    public var group: String
    public var label: String
    /// Nil when every sensor of the group is powered down.
    public var averageCelsius: Double?
    public var maximumCelsius: Double?
    public var hottestKey: String?
    public var count: Int
    public var inactiveCount: Int

    public static func summarize(_ temperatures: [TemperatureDTO]) -> [TemperatureGroupSummary] {
        Dictionary(grouping: temperatures, by: \.group).map { group, readings in
            let active = readings.filter { FanTemperatureSample.plausibleCelsius.contains($0.celsius) }
            let hottest = active.max { $0.celsius < $1.celsius }
            return TemperatureGroupSummary(
                group: group,
                label: SensorGroups.label(for: group),
                averageCelsius: active.isEmpty ? nil : active.map(\.celsius).reduce(0, +) / Double(active.count),
                maximumCelsius: hottest?.celsius,
                hottestKey: hottest?.key,
                count: readings.count,
                inactiveCount: readings.count - active.count
            )
        }
        .sorted { (SensorGroups.sortKey(for: $0.group), $0.group) < (SensorGroups.sortKey(for: $1.group), $1.group) }
    }
}

// MARK: - Conflicting fan controllers

/// Another tool that can write fan speeds. Two controllers fight over the SMC
/// (each re-imposes its own target), so Pulse warns instead of silently losing.
public struct FanControlConflict: Codable, Equatable, Sendable {
    public var product: String
    /// LaunchDaemon plist or process that revealed it.
    public var evidence: String
    public var running: Bool

    public init(product: String, evidence: String, running: Bool) {
        self.product = product
        self.evidence = evidence
        self.running = running
    }
}

public enum FanControlConflicts {
    struct KnownController {
        var product: String
        /// LaunchDaemon labels of privileged helpers.
        var labels: [String]
        /// Process names of apps that drive fans while running.
        var processes: [String]
    }

    static let known: [KnownController] = [
        KnownController(product: "smctl", labels: ["one.leaper.smctl.daemon", "dev.smctl.daemon"], processes: ["smctld"]),
        KnownController(product: "TG Pro", labels: ["com.tunabellysoftware.TGFanHelper"], processes: ["TG Pro"]),
        KnownController(product: "Macs Fan Control", labels: ["com.crystalidea.macsfancontrol.smcwrite"], processes: ["Macs Fan Control"]),
        KnownController(product: "Stats", labels: ["eu.exelban.Stats.SMC.Helper"], processes: []),
        KnownController(product: "smcFanControl", labels: ["com.eidac.smcFanControl"], processes: ["smcFanControl"])
    ]

    /// Detects installed or running fan controllers other than this product.
    /// Inputs are injectable for tests; defaults inspect the live system.
    public static func detect(
        launchDaemonsDirectory: String = "/Library/LaunchDaemons",
        runningProcesses: Set<String>? = nil,
        ownLabel: String = ProductIdentity.machServiceName
    ) -> [FanControlConflict] {
        let processes = runningProcesses ?? runningProcessNames()
        var conflicts: [FanControlConflict] = []
        for controller in known {
            let labels = controller.labels.filter { $0 != ownLabel }
            let labelRunning = labels.contains { processes.contains($0) }
            let appRunning = controller.processes.first { processes.contains($0) }
            let installed = labels
                .map { "\(launchDaemonsDirectory)/\($0).plist" }
                .first { FileManager.default.fileExists(atPath: $0) }
            if let installed {
                conflicts.append(FanControlConflict(product: controller.product, evidence: installed, running: labelRunning || appRunning != nil))
            } else if let appRunning {
                conflicts.append(FanControlConflict(product: controller.product, evidence: "process \(appRunning)", running: true))
            } else if labelRunning {
                conflicts.append(FanControlConflict(product: controller.product, evidence: "helper process", running: true))
            }
        }
        return conflicts
    }

    /// Short names (`p_comm`, up to 32 bytes) of every process, via libproc.
    static func runningProcessNames() -> Set<String> {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 32)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        var names = Set<String>()
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        for pid in pids.prefix(Int(count)) where pid > 0 {
            if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
                names.insert(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
        }
        return names
    }
}
