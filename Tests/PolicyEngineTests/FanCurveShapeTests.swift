import XCTest
@testable import PolicyEngine

final class FanCurveShapeTests: XCTestCase {
    private let grid = (0...1000).map { Double($0) / 1000 }

    private func shape(_ kind: FanCurveShapeKind, steepness: Double? = nil, steps: Int = 4) throws -> FanCurveShape {
        try FanCurveShape(kind: kind, startCelsius: 0, endCelsius: 1, steepness: steepness, stepCount: steps)
    }

    // MARK: Normalized shape properties

    func testEveryShapeHitsBothEndpoints() throws {
        for kind in FanCurveShapeKind.allCases {
            for steepness in [0.0, 0.5, kind.defaultSteepness, FanCurveShape.maximumSteepness] {
                let s = try shape(kind, steepness: steepness)
                XCTAssertEqual(s.normalized(0), 0, accuracy: 1e-9, "\(kind) k=\(steepness)")
                XCTAssertEqual(s.normalized(1), 1, accuracy: 1e-9, "\(kind) k=\(steepness)")
            }
        }
    }

    func testEveryShapeIsMonotonicAndBounded() throws {
        for kind in FanCurveShapeKind.allCases {
            for steepness in [0.0, 1, kind.defaultSteepness, FanCurveShape.maximumSteepness] {
                let s = try shape(kind, steepness: steepness, steps: 7)
                var previous = -Double.infinity
                for x in grid {
                    let y = s.normalized(x)
                    XCTAssertTrue((0...1).contains(y), "\(kind) k=\(steepness) f(\(x))=\(y)")
                    XCTAssertGreaterThanOrEqual(y, previous, "\(kind) k=\(steepness) not monotonic at \(x)")
                    previous = y
                }
            }
        }
    }

    func testCurvedShapesAreStrictlyIncreasing() throws {
        for kind in [FanCurveShapeKind.linear, .sigmoid, .exponential, .logarithmic] {
            let s = try shape(kind)
            for (a, b) in zip(grid, grid.dropFirst()) {
                XCTAssertLessThan(s.normalized(a), s.normalized(b), "\(kind) flat between \(a) and \(b)")
            }
        }
    }

    func testInputOutsideUnitIntervalIsClamped() throws {
        for kind in FanCurveShapeKind.allCases {
            let s = try shape(kind)
            XCTAssertEqual(s.normalized(-5), 0, accuracy: 1e-12)
            XCTAssertEqual(s.normalized(7), 1, accuracy: 1e-12)
        }
    }

    func testZeroSteepnessDegeneratesToLinear() throws {
        for kind in [FanCurveShapeKind.sigmoid, .exponential, .logarithmic] {
            let s = try shape(kind, steepness: 0)
            for x in grid { XCTAssertEqual(s.normalized(x), x, accuracy: 1e-12) }
        }
    }

    func testSigmoidIsPointSymmetricAroundMidpoint() throws {
        let s = try shape(.sigmoid)
        XCTAssertEqual(s.normalized(0.5), 0.5, accuracy: 1e-12)
        for x in grid {
            XCTAssertEqual(s.normalized(x) + s.normalized(1 - x), 1, accuracy: 1e-9)
        }
    }

    func testExponentialIsConvexAndLogarithmicIsItsInverse() throws {
        let exponential = try shape(.exponential)
        let logarithmic = try shape(.logarithmic)
        for x in grid where x > 0 && x < 1 {
            XCTAssertLessThan(exponential.normalized(x), x)
            XCTAssertGreaterThan(logarithmic.normalized(x), x)
            XCTAssertEqual(logarithmic.normalized(exponential.normalized(x)), x, accuracy: 1e-9)
        }
    }

