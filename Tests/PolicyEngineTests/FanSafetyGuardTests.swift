import XCTest
@testable import PolicyEngine

final class FanSafetyGuardTests: XCTestCase {
    func testCeilingClampAndTrip() {
        var defaultGuard = FanSafetyGuard()
        XCTAssertFalse(
            defaultGuard.evaluate(samples: [sample(94.9)], manualPolicyActive: true).forceAuto
        )
        XCTAssertTrue(
            defaultGuard.evaluate(samples: [sample(95)], manualPolicyActive: true).forceAuto
        )

        var clamped = FanSafetyGuard(configuredCeilingCelsius: 120)
        XCTAssertEqual(clamped.configuredCeilingCelsius, 105)
        XCTAssertFalse(
            clamped.evaluate(samples: [sample(104.9)], manualPolicyActive: true).forceAuto
        )
        XCTAssertTrue(
            clamped.evaluate(samples: [sample(105)], manualPolicyActive: true).forceAuto
        )
    }

    func testBlindManualControlIsUnsafe() {
        // Regression (fail-open): with manual fans active and no readable temperature,
        // the guard must force auto — it is the only thermal floor in manual mode.
        var guardrail = FanSafetyGuard()
        let decision = guardrail.evaluate(samples: [], manualPolicyActive: true)
        XCTAssertTrue(decision.forceAuto)
        XCTAssertTrue(guardrail.isLatched)
    }

    func testEmptySamplesWithoutManualPolicyDoesNothing() {
        var guardrail = FanSafetyGuard()
        let decision = guardrail.evaluate(samples: [], manualPolicyActive: false)
        XCTAssertFalse(decision.forceAuto)
        XCTAssertFalse(guardrail.isLatched)
    }

    func testLatchHoldsUntilCooledBelowReleaseThreshold() {
        var guardrail = FanSafetyGuard()  // ceiling 95, release at 90

        XCTAssertTrue(guardrail.evaluate(samples: [sample(96)], manualPolicyActive: true).forceAuto)
        XCTAssertTrue(guardrail.isLatched)

        // Cooled below ceiling but not below release threshold: still latched, still forcing auto.
        XCTAssertTrue(guardrail.evaluate(samples: [sample(92)], manualPolicyActive: true).forceAuto)
        XCTAssertTrue(guardrail.isLatched)

        // Cooled to the release threshold: latch releases, manual allowed again.
        XCTAssertFalse(guardrail.evaluate(samples: [sample(90)], manualPolicyActive: true).forceAuto)
        XCTAssertFalse(guardrail.isLatched)
    }

    func testLatchReleasesWhileSystemInControl() {
        // After a trip the daemon clears policy (manualPolicyActive becomes false);
        // the latch must still release on cool readings so the user is not locked out.
        var guardrail = FanSafetyGuard()
        _ = guardrail.evaluate(samples: [sample(96)], manualPolicyActive: true)
        XCTAssertTrue(guardrail.isLatched)

        _ = guardrail.evaluate(samples: [sample(89)], manualPolicyActive: false)
        XCTAssertFalse(guardrail.isLatched)
    }

    func testStartupReconciliationRestoresCrashResidueOnlyWithoutLocalPolicy() {
        let reconciler = FanStartupReconciler()

        XCTAssertTrue(reconciler.shouldRestoreAuto(hasLocalManualPolicy: false, fanModes: [0: 1], ftstValue: 0))
        XCTAssertTrue(reconciler.shouldRestoreAuto(hasLocalManualPolicy: false, fanModes: [0: 0], ftstValue: 1))
        XCTAssertFalse(reconciler.shouldRestoreAuto(hasLocalManualPolicy: true, fanModes: [0: 1], ftstValue: 1))
        XCTAssertFalse(reconciler.shouldRestoreAuto(hasLocalManualPolicy: false, fanModes: [0: 0, 1: 3], ftstValue: 0))
    }

    private func sample(_ celsius: Double) -> FanTemperatureSample {
        FanTemperatureSample(sensor: "cpu", celsius: celsius)
    }
}
