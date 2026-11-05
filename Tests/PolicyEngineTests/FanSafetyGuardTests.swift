import XCTest
@testable import PolicyEngine

final class FanSafetyGuardTests: XCTestCase {
    func testNonFiniteCeilingsUseSafeDefault() {
        for ceiling in [Double.nan, .infinity, -.infinity] {
            var guardrail = FanSafetyGuard(configuredCeilingCelsius: ceiling)
            XCTAssertEqual(guardrail.configuredCeilingCelsius, 100)
            _ = guardrail.evaluate(samples: [sample(105)], manualPolicyActive: true)
            XCTAssertEqual(guardrail.evaluate(samples: [sample(105)], manualPolicyActive: true).action, .holdMaximumRPM)
        }
    }

    func testNonFiniteTemperaturesCountAsSensorBlindness() {
        var guardrail = FanSafetyGuard()
        XCTAssertEqual(guardrail.evaluate(samples: [sample(.nan), sample(.infinity)], manualPolicyActive: true).action, .restoreAuto)
        XCTAssertTrue(guardrail.isLatched)
        XCTAssertEqual(guardrail.evaluate(samples: [sample(90), sample(.nan)], manualPolicyActive: true).action, .none)
        XCTAssertFalse(guardrail.isLatched)
    }

    func testMutatingCeilingCannotDisableTheGuard() {
        var guardrail = FanSafetyGuard()
        guardrail.configuredCeilingCelsius = .nan
        _ = guardrail.evaluate(samples: [sample(105)], manualPolicyActive: true)
        XCTAssertEqual(guardrail.evaluate(samples: [sample(105)], manualPolicyActive: true).action, .holdMaximumRPM)
        XCTAssertEqual(guardrail.configuredCeilingCelsius, 100)
    }

    func testCeilingClampAndSustainedTrip() {
        var defaultGuard = FanSafetyGuard()  // ceiling 100
        XCTAssertEqual(
            defaultGuard.evaluate(samples: [sample(99.9)], manualPolicyActive: true).action, .none
        )
        // First over-ceiling tick: debounced, not yet a trip.
        XCTAssertEqual(
            defaultGuard.evaluate(samples: [sample(100)], manualPolicyActive: true).action, .none
        )
        // Second consecutive tick: trip, holding maximum RPM rather than auto.
        XCTAssertEqual(
            defaultGuard.evaluate(samples: [sample(100)], manualPolicyActive: true).action, .holdMaximumRPM
        )

        var clamped = FanSafetyGuard(configuredCeilingCelsius: 120)
        XCTAssertEqual(clamped.configuredCeilingCelsius, 105)
        XCTAssertEqual(clamped.evaluate(samples: [sample(105)], manualPolicyActive: true).action, .none)
        XCTAssertEqual(clamped.evaluate(samples: [sample(105)], manualPolicyActive: true).action, .holdMaximumRPM)
    }

    func testOverheatAndBlindnessChooseDifferentActions() {
        var overheated = FanSafetyGuard()
        _ = overheated.evaluate(samples: [sample(101)], manualPolicyActive: true)
        let heat = overheated.evaluate(samples: [sample(101)], manualPolicyActive: true)
        XCTAssertEqual(heat.action, .holdMaximumRPM)
        XCTAssertFalse(heat.forceAuto)

        var blind = FanSafetyGuard()
        let noReadings = blind.evaluate(samples: [], manualPolicyActive: true)
        XCTAssertEqual(noReadings.action, .restoreAuto)
        XCTAssertTrue(noReadings.forceAuto)
    }

    func testAppleSiliconHotspotSensorsHaveDedicatedCeiling() {
        var guardrail = FanSafetyGuard()

        XCTAssertEqual(
            guardrail.evaluate(samples: [sample(119.9, sensor: "Tp3P")], manualPolicyActive: true).action, .none
        )
        XCTAssertEqual(
            guardrail.evaluate(samples: [sample(119.9, sensor: "Tp3P")], manualPolicyActive: true).action, .none
        )
        XCTAssertFalse(guardrail.isLatched)
        XCTAssertEqual(guardrail.configuredHotSpotCeilingCelsius, 120)
    }

