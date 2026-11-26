import Foundation
import os
import PolicyEngine
import ProductIdentity
import SMCCore
import SMCtlProtocol

// Pulse additions to the daemon, kept out of Daemon.swift so upstream merges stay
// simple: percent/shape curves in TOML, curve management, telemetry, and the
// SMC write deadband.

private let pulseLogger = Logger(subsystem: ProductIdentity.logSubsystem, category: "curves")

// MARK: - TOML mapping

/// TOML form of a `FanCurveShape`:
/// `shape = { type = "sigmoid", start = 70, end = 100, min = "0%", max = "100%", steepness = 8, steps = 4 }`.
/// `min`/`max` are percentages of the fan range; bare numbers are read as percent,
/// "max" as 100%.
struct FanShapeConfig: Codable, Equatable, Sendable {
    var type: String
    var start: Double
    var end: Double
    var min: FanSpeedValue?
    var max: FanSpeedValue?
    var steepness: Double?
    var steps: Int?

    enum CodingKeys: String, CodingKey {
        case type, start, end, min, max, steepness, steps
    }

    init(shape: FanCurveShape) {
        type = shape.kind.rawValue
        start = shape.startCelsius
        end = shape.endCelsius
        min = .percent(Self.percent(shape.minimumFraction))
        max = .percent(Self.percent(shape.maximumFraction))
        steepness = shape.kind == .linear || shape.kind == .steps ? nil : shape.steepness
        steps = shape.kind == .steps ? shape.stepCount : nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        guard let start = try container.decodeLenientDoubleIfPresent(forKey: .start),
              let end = try container.decodeLenientDoubleIfPresent(forKey: .end) else {
            throw DecodingError.keyNotFound(CodingKeys.start, .init(codingPath: container.codingPath, debugDescription: "shape needs start and end temperatures"))
        }
        self.start = start
        self.end = end
        min = try container.decodeIfPresent(FanSpeedValue.self, forKey: .min)
        max = try container.decodeIfPresent(FanSpeedValue.self, forKey: .max)
        steepness = try container.decodeLenientDoubleIfPresent(forKey: .steepness)
        steps = try container.decodeIfPresent(Int.self, forKey: .steps)
    }

    func shape() throws -> FanCurveShape {
        guard let kind = FanCurveShapeKind(rawValue: type.lowercased()) else {
            let known = FanCurveShapeKind.allCases.map(\.rawValue).joined(separator: ", ")
            throw PolicyError.invalidFanCurve("unknown shape type '\(type)' (expected one of: \(known))")
        }
        return try FanCurveShape(
            kind: kind,
            startCelsius: start,
            endCelsius: end,
            minimumFraction: Self.fraction(min, default: 0),
            maximumFraction: Self.fraction(max, default: 1),
            steepness: steepness,
            stepCount: steps ?? 4
        )
    }

    /// Fraction → percent without binary noise (0.29 * 100 = 28.999999999999996).
    private static func percent(_ fraction: Double) -> Double {
        (fraction * 100 * 1e6).rounded() / 1e6
    }

    private static func fraction(_ value: FanSpeedValue?, default fallback: Double) -> Double {
        switch value {
        case nil: return fallback
        case .percent(let percent), .rpm(let percent): return percent / 100
        case .maximum: return 1
        }
    }

    var tomlInlineTable: String {
        var fields = ["type = \(SmctlDaemon.tomlString(type))", "start = \(start)", "end = \(end)"]
        if let min { fields.append("min = \(SmctlDaemon.tomlString(min.configString))") }
        if let max { fields.append("max = \(SmctlDaemon.tomlString(max.configString))") }
        if let steepness { fields.append("steepness = \(steepness)") }
        if let steps { fields.append("steps = \(steps)") }
        return "{ " + fields.joined(separator: ", ") + " }"
    }
}

extension FanCurveConfig {
    init(spec: FanCurveSpec) {
        self.init(
            name: spec.name,
            sensors: spec.sensors,
            points: spec.points.map { point in
                let speed: FanPointValue
                switch point.speed {
                case .rpm(let value): speed = .number(value)
                case .percent(let value): speed = .percent(value)
                case .maximum: speed = .maximum
                }
                return [.number(point.celsius), speed]
            },
            hysteresis: spec.hysteresisCelsius,
            slew_rate: spec.riseRate,
            fall_slew_rate: spec.fallRate,
            weights: spec.weights.isEmpty ? nil : spec.weights,
            label: spec.label,
            shape: spec.shape.map(FanShapeConfig.init(shape:)),
            smoothing: spec.smoothingSeconds
        )
    }