    func testSteepnessIncreasesReactivity() throws {
        // Sigmoid: steeper means a sharper climb at the midpoint.
        let slope = { (s: FanCurveShape) in (s.normalized(0.51) - s.normalized(0.49)) / 0.02 }
        XCTAssertLessThan(slope(try shape(.sigmoid, steepness: 4)), slope(try shape(.sigmoid, steepness: 12)))
        // Exponential: steeper stays lower for longer; logarithmic reacts earlier.
        XCTAssertGreaterThan(try shape(.exponential, steepness: 1).normalized(0.5), try shape(.exponential, steepness: 6).normalized(0.5))
        XCTAssertLessThan(try shape(.logarithmic, steepness: 1).normalized(0.5), try shape(.logarithmic, steepness: 6).normalized(0.5))
    }

    func testStepsProducePlateaus() throws {
        let s = try shape(.steps, steps: 4)
        XCTAssertEqual(s.normalized(0.10), 0)
        XCTAssertEqual(s.normalized(0.249), 0)
        XCTAssertEqual(s.normalized(0.25), 0.25)
        XCTAssertEqual(s.normalized(0.6), 0.5)
        XCTAssertEqual(s.normalized(0.99), 0.75)
        XCTAssertEqual(Set(grid.map(s.normalized)).count, 5)
    }

    // MARK: Placement in temperature and speed

    func testFractionIsFlatOutsideTheRampAndScaledInside() throws {
        let s = try FanCurveShape(kind: .linear, startCelsius: 70, endCelsius: 100, minimumFraction: 0.2, maximumFraction: 0.8)
        XCTAssertEqual(s.fraction(at: -40), 0.2, accuracy: 1e-12)
        XCTAssertEqual(s.fraction(at: 70), 0.2, accuracy: 1e-12)
        XCTAssertEqual(s.fraction(at: 85), 0.5, accuracy: 1e-12)
        XCTAssertEqual(s.fraction(at: 100), 0.8, accuracy: 1e-12)
        XCTAssertEqual(s.fraction(at: 140), 0.8, accuracy: 1e-12)
    }

    func testStretchingTheRampMovesTheCurveNotItsCharacter() throws {
        let narrow = try FanCurveShape(kind: .sigmoid, startCelsius: 80, endCelsius: 90)
        let wide = try FanCurveShape(kind: .sigmoid, startCelsius: 60, endCelsius: 100)
        XCTAssertEqual(narrow.fraction(at: 85), 0.5, accuracy: 1e-12)
        XCTAssertEqual(wide.fraction(at: 80), 0.5, accuracy: 1e-12)
        XCTAssertEqual(narrow.fraction(at: 82.5), wide.fraction(at: 70), accuracy: 1e-12)
    }

    // MARK: Compilation to points

    func testCompiledPointsAreUsableByFanCurveAndTrackTheShape() throws {
        for kind in FanCurveShapeKind.allCases where kind != .steps {
            for steepness in [kind.defaultSteepness, 15, FanCurveShape.maximumSteepness] {
                let s = try FanCurveShape(kind: kind, startCelsius: 65, endCelsius: 105, minimumFraction: 0.1, maximumFraction: 0.9, steepness: steepness)
                let compiled = s.compiledPoints()
                XCTAssertEqual(compiled.first?.celsius, 65)
                XCTAssertEqual(compiled.last?.celsius, 105)
                XCTAssertLessThanOrEqual(compiled.count, 160)
                let curve = try FanCurve(name: "t", points: compiled.map { FanCurvePoint($0.celsius, $0.fraction) })
                for t in stride(from: 50.0, through: 120, by: 0.25) {
                    let approx = FanCurveEngine.interpolate(points: curve.points, temperature: t)
                    XCTAssertEqual(approx, s.fraction(at: t), accuracy: 0.01, "\(kind) k=\(steepness) at \(t)C")
                }
            }
        }
    }

    func testGentleShapesStayCompact() throws {
        XCTAssertEqual(try FanCurveShape(kind: .linear, startCelsius: 60, endCelsius: 100).compiledPoints().count, 17)
        XCTAssertLessThanOrEqual(try FanCurveShape(kind: .sigmoid, startCelsius: 60, endCelsius: 100).compiledPoints().count, 48)
    }

