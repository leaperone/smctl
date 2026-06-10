import Foundation

/// macOS thermal pressure level, mirrored from `ProcessInfo.ThermalState`.
/// This is the system's own assessment of thermal headroom — the cleanest
/// "are we being throttled?" signal, available without root or a subprocess.
public enum ThermalPressure: String, Codable, Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .unknown
        }
    }
}

/// CPU throttling quantified from `pmset -g therm`.
///
/// Apple Silicon does not expose `IOPMCopyCPUPowerStatus` (it returns
/// kIOReturnNotFound — verified on M4 mini), so `pmset` is the only public,
/// non-root source for the actual speed-limit percentage. When the system has
/// recorded no thermal pressure, `pmset` reports "No CPU power status has been
/// recorded" and `recorded` is false — which means "not throttled", not "unknown".
public struct CPUThrottleStatus: Codable, Equatable, Sendable {
    /// True when `pmset` has a CPU power status to report. False means the system
    /// has recorded no throttling — treat the CPU as running at full speed.
    public var recorded: Bool
    /// CPU_Speed_Limit: percent of full clock available (100 = no throttling).
    public var speedLimitPercent: Int?
    /// CPU_Scheduler_Limit: percent of scheduler capacity available.
    public var schedulerLimitPercent: Int?
    /// CPU_Available_CPUs: cores the scheduler is currently allowed to use.
    public var availableCPUs: Int?

    public init(
        recorded: Bool,
        speedLimitPercent: Int? = nil,
        schedulerLimitPercent: Int? = nil,
        availableCPUs: Int? = nil
    ) {
        self.recorded = recorded
        self.speedLimitPercent = speedLimitPercent
        self.schedulerLimitPercent = schedulerLimitPercent
        self.availableCPUs = availableCPUs
    }

    /// True when the CPU is demonstrably below full speed.
    public var isThrottled: Bool {
        guard let speedLimitPercent else { return false }
        return speedLimitPercent < 100
    }
}

public struct PowerSnapshot: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var thermalPressure: ThermalPressure
    public var cpu: CPUThrottleStatus
    /// PDTR — DC-in total power in watts. Legitimately ~0 when running on
    /// battery (it measures adapter delivery, not consumption).
    public var packagePowerWatts: Double?
    /// PSTR — system total power in watts. Meaningful on both AC and battery;
    /// the better "what is the machine drawing" signal on portables.
    public var systemPowerWatts: Double?
    /// VD0R — DC input voltage in volts.
    public var inputVoltage: Double?
    /// ID0R — DC input current in amps.
    public var inputCurrent: Double?

    public init(
        timestamp: Date,
        thermalPressure: ThermalPressure,
        cpu: CPUThrottleStatus,
        packagePowerWatts: Double?,
        systemPowerWatts: Double?,
        inputVoltage: Double?,
        inputCurrent: Double?
    ) {
        self.timestamp = timestamp
        self.thermalPressure = thermalPressure
        self.cpu = cpu
        self.packagePowerWatts = packagePowerWatts
        self.systemPowerWatts = systemPowerWatts
        self.inputVoltage = inputVoltage
        self.inputCurrent = inputCurrent
    }

    /// Input power in watts, computed when both voltage and current are readable.
    public var inputPowerWatts: Double? {
        guard let inputVoltage, let inputCurrent else { return nil }
        return inputVoltage * inputCurrent
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, thermalPressure, cpu, packagePowerWatts, systemPowerWatts
        case inputVoltage, inputCurrent, inputPowerWatts
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(thermalPressure, forKey: .thermalPressure)
        try container.encode(cpu, forKey: .cpu)
        try container.encodeIfPresent(packagePowerWatts, forKey: .packagePowerWatts)
        try container.encodeIfPresent(systemPowerWatts, forKey: .systemPowerWatts)
        try container.encodeIfPresent(inputVoltage, forKey: .inputVoltage)
        try container.encodeIfPresent(inputCurrent, forKey: .inputCurrent)
        try container.encodeIfPresent(inputPowerWatts, forKey: .inputPowerWatts)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        thermalPressure = try container.decode(ThermalPressure.self, forKey: .thermalPressure)
        cpu = try container.decode(CPUThrottleStatus.self, forKey: .cpu)
        packagePowerWatts = try container.decodeIfPresent(Double.self, forKey: .packagePowerWatts)
        systemPowerWatts = try container.decodeIfPresent(Double.self, forKey: .systemPowerWatts)
        inputVoltage = try container.decodeIfPresent(Double.self, forKey: .inputVoltage)
        inputCurrent = try container.decodeIfPresent(Double.self, forKey: .inputCurrent)
    }
}

/// Pure parser for `pmset -g therm` output. Kept side-effect free so it can be
/// unit-tested against captured fixtures without forking a subprocess.
public enum PmsetThermParser {
    public static func parse(_ output: String) -> CPUThrottleStatus {
        let speed = value(for: "CPU_Speed_Limit", in: output)
        let scheduler = value(for: "CPU_Scheduler_Limit", in: output)
        let cpus = value(for: "CPU_Available_CPUs", in: output)
        let recorded = speed != nil || scheduler != nil || cpus != nil
        return CPUThrottleStatus(
            recorded: recorded,
            speedLimitPercent: speed,
            schedulerLimitPercent: scheduler,
            availableCPUs: cpus
        )
    }

    /// Matches a line like `CPU_Speed_Limit 	= 100` (whitespace around `=` varies).
    private static func value(for label: String, in output: String) -> Int? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(label) else { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let rhs = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            // Take the leading integer; tolerate trailing units/garbage.
            let digits = rhs.prefix { $0.isNumber }
            if let number = Int(digits) {
                return number
            }
        }
        return nil
    }
}

/// Reads the unified power/thermal picture: thermal pressure (ProcessInfo),
/// CPU throttling (pmset), and DC power rails (SMC). Pure-read, no root, no
/// daemon — mirrors `SensorReader`.
public final class PowerReader {
    private let backend: SMCBackend
    private let thermalStateProvider: () -> ProcessInfo.ThermalState
    private let pmsetThermProvider: () -> String?
    private let now: () -> Date

    public init(
        backend: SMCBackend,
        thermalStateProvider: @escaping () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
        pmsetThermProvider: @escaping () -> String? = PowerReader.runPmsetTherm,
        now: @escaping () -> Date = { Date() }
    ) {
        self.backend = backend
        self.thermalStateProvider = thermalStateProvider
        self.pmsetThermProvider = pmsetThermProvider
        self.now = now
    }

    public func snapshot() -> PowerSnapshot {
        let cpu = pmsetThermProvider().map(PmsetThermParser.parse)
            ?? CPUThrottleStatus(recorded: false)
        return PowerSnapshot(
            timestamp: now(),
            thermalPressure: ThermalPressure(thermalStateProvider()),
            cpu: cpu,
            packagePowerWatts: numericValue("PDTR"),
            systemPowerWatts: numericValue("PSTR"),
            inputVoltage: numericValue("VD0R"),
            inputCurrent: numericValue("ID0R")
        )
    }

    private func numericValue(_ key: String) -> Double? {
        guard let value = try? backend.readValue(key) else { return nil }
        return value.decoded?.doubleValue
    }

    /// Runs `/usr/bin/pmset -g therm` and returns its stdout, or nil on failure.
    /// pmset needs no privileges to read thermal state.
    public static func runPmsetTherm() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "therm"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
