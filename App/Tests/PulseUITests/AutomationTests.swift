import Foundation
import Testing
@testable import PulseUI

struct AutomationTests {
    let game = AutomationRule(condition: .appsRunning(["com.example.game"]), profile: "performance")
    let battery = AutomationRule(condition: .onBattery, profile: "silent")
    let t0 = Date(timeIntervalSince1970: 1_000)

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    @Test func aRuleAppliesOnceSettledThenReturnsToTheBaseProfile() {
        var engine = AutomationEngine(rules: [game])
        let playing = SystemSnapshot(runningApps: ["com.example.game"])
        #expect(engine.evaluate(SystemSnapshot(), activeProfile: "balanced", now: at(0)) == nil)
        #expect(engine.evaluate(playing, activeProfile: "balanced", now: at(1)) == nil, "not settled yet")
        #expect(engine.evaluate(playing, activeProfile: "balanced", now: at(6)) == "performance")
        #expect(engine.activeRule == game)
        #expect(engine.evaluate(playing, activeProfile: "performance", now: at(8)) == nil)
        #expect(engine.evaluate(SystemSnapshot(), activeProfile: "performance", now: at(10)) == "balanced", "back to the base")
        #expect(engine.activeRule == nil)
    }

    @Test func aShortBlipChangesNothing() {
        var engine = AutomationEngine(rules: [game])
        _ = engine.evaluate(SystemSnapshot(), activeProfile: "balanced", now: at(0))
        #expect(engine.evaluate(SystemSnapshot(runningApps: ["com.example.game"]), activeProfile: "balanced", now: at(1)) == nil)
        #expect(engine.evaluate(SystemSnapshot(), activeProfile: "balanced", now: at(3)) == nil)
        #expect(engine.evaluate(SystemSnapshot(runningApps: ["com.example.game"]), activeProfile: "balanced", now: at(5)) == nil, "the clock restarted")
    }

    @Test func firstMatchingRuleWins() {
        var engine = AutomationEngine(rules: [game, battery])
        let both = SystemSnapshot(runningApps: ["com.example.game"], onBattery: true)
        _ = engine.evaluate(both, activeProfile: "balanced", now: at(0))
        #expect(engine.evaluate(both, activeProfile: "balanced", now: at(6)) == "performance")
        engine.rules = [battery, game]
        #expect(engine.evaluate(both, activeProfile: "performance", now: at(8)) == "silent")
    }

    @Test func aManualChoiceWinsUntilTheConditionGoesAway() {
        var engine = AutomationEngine(rules: [game])
        let playing = SystemSnapshot(runningApps: ["com.example.game"])
        _ = engine.evaluate(playing, activeProfile: "balanced", now: at(0))
        #expect(engine.evaluate(playing, activeProfile: "balanced", now: at(6)) == "performance")
        #expect(engine.evaluate(playing, activeProfile: "performance", now: at(8)) == nil)
        // The user picks Silent while still playing.
        #expect(engine.evaluate(playing, activeProfile: "silent", now: at(10)) == nil)
        #expect(engine.baseProfile == "silent")
        #expect(engine.evaluate(playing, activeProfile: "silent", now: at(30)) == nil, "suspended while the game runs")
        // Game closed: nothing to do, Silent is the base. Next game: the rule applies again.
        #expect(engine.evaluate(SystemSnapshot(), activeProfile: "silent", now: at(40)) == nil)
        _ = engine.evaluate(playing, activeProfile: "silent", now: at(50))
        #expect(engine.evaluate(playing, activeProfile: "silent", now: at(56)) == "performance")
    }

    @Test func afterASafetyTripRulesWaitForTheUser() {
        var engine = AutomationEngine(rules: [game])
        let playing = SystemSnapshot(runningApps: ["com.example.game"])
        _ = engine.evaluate(playing, activeProfile: "balanced", now: at(0))
        #expect(engine.evaluate(playing, activeProfile: "balanced", now: at(6)) == "performance")
        engine.safetyTripped()
        #expect(engine.evaluate(playing, activeProfile: "auto", now: at(10)) == nil)
        #expect(engine.evaluate(SystemSnapshot(), activeProfile: "auto", now: at(20)) == nil, "not even back to the base")
        #expect(engine.suspendedForSafety)
        // The user picks Balanced again: rules resume.
        #expect(engine.evaluate(SystemSnapshot(), activeProfile: "balanced", now: at(30)) == nil)
        #expect(!engine.suspendedForSafety)
        _ = engine.evaluate(playing, activeProfile: "balanced", now: at(40))
        #expect(engine.evaluate(playing, activeProfile: "balanced", now: at(46)) == "performance")
    }

