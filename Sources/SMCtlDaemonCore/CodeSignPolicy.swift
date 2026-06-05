import Foundation
import Security

/// Code-signing based client authorization for the XPC boundary.
///
/// Policy: if the daemon binary itself carries a Developer ID Team ID, every WRITE
/// request must come from a client signed with the SAME Team ID (plus the euid gate).
/// If the daemon is unsigned or ad-hoc signed (local/source builds, e.g. Homebrew
/// from-source), Team ID enforcement is impossible by construction and authorization
/// falls back to the euid gate alone.
enum CodeSignPolicy {
    /// Team ID from the daemon's own signature; nil for unsigned/ad-hoc builds.
    static func ownTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any] else {
            return nil
        }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Validates that the connecting process is signed with `teamID`, anchored to
    /// Apple's Developer ID chain. Identification is by audit token — the only
    /// spoof-resistant handle (PID-based checks are racy by design).
    static func clientMatches(teamID: String, connection: NSXPCConnection) -> Bool {
        var token = connection.smctlAuditToken
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary

        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
            return false
        }

        let requirementString = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            return false
        }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

extension NSXPCConnection {
    /// The peer's audit token. Apple exposes this to XPC services but not (yet) as
    /// public NSXPCConnection API; the KVC accessor is the established pattern used
    /// by privileged-helper implementations. Falls back to an all-zero token (which
    /// can never satisfy a signing requirement) if the accessor disappears.
    var smctlAuditToken: audit_token_t {
        var token = audit_token_t()
        if let value = self.value(forKey: "auditToken") as? NSValue {
            value.getValue(&token)
        }
        return token
    }
}
