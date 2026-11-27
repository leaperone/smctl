import AppKit
import ProductIdentity
import SwiftUI

/// The popover's notices about the fan control service's version and new releases.
struct UpdateNotices: View {
    let updates: UpdateCenter

    var body: some View {
        switch updates.service {
        case .current:
            EmptyView()
        case .updating(let installed, let available):
            Notice(
                systemImage: "arrow.triangle.2.circlepath",
                tint: .blue,
                title: "Updating the fan control service",
                message: "Enter your password to replace the service (\(installed)) with this version of Pulse (\(available))."
            )
        case .outdated(let installed, let available, let error):
            Notice(
                systemImage: "arrow.triangle.2.circlepath",
                tint: .orange,
                title: "The fan control service is out of date",
                message: "It still runs \(installed), and Pulse is \(available). " + (error ?? "Updating it asks for your password."),
                actionTitle: "Update…",
                action: { updates.updateService() }
            )
        }
        if let version = updates.availableVersion {
            Notice(
                systemImage: "arrow.down.circle",
                tint: .blue,
                title: "Pulse \(version) is available",
                message: updates.channel.upgradeCommand.map { "Upgrade in Terminal: \($0)" }
                    ?? "Download it from GitHub and replace Pulse in Applications.",
                actionTitle: updates.channel.upgradeCommand == nil ? "Download…" : "Copy Command",
                action: { Self.upgrade(with: updates.channel.upgradeCommand) },
                secondaryTitle: "Later",
                secondaryAction: { updates.dismissAvailableVersion() }
            )
        }
    }

    private static func upgrade(with command: String?) {
        if let command {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        } else if let url = URL(string: ProductIdentity.releasesURL) {
            NSWorkspace.shared.open(url)
        }
    }
}
