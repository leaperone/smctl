import XCTest
@testable import PolicyEngine

final class FanCurveSpecTests: XCTestCase {
    private let range = FanSpeedRange(minimumRPM: 1000, maximumRPM: 4900)

    func testSpeedValueParsing() throws {
        XCTAssertEqual(try FanSpeedValue(parsing: "40%"), .percent(40))
        XCTAssertEqual(try FanSpeedValue(parsing: " 12.5 % "), .percent(12.5))
        XCTAssertEqual(try FanSpeedValue(parsing: "MAX"), .maximum)
        XCTAssertEqual(try FanSpeedValue(parsing: "1600"), .rpm(1600))
        for bad in ["", "%", "fast", "40%%", "4O%"] {
            XCTAssertThrowsError(try FanSpeedValue(parsing: bad), bad)
        }
        XCTAssertEqual(FanSpeedValue.percent(40).configString, "40%")
        XCTAssertEqual(FanSpeedValue.percent(12.5).configString, "12.5%")
        XCTAssertEqual(FanSpeedValue.rpm(1600).configString, "1600")
    }

    func testSpeedAndRateValuesResolveAgainstTheFanRange() throws {
        XCTAssertEqual(FanSpeedValue.percent(50).rpm(in: range), 2950)
        XCTAssertEqual(FanSpeedValue.percent(250).rpm(in: range), 4900, "clamped")
        XCTAssertEqual(FanSpeedValue.maximum.rpm(in: range), 4900)
        XCTAssertEqual(FanSpeedValue.rpm(1600).rpm(in: range), 1600)
        XCTAssertEqual(FanRateValue.percentPerSecond(10).rpmPerSecond(in: range), 390)
        XCTAssertEqual(FanRateValue.rpmPerSecond(600).rpmPerSecond(in: range), 600)
        XCTAssertEqual(try FanRateValue(parsing: "8%"), .percentPerSecond(8))
        XCTAssertThrowsError(try FanRateValue(parsing: "max"))
    }

    func testNameRules() {
        for good in ["night", "work-2", "a", "0db", "silent_v2", String(repeating: "x", count: 32)] {
            XCTAssertTrue(FanCurveSpec.isValidName(good), good)
        }
        for bad in ["", "Night", "night mode", "-night", "_x", "nuit-été", "a\"b", String(repeating: "x", count: 33)] {
            XCTAssertFalse(FanCurveSpec.isValidName(bad), bad)
        }
    }

    func testReservedNamesNeedExplicitPermission() throws {
        var spec = FanCurvePresets.balanced
        XCTAssertNoThrow(try spec.validate(allowReservedName: true))
        XCTAssertThrowsError(try spec.validate())
        spec.name = "my-balanced"
        XCTAssertNoThrow(try spec.validate())
    }

    func testContentValidationIgnoresLegacyNames() throws {
        let legacy = FanCurveSpec(name: "Cooler Profile", points: [FanCurveSpecPoint(60, .rpm(1000)), FanCurveSpecPoint(90, .maximum)])
        XCTAssertThrowsError(try legacy.validate())
        XCTAssertNoThrow(try legacy.resolve(for: range))
    }

    func testPointsResolveSortedWithMixedUnits() throws {
        let spec = FanCurveSpec(name: "mixed", points: [
            FanCurveSpecPoint(95, .maximum),
            FanCurveSpecPoint(60, .rpm(1200)),
            FanCurveSpecPoint(80, .percent(50))
        ])
        let curve = try spec.resolve(for: range)
        XCTAssertEqual(curve.points.map(\.temperatureCelsius), [60, 80, 95])
        XCTAssertEqual(curve.points.map(\.rpm), [1200, 2950, 4900])
    }

    func testPercentRatesBecomeRPMPerFan() throws {
        let spec = FanCurveSpec(name: "r", shape: try FanCurveShape(kind: .linear, startCelsius: 60, endCelsius: 90),
                                riseRate: .percentPerSecond(10), fallRate: .percentPerSecond(2.5), smoothingSeconds: 4)
        let small = try spec.resolve(for: FanSpeedRange(minimumRPM: 1000, maximumRPM: 2000))
        let large = try spec.resolve(for: FanSpeedRange(minimumRPM: 1000, maximumRPM: 6000))
        XCTAssertEqual(small.slewRateRPMPerSecond, 100)
        XCTAssertEqual(large.slewRateRPMPerSecond, 500)
        XCTAssertEqual(large.fallSlewRateRPMPerSecond, 125)
        XCTAssertEqual(large.smoothingSeconds, 4)
    }

    func testSpecRoundTripsThroughJSON() throws {
        let specs = FanCurvePresets.all + [FanCurveSpec(
            name: "pts", label: "Points", sensors: ["Tp*"], weights: ["Tp*": 2],
            points: [FanCurveSpecPoint(60, .rpm(1100)), FanCurveSpecPoint(80, .percent(40)), FanCurveSpecPoint(95, .maximum)],
            hysteresisCelsius: 2, riseRate: .rpmPerSecond(300), fallRate: .percentPerSecond(3)
        )]
        for spec in specs {
            XCTAssertEqual(try JSONDecoder().decode(FanCurveSpec.self, from: JSONEncoder().encode(spec)), spec)
        }
    }

    // MARK: Presets

    func testPresetsAreValidAndReserved() throws {
        XCTAssertEqual(FanCurvePresets.all.map(\.name), ["silent", "balanced", "performance"])
        for preset in FanCurvePresets.all {
            XCTAssertNoThrow(try preset.validate(allowReservedName: true))
            XCTAssertTrue(FanCurvePresets.reservedNames.contains(preset.name))
            XCTAssertEqual(FanCurvePresets.named(preset.name), preset)
        }
        XCTAssertNil(FanCurvePresets.named("quiet"), "smctl's RPM built-ins are resolved by the daemon, not here")
    }

    func testPresetsAreOrderedFromQuietToCool() throws {
        let fractions = { (celsius: Double) in
            FanCurvePresets.all.map { preset in preset.shape!.fraction(at: celsius) }
        }
        for celsius in [70.0, 80, 85, 90] {
            let values = fractions(celsius)
            XCTAssertLessThanOrEqual(values[0], values[1], "silent ≤ balanced at \(celsius)C")
            XCTAssertLessThanOrEqual(values[1], values[2], "balanced ≤ performance at \(celsius)C")
        }
        // Idle hot-spots (~60C) stay near the floor on every preset.
        XCTAssertTrue(fractions(60).allSatisfy { $0 <= 0.1 + 1e-9 })
        // Every preset reaches full speed before the 110C hot-spot hard ceiling.
        XCTAssertTrue(fractions(105).allSatisfy { $0 == 1 })
    }

    func testPresetsSmoothAtLeastFiveSeconds() {
        for preset in FanCurvePresets.all {
            XCTAssertGreaterThanOrEqual(preset.smoothingSeconds ?? 0, 5, preset.name)
        }
    }

    func testPresetsRiseFasterThanTheyFall() {
        for preset in FanCurvePresets.all {
            guard case .percentPerSecond(let rise) = preset.riseRate, case .percentPerSecond(let fall) = preset.fallRate else {
                return XCTFail("\(preset.name) rates should be percent based")
            }
            XCTAssertGreaterThan(rise, fall, preset.name)
        }
    }
}
