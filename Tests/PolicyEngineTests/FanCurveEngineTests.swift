import XCTest
@testable import PolicyEngine

final class FanCurveEngineTests: XCTestCase {
    func testLinearInterpolationAndClamping() throws {
        let curve = try FanCurve(
            name: "custom",
            points: [
                FanCurvePoint(50, 1000),
                FanCurvePoint(70, 3000),
                FanCurvePoint(90, 5000)
            ]
        )

        XCTAssertEqual(FanCurveEngine.interpolate(points: curve.points, temperature: 40), 1000, accuracy: 0.01)
        XCTAssertEqual(FanCurveEngine.interpolate(points: curve.points, temperature: 60), 2000, accuracy: 0.01)
        XCTAssertEqual(FanCurveEngine.interpolate(points: curve.points, temperature: 80), 4000, accuracy: 0.01)
        XCTAssertEqual(FanCurveEngine.interpolate(points: curve.points, temperature: 100), 5000, accuracy: 0.01)
    }

    func testAggregationDefaultsToMaxAndSupportsWeights() throws {
        let samples = [
            FanTemperatureSample(sensor: "cpu", celsius: 80),
            FanTemperatureSample(sensor: "gpu", celsius: 60),
            FanTemperatureSample(sensor: "ambient", celsius: 30)
        ]

        XCTAssertEqual(try FanCurveEngine.aggregate(samples: samples, sensors: ["cpu", "gpu"]), 80)
        XCTAssertEqual(
            try FanCurveEngine.aggregate(samples: samples, sensors: ["cpu", "gpu"], weights: ["cpu": 0.25, "gpu": 0.75]),
            65,
            accuracy: 0.01
        )
    }

    func testHysteresisIsBidirectionalDeadZone() throws {
        let curve = try FanCurve(
            name: "custom",
            points: [
                FanCurvePoint(50, 1000),
                FanCurvePoint(70, 3000)
            ],
            hysteresisCelsius: 3
        )
        var engine = FanCurveEngine()
        let first = try engine.evaluate(
            curve: curve,
            samples: [FanTemperatureSample(sensor: "cpu", celsius: 60)],
            now: Date(timeIntervalSince1970: 0)
        )
        let insideUp = try engine.evaluate(
            curve: curve,
            samples: [FanTemperatureSample(sensor: "cpu", celsius: 62.9)],
            now: Date(timeIntervalSince1970: 1)
        )
        let outsideUp = try engine.evaluate(
            curve: curve,
            samples: [FanTemperatureSample(sensor: "cpu", celsius: 63.1)],
            now: Date(timeIntervalSince1970: 2)
        )
        let insideDown = try engine.evaluate(
            curve: curve,
            samples: [FanTemperatureSample(sensor: "cpu", celsius: 60.2)],
            now: Date(timeIntervalSince1970: 3)
        )
        let outsideDown = try engine.evaluate(
            curve: curve,
            samples: [FanTemperatureSample(sensor: "cpu", celsius: 59)],
            now: Date(timeIntervalSince1970: 4)
        )

        XCTAssertEqual(first.effectiveTemperature, 60, accuracy: 0.01)
        XCTAssertEqual(insideUp.effectiveTemperature, 60, accuracy: 0.01)
        XCTAssertEqual(outsideUp.effectiveTemperature, 63.1, accuracy: 0.01)
        XCTAssertEqual(insideDown.effectiveTemperature, 63.1, accuracy: 0.01)
        XCTAssertEqual(outsideDown.effectiveTemperature, 59, accuracy: 0.01)
    }

    func testSlewRateLimitsRpmChangesPerSecondInBothDirections() throws {
        let curve = try FanCurve(
            name: "custom",
            points: [
                FanCurvePoint(50, 1000),
                FanCurvePoint(90, 5000)
            ],
            slewRateRPMPerSecond: 500
        )
        var engine = FanCurveEngine()
        let start = Date(timeIntervalSince1970: 0)

        let first = try engine.evaluate(
            curve: curve,
            samples: [FanTemperatureSample(sensor: "cpu", celsius: 50)],
            now: start
        )
        let up = try engine.evaluate(
            curve: curve,
            samples: [FanTemperatureSample(sensor: "cpu", celsius: 90)],
            now: start.addingTimeInterval(2)
        )
        let down = try engine.evaluate(
            curve: curve,
            samples: [FanTemperatureSample(sensor: "cpu", celsius: 50)],
            now: start.addingTimeInterval(3)
        )

        XCTAssertEqual(first.targetRPM, 1000, accuracy: 0.01)
        XCTAssertEqual(up.unclampedRPM, 5000, accuracy: 0.01)
        XCTAssertEqual(up.targetRPM, 2000, accuracy: 0.01)
        XCTAssertEqual(down.unclampedRPM, 1000, accuracy: 0.01)
        XCTAssertEqual(down.targetRPM, 1500, accuracy: 0.01)
    }
}