    func spec() throws -> FanCurveSpec {
        let points = try points.map { values -> FanCurveSpecPoint in
            guard values.count == 2 else {
                throw DaemonError.unsupported("Fan curve '\(name)' points must contain [temperature, speed].")
            }
            guard case .number(let temperature) = values[0] else {
                throw DaemonError.unsupported("Fan curve '\(name)' temperature must be numeric.")
            }
            switch values[1] {
            case .number(let rpm): return FanCurveSpecPoint(temperature, .rpm(rpm))
            case .percent(let percent): return FanCurveSpecPoint(temperature, .percent(percent))
            case .maximum: return FanCurveSpecPoint(temperature, .maximum)
            }
        }
        return FanCurveSpec(
            name: name,
            label: label,
            sensors: sensors,
            weights: weights ?? [:],
            shape: try shape?.shape(),
            points: points,
            hysteresisCelsius: hysteresis,
            riseRate: slew_rate,
            fallRate: fall_slew_rate,
            smoothingSeconds: smoothing
        )
    }
}

// MARK: - Daemon

extension SmctlDaemon {
    /// Skip SMC writes when the fan is already in manual mode with a target within
    /// this distance: max(50 RPM, 1% of the fan range).
    static let fanWriteDeadbandRPM = 50.0
    static let fanWriteDeadbandFraction = 0.01