    func testAppleSiliconHotspotSensorsStillTripAtHardCeiling() {
        var guardrail = FanSafetyGuard()

        XCTAssertEqual(
            guardrail.evaluate(samples: [sample(120, sensor: "Tp3P")], manualPolicyActive: true).action, .none
        )
        let decision = guardrail.evaluate(samples: [sample(120, sensor: "Tp3P")], manualPolicyActive: true)
        XCTAssertEqual(decision.action, .holdMaximumRPM)
        XCTAssertTrue(guardrail.isLatched)
        XCTAssertTrue(decision.reason?.contains("Tp3P") ?? false)
        XCTAssertTrue(decision.reason?.contains("120") ?? false)
    }

    func testHotSpotCeilingAndReleaseHysteresisAreConfigurable() {
        var guardrail = FanSafetyGuard(
            configuredCeilingCelsius: 100,
            hotSpotCeilingCelsius: 118,
            releaseHysteresisCelsius: 3
        )
        XCTAssertEqual(guardrail.configuredHotSpotCeilingCelsius, 118)

        XCTAssertEqual(
            guardrail.evaluate(samples: [sample(117.9, sensor: "Tp3P")], manualPolicyActive: true).action, .none
        )
        XCTAssertEqual(
            guardrail.evaluate(samples: [sample(118, sensor: "Tp3P")], manualPolicyActive: true).action, .none
        )
        XCTAssertEqual(
            guardrail.evaluate(samples: [sample(118, sensor: "Tp3P")], manualPolicyActive: true).action, .holdMaximumRPM
        )
        XCTAssertTrue(guardrail.isLatched)

        // Release threshold is 118 - 3 = 115.
        XCTAssertEqual(
            guardrail.evaluate(samples: [sample(116, sensor: "Tp3P")], manualPolicyActive: true).action, .holdMaximumRPM
        )
        XCTAssertEqual(
            guardrail.evaluate(samples: [sample(115, sensor: "Tp3P")], manualPolicyActive: true).action, .none
        )
        XCTAssertFalse(guardrail.isLatched)
    }

    func testHotSpotCeilingClampsToHardMaximum() {
        let guardrail = FanSafetyGuard(hotSpotCeilingCelsius: 999)
        XCTAssertEqual(guardrail.configuredHotSpotCeilingCelsius, 125)
    }

    func testNonHotspotSensorsKeepBaseCeiling() {
        var guardrail = FanSafetyGuard()

        XCTAssertEqual(guardrail.evaluate(samples: [sample(100, sensor: "TC0P")], manualPolicyActive: true).action, .none)
        XCTAssertEqual(guardrail.evaluate(samples: [sample(100, sensor: "TC0P")], manualPolicyActive: true).action, .holdMaximumRPM)
        XCTAssertTrue(guardrail.isLatched)
    }

    func testTransientSpikeDoesNotTrip() {
        // A single hot-spot spike between cool readings must not trip the guard.
        var guardrail = FanSafetyGuard()
        XCTAssertEqual(guardrail.evaluate(samples: [sample(101)], manualPolicyActive: true).action, .none)
        XCTAssertEqual(guardrail.evaluate(samples: [sample(90)], manualPolicyActive: true).action, .none)
        XCTAssertEqual(guardrail.evaluate(samples: [sample(101)], manualPolicyActive: true).action, .none)
        XCTAssertFalse(guardrail.isLatched)
    }

    func testBlindManualControlIsUnsafe() {
        // Regression (fail-open): with manual fans active and no readable temperature,
        // the guard must hand control back to the system immediately — no debounce.
        var guardrail = FanSafetyGuard()
        let decision = guardrail.evaluate(samples: [], manualPolicyActive: true)
        XCTAssertEqual(decision.action, .restoreAuto)
        XCTAssertTrue(guardrail.isLatched)
    }

