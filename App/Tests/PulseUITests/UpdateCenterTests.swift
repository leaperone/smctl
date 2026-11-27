import Foundation
import SMCtlClient
import Testing
@testable import PulseUI

/// Records the installer's calls and answers with `result`.
private final class FakeInstaller: @unchecked Sendable {
    private let lock = NSLock()
    private var _prompts: [String] = []
    var result: Result<Bool, Error> = .success(true)
    var prompts: [String] { lock.withLock { _prompts } }

    func install(_ prompt: String) throws -> Bool {
        lock.withLock { _prompts.append(prompt) }
        return try result.get()
    }
}

@MainActor
struct UpdateCenterTests {
    private func center(app: String = "1.1.0", installer: FakeInstaller = FakeInstaller(), latest: String? = nil,
                        defaults: UserDefaults = UserDefaults(suiteName: "UpdateCenterTests-\(UUID())")!) -> UpdateCenter {
        UpdateCenter(appVersion: app, channel: .cask, defaults: defaults,
                     installer: { try installer.install($0) }, fetchLatest: { latest })
    }

    /// The installer runs in a detached task: wait for its result.
    private func settle(_ center: UpdateCenter) async {
        for _ in 0..<200 {
            if case .updating = center.service { try? await Task.sleep(for: .milliseconds(5)) } else { return }
        }
    }

    @Test func olderDaemonIsReplacedOnceAutomatically() async {
        let installer = FakeInstaller()
        let updates = center(installer: installer)
        var refreshed = 0
        updates.onServiceUpdated = { refreshed += 1 }
        updates.observe(daemonVersion: "1.0.0", latestFromDaemon: nil)
        #expect(updates.service == .updating(installed: "1.0.0", available: "1.1.0"))
        await settle(updates)
        #expect(updates.service == .current)
        #expect(installer.prompts.count == 1)
        #expect(installer.prompts.first?.contains("1.1.0") == true)
        #expect(refreshed == 1)
        updates.observe(daemonVersion: "1.1.0", latestFromDaemon: nil)
        #expect(updates.service == .current)
        #expect(installer.prompts.count == 1)
    }

    @Test func cancelledPromptOffersARetryButDoesNotNag() async {
        let installer = FakeInstaller()
        installer.result = .success(false)
        let updates = center(installer: installer)
        updates.observe(daemonVersion: "1.0.0", latestFromDaemon: nil)
        await settle(updates)
        #expect(updates.service == .outdated(installed: "1.0.0", available: "1.1.0", error: nil))
        updates.observe(daemonVersion: "1.0.0", latestFromDaemon: nil)
        #expect(installer.prompts.count == 1, "one automatic prompt per daemon version")
        installer.result = .success(true)
        updates.updateService()
        await settle(updates)
        #expect(updates.service == .current)
        #expect(installer.prompts.count == 2)
    }

    @Test func failureIsShown() async {
        let installer = FakeInstaller()
        installer.result = .failure(InstallerError("boom"))
        let updates = center(installer: installer)
        updates.observe(daemonVersion: "1.0.0", latestFromDaemon: nil)
        await settle(updates)
        #expect(updates.service == .outdated(installed: "1.0.0", available: "1.1.0", error: "boom"))
    }

    @Test func neverDowngradesNorTouchesDevelopmentBuilds() async {
        let installer = FakeInstaller()
        for (app, daemon) in [("1.0.0", "1.1.0"), ("0.0.0-dev", "1.0.0"), ("1.0.0", "0.0.0-dev"), ("1.0.0", "1.0.0")] {
            let updates = center(app: app, installer: installer)
            updates.observe(daemonVersion: daemon, latestFromDaemon: nil)
            #expect(updates.service == .current, "\(app) app, \(daemon) daemon")
        }
        #expect(installer.prompts.isEmpty)
    }

    @Test func newReleaseFromTheDaemonCanBeHidden() {
        let updates = center(app: "1.0.0")
        updates.observe(daemonVersion: "1.0.0", latestFromDaemon: "v1.2.0")
        #expect(updates.availableVersion == "1.2.0")
        updates.dismissAvailableVersion()
        #expect(updates.availableVersion == nil)
        #expect(updates.newerVersion == "1.2.0", "About still shows it")
        updates.observe(daemonVersion: "1.0.0", latestFromDaemon: "v1.3.0")
        #expect(updates.availableVersion == "1.3.0", "a newer release shows again")
        updates.observe(daemonVersion: "1.0.0", latestFromDaemon: "v1.0.0")
        #expect(updates.availableVersion == nil)
    }

    @Test func withoutADaemonTheAppChecksItselfDaily() async {
        let updates = center(app: "1.0.0", latest: "v1.0.1")
        let start = Date()
        updates.observe(daemonVersion: nil, latestFromDaemon: nil, now: start)
        for _ in 0..<200 where updates.availableVersion == nil { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(updates.availableVersion == "1.0.1")
        #expect(updates.service == .current)
    }

    @Test func storeFeedsTheUpdateCenter() async {
        // SampleService reports daemon 0.2.4; an app at 1.0.0 replaces it.
        let installer = FakeInstaller()
        let store = PulseStore(service: SampleService(), fallback: nil, updates: center(app: "1.0.0", installer: installer))
        await store.refresh()
        await settle(store.updates)
        #expect(installer.prompts.count == 1)
    }
}
