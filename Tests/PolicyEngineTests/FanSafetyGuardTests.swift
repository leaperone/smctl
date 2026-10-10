import XCTest
@testable import PolicyEngine

final class FanSafetyGuardTests: XCTestCase {
    func testCeilingClampAndSustainedTrip() {
        var defaultGuard = FanSafetyGuard()  // ceiling 100
        XCTAssertFalse(
            defaultGuard.evaluate(samples: [sample(99.9)], manualPolicyActive: true).holdAtMaxRPM
        )
        // First over-ceiling tick: debounced, not yet a trip.
        XCTAssertFalse(
            defaultGuard.evaluate(samples: [sample(100)], manualPolicyActive: true).holdAtMaxRPM
        )
        // Second consecutive tick: trip into the max-RPM fail-safe hold.
        XCTAssertTrue(
            defaultGuard.evaluate(samples: [sample(100)], manualPolicyActive: true).holdAtMaxRPM
        )

        var clamped = FanSafetyGuard(configuredCeilingCelsius: 120)
        XCTAssertEqual(clamped.configuredCeilingCelsius, 105)
        XCTAssertFalse(clamped.evaluate(samples: [sample(105)], manualPolicyActive: true).holdAtMaxRPM)
        XCTAssertTrue(clamped.evaluate(samples: [sample(105)], manualPolicyActive: true).holdAtMaxRPM)
    }

    func testAppleSiliconHotspotSensorsHaveDedicatedCeiling() {
        var guardrail = FanSafetyGuard()

        XCTAssertFalse(
            guardrail.evaluate(samples: [sample(105.859375, sensor: "Tp3P")], manualPolicyActive: true).holdAtMaxRPM
        )
        XCTAssertFalse(
            guardrail.evaluate(samples: [sample(105.859375, sensor: "Tp3P")], manualPolicyActive: true).holdAtMaxRPM
        )
        XCTAssertFalse(guardrail.isLatched)
    }

    func testAppleSiliconHotspotSensorsStillTripAtHardCeiling() {
        var guardrail = FanSafetyGuard()

        XCTAssertFalse(
            guardrail.evaluate(samples: [sample(110, sensor: "Tp3P")], manualPolicyActive: true).holdAtMaxRPM
        )
        let decision = guardrail.evaluate(samples: [sample(110, sensor: "Tp3P")], manualPolicyActive: true)
        XCTAssertTrue(decision.holdAtMaxRPM)
        XCTAssertTrue(guardrail.isLatched)
        XCTAssertTrue(decision.reason?.contains("Tp3P") ?? false)
        XCTAssertTrue(decision.reason?.contains("110") ?? false)
    }

    // Field incident (M1 Max, 2026-10-09): TC22 — a die-core hotspot — sat at
    // 100.67C under ordinary sustained load while the curve was already commanding
    // full RPM. The old guard classified only "Tp" as hotspot and tripped, tearing
    // down the user's policy. TC*/Tg* must share the hotspot allowance.
    func testCoreAndHotspotSensorsAtFullLoadDoNotTrip() {
        var guardrail = FanSafetyGuard()
        for sensor in ["TC22", "TC09", "Tg0D"] {
            _ = guardrail.evaluate(samples: [], manualPolicyActive: false)
            XCTAssertFalse(
                guardrail.evaluate(samples: [sample(105, sensor: sensor)], manualPolicyActive: true).holdAtMaxRPM,
                "\(sensor) at 105C is normal sustained-load territory")
            XCTAssertFalse(
                guardrail.evaluate(samples: [sample(105, sensor: sensor)], manualPolicyActive: true).holdAtMaxRPM,
                "\(sensor) at 105C must not trip even on consecutive ticks")
            XCTAssertFalse(guardrail.isLatched)
        }
    }

    func testNonHotspotSensorsKeepBaseCeiling() {
        var guardrail = FanSafetyGuard()

        XCTAssertFalse(guardrail.evaluate(samples: [sample(100, sensor: "Ts04")], manualPolicyActive: true).holdAtMaxRPM)
        XCTAssertTrue(guardrail.evaluate(samples: [sample(100, sensor: "Ts04")], manualPolicyActive: true).holdAtMaxRPM)
        XCTAssertTrue(guardrail.isLatched)
    }

    func testTransientSpikeDoesNotTrip() {
        // A single hot-spot spike between cool readings must not trip the guard.
        var guardrail = FanSafetyGuard()
        XCTAssertFalse(guardrail.evaluate(samples: [sample(101)], manualPolicyActive: true).holdAtMaxRPM)
        XCTAssertFalse(guardrail.evaluate(samples: [sample(90)], manualPolicyActive: true).holdAtMaxRPM)
        XCTAssertFalse(guardrail.evaluate(samples: [sample(101)], manualPolicyActive: true).holdAtMaxRPM)
        XCTAssertFalse(guardrail.isLatched)
    }

    // Field incident (M1 Max, 2026-10-10 08:30): the guard latched because Ts02
    // reported 279.56C — a corrupt SMC sentinel, not a temperature — on a machine
    // whose real sensors all sat near 66C. Implausible readings must carry no
    // policy weight in either direction.
    func testGarbageSentinelReadingDoesNotTrip() {
        var guardrail = FanSafetyGuard()

        for tick in 0..<5 {
            let decision = guardrail.evaluate(
                samples: [sample(81, sensor: "Tp0M"), sample(77, sensor: "TC22"), sample(279.56, sensor: "Ts02")],
                manualPolicyActive: true
            )
            XCTAssertFalse(
                decision.holdAtMaxRPM,
                "sentinel on tick \(tick) must not trip the guard"
            )
        }
        XCTAssertFalse(guardrail.isLatched)
    }