    func testCompiledStepsKeepExactPlateaus() throws {
        let s = try FanCurveShape(kind: .steps, startCelsius: 60, endCelsius: 100, stepCount: 4)
        let compiled = s.compiledPoints()
        let temperatures = compiled.map(\.celsius)
        XCTAssertEqual(temperatures, temperatures.sorted())
        XCTAssertEqual(Set(temperatures).count, temperatures.count, "temperatures must be unique")
        let curve = try FanCurve(name: "steps", points: compiled.map { FanCurvePoint($0.celsius, $0.fraction) })
        for t in [55.0, 61, 69, 71, 79, 81, 99, 100, 110] {
            XCTAssertEqual(FanCurveEngine.interpolate(points: curve.points, temperature: t), s.fraction(at: t), accuracy: 1e-9, "at \(t)C")
        }
    }

    // MARK: Validation and coding

    func testInvalidParametersAreRejected() {
        let cases: [() throws -> FanCurveShape] = [
            { try FanCurveShape(kind: .linear, startCelsius: 90, endCelsius: 90) },
            { try FanCurveShape(kind: .linear, startCelsius: 95, endCelsius: 80) },
            { try FanCurveShape(kind: .linear, startCelsius: .nan, endCelsius: 80) },
            { try FanCurveShape(kind: .linear, startCelsius: 60, endCelsius: .infinity) },
            { try FanCurveShape(kind: .linear, startCelsius: 60, endCelsius: 90, minimumFraction: -0.1) },
            { try FanCurveShape(kind: .linear, startCelsius: 60, endCelsius: 90, maximumFraction: 1.01) },
            { try FanCurveShape(kind: .linear, startCelsius: 60, endCelsius: 90, minimumFraction: 0.7, maximumFraction: 0.3) },
            { try FanCurveShape(kind: .sigmoid, startCelsius: 60, endCelsius: 90, steepness: -1) },
            { try FanCurveShape(kind: .sigmoid, startCelsius: 60, endCelsius: 90, steepness: 31) },
            { try FanCurveShape(kind: .sigmoid, startCelsius: 60, endCelsius: 90, steepness: .nan) },
            { try FanCurveShape(kind: .steps, startCelsius: 60, endCelsius: 90, stepCount: 0) },
            { try FanCurveShape(kind: .steps, startCelsius: 60, endCelsius: 90, stepCount: 21) }
        ]
        for (index, make) in cases.enumerated() {
            XCTAssertThrowsError(try make(), "case \(index) should be rejected")
        }
    }

    func testDefaultSteepnessIsAppliedPerKind() throws {
        XCTAssertEqual(try shape(.sigmoid).steepness, 8)
        XCTAssertEqual(try shape(.exponential).steepness, 3)
        XCTAssertEqual(try shape(.linear).steepness, 0)
    }

    func testShapeRoundTripsThroughCodable() throws {
        let s = try FanCurveShape(kind: .logarithmic, startCelsius: 70, endCelsius: 100, minimumFraction: 0.1, maximumFraction: 0.6, steepness: 4, stepCount: 3)
        let decoded = try JSONDecoder().decode(FanCurveShape.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded, s)
    }
}

final class FanSpeedRangeTests: XCTestCase {
    func testFractionsMapOntoTheFanRange() {
        let range = FanSpeedRange(minimumRPM: 1000, maximumRPM: 4900)
        XCTAssertEqual(range.rpm(forFraction: 0), 1000)
        XCTAssertEqual(range.rpm(forFraction: 0.5), 2950)
        XCTAssertEqual(range.rpm(forFraction: 1), 4900)
    }

    func testOutOfRangeAndInvalidFractionsAreClamped() {
        let range = FanSpeedRange(minimumRPM: 1200, maximumRPM: 6000)
        XCTAssertEqual(range.rpm(forFraction: -1), 1200)
        XCTAssertEqual(range.rpm(forFraction: 3), 6000)
        XCTAssertEqual(range.rpm(forFraction: .nan), 1200)
    }

