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
        try addACL("everyone allow write,append,writeattr,writeextattr", to: source)
        try manager.createSymbolicLink(at: link, withDestinationURL: source)

        try DaemonInstall.installHelper(from: link, to: destination)
        try Data("replaced source".utf8).write(to: source)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "original helper")
        var info = stat()
        XCTAssertEqual(lstat(destination.path, &info), 0)
        XCTAssertEqual(info.st_mode & mode_t(S_IFMT), mode_t(S_IFREG))
        XCTAssertEqual(info.st_mode & 0o777, 0o755)
        XCTAssertEqual(info.st_uid, geteuid())
        let acl = try XCTUnwrap(acl_get_file(destination.path, ACL_TYPE_EXTENDED))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        XCTAssertEqual(acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry), -1, "the protected copy must not retain source ACLs")

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
        let aclDirectory = root.appendingPathComponent("acl-directory")
        try manager.createDirectory(at: aclDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        try addACL("everyone allow add_file,delete_child", to: aclDirectory)
        XCTAssertThrowsError(try DaemonInstall.installHelper(from: source, to: aclDirectory.appendingPathComponent("helper")))
        XCTAssertFalse(manager.fileExists(atPath: writable.appendingPathComponent("helper").path))
    }

    private func addACL(_ acl: String, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", acl, url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "ACL fixture must be applied")
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
