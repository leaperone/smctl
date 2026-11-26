import Foundation
import PolicyEngine
import SMCtlProtocol
import Testing
@testable import PulseUI

struct FanlessAndMultiFanTests {
    private func fan(_ index: Int, _ low: Double, _ high: Double) -> FanStatusDTO {
        FanStatusDTO(index: index, actualRPM: low, targetRPM: low, minimumRPM: low, maximumRPM: high, mode: "auto")
    }

    @Test func noteOnlyWhenFansDiffer() {
        #expect(FanRangeNote.text(fans: []) == nil)
        #expect(FanRangeNote.text(fans: [fan(0, 1000, 4900)]) == nil)
        #expect(FanRangeNote.text(fans: [fan(0, 1200, 5000), fan(1, 1200, 5000)]) == nil, "identical fans need no note")
        let note = FanRangeNote.text(fans: [fan(0, 1200, 5779), fan(1, 1200, 6241)])
        #expect(note == "RPM of Fan 1. Fan 2 runs the same % on 1200–6241 RPM.")
    }

    @MainActor @Test func fanlessMacIsMonitoringOnly() async {
        let store = await PulseStore.preview(SampleService(fanRanges: []))
        #expect(store.isFanless)
        #expect(!store.canControlFans)
        #expect(store.canEditCurves, "curves stay editable (for a config shared with another Mac)")
    }

    @MainActor @Test func macBookProReportsBothFans() async {
        let store = await PulseStore.preview(SampleService(profile: "balanced", fanRanges: SampleService.macBookProFans))
        #expect(!store.isFanless)
        #expect(store.fans.map(\.maximumRPM) == [5779, 6241])
        #expect(store.canControlFans)
    }

    @MainActor @Test func readOnlyIsNotFanless() async {
        let store = await PulseStore.preview(SampleService(failing: true))
        #expect(!store.isFanless, "no telemetry is a different state from no fan")
    }
}