    func testSameFractionGivesEachFanItsOwnSpeed() {
        let left = FanSpeedRange(minimumRPM: 1200, maximumRPM: 5800)
        let right = FanSpeedRange(minimumRPM: 1300, maximumRPM: 6500)
        XCTAssertEqual(left.rpm(forFraction: 0.5), 3500)
        XCTAssertEqual(right.rpm(forFraction: 0.5), 3900)
    }

    func testRangeIsNormalizedAndInvertible() {
        let swapped = FanSpeedRange(minimumRPM: 5000, maximumRPM: 1000)
        XCTAssertEqual(swapped.minimumRPM, 1000)
        XCTAssertEqual(swapped.maximumRPM, 5000)
        XCTAssertEqual(FanSpeedRange(minimumRPM: -50, maximumRPM: 3000).minimumRPM, 0)
        let range = FanSpeedRange(minimumRPM: 1000, maximumRPM: 4900)
        for fraction in stride(from: 0.0, through: 1, by: 0.05) {
            XCTAssertEqual(range.fraction(forRPM: range.rpm(forFraction: fraction)), fraction, accuracy: 1e-12)
        }
        XCTAssertEqual(FanSpeedRange(minimumRPM: 2000, maximumRPM: 2000).fraction(forRPM: 2000), 0)
    }
}

final class SensorSelectorTests: XCTestCase {
    func testExactAndGlobMatching() {
        XCTAssertTrue(SensorSelector.matches("Tp09", pattern: "Tp09"))
        XCTAssertFalse(SensorSelector.matches("Tp09", pattern: "Tp0"))
        XCTAssertTrue(SensorSelector.matches("Tp3P", pattern: "Tp*"))
        XCTAssertFalse(SensorSelector.matches("Ts00", pattern: "Tp*"))
        XCTAssertTrue(SensorSelector.matches("Tg0D", pattern: "T?0?"))
        XCTAssertTrue(SensorSelector.matches("Tp0E", pattern: "*E"))
        XCTAssertTrue(SensorSelector.matches("anything", pattern: "*"))
        XCTAssertTrue(SensorSelector.matches("Tp01", pattern: "T*0*1"))
        XCTAssertFalse(SensorSelector.matches("tp01", pattern: "Tp*"), "SMC keys are case-sensitive")
    }

    func testAnyOfMixesPatternsAndKeys() {
        XCTAssertTrue(SensorSelector.matches("Tg0P", anyOf: ["Tp*", "Tg0P"]))
        XCTAssertFalse(SensorSelector.matches("Ts01", anyOf: ["Tp*", "Tg*"]))
        XCTAssertFalse(SensorSelector.matches("Ts01", anyOf: []))
    }

    func testExactWeightWinsOverPattern() {
        let weights = ["Tp*": 1.0, "Tp09": 3.0, "T*": 0.5]
        XCTAssertEqual(SensorSelector.weight(for: "Tp09", in: weights), 3)
        XCTAssertEqual(SensorSelector.weight(for: "Tp01", in: weights), 0.5, "sorted order makes 'T*' win deterministically")
        XCTAssertNil(SensorSelector.weight(for: "Ts01", in: ["Tp*": 1]))
    }

    func testAggregationAcceptsPatterns() throws {
        let samples = [
            FanTemperatureSample(sensor: "Tp01", celsius: 70),
            FanTemperatureSample(sensor: "Tp3P", celsius: 82),
            FanTemperatureSample(sensor: "Tg0P", celsius: 90),
            FanTemperatureSample(sensor: "Ts00", celsius: 45)
        ]
        XCTAssertEqual(try FanCurveEngine.aggregate(samples: samples, sensors: ["Tp*"]), 82)
        XCTAssertEqual(try FanCurveEngine.aggregate(samples: samples, sensors: ["Tp*", "Tg*"]), 90)
        XCTAssertEqual(try FanCurveEngine.aggregate(samples: samples, sensors: ["Tp*"], weights: ["Tp*": 1]), 76, accuracy: 1e-9)
        XCTAssertThrowsError(try FanCurveEngine.aggregate(samples: samples, sensors: ["Tz*"]))
    }