    func testSentinelCannotPinTheLatchForever() {
        // Trip on genuine heat, then cool everything except one permanently
        // garbage sensor. The latch must release; the old allSatisfy over raw
        // samples kept the machine locked out of its own profile forever.
        var guardrail = FanSafetyGuard()
        _ = guardrail.evaluate(samples: [sample(101, sensor: "Ts04")], manualPolicyActive: true)
        _ = guardrail.evaluate(samples: [sample(101, sensor: "Ts04")], manualPolicyActive: true)
        XCTAssertTrue(guardrail.isLatched)

        let decision = guardrail.evaluate(
            samples: [sample(70, sensor: "Ts04"), sample(66, sensor: "Tp0M"), sample(279.56, sensor: "Ts02")],
            manualPolicyActive: true
        )
        XCTAssertFalse(decision.holdAtMaxRPM)
        XCTAssertFalse(guardrail.isLatched)
    }

    func testAllReadingsImplausibleEngagesFailSafeImmediately() {
        var guardrail = FanSafetyGuard()
        let decision = guardrail.evaluate(
            samples: [sample(279.56, sensor: "Ts02"), sample(.nan, sensor: "Tp0M"), sample(-999, sensor: "TC01")],
            manualPolicyActive: true
        )
        XCTAssertTrue(decision.holdAtMaxRPM, "blind-by-corruption must not be debounced")
        XCTAssertTrue(guardrail.isLatched)
        XCTAssertTrue(decision.reason?.contains("implausible") ?? false)
        XCTAssertTrue(decision.reason?.contains("Ts02") ?? false)
    }

    func testPlausibilityPredicate() {
        XCTAssertTrue(FanSafetyGuard.isPlausible(sample(66)))
        XCTAssertTrue(FanSafetyGuard.isPlausible(sample(-40)))
        XCTAssertTrue(FanSafetyGuard.isPlausible(sample(150)))
        XCTAssertFalse(FanSafetyGuard.isPlausible(sample(279.56)))
        XCTAssertFalse(FanSafetyGuard.isPlausible(sample(-41)))
        XCTAssertFalse(FanSafetyGuard.isPlausible(sample(.nan)))
        XCTAssertFalse(FanSafetyGuard.isPlausible(sample(.infinity)))
    }

    func testBlindManualControlEngagesFailSafe() {
        // Regression (fail-open): with manual fans active and no readable temperature,
        // the guard must hold fans at maximum immediately — no debounce when blind.
        var guardrail = FanSafetyGuard()
        let decision = guardrail.evaluate(samples: [], manualPolicyActive: true)
        XCTAssertTrue(decision.holdAtMaxRPM)
        XCTAssertTrue(guardrail.isLatched)
    }

    func testEmptySamplesWithoutManualPolicyDoesNothing() {
        var guardrail = FanSafetyGuard()
        let decision = guardrail.evaluate(samples: [], manualPolicyActive: false)
        XCTAssertFalse(decision.holdAtMaxRPM)
        XCTAssertFalse(guardrail.isLatched)
    }

    func testLatchHoldsUntilCooledBelowReleaseThreshold() {
        var guardrail = FanSafetyGuard()  // ceiling 100, release at 95

        XCTAssertFalse(guardrail.evaluate(samples: [sample(101)], manualPolicyActive: true).holdAtMaxRPM)
        XCTAssertTrue(guardrail.evaluate(samples: [sample(101)], manualPolicyActive: true).holdAtMaxRPM)
        XCTAssertTrue(guardrail.isLatched)

        // Cooled below ceiling but not below release threshold: still holding.
        XCTAssertTrue(guardrail.evaluate(samples: [sample(97)], manualPolicyActive: true).holdAtMaxRPM)
        XCTAssertTrue(guardrail.isLatched)

        // Cooled to the release threshold: latch releases, the configured profile
        // resumes, manual targets are accepted again.
        XCTAssertFalse(guardrail.evaluate(samples: [sample(95)], manualPolicyActive: true).holdAtMaxRPM)
        XCTAssertFalse(guardrail.isLatched)
    }

    func testHotspotLatchUsesHotspotReleaseThreshold() {
        var guardrail = FanSafetyGuard()  // Tp* effective ceiling 110, release at 105

        _ = guardrail.evaluate(samples: [sample(110, sensor: "Tp3P")], manualPolicyActive: true)
        _ = guardrail.evaluate(samples: [sample(110, sensor: "Tp3P")], manualPolicyActive: true)
        XCTAssertTrue(guardrail.isLatched)

        XCTAssertTrue(guardrail.evaluate(samples: [sample(106, sensor: "Tp3P")], manualPolicyActive: true).holdAtMaxRPM)
        XCTAssertTrue(guardrail.isLatched)

        XCTAssertFalse(guardrail.evaluate(samples: [sample(105, sensor: "Tp3P")], manualPolicyActive: true).holdAtMaxRPM)
        XCTAssertFalse(guardrail.isLatched)
    }

    func testLatchReleasesWhileSystemInControl() {
        // After a trip the operator may hand control back to the system manually;
        // the latch must still release on cool readings so the user is not locked out.
        var guardrail = FanSafetyGuard()
        _ = guardrail.evaluate(samples: [sample(101)], manualPolicyActive: true)
        _ = guardrail.evaluate(samples: [sample(101)], manualPolicyActive: true)
        XCTAssertTrue(guardrail.isLatched)

        _ = guardrail.evaluate(samples: [sample(94)], manualPolicyActive: false)
        XCTAssertFalse(guardrail.isLatched)

        XCTAssertFalse(guardrail.evaluate(samples: [sample(101)], manualPolicyActive: true).holdAtMaxRPM)
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
