import Foundation
import PolicyEngine
import SMCtlClient
import SMCtlProtocol

/// In-memory service with Mac mini M4-like readings, for previews, snapshots and
/// tests. Activating a profile or saving a curve updates its state.
public final class SampleService: PulseService, @unchecked Sendable {
    private let lock = NSLock()
    private var profile: String
    private var userCurves: [FanCurveSpec]
    private var tick = 0
    public var failing: Bool
    public var conflictList: [FanControlConflict]
    public var latched: Bool
    /// One speed range per fan: Mac mini M4 by default, `macBookProFans` or `[]` (fanless MacBook Air).
    public var fanRanges: [FanSpeedRange]
    public var samplingInterval = 2
    public var batterySamplingInterval: Int?
    public var onBattery: Bool?
    /// Latest release reported by the daemon's update check.
    public var latestVersion: String?

    public static let macMiniFans = [FanSpeedRange(minimumRPM: 1000, maximumRPM: 4900)]
    /// MacBook Pro M1 Pro (14"/16"): two fans with different maxima.
    public static let macBookProFans = [FanSpeedRange(minimumRPM: 1200, maximumRPM: 5779), FanSpeedRange(minimumRPM: 1200, maximumRPM: 6241)]

    public init(profile: String = "balanced", failing: Bool = false, conflicts: [FanControlConflict] = [], latched: Bool = false,
                fanRanges: [FanSpeedRange] = SampleService.macMiniFans) {
        self.fanRanges = fanRanges
        self.profile = profile
        self.failing = failing
        self.conflictList = conflicts
        self.latched = latched
        self.userCurves = [FanCurveSpec(
            name: "night", label: "Night",
            shape: try! FanCurveShape(kind: .exponential, startCelsius: 85, endCelsius: 105, maximumFraction: 0.6),
            hysteresisCelsius: 3, riseRate: .percentPerSecond(4), fallRate: .percentPerSecond(2), smoothingSeconds: 15,
            idle: .off
        ), FanCurveSpec(
            name: "steady", label: "Steady", sensors: ["Tp*"],
            points: [.init(50, .percent(5)), .init(65, .percent(15)), .init(80, .percent(45)), .init(92, .percent(80)), .init(100, .percent(100))],
            hysteresisCelsius: 2, riseRate: .percentPerSecond(6), fallRate: .percentPerSecond(3), smoothingSeconds: 8
        )]
    }

    public func telemetry() throws -> TelemetryDTO {
        try lock.withLock {
            if failing { throw SMCtlClientError("pulsed is not running.") }
            tick += 1
            let wave = sin(Double(tick) / 6)
            let cpu = [48.6, 57.4, 59.6, 49.3, 58.1, 60.0, 49.2, 58.0, 49.1, 57.9, 60.6, 61.2].map { $0 + wave * 6 }
            let temperatures = zip(["Tp00", "Tp01", "Tp02", "Tp04", "Tp05", "Tp06", "Tp08", "Tp09", "Tp0C", "Tp0D", "Tp0E", "Tp3P"], cpu)
                .map { TemperatureDTO(key: $0, group: "Tp", celsius: $1) }
                + [("Tg0C", 41.0), ("Tg0D", 44.2), ("Tg0H", 43.9), ("Tg0P", 43.6)].map { TemperatureDTO(key: $0, group: "Tg", celsius: $1 + wave * 2) }
                + [("Ts00", 36.3), ("Ts01", 36.3), ("Ts0M", 39.5)].map { TemperatureDTO(key: $0, group: "Ts", celsius: $1) }
            let manual = profile != "auto"
            let fraction = manual ? 0.1 + wave * 0.05 : 0
            return TelemetryDTO(
                timestamp: Date(),
                daemonVersion: "0.2.4",
                profile: profile,
                temperatures: temperatures,
                fans: fanRanges.enumerated().map { index, range in
                    let rpm = range.rpm(forFraction: fraction)
                    return FanStatusDTO(index: index, actualRPM: rpm, targetRPM: rpm.rounded(), minimumRPM: range.minimumRPM,
                                        maximumRPM: range.maximumRPM, mode: manual ? "manual" : "auto")
                },
                curve: manual ? fanRanges.enumerated().map { index, range in
                    FanCurveStateDTO(index: index, aggregatedCelsius: cpu.max() ?? 0, effectiveCelsius: 58.4 + wave * 4,
                                     targetRPM: range.rpm(forFraction: fraction).rounded())
                } : [],
                power: [PowerReadingDTO(key: "PSTR", name: "System Power", value: 6.2, unit: "W")],
                safety: SafetyStateDTO(latched: latched, ceilingCelsius: 100, lastTripReason: latched ? "Tp3P held at 111 °C" : nil),
                lastError: nil,
                samplingInterval: samplingInterval,
                batterySamplingInterval: batterySamplingInterval,
                onBattery: onBattery,
                latestVersion: latestVersion
            )
        }
    }

    public func setSamplingInterval(_ seconds: Int?, onBattery: Bool) throws {
        lock.withLock {
            if onBattery { batterySamplingInterval = seconds } else if let seconds { samplingInterval = seconds }
        }
    }

    public func curves() throws -> FanCurveListDTO {
        try lock.withLock {
            if failing { throw SMCtlClientError("pulsed is not running.") }
            return FanCurveListDTO(
                activeProfile: profile,
                curves: FanCurvePresets.all.map { FanCurveEntryDTO(builtin: true, spec: $0) }
                    + userCurves.map { FanCurveEntryDTO(builtin: false, spec: $0) },
                invalid: [:]
            )
        }
    }

    public func activate(profile name: String) throws {
        try lock.withLock {
            if failing { throw SMCtlClientError("pulsed is not running.") }
            guard name == "auto" || FanCurvePresets.named(name) != nil || userCurves.contains(where: { $0.name == name }) else {
                throw SMCtlClientError("Fan profile '\(name)' is not configured.")
            }
            profile = name
        }
    }

    public func upsert(_ spec: FanCurveSpec, activate: Bool) throws {
        try spec.validate()
        lock.withLock {
            userCurves.removeAll { $0.name == spec.name }
            userCurves.append(spec)
            if activate { profile = spec.name }
        }
    }

    public func delete(curve name: String) throws {
        lock.withLock {
            userCurves.removeAll { $0.name == name }
            if profile == name { profile = "auto" }
        }
    }

    public func conflicts() -> [FanControlConflict] {
        lock.withLock { conflictList }
    }
}

extension PulseStore {
    /// A store filled with `samples` ticks of sample data, for previews and snapshots.
    @MainActor
    /// `stressTest` names a curve whose stress test is shown as running (nothing runs).
    public static func preview(_ service: SampleService = SampleService(), samples: Int = 60,
                               updates: UpdateCenter? = nil, stressTest: String? = nil) async -> PulseStore {
        let store = PulseStore(service: service, fallback: nil, updates: updates)
        if let stressTest {
            store.stressTestDidStart(StressTestModel(profile: stressTest.lowercased(), title: stressTest, service: nil, store: store))
        }
        let start = Date().addingTimeInterval(-Double(samples) * 2)
        for index in 0..<samples {
            await store.refresh(forceLists: index == 0, now: start.addingTimeInterval(Double(index) * 2))
        }
        return store
    }
}
