import Foundation
import PolicyEngine
import SMCtlProtocol

/// Pulse calls on the shared daemon connection.
extension DaemonClient {
    public func getTelemetry() throws -> TelemetryDTO {
        try call { proxy, reply in
            proxy.getTelemetry(withReply: reply)
        }
    }

    public func listFanCurves() throws -> FanCurveListDTO {
        try call { proxy, reply in
            proxy.listFanCurves(withReply: reply)
        }
    }

    public func upsertFanCurve(_ spec: FanCurveSpec, activate: Bool = false) throws {
        let data = try SMCtlProtocolCoding.encode(UpsertFanCurveRequestDTO(spec: spec, activate: activate))
        let _: EmptyResponseDTO = try call { proxy, reply in
            proxy.upsertFanCurve(data, withReply: reply)
        }
    }

    public func setSamplingInterval(seconds: Int) throws {
        let data = try SMCtlProtocolCoding.encode(SetSamplingIntervalRequestDTO(seconds: seconds))
        let _: EmptyResponseDTO = try call { proxy, reply in
            proxy.setSamplingInterval(data, withReply: reply)
        }
    }

    public func deleteFanCurve(named name: String) throws {
        let data = try SMCtlProtocolCoding.encode(DeleteFanCurveRequestDTO(name: name))
        let _: EmptyResponseDTO = try call { proxy, reply in
            proxy.deleteFanCurve(data, withReply: reply)
        }
    }
}
