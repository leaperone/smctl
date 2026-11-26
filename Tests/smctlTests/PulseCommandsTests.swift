import XCTest
import PolicyEngine
import SMCtlProtocol
@testable import smctl

final class PulseCommandsTests: XCTestCase {
    private let presets = FanCurvePresets.all.map { FanCurveEntryDTO(builtin: true, spec: $0) }

    // MARK: Parsing

    func testParsesPointsInEveryUnit() throws {
        let points = try parseCurvePoints("60:10%, 80:1800 ,95:max")
        XCTAssertEqual(points, [
            FanCurveSpecPoint(60, .percent(10)),
            FanCurveSpecPoint(80, .rpm(1800)),
            FanCurveSpecPoint(95, .maximum)
        ])
        for bad in ["60", "60:", ":10%", "x:10%", "60:fast", "60:10%;70:20%"] {
            XCTAssertThrowsError(try parseCurvePoints(bad), bad)
        }
    }

    func testParsesPercentages() throws {
        XCTAssertEqual(try parsePercent("40%"), 0.4)
        XCTAssertEqual(try parsePercent("40"), 0.4)
        XCTAssertEqual(try parsePercent(" 12.5 % "), 0.125)
        XCTAssertEqual(try parsePercent("MAX"), 1)
        for bad in ["-5%", "101%", "abc", "%"] {
            XCTAssertThrowsError(try parsePercent(bad), bad)
        }
    }

    func testParsesSensorLists() {
        XCTAssertEqual(parseSensorList("Tp*, Tg0P"), ["Tp*", "Tg0P"])
        XCTAssertEqual(parseSensorList("all"), [])
        XCTAssertEqual(parseSensorList(" ALL "), [])
        XCTAssertEqual(parseSensorList(""), [])
    }

    // MARK: fan curve set

    private func build(_ arguments: [String], existing: [FanCurveEntryDTO]? = nil) throws -> FanCurveSpec {
        try FanCurveSet.parse(arguments).buildSpec(existing: existing ?? presets)
    }

    func testCreatesAShapeCurve() throws {
        let spec = try build(["night", "--shape", "sigmoid", "--start", "75", "--end", "100", "--max", "60%",
                              "--sensors", "Tp*", "--rise", "6%", "--fall", "150", "--smoothing", "8", "--label", "Nuit"])
        XCTAssertEqual(spec.name, "night")
        XCTAssertEqual(spec.label, "Nuit")
        XCTAssertEqual(spec.shape, try FanCurveShape(kind: .sigmoid, startCelsius: 75, endCelsius: 100, maximumFraction: 0.6))
        XCTAssertEqual(spec.sensors, ["Tp*"])
        XCTAssertEqual(spec.riseRate, .percentPerSecond(6))
        XCTAssertEqual(spec.fallRate, .rpmPerSecond(150))
        XCTAssertEqual(spec.smoothingSeconds, 8)
        XCTAssertNoThrow(try spec.validate())
    }

    func testCopiesAPresetAndOverridesOnlyWhatIsGiven() throws {
        let spec = try build(["perf2", "--from", "performance", "--start", "55"])
        let preset = FanCurvePresets.performance
        XCTAssertEqual(spec.name, "perf2")
        XCTAssertNil(spec.label, "a copy must not keep the preset's label")
        XCTAssertEqual(spec.shape?.startCelsius, 55)
        XCTAssertEqual(spec.shape?.endCelsius, preset.shape?.endCelsius)
        XCTAssertEqual(spec.shape?.steepness, preset.shape?.steepness)
        XCTAssertEqual(spec.shape?.minimumFraction, preset.shape?.minimumFraction)
        XCTAssertEqual(spec.riseRate, preset.riseRate)
        XCTAssertEqual(spec.smoothingSeconds, preset.smoothingSeconds)
        XCTAssertNoThrow(try spec.validate())
    }

    func testUpdatesAnExistingCustomCurveInPlace() throws {
        let existing = presets + [FanCurveEntryDTO(builtin: false, spec: FanCurveSpec(
            name: "work", label: "Work", sensors: ["Tp*"],
            shape: try FanCurveShape(kind: .exponential, startCelsius: 70, endCelsius: 100, steepness: 5),
            hysteresisCelsius: 3
        ))]
        let spec = try build(["work", "--end", "95", "--smoothing", "0"], existing: existing)
        XCTAssertEqual(spec.label, "Work")
        XCTAssertEqual(spec.sensors, ["Tp*"])
        XCTAssertEqual(spec.shape?.kind, .exponential)
        XCTAssertEqual(spec.shape?.endCelsius, 95)
        XCTAssertEqual(spec.shape?.steepness, 5, "steepness is kept while the shape type is unchanged")
        XCTAssertNil(spec.smoothingSeconds, "0 disables smoothing")

        let switched = try build(["work", "--shape", "sigmoid"], existing: existing)
        XCTAssertEqual(switched.shape?.steepness, FanCurveShapeKind.sigmoid.defaultSteepness, "a new shape type gets its own default steepness")
    }