    @Test func disabledRulesAndPowerConditions() {
        var off = battery
        off.enabled = false
        var engine = AutomationEngine(rules: [off])
        let unplugged = SystemSnapshot(onBattery: true)
        _ = engine.evaluate(unplugged, activeProfile: "balanced", now: at(0))
        #expect(engine.evaluate(unplugged, activeProfile: "balanced", now: at(10)) == nil)
        #expect(!AutomationCondition.onBattery.holds(in: SystemSnapshot(onBattery: nil)), "no battery: never on battery")
        #expect(!AutomationCondition.onPowerAdapter.holds(in: SystemSnapshot(onBattery: nil)))
        #expect(AutomationCondition.lowPowerMode.holds(in: SystemSnapshot(lowPowerMode: true)))
    }

    @Test func aSwitchInFlightIsNotAManualChoice() {
        var engine = AutomationEngine(rules: [game])
        let playing = SystemSnapshot(runningApps: ["com.example.game"])
        _ = engine.evaluate(playing, activeProfile: "balanced", now: at(0))
        #expect(engine.evaluate(playing, activeProfile: "balanced", now: at(6)) == "performance")
        // The next poll still reports the old profile.
        #expect(engine.evaluate(playing, activeProfile: "balanced", now: at(7)) == nil)
        #expect(engine.baseProfile == "balanced", "not taken for a manual choice")
        #expect(engine.evaluate(playing, activeProfile: "performance", now: at(8)) == nil)
        #expect(engine.activeRule == game)
    }

    @Test func aChoiceMadeDuringASwitchStillWins() {
        var engine = AutomationEngine(rules: [game])
        let playing = SystemSnapshot(runningApps: ["com.example.game"])
        _ = engine.evaluate(playing, activeProfile: "balanced", now: at(0))
        #expect(engine.evaluate(playing, activeProfile: "balanced", now: at(6)) == "performance")
        #expect(engine.evaluate(playing, activeProfile: "silent", now: at(7)) == nil)
        #expect(engine.baseProfile == "silent")
        #expect(engine.evaluate(playing, activeProfile: "silent", now: at(30)) == nil)
    }

    @Test func aRefusedSwitchIsRetriedNotTakenForAChoice() {
        var engine = AutomationEngine(rules: [game])
        let playing = SystemSnapshot(runningApps: ["com.example.game"])
        _ = engine.evaluate(playing, activeProfile: "balanced", now: at(0))
        #expect(engine.evaluate(playing, activeProfile: "balanced", now: at(6)) == "performance")
        #expect(engine.evaluate(playing, activeProfile: "balanced", now: at(20)) == "performance", "retried after the timeout")
        #expect(engine.baseProfile == "balanced")
    }

    @Test func rulesRoundTripThroughJSON() throws {
        let data = try JSONEncoder().encode([game, battery])
        #expect(try JSONDecoder().decode([AutomationRule].self, from: data) == [game, battery])
    }
}

@MainActor
struct AutomationControllerTests {
    @Test func switchesTheDaemonAndPersistsRules() async throws {
        let defaults = UserDefaults(suiteName: "pulse.automation.tests.\(UUID().uuidString)")!
        let store = PulseStore(service: SampleService(profile: "balanced"), fallback: nil)
        await store.refresh()
        let controller = AutomationController(store: store, defaults: defaults, observeSystem: false)
        controller.add(AutomationRule(condition: .appsRunning(["com.example.game"]), profile: "performance"))
        controller.setSnapshot(SystemSnapshot(runningApps: ["com.example.game"]))
        let start = Date()
        // Polls tick with the real clock: start the condition 6 s ago.
        controller.tick(now: start.addingTimeInterval(-6))
        controller.tick(now: start)
        for _ in 0..<50 where store.activeProfile != "performance" {
            try await Task.sleep(for: .milliseconds(10))
            await store.refresh()
        }
        #expect(store.activeProfile == "performance")
        #expect(controller.activeRule?.profile == "performance")

        let reloaded = AutomationController(store: PulseStore(service: SampleService(profile: "auto"), fallback: nil), defaults: defaults, observeSystem: false)
        #expect(reloaded.rules == controller.rules)
    }
}
