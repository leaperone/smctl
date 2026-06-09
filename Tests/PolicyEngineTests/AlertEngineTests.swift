import XCTest
@testable import PolicyEngine

final class AlertEngineTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func tempRule(for seconds: Double = 0, cooldown: Double = 300, resolve: Bool = false) -> AlertRule {
        AlertRule(
            name: "cpu-hot",
            trigger: AlertTrigger(kind: .temp, sensor: "Tp09", above: 85),
            forSeconds: seconds,
            cooldownSeconds: cooldown,
            resolve: resolve
        )
    }

    private func input(_ celsius: Double, sensor: String = "Tp09") -> AlertConditionInput {
        AlertConditionInput(samples: [FanTemperatureSample(sensor: sensor, celsius: celsius)])
    }

    func testFiresWhenThresholdExceeded() {
        var engine = AlertEngine()
        let events = engine.evaluate(rules: [tempRule()], input: input(90), now: base)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .fired)
        XCTAssertEqual(events.first?.value, 90)
        XCTAssertEqual(events.first?.triggerKind, .temp)
    }

    func testDoesNotFireBelowThreshold() {
        var engine = AlertEngine()
        XCTAssertTrue(engine.evaluate(rules: [tempRule()], input: input(80), now: base).isEmpty)
    }

    func testSustainedDurationDebounce() {
        var engine = AlertEngine()
        let rule = tempRule(for: 30)
        // First tick over threshold starts the timer but does not fire.
        XCTAssertTrue(engine.evaluate(rules: [rule], input: input(90), now: base).isEmpty)
        // 20s later: still within the window.
        XCTAssertTrue(engine.evaluate(rules: [rule], input: input(90), now: base.addingTimeInterval(20)).isEmpty)
        // 30s later: fires.
        let fired = engine.evaluate(rules: [rule], input: input(90), now: base.addingTimeInterval(30))
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired.first?.kind, .fired)
    }

    func testDebounceResetsWhenConditionDrops() {
        var engine = AlertEngine()
        let rule = tempRule(for: 30)
        _ = engine.evaluate(rules: [rule], input: input(90), now: base)
        // Drops below threshold before the window elapses → timer resets.
        _ = engine.evaluate(rules: [rule], input: input(70), now: base.addingTimeInterval(10))
        // Back over threshold; only now does a fresh 30s window start.
        _ = engine.evaluate(rules: [rule], input: input(90), now: base.addingTimeInterval(20))
        XCTAssertTrue(engine.evaluate(rules: [rule], input: input(90), now: base.addingTimeInterval(40)).isEmpty)
        XCTAssertEqual(engine.evaluate(rules: [rule], input: input(90), now: base.addingTimeInterval(50)).count, 1)
    }

    func testCooldownSuppressesRefiring() {
        var engine = AlertEngine()
        let rule = tempRule(cooldown: 300)
        XCTAssertEqual(engine.evaluate(rules: [rule], input: input(90), now: base).count, 1)
        // Still hot 100s later, but inside cooldown → silent.
        XCTAssertTrue(engine.evaluate(rules: [rule], input: input(95), now: base.addingTimeInterval(100)).isEmpty)
        // After cooldown elapses → fires again.
        XCTAssertEqual(engine.evaluate(rules: [rule], input: input(95), now: base.addingTimeInterval(301)).count, 1)
    }

    func testResolveEmitsWhenCleared() {
        var engine = AlertEngine()
        let rule = tempRule(resolve: true)
        XCTAssertEqual(engine.evaluate(rules: [rule], input: input(90), now: base).first?.kind, .fired)
        let resolved = engine.evaluate(rules: [rule], input: input(70), now: base.addingTimeInterval(10))
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.kind, .resolved)
    }

    func testNoResolveWhenDisabled() {
        var engine = AlertEngine()
        let rule = tempRule(resolve: false)
        _ = engine.evaluate(rules: [rule], input: input(90), now: base)
        XCTAssertTrue(engine.evaluate(rules: [rule], input: input(70), now: base.addingTimeInterval(10)).isEmpty)
    }

    func testAnySensorMatchesHottest() {
        var engine = AlertEngine()
        let rule = AlertRule(name: "any-hot", trigger: AlertTrigger(kind: .temp, sensor: "any", above: 85))
        let multi = AlertConditionInput(samples: [
            FanTemperatureSample(sensor: "Tp01", celsius: 60),
            FanTemperatureSample(sensor: "Tp09", celsius: 92),
            FanTemperatureSample(sensor: "Tg05", celsius: 88)
        ])
        let events = engine.evaluate(rules: [rule], input: multi, now: base)
        XCTAssertEqual(events.first?.value, 92)
        XCTAssertEqual(events.first?.reason.contains("Tp09"), true)
    }

    func testGuardTrigger() {
        var engine = AlertEngine()
        let rule = AlertRule(name: "guard", trigger: AlertTrigger(kind: .guardTripped))
        let tripped = AlertConditionInput(guardTripped: true, guardReason: "Tp09 105C")
        let events = engine.evaluate(rules: [rule], input: tripped, now: base)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.reason, "Tp09 105C")
    }

    func testWriteErrorTrigger() {
        var engine = AlertEngine()
        let rule = AlertRule(name: "smc", trigger: AlertTrigger(kind: .writeError))
        let err = AlertConditionInput(writeError: "CH0B verify failed")
        XCTAssertEqual(engine.evaluate(rules: [rule], input: err, now: base).first?.reason, "CH0B verify failed")
    }

    func testStatesReportLifecycle() {
        var engine = AlertEngine()
        let rule = tempRule(cooldown: 300)
        XCTAssertEqual(engine.states(for: [rule], now: base).first?.status, .armed)
        _ = engine.evaluate(rules: [rule], input: input(90), now: base)
        XCTAssertEqual(engine.states(for: [rule], now: base).first?.status, .cooling)
        // After cooldown but still hot in runtime, status reflects firing.
        XCTAssertEqual(engine.states(for: [rule], now: base.addingTimeInterval(400)).first?.status, .firing)
    }

    func testRemovedRuleStateIsDropped() {
        var engine = AlertEngine()
        let rule = tempRule()
        _ = engine.evaluate(rules: [rule], input: input(90), now: base)
        // Re-evaluate with an empty rule set; the stale runtime must be purged so a
        // re-added rule starts armed, not mid-cooldown.
        _ = engine.evaluate(rules: [], input: input(90), now: base.addingTimeInterval(10))
        let events = engine.evaluate(rules: [rule], input: input(90), now: base.addingTimeInterval(20))
        XCTAssertEqual(events.count, 1, "Re-added rule should fire fresh, not be suppressed by purged cooldown")
    }
}
