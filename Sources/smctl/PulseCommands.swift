import ArgumentParser
import Darwin
import Foundation
import PolicyEngine
import ProductIdentity
import SMCCore
import SMCtlClient
import SMCtlProtocol

// Pulse commands: `pulse status` and `pulse fan curve …`. Kept apart from
// SMCtl.swift so upstream merges stay simple.

private func withDaemon<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let error as SMCtlClientError {
        throw ValidationError(error.localizedDescription)
    }
}

// MARK: - pulse status

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Overview: temperatures, fans, active profile, daemon and safety state."
    )

    @Flag(name: .long, help: "Print machine-readable JSON.")
    var json = false

    @Flag(name: .long, help: "Refresh until interrupted.")
    var watch = false

    @Option(name: .long, help: "Refresh interval in seconds for --watch.")
    var interval: Double = 2

    func validate() throws {
        guard interval.isFinite, interval >= 0.5 else {
            throw ValidationError("--interval must be at least 0.5 seconds.")
        }
    }

    func run() throws {
        let client = DaemonClient()
        let reader = (try? SMCConnection()).map { SensorReader(backend: $0) }
        repeat {
            let report = StatusReport.collect(client: client, fallback: reader)
            if json {
                print(try CLIJSON.encodeString(report))
            } else {
                if watch { print("\u{1B}[2J\u{1B}[H", terminator: "") }
                print(report.humanDescription, terminator: "")
            }
            if watch {
                fflush(stdout)
                usleep(useconds_t(interval * 1_000_000))
            }
        } while watch
    }
}

struct StatusReport: Codable, Equatable {
    struct DaemonState: Codable, Equatable {
        var running: Bool
        var version: String?
        var message: String?
    }

    struct Fan: Codable, Equatable {
        var index: Int
        var actualRPM: Double?
        var targetRPM: Double?
        var minimumRPM: Double?
        var maximumRPM: Double?
        var percent: Double?
        var mode: String
    }

    var timestamp: Date
    var daemon: DaemonState
    var profile: String?
    var groups: [TemperatureGroupSummary]
    var temperatures: [TemperatureDTO]
    var fans: [Fan]
    var curve: [FanCurveStateDTO]
    var power: [PowerReadingDTO]
    var safety: SafetyStateDTO?
    var conflicts: [FanControlConflict]

    /// Daemon telemetry when reachable; otherwise a direct, read-only SMC snapshot.
    static func collect(client: DaemonClient, fallback: SensorReader?) -> StatusReport {
        let conflicts = FanControlConflicts.detect()
        do {
            let telemetry = try client.getTelemetry()
            return StatusReport(
                telemetry: telemetry,
                daemon: DaemonState(running: true, version: telemetry.daemonVersion, message: telemetry.lastError),
                conflicts: conflicts
            )
        } catch {
            let message = (error as? SMCtlClientError)?.localizedDescription ?? String(describing: error)
            let snapshot = fallback?.snapshot()
            return StatusReport(
                timestamp: snapshot?.timestamp ?? Date(),
                daemon: DaemonState(running: false, version: nil, message: message),
                profile: nil,
                temperatures: (snapshot?.temperatures ?? []).compactMap {
                    $0.celsius.isFinite ? TemperatureDTO(key: $0.key, group: $0.group, celsius: $0.celsius) : nil
                },
                fans: (snapshot?.fans ?? []).map {
                    FanStatusDTO(index: $0.index, actualRPM: $0.actualRPM, targetRPM: $0.targetRPM,
                                 minimumRPM: $0.minimumRPM, maximumRPM: $0.maximumRPM, mode: $0.mode ?? "unknown")
                },
                curve: [],
                power: (snapshot?.power ?? []).compactMap { reading in
                    reading.value.map { PowerReadingDTO(key: reading.key, name: reading.name, value: $0, unit: reading.unit) }
                },
                safety: nil,
                conflicts: conflicts
            )
        }
    }

