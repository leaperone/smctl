import XCTest
import Darwin
@testable import smctl

final class DaemonInstallPathTests: XCTestCase {
    func testInstalledHelperIsAnIndependentRegularFile() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        defer { try? manager.removeItem(at: root) }
        let source = root.appendingPathComponent("smctld-source")
        let link = root.appendingPathComponent("smctld-link")
        let destination = root.appendingPathComponent("protected/smctld")
        try Data("original helper".utf8).write(to: source)
        try manager.createSymbolicLink(at: link, withDestinationURL: source)

        try DaemonInstall.installHelper(from: link, to: destination)
        try Data("replaced source".utf8).write(to: source)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "original helper")
        var info = stat()
        XCTAssertEqual(lstat(destination.path, &info), 0)
        XCTAssertEqual(info.st_mode & mode_t(S_IFMT), mode_t(S_IFREG))
        XCTAssertEqual(info.st_mode & 0o777, 0o755)
        XCTAssertEqual(info.st_uid, geteuid())

        try DaemonInstall.installHelper(from: link, to: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "replaced source")
    }

    func testInstallerRejectsWritableOrSymlinkDirectories() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        defer { try? manager.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try Data("helper".utf8).write(to: source)
        let writable = root.appendingPathComponent("writable")
        try manager.createDirectory(at: writable, withIntermediateDirectories: false)
        try manager.setAttributes([.posixPermissions: 0o777], ofItemAtPath: writable.path)
        XCTAssertThrowsError(try DaemonInstall.installHelper(from: source, to: writable.appendingPathComponent("helper")))
        let link = root.appendingPathComponent("link")
        try manager.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try DaemonInstall.installHelper(from: source, to: link.appendingPathComponent("helper")))
        XCTAssertFalse(manager.fileExists(atPath: writable.appendingPathComponent("helper").path))
    }

    func testLaunchDaemonExecutesTheProtectedCopy() throws {
        let data = Data(try DaemonInstall.plist().utf8)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/Library/PrivilegedHelperTools/one.leaper.smctl.daemon"])
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
    }

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
