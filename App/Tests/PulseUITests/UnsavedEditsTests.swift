import Foundation
import PolicyEngine
import Testing
@testable import PulseUI

@MainActor
struct UnsavedEditsTests {
    func editor(_ name: String = "night") -> CurveEditorModel {
        var spec = FanCurvePresets.balanced
        spec.name = name
        spec.label = "Night"
        return CurveEditorModel(spec: spec, range: FanSpeedRange(minimumRPM: 1000, maximumRPM: 4900))
    }

    @Test func leavingACleanCurveSelectsRightAway() {
        let navigation = SettingsNavigation(selectedCurve: "night")
        let model = editor()
        navigation.editor = model
        navigation.request("silent")
        #expect(navigation.selectedCurve == "silent")
        #expect(navigation.pending == nil)
    }

    @Test func leavingAnEditedCurveAsksFirst() {
        let navigation = SettingsNavigation(selectedCurve: "night")
        let model = editor()
        navigation.editor = model
        model.edit("Change Shape") { $0.setKind(.linear) }

        navigation.request("silent")
        #expect(navigation.selectedCurve == "night", "waits for an answer")
        #expect(navigation.pending == PendingSelection(curve: "silent"))

        navigation.cancelPending()
        #expect(navigation.selectedCurve == "night")
        #expect(navigation.pending == nil)

        // The popover's "Edit Curves…" goes through the same check.
        navigation.apply(.curve("silent"))
        #expect(navigation.pending == PendingSelection(curve: "silent"))
        navigation.confirmPending()
        #expect(navigation.selectedCurve == "silent")
        #expect(navigation.pending == nil)
    }

    @Test func ownSaveComingBackIsAbsorbed() {
        let model = editor()
        model.edit("Change Shape") { $0.setKind(.linear) }
        let saved = model.draft.spec
        #expect(model.savedCurveChanged(to: saved) == .absorbed)
        #expect(!model.draft.isDirty)
    }

    @Test func changesElsewhereReloadWhenClean() {
        let model = editor()
        var elsewhere = model.draft.spec
        elsewhere.hysteresisCelsius = 7
        #expect(model.savedCurveChanged(to: elsewhere) == .absorbed)
        #expect(model.draft.spec.hysteresisCelsius == 7)
        #expect(!model.draft.isDirty)
    }

    @Test func changesElsewhereConflictWithEdits() {
        let model = editor()
        model.edit("Change Shape") { $0.setKind(.linear) }
        var elsewhere = model.draft.original
        elsewhere.hysteresisCelsius = 7
        #expect(model.savedCurveChanged(to: elsewhere) == .conflict)
        #expect(model.draft.spec.shape?.kind == .linear, "edits untouched until the user decides")

        model.keepEdits(over: elsewhere)
        #expect(model.draft.original == elsewhere)
        #expect(model.draft.isDirty)
        #expect(model.savedCurveChanged(to: elsewhere) == .absorbed, "asked once")
    }

    @Test func renameElsewhereKeepsEdits() {
        let model = editor()
        model.edit("Change Shape") { $0.setKind(.linear) }
        var renamed = model.draft.original
        renamed.label = "Late night"
        #expect(model.savedCurveChanged(to: renamed) == .absorbed)
        #expect(model.draft.spec.label == "Late night")
        #expect(model.draft.spec.shape?.kind == .linear)
        #expect(model.draft.isDirty)
    }
}