    init(telemetry: TelemetryDTO, daemon: DaemonState, conflicts: [FanControlConflict]) {
        self.init(
            timestamp: telemetry.timestamp, daemon: daemon, profile: telemetry.profile,
            temperatures: telemetry.temperatures, fans: telemetry.fans, curve: telemetry.curve,
            power: telemetry.power, safety: telemetry.safety, conflicts: conflicts
        )
    }

    init(
        timestamp: Date, daemon: DaemonState, profile: String?, temperatures: [TemperatureDTO],
        fans: [FanStatusDTO], curve: [FanCurveStateDTO], power: [PowerReadingDTO],
        safety: SafetyStateDTO?, conflicts: [FanControlConflict]
    ) {
        self.timestamp = timestamp
        self.daemon = daemon
        self.profile = profile
        self.temperatures = temperatures
        self.groups = TemperatureGroupSummary.summarize(temperatures)
        self.fans = fans.map { fan in
            var percent: Double?
            if let actual = fan.actualRPM, let minimum = fan.minimumRPM, let maximum = fan.maximumRPM, maximum > minimum {
                percent = FanSpeedRange(minimumRPM: minimum, maximumRPM: maximum).fraction(forRPM: actual) * 100
            }
            return Fan(index: fan.index, actualRPM: fan.actualRPM, targetRPM: fan.targetRPM,
                       minimumRPM: fan.minimumRPM, maximumRPM: fan.maximumRPM, percent: percent, mode: fan.mode)
        }
        self.curve = curve
        self.power = power
        self.safety = safety
        self.conflicts = conflicts
    }

    var humanDescription: String {
        var out = ""
        let daemonText: String
        if daemon.running {
            daemonText = "daemon \(daemon.version ?? "?")"
        } else {
            daemonText = "daemon not running (read-only)"
        }
        out += "\(ProductIdentity.cliName) · \(daemonText)"
        if let profile { out += " · profile \(profile)" }
        out += "\n"
        if !daemon.running, let message = daemon.message {
            out += "  \(message)\n"
        }

        out += "\nTemperatures\n"
        if groups.isEmpty { out += "  none readable\n" }
        for group in groups {
            var line = "  " + pad(group.label, 8)
            if let average = group.averageCelsius, let maximum = group.maximumCelsius, let hottest = group.hottestKey {
                line += "avg " + pad(celsius(average), 9) + "max " + pad(celsius(maximum), 9) + pad("(\(hottest))", 7)
            } else {
                line += pad("sensors off (powered down)", 39)
            }
            line += "· \(group.count) sensor\(group.count == 1 ? "" : "s")"
            if group.inactiveCount > 0, group.averageCelsius != nil { line += ", \(group.inactiveCount) off" }
            out += line + "\n"
        }

        out += "\nFans\n"
        if fans.isEmpty { out += "  none reported\n" }
        for fan in fans {
            var line = "  " + pad("Fan \(fan.index)", 8) + pad(rpm(fan.actualRPM), 10)
            if let percent = fan.percent { line += "\(Int(percent.rounded()))% · " }
            line += "target \(rpm(fan.targetRPM)) · \(fan.mode)"
            if let minimum = fan.minimumRPM, let maximum = fan.maximumRPM {
                line += " · range \(Int(minimum))–\(Int(maximum))"
            }
            out += line + "\n"
        }

        if !curve.isEmpty {
            out += "\nCurve\n"
            for state in curve {
                out += "  " + pad("Fan \(state.index)", 8)
                    + "\(celsius(state.aggregatedCelsius)) in → \(celsius(state.effectiveCelsius)) effective → \(rpm(state.targetRPM))\n"
            }
        }

        if !power.isEmpty {
            out += "\nPower\n  " + power.map { "\($0.name) \(String(format: "%.1f", $0.value)) \($0.unit ?? "")" }.joined(separator: " · ") + "\n"
        }

        if let safety {
            let hotSpot = min(safety.ceilingCelsius + FanSafetyGuard.hotSpotAllowanceCelsius, FanSafetyGuard.hotSpotHardMaximumCeilingCelsius)
            out += "\nSafety  "
            out += safety.latched ? "LATCHED — fans handed back to macOS" : "ok"
            out += " · ceiling \(celsius(safety.ceilingCelsius)) (hot-spots \(celsius(hotSpot)))\n"
            if let reason = safety.lastTripReason { out += "  last trip: \(reason)\n" }
        }

        if !conflicts.isEmpty {
            out += "\nOther fan controllers\n"
            for conflict in conflicts {
                out += "  ! \(conflict.product): \(conflict.running ? "RUNNING" : "installed, not running") (\(conflict.evidence))\n"
            }
            if conflicts.contains(where: \.running) {
                out += "  Two controllers fight over the fans: quit or uninstall the other one.\n"
            }
        }
        return out
    }
}

