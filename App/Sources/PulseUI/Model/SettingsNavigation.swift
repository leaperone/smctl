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

/// Selection shared between the settings window controller and its panes. It
/// outlives the window (which is released when closed), so reopening the
/// Curves pane returns to the same curve.
@MainActor
@Observable
public final class SettingsNavigation {
    public var selectedCurve: String?

    public init(selectedCurve: String? = nil) {
        self.selectedCurve = selectedCurve
    }

    public func apply(_ destination: SettingsDestination) {
        if case .curve(let name?) = destination {
            selectedCurve = name
        }
    }
}