    func testEmptySamplesWithoutManualPolicyDoesNothing() {
        var guardrail = FanSafetyGuard()
        let decision = guardrail.evaluate(samples: [], manualPolicyActive: false)
        XCTAssertEqual(decision.action, .none)
        XCTAssertFalse(guardrail.isLatched)
    }

    func testLatchHoldsUntilCooledBelowReleaseThreshold() {
        var guardrail = FanSafetyGuard()  // ceiling 100, release at 95

        XCTAssertEqual(guardrail.evaluate(samples: [sample(101)], manualPolicyActive: true).action, .none)
        XCTAssertEqual(guardrail.evaluate(samples: [sample(101)], manualPolicyActive: true).action, .holdMaximumRPM)
        XCTAssertTrue(guardrail.isLatched)

        // Cooled below ceiling but not below release threshold: still holding max.
        XCTAssertEqual(guardrail.evaluate(samples: [sample(97)], manualPolicyActive: true).action, .holdMaximumRPM)
        XCTAssertTrue(guardrail.isLatched)

        // Cooled to the release threshold: latch releases, manual allowed again.
        XCTAssertEqual(guardrail.evaluate(samples: [sample(95)], manualPolicyActive: true).action, .none)
        XCTAssertFalse(guardrail.isLatched)
    }

    func testHotspotLatchUsesHotspotReleaseThreshold() {
        var guardrail = FanSafetyGuard()  // Tp* default ceiling 120, release at 115

        _ = guardrail.evaluate(samples: [sample(120, sensor: "Tp3P")], manualPolicyActive: true)
        _ = guardrail.evaluate(samples: [sample(120, sensor: "Tp3P")], manualPolicyActive: true)
        XCTAssertTrue(guardrail.isLatched)

        XCTAssertEqual(guardrail.evaluate(samples: [sample(116, sensor: "Tp3P")], manualPolicyActive: true).action, .holdMaximumRPM)
        XCTAssertTrue(guardrail.isLatched)

        XCTAssertEqual(guardrail.evaluate(samples: [sample(115, sensor: "Tp3P")], manualPolicyActive: true).action, .none)
        XCTAssertFalse(guardrail.isLatched)
    }

    func testLatchReleasesWhileSystemInControl() {
        // After a trip the daemon clears policy (manualPolicyActive becomes false);
        // the latch must still release on cool readings so the user is not locked out.
        var guardrail = FanSafetyGuard()
        _ = guardrail.evaluate(samples: [sample(101)], manualPolicyActive: true)
        _ = guardrail.evaluate(samples: [sample(101)], manualPolicyActive: true)
        XCTAssertTrue(guardrail.isLatched)

        _ = guardrail.evaluate(samples: [sample(94)], manualPolicyActive: false)
        XCTAssertFalse(guardrail.isLatched)

        XCTAssertEqual(guardrail.evaluate(samples: [sample(101)], manualPolicyActive: true).action, .none)
        XCTAssertFalse(guardrail.isLatched)
    }

    func testStartupReconciliationRestoresCrashResidueOnlyWithoutLocalPolicy() {
        let reconciler = FanStartupReconciler()

        XCTAssertTrue(reconciler.shouldRestoreAuto(hasLocalManualPolicy: false, fanModes: [0: 1], ftstValue: 0))
        XCTAssertTrue(reconciler.shouldRestoreAuto(hasLocalManualPolicy: false, fanModes: [0: 0], ftstValue: 1))
        XCTAssertFalse(reconciler.shouldRestoreAuto(hasLocalManualPolicy: true, fanModes: [0: 1], ftstValue: 1))
        XCTAssertFalse(reconciler.shouldRestoreAuto(hasLocalManualPolicy: false, fanModes: [0: 0, 1: 3], ftstValue: 0))
    }

    private func sample(_ celsius: Double, sensor: String = "cpu") -> FanTemperatureSample {
        FanTemperatureSample(sensor: sensor, celsius: celsius)
    }
}
