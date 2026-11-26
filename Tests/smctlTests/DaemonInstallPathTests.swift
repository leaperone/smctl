import XCTest
import Darwin
import ProductIdentity
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
        let sourceACL = try XCTUnwrap(acl_get_file(source.path, ACL_TYPE_EXTENDED))
        defer { acl_free(UnsafeMutableRawPointer(sourceACL)) }
        var sourceEntry: acl_entry_t?
        XCTAssertEqual(acl_get_entry(sourceACL, ACL_FIRST_ENTRY.rawValue, &sourceEntry), 0)
        try manager.createSymbolicLink(at: link, withDestinationURL: source)

        try DaemonInstall.installHelper(from: link, to: destination)
        try Data("replaced source".utf8).write(to: source)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "original helper")
        var info = stat()
        XCTAssertEqual(lstat(destination.path, &info), 0)
        XCTAssertEqual(info.st_mode & mode_t(S_IFMT), mode_t(S_IFREG))
        XCTAssertEqual(info.st_mode & 0o777, 0o755)
        XCTAssertEqual(info.st_uid, geteuid())
        if let acl = acl_get_file(destination.path, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t?
            XCTAssertEqual(acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry), -1, "the protected copy must not retain source ACLs")
        } else {
            XCTAssertEqual(errno, ENOENT)
        }

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
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [ProductIdentity.installedHelperPath])
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
    }

    func testResolvesSmctldNextToExecutable() {
        let path = smctldPath(
            besideExecutable: "/opt/homebrew/bin/\(ProductIdentity.cliName)",
            fileExists: { $0 == "/opt/homebrew/bin/\(ProductIdentity.daemonName)" }
        )
        XCTAssertEqual(path, "/opt/homebrew/bin/\(ProductIdentity.daemonName)")
    }

    func testKeepsSymlinkDirectorySoItSurvivesBrewUpgrade() {
        // Must NOT resolve /opt/homebrew/bin's symlink to the versioned Cellar path;
        // the LaunchDaemon points at the stable symlink directory (#8).
        let path = smctldPath(
            besideExecutable: "/opt/homebrew/bin/\(ProductIdentity.cliName)",
            fileExists: { _ in true }
        )
        XCTAssertEqual(path, "/opt/homebrew/bin/\(ProductIdentity.daemonName)")
    }

    func testReturnsNilWhenSiblingMissing() {
        XCTAssertNil(
            smctldPath(besideExecutable: "/usr/local/bin/\(ProductIdentity.cliName)", fileExists: { _ in false })
        )
    }

    func testNormalizesRelativeComponents() {
        let path = smctldPath(
            besideExecutable: "/opt/homebrew/bin/./\(ProductIdentity.cliName)",
            fileExists: { $0 == "/opt/homebrew/bin/\(ProductIdentity.daemonName)" }
        )
        XCTAssertEqual(path, "/opt/homebrew/bin/\(ProductIdentity.daemonName)")
    }

    func testDaemonFoundThroughTheCLILinkIntoTheApp() {
        let app = "/Applications/Pulse.app/Contents/Helpers"
        let exists: (String) -> Bool = { $0 == "\(app)/\(ProductIdentity.daemonName)" }
        XCTAssertEqual(
            smctldPath(besideExecutable: "/usr/local/bin/pulse", resolve: { _ in "\(app)/pulse" }, fileExists: exists),
            "\(app)/\(ProductIdentity.daemonName)",
            "pulse run through /usr/local/bin finds the daemon inside the app"
        )
        let brew: (String) -> Bool = { $0 == "/opt/homebrew/bin/\(ProductIdentity.daemonName)" }
        XCTAssertEqual(
            smctldPath(besideExecutable: "/opt/homebrew/bin/pulse", resolve: { _ in "/opt/homebrew/Cellar/pulse/1/bin/pulse" }, fileExists: brew),
            "/opt/homebrew/bin/\(ProductIdentity.daemonName)",
            "the unresolved path still wins, so Homebrew upgrades keep a valid LaunchDaemon"
        )
        XCTAssertNil(smctldPath(besideExecutable: "/usr/local/bin/pulse", resolve: { $0 }, fileExists: { _ in false }))
    }
}
