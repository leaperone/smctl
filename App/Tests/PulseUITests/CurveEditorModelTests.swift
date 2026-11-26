import CoreGraphics
import Foundation
import PolicyEngine
import Testing
@testable import PulseUI

@MainActor
struct CurveEditorModelTests {
    func makeModel() -> (CurveEditorModel, UndoManager) {
        var spec = FanCurvePresets.balanced
        spec.name = "mine"
        let model = CurveEditorModel(spec: spec, range: FanSpeedRange(minimumRPM: 1000, maximumRPM: 4900))
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        return (model, undo)
    }

    func step(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    @Test func aDragIsOneSnappedUndoStep() {
        let (model, undo) = makeModel()
        step(undo) {
            model.beginDrag(.start)
            model.drag(to: 61.3, percent: 9.6)
            model.drag(to: 64.8, percent: 12.4)
            model.endDrag()
        }
        #expect(model.draft.handle(.start)! == (65, 12), "snapped to 0.5 °C and 1 %")
        #expect(model.dragging == nil)
        #expect(undo.canUndo)
        #expect(undo.undoActionName == "Move")
        undo.undo()
        #expect(model.draft.handle(.start)! == (70, 0), "one undo restores the drag's start")
        #expect(undo.canRedo)
        undo.redo()
        #expect(model.draft.handle(.start)! == (65, 12))
    }

    @Test func aDragThatChangesNothingLeavesNoUndo() {
        let (model, undo) = makeModel()
        // No grouping: registering anything here would raise, as no group is open.
        model.beginDrag(.end)
        model.drag(to: 100, percent: 100)
        model.endDrag()
        #expect(!undo.canUndo)
        #expect(!model.draft.isDirty)
    }

    @Test func doubleClickOnAShapeConvertsThenAddsAPoint() {
        let (model, undo) = makeModel()
        step(undo) { model.addPoint(celsius: 45.2, percent: 20.4) }
        #expect(model.draft.isPoints)
        let selected = model.selectedPoint
        #expect(selected != nil)
        #expect(model.draft.percentPoints[selected!] == (45, 20))
        undo.undo()
        #expect(!model.draft.isPoints, "one undo goes back to the shape")
        #expect(model.selectedPoint == nil, "the selection is cleared when its point disappears")
    }

    @Test func deletingTheSelectedPoint() {
        let (model, _) = makeModel()
        model.setKind(nil)
        let count = model.draft.percentPoints.count
        model.selectedPoint = 1
        model.deleteSelectedPoint()
        #expect(model.draft.percentPoints.count == count - 1)
        #expect(model.selectedPoint == nil)
    }

    @Test func revertAndReload() {
        let (model, undo) = makeModel()
        step(undo) { model.setKind(.linear) }
        #expect(model.draft.isDirty)
        step(undo) { model.revert() }
        #expect(!model.draft.isDirty)
        undo.undo()
        #expect(model.draft.spec.shape?.kind == .linear, "revert is undoable")

        let saved = model.draft.spec
        model.reload(spec: saved, range: model.draft.range)
        #expect(!model.draft.isDirty, "after a save the saved curve is the new original")
        #expect(!undo.canUndo)
    }

    @Test func handlesAndHitTesting() {
        let (model, _) = makeModel()
        #expect(model.handles.map(\.handle) == [.start, .end])
        model.setKind(nil)
        #expect(model.handles.count == model.draft.percentPoints.count)

        let positions: [(EditorHandle, CGPoint)] = [(.start, CGPoint(x: 10, y: 10)), (.end, CGPoint(x: 30, y: 10))]
        #expect(CurveEditorModel.nearest(to: CGPoint(x: 13, y: 12), in: positions) == .start)
        #expect(CurveEditorModel.nearest(to: CGPoint(x: 26, y: 10), in: positions) == .end)
        #expect(CurveEditorModel.nearest(to: CGPoint(x: 20, y: 40), in: positions) == nil)
    }

    @Test func rpmTicksAreRoundThousands() {
        let ticks = EditableCurveChart.rpmTicks(FanSpeedRange(minimumRPM: 1000, maximumRPM: 4900))
        let rpm = ticks.map { (1000 + 3900 * $0 / 100).rounded() }
        #expect(rpm == [1000, 2000, 3000, 4000])
        #expect(EditableCurveChart.rpmTicks(FanSpeedRange(minimumRPM: 1200, maximumRPM: 2800)).count == 3, "500 RPM steps when narrow")
    }

    @Test func aSliderGestureIsOneUndoStep() {
        let (model, undo) = makeModel()
        step(undo) {
            model.beginContinuousEdit()
            for value in [9.0, 11.5, 13, 14.3] {
                model.edit("Change Steepness") { $0.setSteepness(value) }
            }
            model.endContinuousEdit("Change Steepness")
        }
        #expect(model.draft.spec.shape?.steepness == 14.3)
        #expect(undo.undoActionName == "Change Steepness")
        undo.undo()
        #expect(model.draft.spec.shape?.steepness == 8, "one undo returns to before the gesture")
        #expect(!undo.canUndo)
    }

    /// Charts morphs a line between updates; a changing point count turned
    /// the curve into spikes while the steepness slider moved.
    @Test func drawnLineKeepsItsPointCountAcrossSteepness() {
        let (model, _) = makeModel()
        let counts = Set(stride(from: 0.5, through: 20, by: 0.5).map { value -> Int in
            model.edit("Change Steepness") { $0.setSteepness(value) }
            return EditableCurveChart.displayLine(model.draft).count
        })
        #expect(counts == [161])
        let line = EditableCurveChart.displayLine(model.draft)
        #expect(line.first?.celsius == CurveDraft.temperatureRange.lowerBound)
        #expect(line.last?.celsius == CurveDraft.temperatureRange.upperBound)
    }
}
