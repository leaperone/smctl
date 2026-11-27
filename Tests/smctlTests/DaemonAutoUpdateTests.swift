import XCTest
@testable import smctl

final class DaemonAutoUpdateTests: XCTestCase {
    private func should(_ arguments: [String], stdin: Bool = true, stderr: Bool = true, env: [String: String] = [:]) -> Bool {
        DaemonAutoUpdate.shouldUpdate(arguments: arguments, stdinIsTerminal: stdin, stderrIsTerminal: stderr, environment: env)
    }

    func testUpdatesFromAnInteractiveCommand() {
        XCTAssertTrue(should(["status"]))
        XCTAssertTrue(should(["fan", "profile", "balanced"]))
    }

    func testNeverWithoutATerminal() {
        XCTAssertFalse(should(["status"], stdin: false), "sudo could not ask for the password")
        XCTAssertFalse(should(["status"], stderr: false))
    }

    func testNeverForScriptsOrDaemonCommands() {
        XCTAssertFalse(should(["status", "--json"]))
        XCTAssertFalse(should(["daemon", "uninstall"]))
        XCTAssertFalse(should(["daemon", "status"]))
        XCTAssertFalse(should(["status"], env: ["PULSE_NO_DAEMON_UPDATE": "1"]))
    }
}
