import XCTest
@testable import smctl

final class DaemonInstallPathTests: XCTestCase {
    func testResolvesSmctldNextToExecutable() {
        let path = smctldPath(
            besideExecutable: "/opt/homebrew/bin/smctl",
            fileExists: { $0 == "/opt/homebrew/bin/smctld" }
        )
        XCTAssertEqual(path, "/opt/homebrew/bin/smctld")
    }

    func testKeepsSymlinkDirectorySoItSurvivesBrewUpgrade() {
        // Must NOT resolve /opt/homebrew/bin's symlink to the versioned Cellar path;
        // the LaunchDaemon points at the stable symlink directory (#8).
        let path = smctldPath(
            besideExecutable: "/opt/homebrew/bin/smctl",
            fileExists: { _ in true }
        )
        XCTAssertEqual(path, "/opt/homebrew/bin/smctld")
    }

    func testReturnsNilWhenSiblingMissing() {
        XCTAssertNil(
            smctldPath(besideExecutable: "/usr/local/bin/smctl", fileExists: { _ in false })
        )
    }

    func testNormalizesRelativeComponents() {
        let path = smctldPath(
            besideExecutable: "/opt/homebrew/bin/./smctl",
            fileExists: { $0 == "/opt/homebrew/bin/smctld" }
        )
        XCTAssertEqual(path, "/opt/homebrew/bin/smctld")
    }
}
