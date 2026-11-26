import Foundation
import PolicyEngine
import SMCtlProtocol
import Testing
@testable import PulseUI

struct CurvePreviewTests {
    let readings = [
        TemperatureDTO(key: "Tp01", group: "Tp", celsius: 70),
        TemperatureDTO(key: "Tp02", group: "Tp", celsius: 80),
        TemperatureDTO(key: "Tg0D", group: "Tg", celsius: 50),
        TemperatureDTO(key: "Tg0E", group: "Tg", celsius: 0), // powered down: ignored
    ]

    @Test func inputFollowsTheDraftsSensorsAndAggregation() {
        var draft = CurveDraft(FanCurvePresets.balanced)
        #expect(CurvePreview.input(spec: draft.spec, temperatures: readings) == 80, "hottest of all")
        draft.setSensorGroups([.gpu])
        #expect(CurvePreview.input(spec: draft.spec, temperatures: readings) == 50)
        draft.setSensorGroups([.cpu])
        draft.setAggregation(.average)
        #expect(CurvePreview.input(spec: draft.spec, temperatures: readings) == 75)
        draft.setSensorGroups([.enclosure])
        #expect(CurvePreview.input(spec: draft.spec, temperatures: readings) == nil, "no matching sensor")
    }

    @Test func previewAsksTheCurve() throws {
        let draft = CurveDraft(FanCurvePresets.balanced)
        let fan = FanStatusDTO(index: 0, actualRPM: 1390, targetRPM: 1390, minimumRPM: 1000, maximumRPM: 4900, mode: "manual")
        let preview = try #require(CurvePreview.make(draft: draft, temperatures: readings, fan: fan))
        #expect(preview.celsius == 80)
        #expect(abs(preview.percent - draft.percent(at: 80)) < 1e-9)
        #expect(abs((preview.fanPercent ?? 0) - 10) < 1e-9)
    }

    @Test func responseText() {
        let range = FanSpeedRange(minimumRPM: 1000, maximumRPM: 5000)
        #expect(ResponseSummary.text(FanCurvePresets.balanced, range: range)
                == "Minimum to full speed in 33 s, back to minimum in 100 s. Slows down only once 3 °C cooler. Ignores spikes shorter than about 6 s.")
        let bare = FanCurveSpec(name: "b", shape: FanCurvePresets.balanced.shape)
        #expect(ResponseSummary.text(bare, range: range) == "The fan follows the curve immediately.")
        let rpm = FanCurveSpec(name: "r", shape: FanCurvePresets.balanced.shape, riseRate: .rpmPerSecond(400))
        #expect(ResponseSummary.text(rpm, range: range) == "Minimum to full speed in 10 s; slows down immediately.")
    }

    @Test func zeroPercentHandsOffToMacOS() throws {
        let draft = CurveDraft(FanCurvePresets.balanced)
        let cool = [TemperatureDTO(key: "Tp01", group: "Tp", celsius: 50)]
        #expect(try #require(CurvePreview.make(draft: draft, temperatures: cool, fan: nil)).handsOffToSystem)
        let warm = [TemperatureDTO(key: "Tp01", group: "Tp", celsius: 85)]
        #expect(try #require(CurvePreview.make(draft: draft, temperatures: warm, fan: nil)).handsOffToSystem == false)
        let floor = CurveDraft(FanCurvePresets.performance)
        #expect(try #require(CurvePreview.make(draft: floor, temperatures: cool, fan: nil)).handsOffToSystem == false, "10% floor")
    }
}
