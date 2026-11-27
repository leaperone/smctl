import Foundation
import ProductIdentity
import SMCtlProtocol

/// How this copy of Pulse was installed, which decides how to upgrade it.
public enum InstallChannel: Equatable, Sendable {
    /// `brew install --cask pulse`: the app, with the CLI inside it.
    case cask
    /// `brew install pulse-cli`: the CLI and the daemon only.
    case formula
    /// Pulse.app downloaded from the GitHub releases.
    case download
    /// Built from a clone of the repository.
    case source

    /// The channel of the executable at `executablePath`: the `pulse` CLI, or
    /// the app's own executable. Symbolic links (Homebrew's `bin`) are resolved.
    public static func detect(
        executablePath: String,
        resolve: (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> InstallChannel {
        let path = resolve(executablePath)
        if path.contains("/Cellar/\(ProductIdentity.homebrewFormula)/") { return .formula }
        guard path.contains(".app/Contents/") else { return .source }
        let caskrooms = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]
        return caskrooms.contains { fileExists("\($0)/\(ProductIdentity.homebrewCask)") } ? .cask : .download
    }

    /// The shell command that upgrades Pulse, or nil when the upgrade is a download.
    public var upgradeCommand: String? {
        switch self {
        case .cask: "brew upgrade --cask \(ProductIdentity.homebrewCask)"
        case .formula: "brew upgrade \(ProductIdentity.homebrewFormula)"
        case .download: nil
        case .source: "git pull && make app"
        }
    }

    /// One sentence on how to upgrade, for the CLI and the app.
    public var upgradeHint: String {
        if let upgradeCommand { return "Upgrade with: \(upgradeCommand)" }
        return "Download it from \(ProductIdentity.releasesURL)"
    }
}

/// What to do when the running daemon's version differs from the client's.
public enum DaemonUpdateDecision: Equatable, Sendable {
    /// Same version, or nothing to compare.
    case none
    /// Both are releases and the client is newer: replace the daemon with the
    /// client's copy of `pulsed` (`pulse daemon install`).
    case update(installed: String, available: String)
    /// Any other difference (an older client, a development build): warn only,
    /// never replace a daemon with an older or unversioned one.
    case mismatch(installed: String, client: String)

    public static func decide(daemon: String, client: String) -> DaemonUpdateDecision {
        guard !daemon.isEmpty, daemon != client else { return .none }
        if SMCtlProtocolInfo.isVersion(client, newerThan: daemon) {
            return .update(installed: daemon, available: client)
        }
        return .mismatch(installed: daemon, client: client)
    }
}