    func testPointsReplaceAShapeAndCannotBeMixedWithShapeOptions() throws {
        let spec = try build(["perf2", "--from", "performance", "--points", "60:10%,90:max"])
        XCTAssertNil(spec.shape)
        XCTAssertEqual(spec.points.count, 2)
        XCTAssertThrowsError(try build(["x", "--points", "60:10%,90:max", "--start", "50"]))
    }

    func testReportsMissingOrUnknownShapeParameters() {
        XCTAssertThrowsError(try build(["x", "--start", "60", "--end", "90"]))          // no shape type
        XCTAssertThrowsError(try build(["x", "--shape", "linear", "--start", "60"]))    // no end
        XCTAssertThrowsError(try build(["x", "--shape", "zigzag", "--start", "60", "--end", "90"]))
        XCTAssertThrowsError(try build(["x", "--from", "missing"]))
    }

    func testNamesAreLowercasedAndValidated() throws {
        XCTAssertEqual(try build(["Night", "--shape", "linear", "--start", "60", "--end", "90"]).name, "night")
        XCTAssertThrowsError(try build(["night mode", "--shape", "linear", "--start", "60", "--end", "90"]).validate())
        XCTAssertThrowsError(try build(["balanced", "--shape", "linear", "--start", "60", "--end", "90"]).validate(), "reserved")
    }

    // MARK: Rendering

    func testPreviewIsMonotonicAndStaysWithinTheFanRange() throws {
        let range = FanSpeedRange(minimumRPM: 1000, maximumRPM: 4900)
        for preset in FanCurvePresets.all {
            let text = curvePreview(preset, builtin: true, active: false, range: range)
            let rpms = text.split(separator: "\n").compactMap { line -> Double? in
                let fields = line.split(separator: " ")
                guard fields.count >= 3, Double(fields[0]) != nil, fields[1].hasSuffix("%") else { return nil }
                return Double(fields[2])
            }
            XCTAssertGreaterThan(rpms.count, 5, preset.name)
            XCTAssertEqual(rpms, rpms.sorted(), "\(preset.name) preview must be monotonic")
            XCTAssertTrue(rpms.allSatisfy { (1000...4900).contains($0) }, preset.name)
        }
    }

    func testPreviewShowsMacOSBelowTheRamp() {
        let range = FanSpeedRange(minimumRPM: 1000, maximumRPM: 4900)
        let text = curvePreview(FanCurvePresets.balanced, builtin: true, active: false, range: range)
        XCTAssertTrue(text.contains("macOS\n"), text)
        XCTAssertTrue(text.contains("goes back to macOS after 15 s"), text)
        let performance = curvePreview(FanCurvePresets.performance, builtin: true, active: false, range: range)
        XCTAssertFalse(performance.contains("macOS"), "a 10% floor never hands off")
    }

    func testStatusListsAverageBeforeMaximumAndHandlesPoweredDownGroups() {
        let report = StatusReport(
            timestamp: Date(), daemon: .init(running: true, version: "0.2.4", message: nil), profile: "auto",
            temperatures: [
                TemperatureDTO(key: "Tp01", group: "Tp", celsius: 40),
                TemperatureDTO(key: "Tp3P", group: "Tp", celsius: 60),
                TemperatureDTO(key: "Tg0C", group: "Tg", celsius: 0.8),
                TemperatureDTO(key: "Tg0D", group: "Tg", celsius: -1.2)
            ],
            fans: [], curve: [], power: [], safety: nil, conflicts: []
        )
        let lines = report.humanDescription.split(separator: "\n").map(String.init)
        let cpu = try? XCTUnwrap(lines.first { $0.hasPrefix("  CPU") })
        XCTAssertNotNil(cpu)
        if let cpu, let avg = cpu.range(of: "avg 50.0 °C"), let max = cpu.range(of: "max 60.0 °C") {
            XCTAssertLessThan(avg.lowerBound, max.lowerBound, cpu)
        } else {
            XCTFail("CPU line: \(String(describing: cpu))")
        }
        XCTAssertTrue(lines.contains { $0.hasPrefix("  GPU") && $0.contains("sensors off") }, report.humanDescription)
    }