private func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
}

private func celsius(_ value: Double) -> String {
    String(format: "%.1f °C", value)
}

private func rpm(_ value: Double?) -> String {
    value.map { "\(Int($0.rounded())) RPM" } ?? "—"
}

// MARK: - pulse fan curve

struct FanCurveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "curve",
        abstract: "List, inspect, create and delete fan curves (percent based, with predefined shapes).",
        subcommands: [FanCurveList.self, FanCurveShow.self, FanCurveSet.self, FanCurveDelete.self]
    )
}

struct FanCurveList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Built-in presets and your curves.")

    @Flag(name: .long, help: "Print machine-readable JSON.")
    var json = false

    func run() throws {
        let list = try withDaemon { try DaemonClient().listFanCurves() }
        if json {
            print(try CLIJSON.encodeString(list))
            return
        }
        print("Active profile: \(list.activeProfile)\n")
        let rows = [("auto", "system", "macOS controls the fans")]
            + list.curves.map { entry in
                (entry.spec.name, entry.builtin ? "built-in" : "custom", curveSummary(entry.spec))
            }
        for (name, kind, summary) in rows {
            let marker = name == list.activeProfile ? "●" : " "
            print("\(marker) \(pad(name, 14))\(pad(kind, 10))\(summary)")
        }
        for (name, reason) in list.invalid.sorted(by: { $0.key < $1.key }) {
            print("! \(pad(name, 14))\(pad("invalid", 10))\(reason)")
        }
    }
}

struct FanCurveShow: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show a curve and preview the speed it asks for at each temperature.")

    @Argument(help: "Curve name.")
    var name: String

    @Option(name: .long, help: "Fan whose RPM range is used for the preview.")
    var fan: Int = 0

    @Flag(name: .long, help: "Print machine-readable JSON.")
    var json = false

    func run() throws {
        let client = DaemonClient()
        let list = try withDaemon { try client.listFanCurves() }
        guard let entry = list.curves.first(where: { $0.spec.name == name }) else {
            throw ValidationError("No curve named '\(name)'. See '\(ProductIdentity.cliName) fan curve list'.")
        }
        if json {
            print(try CLIJSON.encodeString(entry))
            return
        }
        print(curvePreview(entry.spec, builtin: entry.builtin, active: list.activeProfile == name, range: fanRange(client: client, index: fan)))
    }
}

