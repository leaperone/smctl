import Foundation
import PolicyEngine
import Testing

/// docs/HELP.md is written by hand: these checks keep its numbers in step
/// with the code (presets, safety ceilings, refresh range).
struct HelpDocumentTests {
    private var help: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("docs/HELP.md")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    @Test func presetRangesMatchTheCode() throws {
        let text = try help
        for preset in FanCurvePresets.all {
            let shape = try #require(preset.shape)
            let range = "\(Int(shape.startCelsius))–\(Int(shape.endCelsius)) °C"
            let row = try #require(text.split(separator: "\n").first { $0.hasPrefix("| **\(preset.label ?? "")** |") }, "\(preset.name)")
            #expect(row.contains(range), "\(preset.name): \(range)")
            #expect(row.contains(preset.weights.isEmpty ? "hottest sensor" : "CPU average"))
            if shape.minimumFraction > 0 {
                #expect(row.contains("Never below \(Int((shape.minimumFraction * 100).rounded())) %"))
            }
        }
    }

    @Test func safetyCeilingsMatchTheCode() throws {
        let text = try help
        #expect(text.contains("**\(Int(FanSafetyGuard.defaultCeilingCelsius)) °C**"))
        #expect(text.contains("**\(Int(FanSafetyGuard.defaultCeilingCelsius + FanSafetyGuard.hotSpotAllowanceCelsius)) °C**"))
        #expect(text.contains("from 1 to 5 seconds (2 s by default)"))
    }
}
