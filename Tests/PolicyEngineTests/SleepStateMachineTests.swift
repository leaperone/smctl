import XCTest
@testable import PolicyEngine

final class SleepStateMachineTests: XCTestCase {
    func testPreSleepDisablesChargingWhenLimitActive() {
        let machine = SleepStateMachine(policy: .relaxed)
        let evaluation = machine.handle(
            event: .systemWillSleep,
            context: SleepContext(
                limit: ChargeLimit(upperBound: 80),
                observation: BatteryObservation(chargePercent: 50, isChargingAllowed: false)
            )
        )

        XCTAssertEqual(evaluation.actions, [.setChargingEnabled(false)])
        XCTAssertTrue(evaluation.allowsPowerChange)
        XCTAssertFalse(evaluation.vetoesIdleSleep)
    }

    func testPreSleepDoesNotTouchChargingWhenLimitDisabled() {
        // Regression: writing the disable unconditionally would leave charging off
        // forever if the daemon disappears during sleep ("bricked" default state).
        let machine = SleepStateMachine(policy: .strict)
        let evaluation = machine.handle(
            event: .systemWillSleep,
            context: SleepContext(
                limit: .disabled,
                observation: BatteryObservation(chargePercent: 50, isChargingAllowed: true)
            )
        )

        XCTAssertEqual(evaluation.actions, [])
        XCTAssertTrue(evaluation.allowsPowerChange)
    }

    func testStrictIdleSleepVetoOnlyWhenChargingFarFromLimit() {
        let machine = SleepStateMachine(policy: .strict)

        XCTAssertTrue(vetoes(machine, percent: 76, chargingAllowed: true))
        XCTAssertFalse(vetoes(machine, percent: 77, chargingAllowed: true))
        XCTAssertFalse(vetoes(machine, percent: 50, chargingAllowed: false))
    }

    func testStrictIdleSleepDoesNotVetoWhenUnplugged() {
        // "Charging session" requires wall power; an unplugged Mac is never charging.
        let machine = SleepStateMachine(policy: .strict)
        XCTAssertFalse(vetoes(machine, percent: 50, chargingAllowed: true, pluggedIn: false))
    }

    func testRelaxedIdleSleepDoesNotVeto() {
        let machine = SleepStateMachine(policy: .relaxed)
        XCTAssertFalse(vetoes(machine, percent: 20, chargingAllowed: true))
    }

    func testWakeForcesReevaluation() {
        let machine = SleepStateMachine(policy: .strict)
        let evaluation = machine.handle(
            event: .systemHasPoweredOn,
            context: SleepContext(
                limit: ChargeLimit(upperBound: 80),
                observation: BatteryObservation(chargePercent: 79, isChargingAllowed: true)
            )
        )

        XCTAssertEqual(evaluation.actions, [.reevaluate])
        XCTAssertTrue(evaluation.forcesReevaluation)
    }

    private func vetoes(
        _ machine: SleepStateMachine,
        percent: Int,
        chargingAllowed: Bool,
        pluggedIn: Bool = true
    ) -> Bool {
        machine.handle(
            event: .canSystemSleep,
            context: SleepContext(
                limit: ChargeLimit(upperBound: 80),
                observation: BatteryObservation(
                    chargePercent: percent,
                    isChargingAllowed: chargingAllowed,
                    isPluggedIn: pluggedIn
                )
            )
        ).vetoesIdleSleep
    }
}