struct FanCurveSet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Create or update a curve. Options not given keep their current value.",
        discussion: """
        Shapes: \(FanCurveShapeKind.allCases.map(\.rawValue).joined(separator: ", ")).
        Speeds are percentages of each fan's range (0% = its minimum RPM).

        Examples:
          \(ProductIdentity.cliName) fan curve set night --shape sigmoid --start 75 --end 100 --max 60% --activate
          \(ProductIdentity.cliName) fan curve set work --from balanced --start 65
          \(ProductIdentity.cliName) fan curve set custom --points 60:10%,80:45%,95:max --sensors 'Tp*'
        """
    )

    @Argument(help: "Curve name: lowercase letters, digits, '-' or '_'.")
    var name: String

    @Option(name: .long, help: "Start from a copy of this curve or preset.")
    var from: String?

    @Option(name: .long, help: "Display name.")
    var label: String?

    @Option(name: .long, help: "Shape type.")
    var shape: String?

    @Option(name: .long, help: "Temperature (°C) where the ramp starts.")
    var start: Double?

    @Option(name: .long, help: "Temperature (°C) where the ramp ends.")
    var end: Double?

    @Option(name: .long, help: "Speed below the ramp, e.g. 10%.")
    var min: String?

    @Option(name: .long, help: "Speed above the ramp, e.g. 100%.")
    var max: String?

    @Option(name: .long, help: "Curvature for sigmoid, exponential and logarithmic (0–30).")
    var steepness: Double?

    @Option(name: .long, help: "Number of plateaus for the steps shape.")
    var steps: Int?

    @Option(name: .long, help: "Explicit points instead of a shape: 60:10%,80:45%,95:max (speeds in %, RPM or max).")
    var points: String?

    @Option(name: .long, help: "Comma-separated sensor keys or patterns (Tp*, Tg*, …); 'all' for every sensor.")
    var sensors: String?

    @Option(name: .long, help: "Cool-down hysteresis in °C.")
    var hysteresis: Double?

    @Option(name: .long, help: "Maximum speed increase per second, e.g. 8% or 400 (RPM/s).")
    var rise: String?

    @Option(name: .long, help: "Maximum speed decrease per second, e.g. 3% or 150 (RPM/s).")
    var fall: String?

    @Option(name: .long, help: "Temperature smoothing time constant in seconds (0 disables).")
    var smoothing: Double?

    @Flag(name: .long, help: "Make it the active profile.")
    var activate = false

    @Flag(name: .long, help: "Preview without saving.")
    var dryRun = false

    func run() throws {
        let client = DaemonClient()
        let existing: [FanCurveEntryDTO]
        if dryRun, let list = try? client.listFanCurves() {
            existing = list.curves
        } else if dryRun {
            // Previewing works without the daemon, from the built-in presets.
            existing = FanCurvePresets.all.map { FanCurveEntryDTO(builtin: true, spec: $0) }
        } else {
            existing = try withDaemon { try client.listFanCurves() }.curves
        }
        let spec = try buildSpec(existing: existing)
        try spec.validate()
        if dryRun {
            print(curvePreview(spec, builtin: false, active: false, range: fanRange(client: client, index: 0)))
            return
        }
        try withDaemon { try client.upsertFanCurve(spec, activate: activate) }
        print("Saved curve '\(spec.name)'\(activate ? " and made it the active profile" : "").")
    }

    func buildSpec(existing: [FanCurveEntryDTO]) throws -> FanCurveSpec {
        let name = name.lowercased()
        var spec: FanCurveSpec
        if let from {
            guard let source = existing.first(where: { $0.spec.name == from.lowercased() }) else {
                throw ValidationError("No curve named '\(from)' to copy.")
            }
            spec = source.spec
            spec.name = name
            spec.label = nil
        } else if let current = existing.first(where: { $0.spec.name == name && !$0.builtin }) {
            spec = current.spec
        } else {
            spec = FanCurveSpec(name: name)
        }
        if let label { spec.label = label.isEmpty ? nil : label }

        if let points {
            guard shape == nil, start == nil, end == nil, min == nil, max == nil, steepness == nil, steps == nil else {
                throw ValidationError("--points cannot be combined with shape options.")
            }
            spec.points = try parseCurvePoints(points)
            spec.shape = nil
        } else if shape != nil || start != nil || end != nil || min != nil || max != nil || steepness != nil || steps != nil {
            let base = spec.shape
            let known = FanCurveShapeKind.allCases.map(\.rawValue).joined(separator: ", ")
            guard let kindName = shape ?? base?.kind.rawValue else {
                throw ValidationError("--shape is required (one of: \(known)).")
            }
            guard let kind = FanCurveShapeKind(rawValue: kindName.lowercased()) else {
                throw ValidationError("Unknown shape '\(kindName)' (one of: \(known)).")
            }
            guard let startValue = start ?? base?.startCelsius, let endValue = end ?? base?.endCelsius else {
                throw ValidationError("--start and --end are required for a new shape.")
            }
            let keepsSteepness = base?.kind == kind
            spec.shape = try FanCurveShape(
                kind: kind,
                startCelsius: startValue,
                endCelsius: endValue,
                minimumFraction: try min.map(parsePercent) ?? base?.minimumFraction ?? 0,
                maximumFraction: try max.map(parsePercent) ?? base?.maximumFraction ?? 1,
                steepness: steepness ?? (keepsSteepness ? base?.steepness : nil),
                stepCount: steps ?? base?.stepCount ?? 4
            )
            spec.points = []
        }

        if let sensors { spec.sensors = parseSensorList(sensors) }
        if let hysteresis { spec.hysteresisCelsius = hysteresis }
        if let rise { spec.riseRate = try FanRateValue(parsing: rise) }
        if let fall { spec.fallRate = try FanRateValue(parsing: fall) }
        if let smoothing { spec.smoothingSeconds = smoothing > 0 ? smoothing : nil }
        return spec
    }
}

