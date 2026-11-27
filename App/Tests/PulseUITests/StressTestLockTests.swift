import Foundation
import SMCtlClient
import Testing
@testable import PulseUI

/// While a stress test runs, it owns the fan profile: the popover, the store
/// and the automation rules leave it alone.
@MainActor
struct StressTestLockTests {
    private func runningTest(_ store: PulseStore) -> StressTestModel {
        let model = StressTestModel(profile: "night", title: "Night", service: nil, store: store)
        // As StressTestModel.start() does, without heating the test machine.
        store.stressTestDidStart(model)
        return model
    }

    @Test func profilesAreLockedWhileATestRuns() async {
        let store = PulseStore(service: SampleService(profile: "night"), fallback: nil)
        await store.refresh()
        #expect(store.canSwitchProfile)
        let test = runningTest(store)
        #expect(!store.canSwitchProfile)
        await store.activate("silent")
        await store.refresh()
        #expect(store.activeProfile == "night", "the popover cannot switch the profile under test")
        store.stressTestDidEnd(test)
        #expect(store.canSwitchProfile)
        await store.activate("silent")
        #expect(store.activeProfile == "silent")
    }

    @Test func endingAnotherTestDoesNotUnlock() async {
        let store = PulseStore(service: SampleService(), fallback: nil)
        await store.refresh()
        _ = runningTest(store)
        store.stressTestDidEnd(StressTestModel(profile: "other", title: "Other", service: nil, store: store))
        #expect(!store.canSwitchProfile)
    }

    @Test func automationWaitsForTheEndOfTheTest() async throws {
        let defaults = UserDefaults(suiteName: "pulse.stresslock.tests.\(UUID().uuidString)")!
        let store = PulseStore(service: SampleService(profile: "night"), fallback: nil)
        await store.refresh()
        let controller = AutomationController(store: store, defaults: defaults, observeSystem: false)
        controller.add(AutomationRule(condition: .appsRunning(["com.example.game"]), profile: "performance"))
        controller.setSnapshot(SystemSnapshot(runningApps: ["com.example.game"]))
        let test = runningTest(store)
        let start = Date()
        controller.tick(now: start.addingTimeInterval(-6))
        controller.tick(now: start)
        try await Task.sleep(for: .milliseconds(100))
        await store.refresh()
        #expect(store.activeProfile == "night", "no rule switches the profile under test")

        store.stressTestDidEnd(test)
        // Paused rules were not evaluated: the condition settles again, then applies.
        controller.tick(now: start.addingTimeInterval(1))
        controller.tick(now: start.addingTimeInterval(1 + AutomationEngine.settleSeconds + 1))
        for _ in 0..<50 where store.activeProfile != "performance" {
            try await Task.sleep(for: .milliseconds(10))
            await store.refresh()
        }
        #expect(store.activeProfile == "performance", "the rules carry on after the test")
    }
}
