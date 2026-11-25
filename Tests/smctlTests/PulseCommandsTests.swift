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

    func testStatusGroupsAreOrderedAndSummarized() {
        let temperatures = [
            TemperatureDTO(key: "Ts00", group: "Ts", celsius: 40),
            TemperatureDTO(key: "Tg0P", group: "Tg", celsius: 50),
            TemperatureDTO(key: "Tp01", group: "Tp", celsius: 60),
            TemperatureDTO(key: "Tp3P", group: "Tp", celsius: 80),
            TemperatureDTO(key: "Zz01", group: "Zz", celsius: 30)
        ]
        let groups = StatusReport.groups(temperatures)
        XCTAssertEqual(groups.map(\.label), ["CPU", "GPU", "Board", "Zz"])
        XCTAssertEqual(groups[0].maximumCelsius, 80)
        XCTAssertEqual(groups[0].hottestKey, "Tp3P")
        XCTAssertEqual(groups[0].averageCelsius, 70)
        XCTAssertEqual(groups[0].count, 2)
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
        XCTAssertTrue(text.contains("50%"), "fan percent of its range")
        XCTAssertTrue(text.contains("LATCHED"))
        XCTAssertTrue(text.contains("hot-spots 110.0 °C"))
        XCTAssertTrue(text.contains("TG Pro: RUNNING"))
    }
}
