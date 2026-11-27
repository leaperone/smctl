import Foundation
import ProductIdentity
import SMCtlClient
import SMCtlProtocol

/// After `brew upgrade fstormacq/tap/pulse-cli`, the running daemon is still the old release:
/// `pulse daemon install` copies `pulsed` into a root-owned location that no
/// upgrade touches. The first command that notices replaces it with the copy next
/// to this CLI, through sudo, then goes on.
enum DaemonAutoUpdate {
    /// Opt-out, e.g. for scripts that must never prompt.
    static let disableVariable = "\(ProductIdentity.environmentPrefix)_NO_DAEMON_UPDATE"

    /// Only in an interactive terminal (sudo may ask for a password), never for
    /// machine-readable output, and never from the `daemon` commands themselves.
    static func shouldUpdate(arguments: [String], stdinIsTerminal: Bool, stderrIsTerminal: Bool,
                             environment: [String: String]) -> Bool {
        guard stdinIsTerminal, stderrIsTerminal else { return false }
        guard environment[disableVariable] != "1" else { return false }
        guard !arguments.contains("--json") else { return false }
        if arguments.first(where: { !$0.hasPrefix("-") }) == "daemon" { return false }
        return true
    }

    /// Installs this CLI's daemon over the running one. Returns true on success.
    static func update(installed: String) -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard shouldUpdate(arguments: arguments, stdinIsTerminal: isatty(STDIN_FILENO) == 1,
                           stderrIsTerminal: isatty(STDERR_FILENO) == 1,
                           environment: ProcessInfo.processInfo.environment),
              let executable = currentExecutablePath(),
              smctldPath(besideExecutable: executable, fileExists: { FileManager.default.isExecutableFile(atPath: $0) }) != nil
        else { return false }

        let cli = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        let version = SMCtlProtocolInfo.version
        let asRoot = geteuid() == 0
        printError("\(ProductIdentity.daemonName) \(installed) is older than \(ProductIdentity.cliName) \(version): updating it"
                   + (asRoot ? "…" : " (sudo may ask for your password)…"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: asRoot ? cli : "/usr/bin/sudo")
        process.arguments = (asRoot ? [] : [cli]) + ["daemon", "install"]
        // Keep this command's own output clean: the install's messages go to stderr.
        process.standardOutput = FileHandle.standardError
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            printError("Could not run the update: \(error.localizedDescription)")
            return false
        }
        guard process.terminationStatus == 0 else {
            printError("The update did not complete; \(ProductIdentity.daemonName) \(installed) is still running.")
            return false
        }
        printError("\(ProductIdentity.daemonName) updated to \(version).\n")
        return true
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
