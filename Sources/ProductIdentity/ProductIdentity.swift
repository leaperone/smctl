/// Every name, identifier and path that ties the build to a specific product.
///
/// Keeping them in one dependency-free module lets downstream forks rebrand the
/// CLI, daemon, XPC service, config location and log subsystem by editing this
/// file alone, which keeps merges from upstream conflict-free.
public enum ProductIdentity {
    /// Name of the CLI executable, as typed by the user.
    public static let cliName = "pulse"
    /// Name of the privileged daemon executable.
    public static let daemonName = "pulsed"
    /// Reverse-DNS prefix used for the log subsystem and dispatch queue labels.
    public static let reverseDNS = "com.stormacq.pulse"
    /// XPC mach service name; also the LaunchDaemon label and installed helper name.
    public static let machServiceName = "\(reverseDNS).daemon"
    /// Unified logging subsystem shared by the CLI and the daemon.
    public static let logSubsystem = reverseDNS
    /// Root-owned daemon configuration file.
    public static let configPath = "/etc/pulse/config.toml"
    /// LaunchDaemon property list installed by `daemon install`.
    public static let launchDaemonPlistPath = "/Library/LaunchDaemons/\(machServiceName).plist"
    /// Root-owned copy of the daemon executable that launchd runs.
    public static let installedHelperPath = "/Library/PrivilegedHelperTools/\(machServiceName)"
    /// Plists left by older releases, removed on uninstall.
    public static let legacyLaunchDaemonPlistPaths: [String] = []
    /// GitHub API endpoint the daemon polls for update hints.
    public static let latestReleaseAPIURL = "https://api.github.com/repos/fstormacq/pulse/releases/latest"
    /// The user help, opened from the menu bar popover.
    public static let helpURL = "https://github.com/fstormacq/pulse/blob/main/docs/HELP.md"
    /// The latest release, for a manual download.
    public static let releasesURL = "https://github.com/fstormacq/pulse/releases/latest"
    /// Homebrew cask (the app, with the CLI) and formula (CLI and daemon only), in the tap below.
    public static let homebrewCask = "pulse"
    public static let homebrewFormula = "pulse-cli"
    public static let homebrewTap = "fstormacq/tap"
    /// Always the full names in commands: Homebrew's own repository has an unrelated
    /// cask also called "pulse", which a bare `brew … --cask pulse` would pick.
    public static let homebrewCaskFullName = "\(homebrewTap)/\(homebrewCask)"
    public static let homebrewFormulaFullName = "\(homebrewTap)/\(homebrewFormula)"
    /// Prefix of environment variables read by the daemon and passed to alert commands.
    public static let environmentPrefix = "PULSE"
}
