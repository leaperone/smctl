import Foundation
import SMCtlProtocol

public final class DaemonClient {
    private let connection: NSXPCConnection

    public init() {
        connection = NSXPCConnection(machServiceName: SMCtlProtocolInfo.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: SMCtlDaemonXPCProtocol.self)
        // Resumed exactly once here; a second resume would trap (over-resume).
        connection.resume()
    }

    deinit {
        connection.invalidate()
    }

    public func ping() throws -> PingDTO {
        try call { proxy, reply in
            proxy.daemonPing(withReply: reply)
        }
    }

    public func getBatteryStatus() throws -> BatteryStatusDTO {
        try call { proxy, reply in
            proxy.getBatteryStatus(withReply: reply)
        }
    }

    public func getFans() throws -> FansStatusDTO {
        try call { proxy, reply in
            proxy.getFans(withReply: reply)
        }
    }

    public func getCapabilities() throws -> CapabilitiesDTO {
        try call { proxy, reply in
            proxy.getCapabilities(withReply: reply)
        }
    }

    public func getDaemonStatus() throws -> DaemonStatusDTO {
        try call { proxy, reply in
            proxy.getDaemonStatus(withReply: reply)
        }
    }

    public func getAlertStatus() throws -> AlertStatusDTO {
        try call { proxy, reply in
            proxy.getAlertStatus(withReply: reply)
        }
    }

    public func testAlert(name: String) throws {
        let data = try SMCtlProtocolCoding.encode(TestAlertRequestDTO(name: name))
        let _: EmptyResponseDTO = try call { proxy, reply in
            proxy.testAlert(data, withReply: reply)
        }
    }

    public func setChargeLimit(_ limit: String, forceDischarge: Bool = false) throws {
        let data = try SMCtlProtocolCoding.encode(SetChargeLimitRequestDTO(limit: limit, forceDischarge: forceDischarge))
        let _: EmptyResponseDTO = try call { proxy, reply in
            proxy.setChargeLimit(data, withReply: reply)
        }
    }

    public func setChargingEnabled(_ enabled: Bool) throws {
        let data = try SMCtlProtocolCoding.encode(SetEnabledRequestDTO(enabled: enabled))
        let _: EmptyResponseDTO = try call { proxy, reply in
            proxy.setChargingEnabled(data, withReply: reply)
        }
    }

    public func setAdapterEnabled(_ enabled: Bool) throws {
        let data = try SMCtlProtocolCoding.encode(SetEnabledRequestDTO(enabled: enabled))
        let _: EmptyResponseDTO = try call { proxy, reply in
            proxy.setAdapterEnabled(data, withReply: reply)
        }
    }

    public func setFanManual(index: Int, rpm: Double, force: Bool) throws {
        let data = try SMCtlProtocolCoding.encode(SetFanManualRequestDTO(index: index, rpm: rpm, force: force))
        let _: EmptyResponseDTO = try call { proxy, reply in
            proxy.setFanManual(data, withReply: reply)
        }
    }

    public func setFanAuto(index: Int?) throws {
        let data = try SMCtlProtocolCoding.encode(SetFanAutoRequestDTO(index: index))
        let _: EmptyResponseDTO = try call { proxy, reply in
            proxy.setFanAuto(data, withReply: reply)
        }
    }

    public func setFanProfile(_ name: String) throws {
        let data = try SMCtlProtocolCoding.encode(SetFanProfileRequestDTO(name: name))
        let _: EmptyResponseDTO = try call { proxy, reply in
            proxy.setFanProfile(data, withReply: reply)
        }
    }

    public func reloadConfig() throws {
        let _: EmptyResponseDTO = try call { proxy, reply in
            proxy.reloadConfig(withReply: reply)
        }
    }

    private func call<T: Decodable>(
        _ body: (SMCtlDaemonXPCProtocol, @escaping (Data?, String?) -> Void) -> Void
    ) throws -> T {
        // Note: the connection is resumed exactly once in init. Resuming an already
        // active NSXPCConnection is an over-resume and traps (SIGTRAP).
        let semaphore = DispatchSemaphore(value: 0)
        let box = XPCResultBox()

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == 4099 {
                // Connection invalidated: the mach service is not registered with launchd.
                box.error = "smctld is not running. Install it with 'sudo smctl daemon install' (check with 'smctl daemon status')."
            } else {
                box.error = String(describing: error)
            }
            semaphore.signal()
        } as? SMCtlDaemonXPCProtocol
        guard let proxy else {
            throw SMCtlClientError("Could not create XPC proxy.")
        }
        body(proxy) { data, error in
            box.data = data
            box.error = error
            semaphore.signal()
        }
        // Bounded wait: never hang the CLI on a wedged daemon or undelivered message.
        if semaphore.wait(timeout: .now() + 15) == .timedOut {
            throw SMCtlClientError("Timed out waiting for smctld (15s). Check 'smctl daemon status'.")
        }

        if let error = box.error {
            throw SMCtlClientError(error)
        }
        guard let data = box.data else {
            throw SMCtlClientError("Daemon returned no data.")
        }
        let result = try SMCtlProtocolCoding.decode(T.self, from: data)
        warnOnVersionIssues(result)
        return result
    }

    /// Two stderr hints, checked once per client, both sourced from the
    /// daemon's ping (piggybacked on the command's own reply when it is a PingDTO,
    /// otherwise via one extra ping):
    ///   - version skew: brew swaps binaries but never restarts the daemon, so a
    ///     stale daemon keeps serving safety fixes that are not actually active
    ///     (observed live: a 0.1.2 daemon served a 0.1.5 CLI for three releases).
    ///   - update available: the daemon's daily check found a newer release.
    private var versionChecked = false

    private func warnOnVersionIssues<T>(_ result: T) {
        guard !versionChecked else { return }
        versionChecked = true  // set before any nested call() to prevent recursion

        let ping: PingDTO?
        if let p = result as? PingDTO {
            ping = p
        } else {
            ping = try? call { proxy, reply in
                proxy.daemonPing(withReply: reply)
            }
        }
        guard let ping else { return }

        if ping.version != SMCtlProtocolInfo.version {
            emit("""
            warning: smctl is \(SMCtlProtocolInfo.version) but the running smctld is \(ping.version).
            Fixes in this version are NOT active until the daemon restarts:
              sudo smctl daemon restart
            """)
        } else if let latest = ping.latestVersion,
                  SMCtlProtocolInfo.isVersion(latest, newerThan: SMCtlProtocolInfo.version) {
            emit("""
            note: smctl \(latest) is available (you have \(SMCtlProtocolInfo.version)). Upgrade:
              brew upgrade smctl && sudo smctl daemon restart
            """)
        }
    }

    private func emit(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n\n").utf8))
    }
}

private final class XPCResultBox: @unchecked Sendable {
    var data: Data?
    var error: String?
}