    /// A TOML basic string with quotes, backslashes and control characters escaped.
    static func tomlString(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    escaped += String(format: "\\u%04X", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return "\"\(escaped)\""
    }

    static func formatCurveConfig(_ curve: FanCurveConfig) -> String {
        var lines = [
            "",
            "[[fan.curves]]",
            "name = \(tomlString(curve.name))",
            "sensors = [\(curve.sensors.map(tomlString).joined(separator: ", "))]"
        ]
        if let label = curve.label { lines.append("label = \(tomlString(label))") }
        if let shape = curve.shape {
            lines.append("shape = \(shape.tomlInlineTable)")
        } else {
            lines.append("points = [\(curve.points.map(formatFanPoint).joined(separator: ", "))]")
        }
        lines.append("hysteresis = \(curve.hysteresis)")
        if let rate = curve.slew_rate { lines.append("slew_rate = \(rateLiteral(rate))") }
        if let rate = curve.fall_slew_rate { lines.append("fall_slew_rate = \(rateLiteral(rate))") }
        if let smoothing = curve.smoothing { lines.append("smoothing = \(smoothing)") }
        if let weights = curve.weights, !weights.isEmpty {
            let pairs = weights.sorted { $0.key < $1.key }.map { "\(tomlString($0.key)) = \($0.value)" }.joined(separator: ", ")
            lines.append("weights = { \(pairs) }")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func rateLiteral(_ rate: FanRateValue) -> String {
        switch rate {
        case .rpmPerSecond(let value): return String(value)
        case .percentPerSecond: return tomlString(rate.configString)
        }
    }

    func fanRangeLocked(_ fan: FanCapability) -> FanSpeedRange {
        FanSpeedRange(
            minimumRPM: readNumericLocked(fan.minimumKey) ?? 0,
            maximumRPM: readNumericLocked(fan.maximumKey) ?? 6000
        )
    }

    func firstFanRangeLocked() -> FanSpeedRange {
        capabilities.fans.first.map(fanRangeLocked) ?? FanSpeedRange(minimumRPM: 0, maximumRPM: 6000)
    }

    /// True unless the fan is verifiably already in manual mode with a target close
    /// enough. Any unreadable state means "write", so the deadband can only skip
    /// redundant writes, never hide a lost manual mode (e.g. after sleep).
    // MARK: Idle handoff

    /// Whether macOS runs `fan` this tick. At the curve's 0% floor the fan is
    /// handed back to macOS, but only after `FanCurveHandoff.releaseDelaySeconds`
    /// spent continuously at 0%: until then the floor is held, so a temperature
    /// hovering at the ramp start (no hysteresis, no smoothing) cannot toggle the
    /// mode — and, on Ftst Macs, the blocking unlock — every second. Taking the
    /// fan back when the curve rises is immediate.
    func handOffIdleFanLocked(_ fan: FanCapability, evaluation: FanCurveEvaluation, range: FanSpeedRange) throws -> Bool {
        guard FanCurveHandoff.releasesToSystem(targetRPM: evaluation.targetRPM, range: range) else {
            curveIdleSince[fan.index] = nil
            handedOffFans.remove(fan.index)
            return false
        }
        guard fanIsManualLocked(fan) else {
            // Already macOS's (e.g. a cool Mac when the curve was activated).
            curveIdleSince[fan.index] = nil
            handedOffFans.insert(fan.index)
            return true
        }
        let now = now()
        let since = curveIdleSince[fan.index] ?? now
        curveIdleSince[fan.index] = since
        guard now.timeIntervalSince(since) >= FanCurveHandoff.releaseDelaySeconds else {
            handedOffFans.remove(fan.index)
            return false
        }
        try restoreFansAutoLocked(indices: [fan.index])
        curveIdleSince[fan.index] = nil
        handedOffFans.insert(fan.index)
        return true
    }

    /// Whether Pulse holds `fan` in manual mode. An unreadable mode counts as
    /// manual, so a handoff is never skipped by mistake; a fan with no mode key
    /// cannot be in manual mode (setAuto and unlock both need the key), so only
    /// the daemon's own bookkeeping counts there.
    func fanIsManualLocked(_ fan: FanCapability) -> Bool {
        if ftstGate.manualFanIndices.contains(fan.index) || manualFanTargets[fan.index] != nil { return true }
        guard let modeKey = fan.modeKey else { return false }
        guard let mode = readUInt8Locked(modeKey) else { return true }
        return mode != FanModeValue.auto.rawValue
    }

    func fanTargetNeedsWriteLocked(fan: FanCapability, target: Double, range: FanSpeedRange) -> Bool {
        guard let modeKey = fan.modeKey,
              readUInt8Locked(modeKey) == FanModeValue.manual.rawValue,
              let current = readNumericLocked(fan.targetKey), current.isFinite else {
            return true
        }
        let threshold = Swift.max(Self.fanWriteDeadbandRPM, range.spanRPM * Self.fanWriteDeadbandFraction)
        return abs(current - target) >= threshold
    }

    /// Pulse presets first, then curves from the config file.
    func fanCurveSpecLocked(named name: String) throws -> FanCurveSpec {
        if let preset = FanCurvePresets.named(name) {
            return preset
        }
        guard let curve = config.fan.curves.first(where: { $0.name == name }) else {
            throw DaemonError.unsupported("Fan profile '\(name)' is not configured.")
        }
        return try curve.spec()
    }

    func listFanCurves() -> FanCurveListDTO {
        queue.sync {
            var entries = FanCurvePresets.all.map { FanCurveEntryDTO(builtin: true, spec: $0) }
            var invalid: [String: String] = [:]
            for curve in config.fan.curves where FanCurvePresets.named(curve.name) == nil {
                do {
                    let spec = try curve.spec()
                    try spec.validateContent()
                    entries.append(FanCurveEntryDTO(builtin: false, spec: spec))
                } catch {
                    invalid[curve.name] = String(describing: error)
                }
            }
            return FanCurveListDTO(activeProfile: currentFanProfileLocked(), curves: entries, invalid: invalid)
        }
    }

    func upsertFanCurve(_ spec: FanCurveSpec, activate: Bool) throws {
        try spec.validate()
        try queue.sync {
            // Rewriting the file while it failed to parse would replace the user's
            // config with defaults.
            if let configError {
                throw DaemonError.unsupported("Refusing to rewrite the config while it fails to parse: \(configError)")
            }
            for fan in capabilities.fans {
                _ = try spec.resolve(for: fanRangeLocked(fan))
            }
            let entry = FanCurveConfig(spec: spec)
            if let index = config.fan.curves.firstIndex(where: { $0.name == spec.name }) {
                config.fan.curves[index] = entry
            } else {
                config.fan.curves.append(entry)
            }
            try Self.writeConfig(config, path: configPath)
            pulseLogger.notice("Saved fan curve \(spec.name, privacy: .public)")
        }
        if activate {
            try setFanProfile(spec.name)
        }
    }

    func deleteFanCurve(named name: String) throws {
        guard !FanCurvePresets.reservedNames.contains(name) else {
            throw DaemonError.unsupported("'\(name)' is a built-in profile and cannot be deleted.")
        }
        try queue.sync {
            if let configError {
                throw DaemonError.unsupported("Refusing to rewrite the config while it fails to parse: \(configError)")
            }
            guard let index = config.fan.curves.firstIndex(where: { $0.name == name }) else {
                throw DaemonError.unsupported("Fan curve '\(name)' is not configured.")
            }
            let wasActive = currentFanProfileLocked() == name
            if wasActive {
                // Hand control back to the system before the curve disappears.
                try restoreFansAutoLocked(indices: capabilities.fans.map(\.index))
                manualFanTargets.removeAll()
                fanCurveEngines.removeAll()
                lastCurveEvaluations.removeAll()
                curveIdleSince.removeAll()
                handedOffFans.removeAll()
                runtimeFanProfile = nil
                config.fan.profile = "auto"
            }
            config.fan.curves.remove(at: index)
            try Self.writeConfig(config, path: configPath)
            pulseLogger.notice("Deleted fan curve \(name, privacy: .public)")
        }
    }

    func telemetry() -> TelemetryDTO {
        queue.sync {
            let snapshot = lastSnapshot
            let profile = currentFanProfileLocked()
            let curveActive = profile != "auto" && profile != "manual"
            return TelemetryDTO(
                timestamp: snapshot?.timestamp ?? Date(),
                daemonVersion: SMCtlProtocolInfo.version,
                profile: profile,
                temperatures: (snapshot?.temperatures ?? []).compactMap { reading in
                    reading.celsius.isFinite ? TemperatureDTO(key: reading.key, group: reading.group, celsius: reading.celsius) : nil
                },
                fans: (snapshot?.fans ?? []).map { fan in
                    FanStatusDTO(
                        index: fan.index,
                        actualRPM: fan.actualRPM,
                        targetRPM: fan.targetRPM,
                        minimumRPM: fan.minimumRPM,
                        maximumRPM: fan.maximumRPM,
                        mode: fan.mode ?? "unknown"
                    )
                },
                curve: curveActive ? lastCurveEvaluations.sorted { $0.key < $1.key }.map { index, evaluation in
                    FanCurveStateDTO(
                        index: index,
                        aggregatedCelsius: evaluation.aggregatedTemperature,
                        effectiveCelsius: evaluation.effectiveTemperature,
                        targetRPM: evaluation.targetRPM,
                        handedToSystem: handedOffFans.contains(index)
                    )
                } : [],
                power: (snapshot?.power ?? []).compactMap { reading in
                    reading.value.flatMap { $0.isFinite ? PowerReadingDTO(key: reading.key, name: reading.name, value: $0, unit: reading.unit) : nil }
                },
                safety: SafetyStateDTO(
                    latched: safetyGuard.isLatched,
                    ceilingCelsius: safetyGuard.configuredCeilingCelsius,
                    lastTripReason: lastSafetyTripReason
                ),
                lastError: lastError
            )
        }
    }
}

// MARK: - XPC

extension XPCService: PulseDaemonXPCProtocol {
    func getTelemetry(withReply reply: @escaping (Data?, String?) -> Void) {
        send(daemon.telemetry(), reply)
    }

    func listFanCurves(withReply reply: @escaping (Data?, String?) -> Void) {
        send(daemon.listFanCurves(), reply)
    }

    func upsertFanCurve(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        doWrite(reply) {
            let request = try SMCtlProtocolCoding.decode(UpsertFanCurveRequestDTO.self, from: requestData)
            try daemon.upsertFanCurve(request.spec, activate: request.activate)
        }
    }

    func deleteFanCurve(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        doWrite(reply) {
            let request = try SMCtlProtocolCoding.decode(DeleteFanCurveRequestDTO.self, from: requestData)
            try daemon.deleteFanCurve(named: request.name)
        }
    }
}
