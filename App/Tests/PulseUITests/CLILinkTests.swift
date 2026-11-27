import Testing
@testable import PulseUI

struct CLILinkTests {
    private let app = "/Applications/Pulse.app/Contents/Helpers/pulse"

    private func linked(_ links: [String: String]) -> String? {
        ServiceInstaller.linkedCLIPath(target: app) { path in path == app ? app : links[path] }
    }

    @Test func homebrewLinkCounts() {
        #expect(linked(["/opt/homebrew/bin/pulse": app]) == "/opt/homebrew/bin/pulse")
    }

    @Test func settingsLinkCounts() {
        #expect(linked(["/usr/local/bin/pulse": app]) == "/usr/local/bin/pulse")
    }

    @Test func anotherPulseDoesNot() {
        // A link to another copy (a development build, the pulse-cli formula) is not this app's CLI.
        #expect(linked(["/usr/local/bin/pulse": "/Users/me/pulse/dist/Pulse.app/Contents/Helpers/pulse",
                        "/opt/homebrew/bin/pulse": "/opt/homebrew/Cellar/pulse-cli/1.0.1/bin/pulse"]) == nil)
        #expect(linked([:]) == nil)
    }
}
