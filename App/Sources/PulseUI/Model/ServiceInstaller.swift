import AppKit
import Foundation
import ProductIdentity
import ServiceManagement

/// Installs the privileged daemon and the `pulse` CLI using the binaries bundled
/// in Pulse.app/Contents/Helpers, after the standard macOS administrator prompt.
public enum ServiceInstaller {
    public static let cliLinkPath = "/usr/local/bin/\(ProductIdentity.cliName)"

    /// `Contents/Helpers` inside the app bundle. During development (swift run),
    /// set PULSE_HELPERS_DIR to the core package's `.build/release`.
    public static var helpersDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["PULSE_HELPERS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
    }

    public static var bundledCLI: URL {
        helpersDirectory.appendingPathComponent(ProductIdentity.cliName)
    }

    public static var helpersAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: bundledCLI.path)
            && FileManager.default.isExecutableFile(atPath: helpersDirectory.appendingPathComponent(ProductIdentity.daemonName).path)
    }

    public static var cliLinkInstalled: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: cliLinkPath)) == bundledCLI.path
    }

    public static func installDaemon() throws {
        try runAsAdministrator(shellCommand([bundledCLI.path, "daemon", "install"]))
    }

    public static func uninstallDaemon() throws {
        try runAsAdministrator(shellCommand([bundledCLI.path, "daemon", "uninstall"]))
    }

    /// Links /usr/local/bin/pulse to the bundled CLI, for Terminal and SSH.
    public static func installCLILink() throws {
        let directory = (cliLinkPath as NSString).deletingLastPathComponent
        try runAsAdministrator(
            shellCommand(["/bin/mkdir", "-p", directory]) + " && " + shellCommand(["/bin/ln", "-sf", bundledCLI.path, cliLinkPath])
        )
    }

    // MARK: Launch at login

    public static var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static func setLaunchesAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    // MARK: Helpers

    /// POSIX shell quoting: every argument single-quoted.
    static func shellCommand(_ arguments: [String]) -> String {
        arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }

    /// AppleScript string literal for `command`.
    static func appleScriptLiteral(_ command: String) -> String {
        "\"" + command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func runAsAdministrator(_ command: String) throws {
        guard helpersAvailable else {
            throw InstallerError("The bundled \(ProductIdentity.cliName) helpers were not found in \(helpersDirectory.path).")
        }
        let source = "do shell script \(appleScriptLiteral(command)) with administrator privileges"
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw InstallerError("Could not prepare the installer script.")
        }
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            // -128: the user cancelled the password prompt.
            if (errorInfo[NSAppleScript.errorNumber] as? Int) == -128 { return }
            throw InstallerError(errorInfo[NSAppleScript.errorMessage] as? String ?? "Installation failed.")
        }
    }
}

public struct InstallerError: LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