struct FanCurveDelete: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a custom curve (fans return to macOS if it was active).")

    @Argument(help: "Curve name.")
    var name: String

    func run() throws {
        try withDaemon { try DaemonClient().deleteFanCurve(named: name.lowercased()) }
        print("Deleted curve '\(name.lowercased())'.")
    }
}

// MARK: - Conflicts

/// Printed after `daemon install`: another controller would fight the new daemon.
func printFanControlConflictWarning(_ conflicts: [FanControlConflict] = FanControlConflicts.detect()) {
    guard !conflicts.isEmpty else { return }
    print("\nOther fan controllers found — two controllers fight over the fans:")
    for conflict in conflicts {
        print("  ! \(conflict.product): \(conflict.running ? "RUNNING" : "installed") (\(conflict.evidence))")
    }
    print("Quit or uninstall them before using \(ProductIdentity.cliName) fan profiles.")
}

// MARK: - Parsing (internal for tests)

/// `60:10%,80:45%,95:max` → points. Speeds accept %, RPM or max.
func parseCurvePoints(_ text: String) throws -> [FanCurveSpecPoint] {
    try text.split(separator: ",").map { item in
        let parts = item.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let celsius = Double(parts[0]) else {
            throw ValidationError("Invalid point '\(item)': expected temperature:speed, e.g. 80:45%.")
        }
        do {
            return FanCurveSpecPoint(celsius, try FanSpeedValue(parsing: parts[1]))
        } catch {
            throw ValidationError("Invalid point '\(item)': \(error)")
        }
    }
}

/// `40%`, `40` or `max` → fraction of the fan range.
func parsePercent(_ text: String) throws -> Double {
    let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
    if trimmed == "max" { return 1 }
    let number = trimmed.hasSuffix("%") ? String(trimmed.dropLast()) : trimmed
    guard let value = Double(number.trimmingCharacters(in: .whitespaces)), value.isFinite, (0...100).contains(value) else {
        throw ValidationError("'\(text)' must be a percentage between 0% and 100%.")
    }
    return value / 100
}

/// `Tp*, Tg0P` → patterns; `all` or empty → every sensor.
func parseSensorList(_ text: String) -> [String] {
    let items = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    return items.count == 1 && items[0].lowercased() == "all" ? [] : items
}

// MARK: - Rendering

