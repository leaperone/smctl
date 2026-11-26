import Observation

/// Where to take the settings window, e.g. from the popover's "Edit…" button.
public enum SettingsDestination: Equatable, Sendable {
    case pane(SettingsPane)
    /// The Curves pane, with this curve selected (nil keeps the selection).
    case curve(String?)

    public var pane: SettingsPane {
        switch self {
        case .pane(let pane): return pane
        case .curve: return .curves
        }
    }
}

/// A selection waiting for the user to save or discard the current edits.
public struct PendingSelection: Equatable, Sendable {
    public var curve: String?
}

/// Selection shared between the settings window controller and its panes. It
/// outlives the window (which is released when closed), so reopening the
/// Curves pane returns to the same curve.
@MainActor
@Observable
public final class SettingsNavigation {
    public private(set) var selectedCurve: String?
    /// Set when leaving a curve with unsaved edits; the pane asks what to do.
    public var pending: PendingSelection?
    /// The curve being edited, if any, so closing the window can check it.
    @ObservationIgnored public weak var editor: CurveEditorModel?

    public init(selectedCurve: String? = nil) {
        self.selectedCurve = selectedCurve
    }

    public var hasUnsavedEdits: Bool { editor?.draft.isDirty ?? false }

    public func apply(_ destination: SettingsDestination) {
        if case .curve(let name?) = destination {
            request(name)
        }
    }

    /// Selects `name`, unless the current curve has unsaved edits: then the
    /// request waits in `pending` until `confirmPending` or `cancelPending`.
    public func request(_ name: String?) {
        guard name != selectedCurve else { return }
        if hasUnsavedEdits {
            pending = PendingSelection(curve: name)
        } else {
            selectedCurve = name
        }
    }

    /// Selects without asking (after saving or discarding, or when the
    /// selected curve disappeared).
    public func select(_ name: String?) {
        pending = nil
        selectedCurve = name
    }

    public func confirmPending() {
        guard let pending else { return }
        select(pending.curve)
    }

    public func cancelPending() {
        pending = nil
    }
}
