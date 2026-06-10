import Foundation
import XCTest
@testable import PolicyEngine

final class ChargeStateMachineTests: XCTestCase {
    func testDualThresholdDeadbandTransitionMatrix() {
        let limit = ChargeLimit(upperBound: 80, lowerDelta: 2)
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            evaluate(limit: limit, percent: 77, chargingAllowed: false, now: now),
            [.setChargingEnabled(true)]
        )
        XCTAssertEqual(
            evaluate(limit: limit, percent: 78, chargingAllowed: false, now: now),
            []
        )
        XCTAssertEqual(
            evaluate(limit: limit, percent: 79, chargingAllowed: true, now: now),
            []
        )
        XCTAssertEqual(
            evaluate(limit: limit, percent: 80, chargingAllowed: true, now: now),
            [.setChargingEnabled(false)]
        )
        XCTAssertEqual(
            evaluate(limit: limit, percent: 81, chargingAllowed: true, now: now),
            [.setChargingEnabled(false)]
        )
    }

    func testDeadbandActsOnAllowedStateEvenWhenUnplugged() {
        // Blocking the allowed state above the limit while unplugged is intentional:
        // the policy is already correct the moment power returns.
        let limit = ChargeLimit(upperBound: 80, lowerDelta: 2)
        XCTAssertEqual(
            evaluate(limit: limit, percent: 81, chargingAllowed: true, pluggedIn: false, now: Date()),
            [.setChargingEnabled(false)]
        )
        XCTAssertEqual(
            evaluate(limit: limit, percent: 50, chargingAllowed: false, pluggedIn: false, now: Date()),
            [.setChargingEnabled(true)]
        )
    }

    func testLimit100DisablesChargeLimiting() {
        XCTAssertEqual(
            evaluate(limit: .disabled, percent: 50, chargingAllowed: false, now: Date()),
            [.setChargingEnabled(true)]
        )
        XCTAssertEqual(
            evaluate(limit: .disabled, percent: 100, chargingAllowed: true, now: Date()),
            []
        )
    }

    func testMissedBeatDisablesChargingThenReevaluates() {
        var machine = ChargeStateMachine(period: 10)
        let first = Date(timeIntervalSince1970: 0)
        _ = machine.evaluate(
            limit: ChargeLimit(upperBound: 80),
            observation: BatteryObservation(chargePercent: 79, isChargingAllowed: true),
            now: first
        )

        let evaluation = machine.evaluate(
            limit: ChargeLimit(upperBound: 80),
            observation: BatteryObservation(chargePercent: 77, isChargingAllowed: true),
            now: first.addingTimeInterval(31)
        )

        XCTAssertTrue(evaluation.sleptSinceLastEvaluation)
        XCTAssertEqual(evaluation.actions, [.setChargingEnabled(false), .setChargingEnabled(true)])
    }

    func testMissedBeatWhileUnpluggedDoesNotDisable() {
        // An unplugged Mac cannot have overshot the limit during sleep — the
        // conservative disable write would only flip the allowed state for nothing.
        var machine = ChargeStateMachine(period: 10)
        let first = Date(timeIntervalSince1970: 0)
        _ = machine.evaluate(
            limit: ChargeLimit(upperBound: 80),
            observation: BatteryObservation(chargePercent: 79, isChargingAllowed: true),
            now: first
        )

        let evaluation = machine.evaluate(
            limit: ChargeLimit(upperBound: 80),
            observation: BatteryObservation(chargePercent: 79, isChargingAllowed: true, isPluggedIn: false),
            now: first.addingTimeInterval(31)
        )

        XCTAssertTrue(evaluation.sleptSinceLastEvaluation)
        XCTAssertEqual(evaluation.actions, [])
    }

    func testParsesSingleAndRangeLimits() throws {
        XCTAssertEqual(try ChargeLimit.parse("80"), ChargeLimit(upperBound: 80, lowerDelta: 2))
        XCTAssertEqual(try ChargeLimit.parse("70-80"), ChargeLimit(upperBound: 80, lowerDelta: 10))
        XCTAssertEqual(try ChargeLimit.parse("stop"), .disabled)
    }

    func testForceDischargeCutsAdapterAboveBandAndRestoresInside() {
        let limit = ChargeLimit(upperBound: 60, lowerDelta: 2)
        let now = Date()

        // Above the band with adapter on: cut it (plus the regular charge disable
        // is already latched here, chargingAllowed: false).
        XCTAssertEqual(
            evaluate(limit: limit, percent: 80, chargingAllowed: false, adapterEnabled: true, forceDischarge: true, now: now),
            [.setAdapterEnabled(false)]
        )
        // Still above: adapter already cut, nothing to do.
        XCTAssertEqual(
            evaluate(limit: limit, percent: 70, chargingAllowed: false, adapterEnabled: false, forceDischarge: true, now: now),
            []
        )
        // Reached the upper bound: hand the adapter back.
        XCTAssertEqual(
            evaluate(limit: limit, percent: 60, chargingAllowed: false, adapterEnabled: false, forceDischarge: true, now: now),
            [.setAdapterEnabled(true)]
        )
        // Inside the band with adapter on: steady state.
        XCTAssertEqual(
            evaluate(limit: limit, percent: 59, chargingAllowed: false, adapterEnabled: true, forceDischarge: true, now: now),
            []
        )
    }

    func testForceDischargeDoesNothingWhenAdapterStateUnknown() {
        let limit = ChargeLimit(upperBound: 60, lowerDelta: 2)
        XCTAssertEqual(
            evaluate(limit: limit, percent: 80, chargingAllowed: false, adapterEnabled: nil, forceDischarge: true, now: Date()),
            []
        )
    }

    func testWithoutForceDischargeThePolicyNeverTouchesTheAdapter() {
        // A manual one-shot `discharge` owns the adapter then; the maintain loop
        // re-enabling it would break the discharge mid-flight.
        let limit = ChargeLimit(upperBound: 60, lowerDelta: 2)
        XCTAssertEqual(
            evaluate(limit: limit, percent: 80, chargingAllowed: false, adapterEnabled: false, forceDischarge: false, now: Date()),
            []
        )
    }

    private func evaluate(
        limit: ChargeLimit,
        percent: Int,
        chargingAllowed: Bool,
        pluggedIn: Bool = true,
        adapterEnabled: Bool? = nil,
        forceDischarge: Bool = false,
        now: Date
    ) -> [BatteryPolicyAction] {
        var machine = ChargeStateMachine(period: 10)
        return machine.evaluate(
            limit: limit,
            observation: BatteryObservation(
                chargePercent: percent,
                isChargingAllowed: chargingAllowed,
                isPluggedIn: pluggedIn,
                isAdapterEnabled: adapterEnabled
            ),
            now: now,
            forceDischarge: forceDischarge
        ).actions
    }
}
