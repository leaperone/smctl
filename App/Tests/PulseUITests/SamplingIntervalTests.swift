import Foundation
import Testing
@testable import PulseUI

struct SamplingIntervalTests {
    @MainActor @Test func pollsFollowTheDaemonInterval() async {
        let service = SampleService()
        let store = await PulseStore.preview(service)
        #expect(store.samplingInterval == 2)
        #expect(store.pollInterval == .seconds(2))
        store.popoverDidOpen()
        #expect(store.pollInterval == .seconds(2), "the popover no longer polls faster than the daemon reads")

        #expect(await store.setSamplingInterval(5))
        #expect(store.samplingInterval == 5)
        #expect(store.pollInterval == .seconds(5))
    }

    @MainActor @Test func withoutDaemonTheAppKeepsItsOwnPace() async {
        let store = await PulseStore.preview(SampleService(failing: true))
        #expect(store.samplingInterval == nil)
        #expect(store.pollInterval == .seconds(2))
    }

    @Test func helpExplainsTheTradeOff() {
        #expect(SamplingSettings.help(seconds: 1).hasPrefix("Fans react within a second"))
        #expect(SamplingSettings.help(seconds: 5).contains("least energy"))
        #expect(SamplingSettings.help(seconds: 3).contains("every second anyway"))
    }
}
