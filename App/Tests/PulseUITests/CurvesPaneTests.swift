import Foundation
import PolicyEngine
import SMCtlProtocol
import Testing
@testable import PulseUI

struct CurveNamingTests {
    @Test func slugsAreValidNames() {
        #expect(CurveNaming.slug("Night mode") == "night-mode")
        #expect(CurveNaming.slug("Été 2026 !") == "ete-2026")
        #expect(CurveNaming.slug("  --  ") == "curve")
        #expect(CurveNaming.slug("Balanced copy") == "balanced-copy")
        let long = CurveNaming.slug(String(repeating: "abc ", count: 20))
        #expect(long.count <= FanCurveSpec.maximumNameLength)
        #expect(!long.hasSuffix("-"))
        for label in ["Night mode", "Été 2026 !", "日本語", "x", String(repeating: "z", count: 80)] {
            #expect(FanCurveSpec.isValidName(CurveNaming.slug(label)), "\(label)")
        }
    }

    @Test func uniqueNamesAvoidExistingAndReserved() {
        #expect(CurveNaming.uniqueName(base: "Night", existing: []) == "night")
        #expect(CurveNaming.uniqueName(base: "Night", existing: ["night", "night-2"]) == "night-3")
        #expect(CurveNaming.uniqueName(base: "Balanced", existing: []) == "balanced-2", "presets are reserved")
        #expect(CurveNaming.uniqueName(base: "Auto", existing: []) == "auto-2")
        let long = String(repeating: "a", count: 32)
        let unique = CurveNaming.uniqueName(base: long, existing: [long])
        #expect(unique.count <= FanCurveSpec.maximumNameLength)
        #expect(unique.hasSuffix("-2"))
    }

    @Test func copyLabelsAndCleanLabels() {
        #expect(CurveNaming.copyLabel("Balanced", existing: []) == "Balanced copy")
        #expect(CurveNaming.copyLabel("Balanced", existing: ["Balanced copy"]) == "Balanced copy 2")
        #expect(CurveNaming.cleanLabel("  Night\nmode ") == "Night mode")
        #expect(CurveNaming.cleanLabel("   ") == nil)
        #expect(CurveNaming.cleanLabel(String(repeating: "x", count: 100))?.count == FanCurveSpec.maximumLabelLength)
    }
}

struct CurveSummaryTests {
    @Test func presetsReadPlainly() {
        #expect(CurveSummary.shape(FanCurvePresets.balanced) == "S-curve, 70–100 °C, 0–100 %, steepness 8")
        #expect(CurveSummary.shape(FanCurvePresets.performance) == "Linear, 55–90 °C, 10–100 %")
        #expect(CurveSummary.sensors(FanCurvePresets.performance) == "CPU, average")
        #expect(CurveSummary.response(FanCurvePresets.balanced) == "up 8 %/s, down 3 %/s")
        #expect(CurveSummary.smoothing(FanCurvePresets.balanced) == "6 s")
        #expect(CurveSummary.sensors(FanCurvePresets.balanced) == "All sensors, hottest")
        let points = FanCurveSpec(name: "p", sensors: ["Tp*", "Tg*"], weights: ["Tp*": 1], points: [.init(40, .percent(0)), .init(90, .maximum)])
        #expect(CurveSummary.shape(points) == "2 points")
        #expect(CurveSummary.sensors(points) == "CPU, GPU, average")
        var weighted = points
        weighted.weights = ["Tp*": 2, "Tg*": 1]
        #expect(CurveSummary.sensors(weighted) == "CPU, GPU, weighted average")
        #expect(CurveSummary.hysteresis(points) == "None")
        #expect(CurveSummary.response(points) == "up immediately, down immediately")
    }
}

@MainActor
struct CurvesPaneStoreTests {
    @Test func duplicateCreateRenameDelete() async {
        let store = await PulseStore.preview(samples: 2)
        #expect(store.canEditCurves)

        let copy = await store.duplicate(FanCurvePresets.balanced)
        #expect(copy == "balanced-copy")
        #expect(store.curveEntries.first { $0.spec.name == "balanced-copy" }?.spec.label == "Balanced copy")
        #expect(await store.duplicate(FanCurvePresets.balanced) == "balanced-copy-2")

        let created = await store.createCurve()
        #expect(created == "custom")
        #expect(await store.createCurve() == "custom-2")

        #expect(await store.rename(curve: "custom", to: "Late night"))
        let renamed = store.curveEntries.first { $0.spec.name == "custom" }
        #expect(renamed?.spec.label == "Late night", "the technical name is kept")
        #expect(!(await store.rename(curve: "balanced", to: "Mine")), "presets cannot be renamed")

        #expect(await store.delete(curve: "custom"))
        #expect(!store.curveEntries.contains { $0.spec.name == "custom" })
    }

    @Test func presetsAreListedWithoutTheDaemon() async {
        let store = await PulseStore.preview(SampleService(failing: true), samples: 1)
        #expect(!store.canEditCurves)
        #expect(store.curveEntries.map(\.spec.name) == FanCurvePresets.all.map(\.name))
        #expect(!store.curveEntries.contains { !$0.builtin })
    }

    @Test func navigationSelectsTheRequestedCurve() {
        let navigation = SettingsNavigation(selectedCurve: "silent")
        navigation.apply(.pane(.general))
        #expect(navigation.selectedCurve == "silent")
        navigation.apply(.curve(nil))
        #expect(navigation.selectedCurve == "silent", "nil keeps the selection")
        navigation.apply(.curve("night"))
        #expect(navigation.selectedCurve == "night")
        #expect(SettingsDestination.curve("night").pane == .curves)
    }
}
