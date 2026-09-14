import Testing
import SMCtlClient
import SMCtlProtocol

@Test
func setChargeLimitRequestRoundTrip() throws {
    let request = SetChargeLimitRequestDTO(limit: "80", forceDischarge: true)
    let data = try SMCtlProtocolCoding.encode(request)
    #expect(try SMCtlProtocolCoding.decode(SetChargeLimitRequestDTO.self, from: data) == request)
    #expect(String(data: data, encoding: .utf8) == #"{"forceDischarge":true,"limit":"80"}"#)
}

@Test
func setChargeLimitRequestOmitsNilForceDischarge() throws {
    let request = SetChargeLimitRequestDTO(limit: "hold")
    let data = try SMCtlProtocolCoding.encode(request)
    #expect(try SMCtlProtocolCoding.decode(SetChargeLimitRequestDTO.self, from: data) == request)
    #expect(String(data: data, encoding: .utf8) == #"{"limit":"hold"}"#)
}

@Test
func setFanManualRequestRoundTrip() throws {
    let request = SetFanManualRequestDTO(index: 1, rpm: 3200, force: true)
    let data = try SMCtlProtocolCoding.encode(request)
    #expect(try SMCtlProtocolCoding.decode(SetFanManualRequestDTO.self, from: data) == request)
    #expect(String(data: data, encoding: .utf8) == #"{"force":true,"index":1,"rpm":3200}"#)
}

@Test
func clientErrorHasNonEmptyDescription() {
    let error = SMCtlClientError("smctld is not running.")
    #expect(error.errorDescription == "smctld is not running.")
    #expect(!error.localizedDescription.isEmpty)
}
