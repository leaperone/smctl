import CoreGraphics
import Foundation
import Observation
import PolicyEngine

/// What the pointer can grab in the editor chart.
public enum EditorHandle: Hashable, Sendable {
    case start
    case end
    case point(Int)
}

/// The editor's state around a `CurveDraft`: selection, dragging and undo.
/// Each edit registers one undo step; a drag (many small moves) registers one
/// step when it ends.
@MainActor
@Observable
public final class CurveEditorModel {
    public private(set) var draft: CurveDraft
    public var selectedPoint: Int?
    public private(set) var dragging: EditorHandle?

    @ObservationIgnored public weak var undoManager: UndoManager?
    @ObservationIgnored private var dragOrigin: FanCurveSpec?

    /// Drag positions snap to these steps, so values read cleanly.
    public static let temperatureSnap = 0.5
    public static let percentSnap = 1.0

    public init(spec: FanCurveSpec, range: FanSpeedRange) {
        draft = CurveDraft(spec, range: range)
    }

    // MARK: Edits

    /// Applies `change` as one undoable step named `name`.
    public func edit(_ name: String, _ change: (inout CurveDraft) -> Void) {
        let before = draft.spec
        change(&draft)
        if draft.spec != before {
            registerUndo(restoring: before, name: name)
        }
        clampSelection()
    }

    public func setKind(_ kind: FanCurveShapeKind?) {
        if let kind {
            edit("Change Shape") { $0.setKind(kind) }
        } else {
            edit("Convert to Points") { $0.convertToPoints() }
        }
        selectedPoint = nil
    }

    /// Discards every change since the curve was loaded.
    public func revert() {
        edit("Revert") { $0.revert() }
        selectedPoint = nil
    }

    /// Replaces the curve after a save or a change made elsewhere; not undoable.
    public func reload(spec: FanCurveSpec, range: FanSpeedRange) {
        draft = CurveDraft(spec, range: range)
        undoManager?.removeAllActions(withTarget: self)
        selectedPoint = nil
        dragging = nil
        dragOrigin = nil
    }

    /// What to do when the saved curve changed outside this editor (command
    /// line, another window, a rename).
    public enum ExternalChange: Equatable, Sendable {
        /// Nothing to do: it is what the editor holds, or there were no edits
        /// and the editor now shows the new version.
        case absorbed
        /// The editor has edits and the saved curve changed: ask the user.
        case conflict
    }

    /// Reconciles the editor with the curve as now saved.
    public func savedCurveChanged(to saved: FanCurveSpec) -> ExternalChange {
        guard saved != draft.original else { return .absorbed }
        if saved == draft.spec || !draft.isDirty {
            // Our own save coming back, or no edits to protect.
            reload(spec: saved, range: draft.range)
            return .absorbed
        }
        var labelOnly = draft.original
        labelOnly.label = saved.label
        if labelOnly == saved {
            // Renamed elsewhere: take the new name, keep the edits.
            draft.rebase(onto: saved)
            draft.setLabel(saved.label ?? "")
            return .absorbed
        }
        return .conflict
    }

    /// Keeps the edits on top of the new saved version (saving overwrites it).
    public func keepEdits(over saved: FanCurveSpec) {
        draft.rebase(onto: saved)
    }

    // MARK: Dragging

    public func beginDrag(_ handle: EditorHandle) {
        dragging = handle
        dragOrigin = draft.spec
        if case .point(let index) = handle { selectedPoint = index }
    }

    /// Moves the dragged handle to (°C, %), snapped.
    public func drag(to celsius: Double, percent: Double) {
        guard let handle = dragging else { return }
        let celsius = (celsius / Self.temperatureSnap).rounded() * Self.temperatureSnap
        let percent = (percent / Self.percentSnap).rounded() * Self.percentSnap
        switch handle {
        case .start: draft.moveHandle(.start, celsius: celsius, percent: percent)
        case .end: draft.moveHandle(.end, celsius: celsius, percent: percent)
        case .point(let index): draft.movePoint(at: index, celsius: celsius, percent: percent)
        }
    }

    public func endDrag() {
        defer {
            dragging = nil
            dragOrigin = nil
        }
        guard let origin = dragOrigin, origin != draft.spec else { return }
        registerUndo(restoring: origin, name: "Move")
    }

    // MARK: Points

    /// Adds a point at (°C, %); on a shape curve, converts it to points first.
    public func addPoint(celsius: Double, percent: Double) {
        let celsius = (celsius / Self.temperatureSnap).rounded() * Self.temperatureSnap
        let percent = (percent / Self.percentSnap).rounded() * Self.percentSnap
        var added: Int?
        edit("Add Point") { draft in
            if !draft.isPoints { draft.convertToPoints() }
            added = draft.addPoint(celsius: celsius, percent: percent)
        }
        selectedPoint = added ?? selectedPoint
    }

    public func deleteSelectedPoint() {
        guard let index = selectedPoint, draft.isPoints, draft.percentPoints.count > 2 else { return }
        edit("Delete Point") { $0.removePoint(at: index) }
        selectedPoint = nil
    }

    // MARK: Hit testing

    /// Handles in (°C, %) for the current curve.
    public var handles: [(handle: EditorHandle, celsius: Double, percent: Double)] {
        if draft.isPoints {
            return draft.percentPoints.enumerated().map { (.point($0.offset), $0.element.celsius, $0.element.percent) }
        }
        return [CurveHandle.start, .end].compactMap { which in
            draft.handle(which).map { (which == .start ? .start : .end, $0.celsius, $0.percent) }
        }
    }

    /// The handle closest to `location` within `radius` points, given each
    /// handle's on-screen position.
    public static func nearest(to location: CGPoint, in positions: [(EditorHandle, CGPoint)], radius: CGFloat = 12) -> EditorHandle? {
        positions
            .map { ($0.0, hypot($0.1.x - location.x, $0.1.y - location.y)) }
            .filter { $0.1 <= radius }
            .min { $0.1 < $1.1 }?.0
    }

    // MARK: Undo

    private func registerUndo(restoring old: FanCurveSpec, name: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let current = model.draft.spec
                model.draft.restore(old)
                model.clampSelection()
                model.registerUndo(restoring: current, name: name)
            }
        }
        undoManager.setActionName(name)
    }

    private func clampSelection() {
        if let index = selectedPoint, !(draft.isPoints && draft.percentPoints.indices.contains(index)) {
            selectedPoint = nil
        }
    }
}