    func testStatusSaysWhenMacOSRunsTheFan() {
        let report = StatusReport(
            timestamp: Date(), daemon: .init(running: true, version: "0.2.5", message: nil), profile: "balanced",
            temperatures: [TemperatureDTO(key: "Tp01", group: "Tp", celsius: 45)],
            fans: [FanStatusDTO(index: 0, actualRPM: 0, targetRPM: 0, minimumRPM: 1200, maximumRPM: 5779, mode: "auto")],
            curve: [FanCurveStateDTO(index: 0, aggregatedCelsius: 45, effectiveCelsius: 45, targetRPM: 0, handedToSystem: true)],
            power: [], safety: SafetyStateDTO(latched: false, ceilingCelsius: 100, lastTripReason: nil),
            conflicts: []
        )
        XCTAssertTrue(report.humanDescription.contains("0% · macOS runs the fan"), report.humanDescription)
    }

    func testStatusTextFlagsLatchedSafetyAndRunningConflicts() {
        let report = StatusReport(
            timestamp: Date(), daemon: .init(running: true, version: "0.2.4", message: nil), profile: "balanced",
            temperatures: [TemperatureDTO(key: "Tp01", group: "Tp", celsius: 104)],
            fans: [FanStatusDTO(index: 0, actualRPM: 2950, targetRPM: 2950, minimumRPM: 1000, maximumRPM: 4900, mode: "manual")],
            curve: [FanCurveStateDTO(index: 0, aggregatedCelsius: 104, effectiveCelsius: 103, targetRPM: 2950)],
            power: [], safety: SafetyStateDTO(latched: true, ceilingCelsius: 100, lastTripReason: "Tp01 too hot"),
            conflicts: [.init(product: "TG Pro", evidence: "process TG Pro", running: true)]
        )
        let text = report.humanDescription
        XCTAssertTrue(text.contains("profile balanced"))
        XCTAssertTrue(text.contains("avg 104.0 °C"))
        XCTAssertTrue(text.contains("50%"), "fan percent of its range")
        XCTAssertTrue(text.contains("LATCHED"))
        XCTAssertTrue(text.contains("hot-spots 110.0 °C"))
        XCTAssertTrue(text.contains("TG Pro: RUNNING"))
    }
}

/// Simulates launchd: bootout takes a few polls to finish, bootstrap fails
/// while the old job is still there.
final class ReloadLaunchDaemonTests: XCTestCase {
    final class FakeLaunchd {
        var loaded: Bool
        var pollsUntilGone: Int
        var bootstrapFailures: Int
        var calls: [[String]] = []

        init(loaded: Bool, pollsUntilGone: Int = 0, bootstrapFailures: Int = 0) {
            self.loaded = loaded
            self.pollsUntilGone = pollsUntilGone
            self.bootstrapFailures = bootstrapFailures
        }

        var stoppingRequested = false

        func run(_ arguments: [String]) -> (status: Int32, output: String) {
            calls.append(arguments)
            switch arguments.first {
            case "print":
                if stoppingRequested, loaded {
                    if pollsUntilGone == 0 { loaded = false } else { pollsUntilGone -= 1 }
                }
                return (loaded ? 0 : 113, "")
            case "bootout":
                stoppingRequested = true
                return (0, "")
            case "bootstrap":
                if loaded { return (5, "Bootstrap failed: 5: Input/output error") }
                if bootstrapFailures > 0 { bootstrapFailures -= 1; return (5, "Bootstrap failed: 5: Input/output error") }
                loaded = true
                stoppingRequested = false
                return (0, "")
            default:
                return (1, "")
            }
        }
    }

    func testReinstallWaitsForTheOldJobBeforeBootstrapping() throws {
        let launchd = FakeLaunchd(loaded: true, pollsUntilGone: 6)
        try reloadLaunchDaemon(label: "x", plistPath: "/p", launchctl: launchd.run, sleep: { _ in })
        XCTAssertTrue(launchd.loaded, "a reinstall must leave the daemon loaded")
        XCTAssertEqual(launchd.calls.filter { $0.first == "bootstrap" }.count, 1, "no failed bootstrap while the old job was stopping")
    }

    func testFreshInstallBootstrapsOnce() throws {
        let launchd = FakeLaunchd(loaded: false)
        try reloadLaunchDaemon(label: "x", plistPath: "/p", launchctl: launchd.run, sleep: { _ in })
        XCTAssertTrue(launchd.loaded)
        XCTAssertFalse(launchd.calls.contains { $0.first == "bootout" })
    }

    func testTransientBootstrapFailuresAreRetried() throws {
        let launchd = FakeLaunchd(loaded: false, bootstrapFailures: 2)
        try reloadLaunchDaemon(label: "x", plistPath: "/p", launchctl: launchd.run, sleep: { _ in })
        XCTAssertTrue(launchd.loaded)
    }

    func testPersistentFailureIsReported() {
        let launchd = FakeLaunchd(loaded: false, bootstrapFailures: 99)
        XCTAssertThrowsError(try reloadLaunchDaemon(label: "x", plistPath: "/p", launchctl: launchd.run, sleep: { _ in }))
    }
}
