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

    /// Returns false when the user cancelled the password prompt. `prompt`
    /// replaces the first line of the macOS dialog.
    @discardableResult
    public static func installDaemon(prompt: String? = nil) throws -> Bool {
        try runAsAdministrator(shellCommand([bundledCLI.path, "daemon", "install"]), prompt: prompt)
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

    /// Runs `command` as root after the standard administrator prompt. Runs
    /// osascript in a child process: NSAppleScript had to run on the main
    /// thread, which froze the app for as long as the prompt was open.
    @discardableResult
    private static func runAsAdministrator(_ command: String, prompt: String? = nil) throws -> Bool {
        guard helpersAvailable else {
            throw InstallerError("The bundled \(ProductIdentity.cliName) helpers were not found in \(helpersDirectory.path).")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let promptClause = prompt.map { " with prompt \(appleScriptLiteral($0))" } ?? ""
        process.arguments = ["-e", "do shell script \(appleScriptLiteral(command))\(promptClause) with administrator privileges"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return true }
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // -128: the user cancelled the password prompt.
        if message.hasSuffix("(-128)") { return false }
        throw InstallerError(cleanMessage(message))
    }

    /// "0:42: execution error: Some text (1)" → "Some text".
    static func cleanMessage(_ message: String) -> String {
        var text = message
        if let range = text.range(of: "execution error: ") { text = String(text[range.upperBound...]) }
        if let range = text.range(of: #" \(-?\d+\)$"#, options: .regularExpression) { text.removeSubrange(range) }
        return text.isEmpty ? "Installation failed." : text
    }
}

public struct InstallerError: LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
