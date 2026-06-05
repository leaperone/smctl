import XCTest
@testable import PolicyEngine

final class FanSafetyGuardTests: XCTestCase {
    func testCeilingClampAndSustainedTrip() {
        var defaultGuard = FanSafetyGuard()  // ceiling 100
        XCTAssertFalse(
            defaultGuard.evaluate(samples: [sample(99.9)], manualPolicyActive: true).forceAuto
        )
        // First over-ceiling tick: debounced, not yet a trip.
        XCTAssertFalse(
            defaultGuard.evaluate(samples: [sample(100)], manualPolicyActive: true).forceAuto
        )
        // Second consecutive tick: trip.
        XCTAssertTrue(
            defaultGuard.evaluate(samples: [sample(100)], manualPolicyActive: true).forceAuto
        )

        var clamped = FanSafetyGuard(configuredCeilingCelsius: 120)
        XCTAssertEqual(clamped.configuredCeilingCelsius, 105)
        XCTAssertFalse(clamped.evaluate(samples: [sample(105)], manualPolicyActive: true).forceAuto)
        XCTAssertTrue(clamped.evaluate(samples: [sample(105)], manualPolicyActive: true).forceAuto)
    }

    func testTransientSpikeDoesNotTrip() {
        // A single hot-spot spike between cool readings must not trip the guard.
        var guardrail = FanSafetyGuard()
        XCTAssertFalse(guardrail.evaluate(samples: [sample(101)], manualPolicyActive: true).forceAuto)
        XCTAssertFalse(guardrail.evaluate(samples: [sample(90)], manualPolicyActive: true).forceAuto)
        XCTAssertFalse(guardrail.evaluate(samples: [sample(101)], manualPolicyActive: true).forceAuto)
        XCTAssertFalse(guardrail.isLatched)
    }

    func testBlindManualControlIsUnsafe() {
        // Regression (fail-open): with manual fans active and no readable temperature,
        // the guard must force auto immediately — no debounce when blind.
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
        var guardrail = FanSafetyGuard()  // ceiling 100, release at 95

        XCTAssertFalse(guardrail.evaluate(samples: [sample(101)], manualPolicyActive: true).forceAuto)
        XCTAssertTrue(guardrail.evaluate(samples: [sample(101)], manualPolicyActive: true).forceAuto)
        XCTAssertTrue(guardrail.isLatched)

        // Cooled below ceiling but not below release threshold: still latched.
        XCTAssertTrue(guardrail.evaluate(samples: [sample(97)], manualPolicyActive: true).forceAuto)
        XCTAssertTrue(guardrail.isLatched)

        // Cooled to the release threshold: latch releases, manual allowed again.
        XCTAssertFalse(guardrail.evaluate(samples: [sample(95)], manualPolicyActive: true).forceAuto)
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