    func testPoweredDownSensorsDoNotDragAveragesDown() throws {
        let samples = [
            FanTemperatureSample(sensor: "Tp01", celsius: 80),
            FanTemperatureSample(sensor: "Tg0C", celsius: 0.8),
            FanTemperatureSample(sensor: "Tg0D", celsius: -1.2)
        ]
        XCTAssertEqual(try FanCurveEngine.aggregate(samples: samples, sensors: ["Tp*", "Tg*"], weights: ["Tp*": 1, "Tg*": 1]), 80)
        // Every selected sensor powered down: that block is cold, not an error.
        XCTAssertEqual(try FanCurveEngine.aggregate(samples: samples, sensors: ["Tg*"]), 0.8, accuracy: 1e-9)
        XCTAssertFalse(FanTemperatureSample(sensor: "x", celsius: 151).isPlausible)
        XCTAssertTrue(FanTemperatureSample(sensor: "x", celsius: 35).isPlausible)
    }
}

final class TemperatureSmootherTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    func testFirstSamplePassesThroughAndZeroDisables() {
        var smoother = TemperatureSmoother(timeConstantSeconds: 10)
        XCTAssertEqual(smoother.update(60, now: t0), 60)
        var disabled = TemperatureSmoother(timeConstantSeconds: 0)
        _ = disabled.update(60, now: t0)
        XCTAssertEqual(disabled.update(90, now: t0.addingTimeInterval(1)), 90)
    }

    func testStepResponseReachesSixtyThreePercentAfterOneTimeConstant() {
        var smoother = TemperatureSmoother(timeConstantSeconds: 10)
        _ = smoother.update(60, now: t0)
        var value = 0.0
        for second in 1...10 {
            value = smoother.update(80, now: t0.addingTimeInterval(Double(second)))
        }
        XCTAssertEqual(value, 60 + 20 * (1 - exp(-1)), accuracy: 1e-9)
    }

    func testIrregularTicksGiveTheSameResult() {
        var regular = TemperatureSmoother(timeConstantSeconds: 5)
        var irregular = TemperatureSmoother(timeConstantSeconds: 5)
        _ = regular.update(50, now: t0)
        _ = irregular.update(50, now: t0)
        _ = irregular.update(90, now: t0.addingTimeInterval(0.5))
        let a = irregular.update(90, now: t0.addingTimeInterval(2))
        let b = regular.update(90, now: t0.addingTimeInterval(2))
        XCTAssertEqual(a, b, accuracy: 1e-9)
    }

    func testRisesCanBypassSmoothingAndNaNIsIgnored() {
        var smoother = TemperatureSmoother(timeConstantSeconds: 10, followsRisesImmediately: true)
        _ = smoother.update(60, now: t0)
        XCTAssertEqual(smoother.update(85, now: t0.addingTimeInterval(1)), 85)
        XCTAssertLessThan(smoother.update(70, now: t0.addingTimeInterval(2)), 85)
        let before = smoother.value
        XCTAssertEqual(smoother.update(.nan, now: t0.addingTimeInterval(3)), before)
    }

    func testEngineSmoothsTheAggregatedTemperature() throws {
        let curve = try FanCurve(
            name: "smooth",
            points: [FanCurvePoint(50, 1000), FanCurvePoint(90, 5000)],
            smoothingSeconds: 10
        )
        var engine = FanCurveEngine()
        _ = try engine.evaluate(curve: curve, samples: [FanTemperatureSample(sensor: "Tp01", celsius: 60)], now: t0)
        let spike = try engine.evaluate(curve: curve, samples: [FanTemperatureSample(sensor: "Tp01", celsius: 90)], now: t0.addingTimeInterval(1))
        XCTAssertEqual(spike.aggregatedTemperature, 90)
        XCTAssertLessThan(spike.effectiveTemperature, 64, "a one-second spike must barely move a 10 s average")
        XCTAssertLessThan(spike.targetRPM, 2500)
    }

    func testEngineWithoutSmoothingIsUnchanged() throws {
        let curve = try FanCurve(name: "raw", points: [FanCurvePoint(50, 1000), FanCurvePoint(90, 5000)])
        XCTAssertNil(curve.smoothingSeconds)
        XCTAssertNil(try FanCurve(name: "raw", points: curve.points, smoothingSeconds: 0).smoothingSeconds)
        var engine = FanCurveEngine()
        _ = try engine.evaluate(curve: curve, samples: [FanTemperatureSample(sensor: "a", celsius: 60)], now: t0)
        let next = try engine.evaluate(curve: curve, samples: [FanTemperatureSample(sensor: "a", celsius: 90)], now: t0.addingTimeInterval(1))
        XCTAssertEqual(next.effectiveTemperature, 90)
        XCTAssertNil(engine.smoother)
    }
}

