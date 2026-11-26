import PolicyEngine
import Testing
@testable import PulseUI

struct HelpContentTests {
    @Test func everyTopicHasText() {
        #expect(HelpContent.topics.count == 8)
        for topic in HelpContent.topics {
            #expect(!topic.paragraphs.isEmpty, "\(topic.title)")
            #expect(topic.paragraphs.allSatisfy { !$0.isEmpty })
        }
        #expect(Set(HelpContent.topics.map(\.id)).count == HelpContent.topics.count, "titles are unique ids")
    }

    @Test func presetDescriptionsFollowTheCode() {
        #expect(HelpContent.describe(FanCurvePresets.silent).contains("hottest sensor from 80–105 °C"))
        #expect(HelpContent.describe(FanCurvePresets.balanced).contains("from 70–100 °C"))
        let performance = HelpContent.describe(FanCurvePresets.performance)
        #expect(performance.contains("CPU average from 55–90 °C, never below 10 %"))
    }

    @Test func safetyAndRefreshNumbersFollowTheCode() {
        let safety = HelpContent.safety.paragraphs.joined()
        #expect(safety.contains("100 °C") && safety.contains("110 °C"))
        #expect(HelpContent.refresh.paragraphs[0].contains("from 1 to 5 seconds"))
    }

    @Test func boldLeadKeepsPercentSigns() {
        let text = HelpContent.attributed("**At 0 %.** What happens at 0 % and 100 %.")
        #expect(String(text.characters) == "At 0 %. What happens at 0 % and 100 %.")
    }
}
