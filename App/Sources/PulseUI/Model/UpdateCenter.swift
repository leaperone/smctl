import Foundation
import Observation
import ProductIdentity
import SMCtlClient
import SMCtlProtocol

/// New releases, and the fan control service after an upgrade.
///
/// An upgrade (Homebrew or a download) replaces Pulse.app, but the daemon runs
/// from a root-owned copy that no upgrade touches. When the running daemon is an
/// older release than the app, the app installs its own `pulsed` over it, once,
/// behind the macOS password prompt. If the prompt is cancelled or the install
/// fails, the popover offers to try again.
@MainActor
@Observable
public final class UpdateCenter {
    public enum ServiceState: Equatable, Sendable {
        /// The daemon runs this app's version, or there is nothing to compare.
        case current
        /// The password prompt is open, or the install is running.
        case updating(installed: String, available: String)
        /// The daemon is older; the automatic update was cancelled or failed.
        case outdated(installed: String, available: String, error: String?)
    }

    public private(set) var service: ServiceState = .current
    /// A release newer than this app (shown in About).
    public private(set) var newerVersion: String?
    /// The same, unless the user chose to hide it (the popover's notice).
    public private(set) var availableVersion: String?
    public let channel: InstallChannel
    public let appVersion: String

    @ObservationIgnored private let installer: @Sendable (_ prompt: String) throws -> Bool
    @ObservationIgnored private let fetchLatest: @Sendable () async -> String?
    @ObservationIgnored private let defaults: UserDefaults
    /// Daemon versions already replaced (or tried) during this run: one prompt each.
    @ObservationIgnored private var attempted: Set<String> = []
    @ObservationIgnored private var latestKnown: String?
    @ObservationIgnored private var lastOwnCheck: Date?
    @ObservationIgnored private var checking = false
    /// Called after the service was replaced, to poll the new daemon at once.
    @ObservationIgnored var onServiceUpdated: (@MainActor () async -> Void)?

    static let dismissedKey = "dismissedUpdateVersion"
    /// Without a daemon (monitoring only) the app asks GitHub itself, at most this often.
    static let ownCheckInterval: TimeInterval = 24 * 60 * 60

    public init(
        appVersion: String = ProductIdentity.version,
        channel: InstallChannel,
        defaults: UserDefaults = .standard,
        installer: @escaping @Sendable (_ prompt: String) throws -> Bool,
        fetchLatest: @escaping @Sendable () async -> String?
    ) {
        self.appVersion = appVersion
        self.channel = channel
        self.defaults = defaults
        self.installer = installer
        self.fetchLatest = fetchLatest
    }

    /// The app's own: installs the bundled daemon and asks GitHub for releases.
    public static func live() -> UpdateCenter {
        UpdateCenter(
            channel: .detect(executablePath: Bundle.main.executablePath ?? Bundle.main.bundlePath),
            installer: { prompt in
                guard ServiceInstaller.helpersAvailable else {
                    throw InstallerError("The bundled \(ProductIdentity.daemonName) was not found in \(ServiceInstaller.helpersDirectory.path).")
                }
                return try ServiceInstaller.installDaemon(prompt: prompt)
            },
            fetchLatest: { await latestRelease() }
        )
    }

    /// Never prompts and never goes online: previews, snapshots and tests.
    public static func inert(appVersion: String = ProductIdentity.version) -> UpdateCenter {
        UpdateCenter(appVersion: appVersion, channel: .download, defaults: UserDefaults(suiteName: "pulse-inert-updates") ?? .standard,
                     installer: { _ in false }, fetchLatest: { nil })
    }

    // MARK: Polling

    /// Called by the store after each poll: `daemonVersion` is nil without a daemon.
    func observe(daemonVersion: String?, latestFromDaemon: String?, now: Date = Date()) {
        if let daemonVersion {
            observeService(daemonVersion: daemonVersion)
        }
        if let latestFromDaemon {
            latestKnown = latestFromDaemon
        } else if daemonVersion == nil, !checking, lastOwnCheck.map({ now.timeIntervalSince($0) >= Self.ownCheckInterval }) ?? true {
            lastOwnCheck = now
            checking = true
            Task {
                let latest = await fetchLatest()
                checking = false
                if let latest { latestKnown = latest }
                updateAvailableVersion()
            }
        }
        updateAvailableVersion()
    }

    private func observeService(daemonVersion: String) {
        if case .updating = service { return }
        guard case .update(let installed, let available) = DaemonUpdateDecision.decide(daemon: daemonVersion, client: appVersion) else {
            if service != .current { service = .current }
            return
        }
        if attempted.insert(installed).inserted {
            replaceService(installed: installed, available: available)
        } else if service == .current {
            service = .outdated(installed: installed, available: available, error: nil)
        }
    }

    // MARK: Actions

    /// The popover's "Update…" after a cancelled or failed automatic update.
    public func updateService() {
        guard case .outdated(let installed, let available, _) = service else { return }
        replaceService(installed: installed, available: available)
    }

    /// Hides the "new version" notice until a newer release comes out.
    public func dismissAvailableVersion() {
        guard let availableVersion else { return }
        defaults.set(availableVersion, forKey: Self.dismissedKey)
        updateAvailableVersion()
    }

    private func replaceService(installed: String, available: String) {
        service = .updating(installed: installed, available: available)
        let installer = self.installer
        let prompt = "Pulse was updated to \(available). Enter your password to update its fan control service too (\(installed) is running)."
        Task {
            let result = await Task.detached { Result { try installer(prompt) } }.value
            switch result {
            case .success(true):
                service = .current
                await onServiceUpdated?()
            case .success(false):
                service = .outdated(installed: installed, available: available, error: nil)
            case .failure(let error):
                service = .outdated(installed: installed, available: available, error: error.localizedDescription)
            }
        }
    }

    private func updateAvailableVersion() {
        var newer: String?
        if let latestKnown, SMCtlProtocolInfo.isVersion(latestKnown, newerThan: appVersion) {
            newer = latestKnown.hasPrefix("v") ? String(latestKnown.dropFirst()) : latestKnown
        }
        let available = newer == defaults.string(forKey: Self.dismissedKey) ? nil : newer
        if newer != newerVersion { newerVersion = newer }
        if available != availableVersion { availableVersion = available }
    }

    // MARK: GitHub

    /// The latest release's tag, or nil on any failure (offline, rate limit…).
    nonisolated static func latestRelease() async -> String? {
        guard let url = URL(string: ProductIdentity.latestReleaseAPIURL) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("\(ProductIdentity.cliName)-app/\(ProductIdentity.version)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["tag_name"] as? String
    }
}