/// End-to-end: a percent shape compiled to points, mapped to a real fan range and
/// driven by the unchanged smctl engine with hysteresis and slew limiting.
final class ShapeDrivenCurveTests: XCTestCase {
    func testPercentShapeDrivesARealFanRangeSafely() throws {
        let range = FanSpeedRange(minimumRPM: 1000, maximumRPM: 4900)
        let shape = try FanCurveShape(kind: .sigmoid, startCelsius: 70, endCelsius: 100)
        let curve = try FanCurve(
            name: "balanced",
            sensors: ["Tp*"],
            points: shape.compiledPoints().map { FanCurvePoint($0.celsius, range.rpm(forFraction: $0.fraction)) },
            hysteresisCelsius: 3,
            slewRateRPMPerSecond: 400,
            fallSlewRateRPMPerSecond: 150
        )
        var engine = FanCurveEngine()
        var now = Date(timeIntervalSinceReferenceDate: 0)
        // Idle, a compile burst up to 103C, then cool-down.
        let trace = Array(repeating: 62.0, count: 10)
            + stride(from: 62.0, through: 103, by: 2).map { $0 }
            + Array(repeating: 103.0, count: 20)
            + stride(from: 103.0, through: 60, by: -1.5).map { $0 }
            + Array(repeating: 60.0, count: 20)
        var previous: Double?
        var directionChanges = 0
        var lastDirection = 0
        for celsius in trace {
            let evaluation = try engine.evaluate(
                curve: curve,
                samples: [FanTemperatureSample(sensor: "Tp01", celsius: celsius), FanTemperatureSample(sensor: "Ts00", celsius: 40)],
                now: now
            )
            XCTAssertGreaterThanOrEqual(evaluation.targetRPM, 1000 - 1e-9)
            XCTAssertLessThanOrEqual(evaluation.targetRPM, 4900 + 1e-9)
            if let previous {
                let delta = evaluation.targetRPM - previous
                XCTAssertLessThanOrEqual(delta, 400 + 1e-9)
                XCTAssertGreaterThanOrEqual(delta, -150 - 1e-9)
                let direction = delta > 1e-9 ? 1 : (delta < -1e-9 ? -1 : 0)
                if direction != 0, lastDirection != 0, direction != lastDirection { directionChanges += 1 }
                if direction != 0 { lastDirection = direction }
            }
            previous = evaluation.targetRPM
            now = now.addingTimeInterval(1)
        }
        XCTAssertEqual(previous ?? 0, 1000, accuracy: 1e-9, "fans must settle back on the floor once cool")
        XCTAssertLessThanOrEqual(directionChanges, 1, "one rise then one fall, no oscillation")
    }
}
