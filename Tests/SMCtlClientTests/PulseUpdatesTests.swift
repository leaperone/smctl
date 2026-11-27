import XCTest
@testable import SMCtlClient

final class PulseUpdatesTests: XCTestCase {
    private func channel(_ path: String, resolvedTo resolved: String? = nil, caskroom: Bool = false) -> InstallChannel {
        InstallChannel.detect(
            executablePath: path,
            resolve: { _ in resolved ?? path },
            fileExists: { caskroom && $0 == "/opt/homebrew/Caskroom/pulse" },
            home: "/Users/me"
        )
    }

    func testChannels() {
        XCTAssertEqual(channel("/opt/homebrew/bin/pulse", resolvedTo: "/opt/homebrew/Cellar/pulse-cli/1.0.0/bin/pulse"), .formula)
        XCTAssertEqual(channel("/opt/homebrew/bin/pulse", resolvedTo: "/Applications/Pulse.app/Contents/Helpers/pulse", caskroom: true), .cask)
        XCTAssertEqual(channel("/Applications/Pulse.app/Contents/MacOS/Pulse", caskroom: true), .cask)
        XCTAssertEqual(channel("/Applications/Pulse.app/Contents/MacOS/Pulse"), .download)
        XCTAssertEqual(channel("/usr/local/bin/pulse", resolvedTo: "/Users/me/Downloads/Pulse.app/Contents/Helpers/pulse"), .download)
        XCTAssertEqual(channel("/Users/me/pulse/.build/release/pulse"), .source)
        XCTAssertEqual(channel("/Users/me/Applications/Pulse.app/Contents/MacOS/Pulse", caskroom: true), .cask)
        XCTAssertEqual(channel("/Users/me/Downloads/Pulse.app/Contents/MacOS/Pulse", caskroom: true), .download,
                       "a \"pulse\" Caskroom entry with Pulse outside Applications is Homebrew's other pulse")
    }

    func testUpgradeHints() {
        XCTAssertEqual(InstallChannel.cask.upgradeCommand, "brew upgrade --cask fstormacq/tap/pulse")
        XCTAssertEqual(InstallChannel.formula.upgradeCommand, "brew upgrade fstormacq/tap/pulse-cli")
        XCTAssertNil(InstallChannel.download.upgradeCommand)
        XCTAssertTrue(InstallChannel.download.upgradeHint.contains("github.com/fstormacq/pulse/releases"))
    }

    func testDaemonUpdateOnlyBetweenReleasesAndForward() {
        XCTAssertEqual(DaemonUpdateDecision.decide(daemon: "1.0.0", client: "1.0.0"), .none)
        XCTAssertEqual(DaemonUpdateDecision.decide(daemon: "", client: "1.0.0"), .none, "no daemon version (read-only mode)")
        XCTAssertEqual(DaemonUpdateDecision.decide(daemon: "1.0.0", client: "1.1.0"), .update(installed: "1.0.0", available: "1.1.0"))
        XCTAssertEqual(DaemonUpdateDecision.decide(daemon: "0.2.4", client: "1.0.0"), .update(installed: "0.2.4", available: "1.0.0"))
        XCTAssertEqual(DaemonUpdateDecision.decide(daemon: "1.1.0", client: "1.0.0"), .mismatch(installed: "1.1.0", client: "1.0.0"),
                       "never downgrade the daemon")
        XCTAssertEqual(DaemonUpdateDecision.decide(daemon: "1.0.0", client: "0.0.0-dev"), .mismatch(installed: "1.0.0", client: "0.0.0-dev"),
                       "a development build never replaces a release")
        XCTAssertEqual(DaemonUpdateDecision.decide(daemon: "0.0.0-dev", client: "1.0.0"), .mismatch(installed: "0.0.0-dev", client: "1.0.0"),
                       "nor is a development daemon replaced behind the developer's back")
    }
}
