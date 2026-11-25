import Darwin
import Foundation
import ProductIdentity

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
