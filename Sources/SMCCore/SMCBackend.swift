import Foundation

public struct SMCReadValue: Codable, Equatable {
    public var key: String
    public var info: SMCKeyInfo
    public var bytes: [UInt8]

    public init(key: String, info: SMCKeyInfo, bytes: [UInt8]) {
        self.key = key
        self.info = info
        self.bytes = bytes
    }

    public var decoded: SMCDecodedValue? {
        try? SMCDataDecoder.decode(key: key, bytes: bytes, dataType: info.dataType)
    }
}

public protocol SMCBackend {
    func readKeyInfo(_ key: String) throws -> SMCKeyInfo
    func readValue(_ key: String) throws -> SMCReadValue
}