func curveSummary(_ spec: FanCurveSpec) -> String {
    var parts: [String] = []
    if let label = spec.label { parts.append(label) }
    if let shape = spec.shape {
        var text = "\(shape.kind.rawValue) \(number(shape.startCelsius))–\(number(shape.endCelsius)) °C, "
            + "\(percentText(shape.minimumFraction))→\(percentText(shape.maximumFraction))"
        switch shape.kind {
        case .sigmoid, .exponential, .logarithmic: text += ", steepness \(number(shape.steepness))"
        case .steps: text += ", \(shape.stepCount) steps"
        case .linear: break
        }
        parts.append(text)
    } else {
        parts.append(spec.points.sorted { $0.celsius < $1.celsius }.map { "\(number($0.celsius))°:\($0.speed.configString)" }.joined(separator: " "))
    }
    parts.append(spec.sensors.isEmpty ? "all sensors" : spec.sensors.joined(separator: ","))
    return parts.joined(separator: " · ")
}

func curvePreview(_ spec: FanCurveSpec, builtin: Bool, active: Bool, range: FanSpeedRange) -> String {
    var out = "\(spec.name)\(builtin ? " (built-in)" : "")\(active ? " — active" : "")\n"
    out += "  \(curveSummary(spec))\n"
    var tuning = ["hysteresis \(number(spec.hysteresisCelsius)) °C"]
    if let rise = spec.riseRate { tuning.append("rise \(rise.configString)/s") }
    if let fall = spec.fallRate { tuning.append("fall \(fall.configString)/s") }
    tuning.append(spec.smoothingSeconds.map { "smoothing \(number($0)) s" } ?? "no smoothing")
    out += "  \(tuning.joined(separator: " · "))\n\n"

    guard let curve = try? spec.resolve(for: range) else {
        return out + "  (curve does not resolve: check its points)\n"
    }
    let lower = (curve.points.first?.temperatureCelsius ?? 40) - 10
    let upper = (curve.points.last?.temperatureCelsius ?? 100) + 5
    let from = (lower / 5).rounded(.down) * 5
    let to = (upper / 5).rounded(.up) * 5
    out += "  Fan range \(Int(range.minimumRPM))–\(Int(range.maximumRPM)) RPM\n"
    out += "     °C      %      RPM\n"
    for celsius in stride(from: from, through: to, by: 5) {
        let target = FanCurveEngine.interpolate(points: curve.points, temperature: celsius)
        let clamped = Swift.min(range.maximumRPM, Swift.max(range.minimumRPM, target))
        let fraction = range.fraction(forRPM: clamped)
        let bar = String(repeating: "█", count: Int((fraction * 24).rounded()))
        out += String(format: "  %5.0f  %4.0f%%  %7.0f  ", celsius, fraction * 100, clamped) + bar + "\n"
    }
    return out
}

private func percentText(_ fraction: Double) -> String {
    "\(number(fraction * 100))%"
}

private func number(_ value: Double) -> String {
    let rounded = (value * 10).rounded() / 10
    return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
}

/// Range of a fan for previews: daemon telemetry, else a direct read, else a typical range.
private func fanRange(client: DaemonClient, index: Int) -> FanSpeedRange {
    if let fan = (try? client.getTelemetry())?.fans.first(where: { $0.index == index }),
       let minimum = fan.minimumRPM, let maximum = fan.maximumRPM {
        return FanSpeedRange(minimumRPM: minimum, maximumRPM: maximum)
    }
    if let connection = try? SMCConnection(),
       let fan = SensorReader(backend: connection).snapshot().fans.first(where: { $0.index == index }),
       let minimum = fan.minimumRPM, let maximum = fan.maximumRPM {
        return FanSpeedRange(minimumRPM: minimum, maximumRPM: maximum)
    }
    return FanSpeedRange(minimumRPM: 1000, maximumRPM: 5000)
}
