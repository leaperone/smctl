import SMCtlProtocol

/// User-facing advice for a CLI/daemon version mismatch.
///
/// The helper outlives `brew upgrade`, so a mismatch is routine. The advice has to
/// depend on *which* side is older: telling a user whose daemon is newer to reinstall
/// the helper from an older CLI silently downgrades the daemon — including safety
/// fixes. Previously the message always assumed the CLI was the newer side.
public enum VersionSkew {
    public enum Direction: Equatable, Sendable {
        /// The CLI is newer: the installed helper needs updating.
        case clientNewer
        /// The daemon is newer: the CLI needs updating, not the daemon.
        case daemonNewer
        /// Not comparable (e.g. a malformed version): say so instead of guessing.
        case divergent
    }

    public static func direction(client: String, daemon: String) -> Direction? {
        if client == daemon {
            return nil
        }
        if SMCtlProtocolInfo.isVersion(client, newerThan: daemon) {
            return .clientNewer
        }
        if SMCtlProtocolInfo.isVersion(daemon, newerThan: client) {
            return .daemonNewer
        }
        return .divergent
    }

    public static func message(client: String, daemon: String) -> String? {
        switch direction(client: client, daemon: daemon) {
        case nil:
            return nil
        case .clientNewer:
            return """
            warning: smctl is \(client) but the running smctld is \(daemon).
            Install this version of the protected helper and restart the daemon:
              sudo smctl daemon install
            """
        case .daemonNewer:
            return """
            note: the running smctld is \(daemon), newer than this smctl (\(client)).
            Upgrade the client; reinstalling the helper from this older build would replace it:
              brew upgrade smctl
            """
        case .divergent:
            return """
            warning: smctl is \(client) but the running smctld is \(daemon); the versions differ.
            Align them before relying on version-specific behaviour:
              brew upgrade smctl && sudo smctl daemon install
            """
        }
    }
}
